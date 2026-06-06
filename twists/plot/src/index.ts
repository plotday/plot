import { Type } from "typebox";

import {
  type Action,
  ActionType,
  type Actor,
  ActorType,
  type Focus,
  type Note,
  type PlanOperation,
  Tag,
  type ToolBuilder,
  Twist,
  type Uuid,
} from "@plotday/twister";
import { AI, type AISource } from "@plotday/twister/tools/ai";
import {
  FocusAccess,
  Plot,
  ThreadAccess,
} from "@plotday/twister/tools/plot";

const SYSTEM_PROMPT = `You are Plot's built-in AI assistant. You are a capable, general-purpose assistant — answer any question or carry out any request the way ChatGPT, Claude, or Gemini would, while also being deeply integrated with the user's Plot workspace.

You have tools:
- searchPlotData: semantically search the user's own notes, threads, and links. Use this whenever a question might be answered by the user's own content.
- listThreads / listFocuses: browse the user's threads and focuses (projects/folders).
- readThreadNotes: read the full conversation of a specific thread to summarize or dig deeper.
- organizeContent: propose a plan to move, archive, rename, or create threads and focuses. The plan is shown to the user for approval — only use it when the user explicitly asks to reorganize.
- Web search is available for up-to-date, real-world information (news, weather, public facts, current events). It is a supplement to searchPlotData, never a substitute for it.

Tool-use rules:
- searchPlotData is your DEFAULT first move. Before answering any question whose answer could plausibly be informed by the user's own content, call searchPlotData FIRST. This includes anything about their notes, threads, tasks, meetings, events, appointments, people, projects, decisions, plans, status, or history — and anything phrased with "my"/"our"/"we"/"I", or naming a specific person, project, company, date, or thing the user would have recorded. Do not assume a question is general knowledge just because it doesn't say "my".
- When you are unsure whether the answer lives in the user's workspace, search it. A needless Plot search is cheap; a missed one means a wrong or generic answer.
- Only skip searchPlotData for requests that are purely general knowledge, creative writing, or external real-world facts with no plausible connection to the user's data.
- If a question could depend on BOTH the user's data and external facts, search Plot first, then web — and reconcile the two in your answer (the user's own content takes precedence when they conflict).
- Never call web search in place of searchPlotData to answer a question about the user's own world.
- Never claim to have looked at the user's data unless you actually called searchPlotData (or another data tool).
- Be concise and direct. Use Markdown (headings, lists, tables, fenced code blocks with a language) when it helps.
- When you reorganize via organizeContent, don't repeat the full plan in your reply — the plan is shown separately for approval.
- If asked what you can do, explain these capabilities in a friendly sentence or two.`;

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
   * Conversational entry point. Responds to any mention by running an agentic
   * AI turn with tools for the user's Plot data and the web.
   */
  async respond(note: Note): Promise<void> {
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

    try {
      const previousNotes = await this.tools.plot.getNotes(thread);
      const messages = this.buildMessages(previousNotes);

      if (messages.length === 0) {
        await this.tools.plot.createNote({
          thread: { id: thread.id },
          content:
            "What can I help you with? Ask me anything — I can answer questions, search your Plot workspace, look things up on the web, and help organize your content.",
        });
        return;
      }

      // Thread IDs surfaced by the data tools become navigation actions.
      const referencedThreadIds = new Set<string>();

      const response = await this.tools.ai.prompt({
        // Plot-funded → Google (Gemini Flash): a frontier model with native
        // web search + tool calling. See AI tool's selectModel.
        model: { speed: "fast", cost: "high" },
        system: SYSTEM_PROMPT,
        messages,
        webSearch: canWebSearch,
        maxSteps: 6,
        // Cast to `any` to avoid TS2589 (deep generic instantiation) from the
        // large inline tool set; tool shapes are validated at runtime.
        tools: {
          searchPlotData: {
            description:
              "Semantically search the user's own notes, threads, and links. Returns the most relevant items. Prefer this over web search whenever the answer could involve the user's own content — call it first when in doubt.",
            inputSchema: Type.Object({
              query: Type.String({
                description: "What to search for in the user's Plot workspace.",
              }),
            }),
            execute: async ({ query }: { query: string }) => {
              const results = await this.tools.plot.search(query, {
                focusId: note.thread.focus.id,
                limit: 8,
              });
              for (const r of results) {
                if (r.thread?.id) referencedThreadIds.add(r.thread.id);
              }
              return results.map((r) => ({
                kind: r.type,
                title: r.thread.title ?? (r.type === "link" ? r.title : null),
                focus: r.focus.title ?? null,
                content: r.content ?? (r.type === "link" ? r.title : null),
                url: r.type === "link" ? r.sourceUrl ?? null : null,
              }));
            },
          },
          listThreads: {
            description:
              "List the user's threads in the current focus.",
            inputSchema: Type.Object({
              includeArchived: Type.Optional(
                Type.Boolean({
                  description: "Include archived threads (default false).",
                })
              ),
            }),
            execute: async ({
              includeArchived,
            }: {
              includeArchived?: boolean;
            }) => {
              const threads = await this.tools.plot.getThreads({
                focusId: note.thread.focus.id,
                includeArchived: includeArchived ?? false,
                limit: 50,
              });
              return threads.map((t) => ({
                id: t.id,
                title: t.title,
                archived: t.archived,
                focus: t.focus.title,
              }));
            },
          },
          listFocuses: {
            description:
              "List the user's focuses (projects/folders).",
            inputSchema: Type.Object({}),
            execute: async () => {
              const focuses = await this.tools.plot.getFocuses();
              return focuses.map((p) => ({ id: p.id, title: p.title }));
            },
          },
          readThreadNotes: {
            description:
              "Read the full notes/conversation of a specific thread by its ID.",
            inputSchema: Type.Object({
              threadId: Type.String({
                description: "The thread ID to read.",
              }),
            }),
            execute: async ({ threadId }: { threadId: string }) => {
              const target = await this.tools.plot.getThread({
                id: threadId as Uuid,
              });
              if (!target) return { error: "Thread not found." };
              referencedThreadIds.add(target.id);
              const notes = await this.tools.plot.getNotes(target);
              return {
                title: target.title,
                notes: notes
                  .filter((n) => n.content?.trim())
                  .map((n) => ({
                    author:
                      n.author.type === ActorType.Twist
                        ? "assistant"
                        : "user",
                    content: n.content,
                  })),
              };
            },
          },
          organizeContent: {
            description:
              "Propose a plan to move, archive, rename, or create threads and focuses. The plan is shown to the user for approval. Only use when the user explicitly asks to reorganize.",
            inputSchema: Type.Object({
              request: Type.String({
                description:
                  "The organization request in the user's words, e.g. 'archive all done threads'.",
              }),
            }),
            execute: async ({ request }: { request: string }) => {
              return await this.buildAndPostPlan(note, request);
            },
          },
        } as any,
      });

      const actions = this.buildActions(
        referencedThreadIds,
        thread.id,
        response.sources
      );

      await this.tools.plot.createNote({
        thread: { id: thread.id },
        content:
          response.text?.trim() ||
          "I wasn't able to come up with a response. Could you rephrase?",
        actions: actions.length > 0 ? actions : undefined,
      });
    } catch (error) {
      // Twists run sandboxed with no PostHog access — console is the only sink.
      console.error("Plot assistant respond failed", error);
      await this.tools.plot.createNote({
        thread: { id: thread.id },
        content:
          "Sorry, I ran into an issue handling that request. Please try again.",
      });
    } finally {
      await this.tools.plot.updateThread({
        id: thread.id,
        twistTags: { [Tag.Twist]: false },
      });
    }
  }

  /**
   * Build the AI message history from a thread's notes: map authors to
   * user/assistant roles, merge consecutive same-role turns (so the provider
   * sees alternating roles), and ensure the first turn is from the user.
   */
  private buildMessages(
    notes: Note[]
  ): Array<{ role: "user" | "assistant"; content: string }> {
    const mapped = notes
      .filter((n) => n.content?.trim())
      .map((n) => ({
        role: (n.author.type === ActorType.Twist ? "assistant" : "user") as
          | "user"
          | "assistant",
        content: n.content as string,
      }));

    const merged: Array<{ role: "user" | "assistant"; content: string }> = [];
    for (const m of mapped) {
      const last = merged[merged.length - 1];
      if (last && last.role === m.role) {
        last.content += "\n\n" + m.content;
      } else {
        merged.push({ ...m });
      }
    }

    // Providers require the conversation to start with a user turn.
    while (merged.length > 0 && merged[0].role === "assistant") {
      merged.shift();
    }
    return merged;
  }

  /** Build navigation actions from referenced threads and web sources. */
  private buildActions(
    threadIds: Set<string>,
    currentThreadId: string,
    sources?: AISource[]
  ): Action[] {
    const actions: Action[] = [];

    for (const id of threadIds) {
      if (id === currentThreadId) continue;
      actions.push({ type: ActionType.thread, threadId: id as Uuid });
      if (actions.length >= 3) break;
    }

    if (sources) {
      let urls = 0;
      for (const source of sources) {
        if (source.sourceType === "url" && source.url) {
          actions.push({
            type: ActionType.external,
            title: source.title || source.url,
            url: source.url,
          });
          if (++urls >= 5) break;
        }
      }
    }

    return actions;
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
   * Generate an organization plan for `request`, post it as a plan note for
   * user approval, and return a short status string for the assistant to relay.
   */
  private async buildAndPostPlan(note: Note, request: string): Promise<string> {
    // Gather context: threads, focuses, and search results in parallel
    const [threads, focuses, searchResults] = await Promise.all([
      this.tools.plot.getThreads({
        focusId: note.thread.focus.id,
        limit: 200,
      }),
      this.tools.plot.getFocuses(),
      this.tools.plot.search(request, {
        focusId: note.thread.focus.id,
        limit: 30,
      }),
    ]);

    if (threads.length === 0) {
      return "There are no threads in this focus to organize.";
    }

    const threadsContext = threads
      .map(
        (t) =>
          `${t.id} | ${t.title} | Focus: ${t.focus.title} (${
            t.focus.id
          }) | Archived: ${t.archived ? "yes" : "no"}`
      )
      .join("\n");

    const focusesContext = focuses
      .map((p) => `${p.id} | ${p.title}`)
      .join("\n");

    const searchContext =
      searchResults.length > 0
        ? searchResults
            .map((r) => `- [${r.thread.title}] (thread ${r.thread.id})`)
            .join("\n")
        : "(no search results)";

    const operationsSchema = Type.Array(
      Type.Union([
        Type.Object({
          type: Type.Literal("updateThread"),
          threadId: Type.String(),
          threadTitle: Type.String(),
          changes: Type.Object({
            archived: Type.Optional(Type.Boolean()),
            title: Type.Optional(Type.String()),
            type: Type.Optional(Type.String()),
            focus: Type.Optional(
              Type.Object({ id: Type.String(), title: Type.String() })
            ),
          }),
        }),
        Type.Object({
          type: Type.Literal("createThread"),
          title: Type.String(),
          focusId: Type.String(),
          focusTitle: Type.String(),
        }),
        Type.Object({
          type: Type.Literal("createNote"),
          threadId: Type.String(),
          threadTitle: Type.String(),
          content: Type.String(),
        }),
        Type.Object({
          type: Type.Literal("updateFocus"),
          focusId: Type.String(),
          focusTitle: Type.String(),
          changes: Type.Object({
            title: Type.Optional(Type.String()),
            archived: Type.Optional(Type.Boolean()),
          }),
        }),
        Type.Object({
          type: Type.Literal("_createFocus"),
          title: Type.String(),
        }),
      ])
    );

    const response = await this.tools.ai.prompt({
      // Structured planning needs a frontier model for reliable operations.
      model: { speed: "fast", cost: "high" },
      system:
        "You are an organizational assistant for a workspace. The user wants to reorganize their content.\n\n" +
        "Given the user's request and the available data, produce a JSON array of operations.\n\n" +
        "Available operation types:\n" +
        "- updateThread: Change a thread's title, archived status, or move it to a different focus. Use changes.focus with {id, title} to move. Set changes.archived to true to archive.\n" +
        "- createThread: Create a new thread in a specific focus.\n" +
        "- createNote: Add a note to an existing thread.\n" +
        "- updateFocus: Rename a focus or archive it.\n" +
        "- _createFocus: Signal that a new focus should be created. Use this when the user asks to move threads to a focus that doesn't exist yet. Focuses are flat — they have no parent.\n\n" +
        "Rules:\n" +
        "- Only reference thread IDs and focus IDs from the provided data (except for _createFocus).\n" +
        "- Include the current title in threadTitle/focusTitle fields for display purposes.\n" +
        "- Be conservative: only include operations that clearly match the user's request.\n" +
        "- Tag changes are not supported. If the user asks about tags, return an empty array.\n" +
        "- Only active (non-archived) threads are included in the list below. Already-archived threads cannot be targeted.\n" +
        "- Return an empty array if the request doesn't match any actionable operations.",
      prompt:
        `Request: ${request}\n\n` +
        `Threads (${threads.length}):\n${threadsContext}\n\n` +
        `Focuses (${focuses.length}):\n${focusesContext}\n\n` +
        `Search results for "${request}":\n${searchContext}`,
      outputSchema: operationsSchema,
    });

    const aiOperations = response.output;
    if (!aiOperations || aiOperations.length === 0) {
      return "I couldn't determine any operations for that request.";
    }

    const threadIds = new Set<string>(threads.map((t) => t.id));
    const focusIds = new Set<string>(focuses.map((p) => p.id));

    // Create signalled focuses eagerly, then map them by title.
    const newFocusMap = new Map<string, Focus>();
    for (const op of aiOperations) {
      if (op.type === "_createFocus") {
        const created = await this.tools.plot.createFocus({
          title: op.title,
        });
        newFocusMap.set(op.title.toLowerCase(), created);
        focusIds.add(created.id);
      }
    }

    const validOperations: PlanOperation[] = [];
    for (const op of aiOperations) {
      if (op.type === "_createFocus") continue;

      if (op.type === "updateThread") {
        if (!threadIds.has(op.threadId)) continue;
        if (op.changes.focus) {
          const newFocus = newFocusMap.get(
            op.changes.focus.title.toLowerCase()
          );
          if (newFocus) {
            op.changes.focus = {
              id: newFocus.id,
              title: newFocus.title,
            };
          } else if (!focusIds.has(op.changes.focus.id)) {
            continue;
          }
        }
        validOperations.push(op as PlanOperation);
      } else if (op.type === "createThread") {
        const newFocus = newFocusMap.get(op.focusTitle.toLowerCase());
        if (newFocus) {
          op.focusId = newFocus.id;
          op.focusTitle = newFocus.title;
        } else if (!focusIds.has(op.focusId)) {
          continue;
        }
        validOperations.push(op as PlanOperation);
      } else if (op.type === "createNote") {
        if (!threadIds.has(op.threadId)) continue;
        validOperations.push(op as PlanOperation);
      } else if (op.type === "updateFocus") {
        if (!focusIds.has(op.focusId)) continue;
        validOperations.push(op as PlanOperation);
      }
    }

    if (validOperations.length === 0) {
      return "I couldn't find any matching content to act on.";
    }

    const operations = validOperations.slice(0, 50);

    const summary = operations
      .map((op) => {
        switch (op.type) {
          case "updateThread":
            if (op.changes.focus)
              return `- Move **${op.threadTitle}** to **${op.changes.focus.title}**`;
            if (op.changes.archived) return `- Archive **${op.threadTitle}**`;
            if (op.changes.title)
              return `- Rename **${op.threadTitle}** to **${op.changes.title}**`;
            return `- Update **${op.threadTitle}**`;
          case "createThread":
            return `- Create thread **${op.title}** in **${op.focusTitle}**`;
          case "createNote":
            return `- Add note to **${op.threadTitle}**`;
          case "updateFocus":
            if (op.changes.archived)
              return `- Archive focus **${op.focusTitle}**`;
            if (op.changes.title)
              return `- Rename focus **${op.focusTitle}** to **${op.changes.title}**`;
            return `- Update focus **${op.focusTitle}**`;
          default:
            return `- Unknown operation`;
        }
      })
      .join("\n");

    const cb = await this.actionCallback(
      this.onPlanResponse,
      note.thread.id as string
    );
    const planAction = this.tools.plot.createPlan({
      title: `Organize: ${request.slice(0, 80)}`,
      operations,
      callback: cb,
    });

    await this.tools.plot.createNote({
      thread: { id: note.thread.id },
      content: `Here's my plan (${operations.length} operation${
        operations.length === 1 ? "" : "s"
      }):\n\n${summary}`,
      actions: [planAction],
    });

    return `Created a plan with ${operations.length} operation${
      operations.length === 1 ? "" : "s"
    }, shown above for your approval.`;
  }

  async onPlanResponse(_action: Action, threadId: string): Promise<void> {
    // The API executes operations on approval and calls back with the action.
    // We just post a confirmation note in the original thread.
    await this.tools.plot.createNote({
      thread: { id: threadId as Uuid },
      content: "Done! The plan has been executed.",
    });
  }
}

export default PlotTwist;
