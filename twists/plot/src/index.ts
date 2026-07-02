import {
  type Action,
  ActionType,
  type Actor,
  type Note,
  type Serializable,
  Tag,
  type ToolBuilder,
  Twist,
  Uuid,
} from "@plotday/twister";
import { AI } from "@plotday/twister/tools/ai";
import {
  FocusAccess,
  Plot,
  ThreadAccess,
} from "@plotday/twister/tools/plot";

import { buildActions } from "./actions";
import {
  type ChatMessage,
  buildMessages,
  partitionHistory,
  withSummary,
} from "./messages";
import {
  OPERATIONS_SCHEMA,
  PLANNER_SYSTEM_PROMPT,
  buildPlannerPrompt,
  describeOperation,
  summarizeOperations,
  validateOperations,
} from "./planner";
import { TurnProgress } from "./progress";
import { SYSTEM_PROMPT } from "./prompt";
import { isTransientAiError, promptWithRetry } from "./retry";
import { buildAgentTools, type AgentToolContext } from "./tools";

class PlotTwist extends Twist<PlotTwist> {
  build(build: ToolBuilder) {
    return {
      plot: build(Plot, {
        thread: {
          access: ThreadAccess.Full,
        },
        note: {
          defaultMention: true,
          // Single conversational handler: every mention routes here, so the
          // assistant responds to anything (no fixed intent menu, no dead-end).
          handler: this.respond,
        },
        focus: {
          access: FocusAccess.Full,
        },
        search: true,
        requireApproval: true,
      }),
      ai: build(AI, { required: false }),
    };
  }

  async activate(_context?: { actor: Actor }) {
    // Onboarding threads are created globally and made visible to all users
    // via the "Everyone" topic.
  }

  /**
   * Conversational entry point. Acquires a per-thread lock so overlapping
   * mentions (e.g. rapid-fire messages) don't run concurrent turns against
   * the same thread, then delegates to {@link respondLocked}.
   */
  async respond(note: Note): Promise<void> {
    const thread = note.thread;
    const lockKey = `respond:${thread.id}`;
    let locked = await this.tools.store.acquireLock(lockKey, 120_000);
    for (let attempt = 0; !locked && attempt < 9; attempt++) {
      await new Promise((resolve) => setTimeout(resolve, 5_000));
      locked = await this.tools.store.acquireLock(lockKey, 120_000);
    }
    // If still locked after ~45s the holder likely crashed mid-TTL; proceed
    // anyway rather than dropping the user's message.
    try {
      await this.respondLocked(note);
    } finally {
      if (locked) await this.tools.store.releaseLock(lockKey);
    }
  }

  /**
   * Runs an agentic AI turn with tools for the user's Plot data and the web.
   * A progress note is created at the start and updated as tools run; it
   * BECOMES the final answer rather than being replaced by a separate note.
   */
  private async respondLocked(note: Note): Promise<void> {
    const thread = note.thread;
    // available() is an RPC method on the built-in AI tool — must be awaited.
    const { prompt: canPrompt, webSearch: canWebSearch } =
      await this.tools.ai.available();

    // Without AI we can only surface existing content.
    if (!canPrompt) {
      await this.replyWithoutAi(note);
      return;
    }

    // Mark the thread as "assistant is working" (cleared in finally).
    await this.tools.plot.updateThread({
      id: thread.id,
      twistTags: { [Tag.Twist]: true },
    });

    let progress: TurnProgress | undefined;
    // When true, this turn has been handed off to a fresh background execution
    // that now OWNS clearing Tag.Twist — the finally below must NOT clear it.
    let handedOff = false;
    try {
      const previousNotes = await this.tools.plot.getNotes(thread);
      const merged = buildMessages(previousNotes);
      const { older, recent } = partitionHistory(merged);
      let messages: ChatMessage[] = recent;
      if (older.length > 0) {
        messages = withSummary(
          recent,
          await this.threadSummary(thread.id, older),
          older.length
        );
      }

      if (messages.length === 0) {
        await this.tools.plot.createNote({
          thread: { id: thread.id },
          content:
            "What can I help you with? Ask me anything — I can answer questions, search your Plot workspace, look things up on the web, and help organize your content.",
        });
        return;
      }

      progress = await TurnProgress.start(this.tools.plot, thread.id as Uuid);

      // Thread IDs surfaced by the data tools become navigation actions.
      const referencedThreadIds = new Set<string>();

      const toolCtx: AgentToolContext = {
        plot: this.tools.plot,
        currentFocusId: note.thread.focus.id,
        currentThreadId: thread.id,
        referencedThreadIds,
        onProgress: (m) => progress!.update(m),
        proposePlan: async (request) => await this.buildAndPostPlan(note, request),
      };
      // Cast to `any` to avoid TS2589 (deep generic instantiation) from the
      // large inline tool set; tool shapes are validated at runtime.
      const agentTools = buildAgentTools(toolCtx) as any;

      const baseRequest = {
        system: SYSTEM_PROMPT,
        webSearch: canWebSearch,
        tools: agentTools,
      };

      // Cast the request `as any` to avoid TS2589 (deep generic instantiation)
      // from the large inline tool set; runtime shapes are validated by the AI
      // tool. The continuation's `messages` intentionally mixes twist-local
      // ChatMessage[] with the AIMessage[] transcript plus a user-role nudge.
      let response = await promptWithRetry(this.tools.ai, {
        ...baseRequest,
        // Plot-funded → Google (Gemini Flash): a frontier model with native
        // web search + tool calling. See AI tool's selectModel.
        model: { speed: "fast", cost: "high" },
        messages,
        maxSteps: 16,
      } as any);

      if (response.finishReason === "tool-calls") {
        // Step budget exhausted mid-chain: ONE continuation on the capable
        // tier (Gemini Pro) with the tool transcript carried forward. Because
        // this branch runs only from the fast-tier result and reassigns
        // `response` to the capable-tier result, it can never re-trigger
        // itself — exactly one continuation per turn.
        const transcript = response.response?.messages ?? [];
        response = await promptWithRetry(this.tools.ai, {
          ...baseRequest,
          model: { speed: "capable", cost: "high" },
          messages: [
            ...messages,
            ...transcript,
            {
              role: "user",
              content:
                "(system note) You stopped mid-task because you hit the step limit. Using what you have already gathered, give your best final answer now. Only call another tool if it is truly essential.",
            },
          ],
          maxSteps: 8,
        } as any);
      }

      if (response.finishReason === "tool-calls") {
        // BOTH budgets are now exhausted (fast maxSteps 16 + capable maxSteps
        // 8) and the model still wants to call tools. Rather than shrug with a
        // half answer, hand off to a FRESH execution (~1000-request budget) for
        // exactly one final turn. Everything the background isolate needs must
        // go through the store — instance variables do NOT survive across
        // executions.
        const stateKey = `bg:${note.id}`;
        await this.set(stateKey, {
          threadId: thread.id as string,
          focusId: note.thread.focus.id as string,
          progressNoteId: progress.noteId as string,
          // The transcript mixes twist-local ChatMessage[] with the AI-SDK
          // AIMessage[] transcript. AIMessage content can (per its type) hold
          // non-plain parts — image/file parts carry Uint8Array/ArrayBuffer,
          // which SuperJSON does not round-trip. Normalize through JSON so the
          // persisted payload is guaranteed plain, serializable data no matter
          // what parts the provider returned.
          messages: JSON.parse(
            JSON.stringify([
              ...messages,
              ...(response.response?.messages ?? []),
            ])
          ) as Serializable,
        });
        await progress.update(
          "This is taking longer than one pass — I'm still working and will post the answer here."
        );
        // Persist state BEFORE enqueueing so the fresh execution always finds
        // it. If runTask itself throws, handedOff stays false: the catch below
        // surfaces the error and the finally clears Tag.Twist.
        await this.runTask(
          await this.callback(this.continueInBackground, stateKey)
        );
        handedOff = true;
        return;
      }

      let finalText =
        response.text?.trim() ||
        "I wasn't able to come up with a complete answer. Could you rephrase or narrow the request?";
      if (response.finishReason === "length") {
        finalText +=
          "\n\n*(I hit a length limit — ask me to continue for more.)*";
      }

      const actions = buildActions(
        referencedThreadIds,
        thread.id,
        response.sources
      );

      // The progress note BECOMES the answer — no separate final note.
      await progress.finish(finalText, actions.length > 0 ? actions : undefined);
    } catch (error) {
      // Twists run sandboxed with no PostHog access — console is the only sink.
      console.error("Plot assistant respond failed", error);
      const content = isTransientAiError(error)
        ? "The AI service is briefly overloaded — please try again in a moment."
        : "Sorry, I ran into an issue handling that request. Please try again.";
      if (progress) {
        await progress.finish(content);
      } else {
        // Progress note itself failed to create (or the error happened
        // before we got that far) — fall back to a plain note so the user
        // still gets a response.
        await this.tools.plot.createNote({
          thread: { id: thread.id },
          content,
        });
      }
    } finally {
      // When handed off, the background task owns clearing the working flag.
      if (!handedOff) {
        await this.tools.plot.updateThread({
          id: thread.id,
          twistTags: { [Tag.Twist]: false },
        });
      }
    }
  }

  /**
   * Fresh-budget continuation for turns that exhausted both prompt rounds.
   * Runs in a NEW execution (~1000-request budget) enqueued via runTask, so
   * ALL state comes from the store — no instance variables survive here.
   * Exactly one hop: this run must end with a final answer (it never
   * re-hands-off), and it always clears the stored state and Tag.Twist.
   */
  async continueInBackground(stateKey: string): Promise<void> {
    // `messages` is typed `Serializable[]` (not `unknown[]`) so the object
    // satisfies `this.get`'s `T extends Serializable` constraint; the array
    // holds the mixed twist-local + AI-SDK transcript replayed verbatim below.
    const state = await this.get<{
      threadId: string;
      focusId: string;
      progressNoteId: string;
      messages: Serializable[];
    }>(stateKey);
    if (!state) return; // already handled or expired

    const threadId = state.threadId as Uuid;
    try {
      const referencedThreadIds = new Set<string>();
      const progressUpdate = async (message: string) => {
        try {
          await this.tools.plot.updateNote({
            id: state.progressNoteId as Uuid,
            content: `*${message}*`,
          });
        } catch (error) {
          console.error("Background progress update failed", error);
        }
      };
      const toolCtx: AgentToolContext = {
        plot: this.tools.plot,
        currentFocusId: state.focusId as Uuid,
        currentThreadId: state.threadId,
        referencedThreadIds,
        onProgress: progressUpdate,
        proposePlan: async () =>
          "Reorganization plans can't be built in a background continuation — ask the user to repeat the reorganize request.",
      };

      const { webSearch: canWebSearch } = await this.tools.ai.available();
      // Cast the request `as any` to avoid TS2589 (deep generic instantiation)
      // from the large inline tool set; runtime shapes are validated by the AI
      // tool. `state.messages` replays the persisted twist-local + AI-SDK
      // transcript verbatim, plus a final user-role nudge.
      const response = await promptWithRetry(this.tools.ai, {
        model: { speed: "capable", cost: "high" },
        system: SYSTEM_PROMPT,
        messages: [
          ...state.messages,
          {
            role: "user",
            content:
              "(system note) You are in a final continuation with a fresh budget. Finish the task and give your complete final answer now.",
          },
        ],
        tools: buildAgentTools(toolCtx),
        webSearch: canWebSearch,
        maxSteps: 24,
      } as any);

      const finalText =
        response.text?.trim() ||
        "I gathered a lot but couldn't finish cleanly — could you narrow the request?";
      const actions = buildActions(
        referencedThreadIds,
        state.threadId,
        response.sources
      );
      await this.tools.plot.updateNote({
        id: state.progressNoteId as Uuid,
        content: finalText,
        actions: actions.length > 0 ? actions : undefined,
      });
    } catch (error) {
      // Twists run sandboxed with no PostHog access — console is the only sink.
      console.error("Background continuation failed", error);
      await this.tools.plot.updateNote({
        id: state.progressNoteId as Uuid,
        content:
          "Sorry — I ran out of room finishing that request. Please try a narrower ask.",
      });
    } finally {
      await this.clear(stateKey);
      await this.tools.plot.updateThread({
        id: threadId,
        twistTags: { [Tag.Twist]: false },
      });
    }
  }

  /**
   * Rolling summary of trimmed-off history, cached per thread. Regenerated
   * only when 10+ new turns have aged out since the cached summary.
   */
  private async threadSummary(
    threadId: string,
    older: ChatMessage[]
  ): Promise<string | null> {
    const key = `summary:${threadId}`;
    // The ENTIRE body (including the cache read) is fault-tolerant: a store
    // or AI failure degrades to "no summary" — it must never fail the turn.
    let cached: { coveredTurns: number; text: string } | null = null;
    try {
      cached = await this.get<{ coveredTurns: number; text: string }>(key);
      if (cached && older.length < cached.coveredTurns + 10) return cached.text;
      const response = await this.tools.ai.prompt({
        model: { speed: "fast", cost: "medium" },
        prompt:
          "Summarize this earlier conversation in under 200 words, keeping named people, projects, decisions, and open questions:\n\n" +
          older.map((m) => `${m.role}: ${m.content}`).join("\n").slice(0, 30_000),
      });
      const text = response.text?.trim();
      if (!text) return cached?.text ?? null;
      await this.set(key, { coveredTurns: older.length, text });
      return text;
    } catch (error) {
      console.error("Thread summary failed", error);
      return cached?.text ?? null; // summary is an enhancement, never a blocker
    }
  }

  /**
   * Fallback when AI prompting is unavailable: surface related threads from
   * semantic search with an upsell, instead of dead-ending.
   */
  private async replyWithoutAi(note: Note): Promise<void> {
    const query = note.content?.trim();
    if (!query) {
      await this.tools.plot.createNote({
        thread: { id: note.thread.id },
        content:
          "Ask me a question and I'll help. AI is currently disabled, so I can only search your existing content — enable AI in settings or add an API key for full answers and web search.",
      });
      return;
    }

    const results = await this.tools.plot.search(query, {
      focusId: note.thread.focus.id,
    });

    if (results.length === 0) {
      await this.tools.plot.createNote({
        thread: { id: note.thread.id },
        content:
          "I couldn't find anything relevant, and AI is disabled so I can't generate an answer. Enable AI in settings or add an API key.",
      });
      return;
    }

    const seen = new Set<string>();
    const threadList = results
      .filter((r) => {
        if (seen.has(r.thread.id)) return false;
        seen.add(r.thread.id);
        return true;
      })
      .slice(0, 5)
      .map((r) => `- ${r.thread.title || "(untitled)"}`)
      .join("\n");

    await this.tools.plot.createNote({
      thread: { id: note.thread.id },
      content: `AI is disabled, but here are some related threads:\n\n${threadList}\n\n*Enable AI in settings or add an API key for full answers and web search.*`,
    });
  }

  /**
   * Compose an organization plan on a capable model (Gemini Pro) with
   * conversation context, validate it, and post it as a plan card. Focus
   * creation is DEFERRED into the plan — nothing mutates until approval.
   */
  private async buildAndPostPlan(note: Note, request: string): Promise<string> {
    const [threads, focuses, previousNotes] = await Promise.all([
      this.tools.plot.getThreads({ focusId: note.thread.focus.id, limit: 200 }),
      this.tools.plot.getFocuses(),
      this.tools.plot.getNotes(note.thread),
    ]);

    if (threads.length === 0) {
      return "There are no threads in this focus to organize.";
    }

    const response = await this.tools.ai.prompt({
      // Structured planning runs on the capable tier (Gemini Pro).
      model: { speed: "capable", cost: "high" },
      system: PLANNER_SYSTEM_PROMPT,
      prompt: buildPlannerPrompt({
        request,
        conversation: buildMessages(previousNotes),
        threads,
        focuses,
      }),
      outputSchema: OPERATIONS_SCHEMA,
    });

    const raw = response.output;
    if (!raw || raw.length === 0) {
      return "I couldn't determine any operations for that request.";
    }

    // Focus creation is deferred: validateOperations assigns client-generated
    // ids (Uuid.Generate) and orders createFocus ops first — nothing mutates
    // until the user approves the plan.
    const operations = validateOperations(raw, threads, focuses, () =>
      Uuid.Generate()
    );
    if (operations.length === 0) {
      return "I couldn't find any matching content to act on.";
    }

    // The server invokes plan callbacks as (action, approved, ...extraArgs) —
    // `approved` is a positional arg inserted before the curried extraArg. The
    // SDK's actionCallback type still models (action, ...extraArgs), so bridge
    // the extra middle param with a cast (runtime order is guaranteed).
    const planCallback = this.onPlanResponse as unknown as (
      action: Action,
      threadId: string
    ) => Promise<void>;
    const cb = await this.actionCallback(planCallback, note.thread.id as string);
    const planAction = this.tools.plot.createPlan({
      title: `Organize: ${request.slice(0, 80)}`,
      operations,
      callback: cb,
    });

    await this.tools.plot.createNote({
      thread: { id: note.thread.id },
      content: `Here's my plan (${operations.length} operation${
        operations.length === 1 ? "" : "s"
      }):\n\n${summarizeOperations(operations)}`,
      actions: [planAction],
    });

    return `Created a plan with ${operations.length} operation${
      operations.length === 1 ? "" : "s"
    }, shown above for the user's approval.`;
  }

  /**
   * Plan decision callback. The server executes approved operations BEFORE
   * invoking this (results ride on the action); rejections just invoke it
   * with approved=false.
   */
  async onPlanResponse(
    action: Action,
    approved: boolean,
    threadId: string
  ): Promise<void> {
    if (action.type !== ActionType.plan) return;

    if (!approved) {
      await this.tools.plot.createNote({
        thread: { id: threadId as Uuid },
        content: "Okay — I won't make those changes.",
      });
      return;
    }

    const results = action.results ?? [];
    const failures = results
      .map((r, i) => ({ result: r, op: action.operations[i] }))
      .filter((x) => x.op && !x.result.success);

    const content =
      failures.length === 0
        ? `Done — completed all ${results.length} operation${
            results.length === 1 ? "" : "s"
          }.`
        : `Completed ${results.length - failures.length} of ${
            results.length
          } operations. These failed:\n\n` +
          failures
            .map(
              (f) => `- ${describeOperation(f.op)} — ${f.result.error ?? "unknown error"}`
            )
            .join("\n");

    await this.tools.plot.createNote({
      thread: { id: threadId as Uuid },
      content,
    });
  }
}

export default PlotTwist;
