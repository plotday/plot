import { Type } from "typebox";

import { Gmail } from "@plotday/tool-gmail";
import { Slack } from "@plotday/tool-slack";
import {
  type ThreadFilter,
  ThreadType,
  type NewThreadWithNotes,
  type NewContact,
  type Note,
  type Priority,
  type ToolBuilder,
  Twist,
} from "@plotday/twister";
import { AI, type AIMessage } from "@plotday/twister/tools/ai";
import { ThreadAccess, Plot } from "@plotday/twister/tools/plot";
import { Uuid } from "@plotday/twister/utils/uuid";

type MessageProvider = "slack" | "gmail";

type Instruction = {
  id: string;
  text: string;
  summary: string;
  authorId: string;
  created: string;
};

type ThreadTask = {
  threadId: string;
  taskId: Uuid;
  created: string;
  lastChecked: string;
};

export default class MessageTasksTwist extends Twist<MessageTasksTwist> {
  build(build: ToolBuilder) {
    return {
      slack: build(Slack, {
        onItem: this.onSlackThread,
        onSyncableDisabled: this.onSyncableDisabled,
      }),
      gmail: build(Gmail, {
        onItem: this.onGmailThread,
        onSyncableDisabled: this.onSyncableDisabled,
      }),
      ai: build(AI),
      plot: build(Plot, {
        thread: {
          access: ThreadAccess.Create,
        },
        note: {
          intents: [
            {
              description:
                "Give the twist an instruction that changes how it creates tasks from messages",
              examples: [
                "Ignore threads from #random",
                "Always create tasks for messages from my manager",
                "Never create tasks for bot messages",
                "Only create tasks when I'm directly mentioned",
              ],
              handler: this.onInstruct,
            },
            {
              description: "List all saved instructions",
              examples: [
                "What are my instructions?",
                "Show my rules",
                "List instructions",
              ],
              handler: this.onListInstructions,
            },
            {
              description:
                "Forget or remove a specific saved instruction",
              examples: [
                "Forget instruction about #random",
                "Remove rule 3",
                "Delete the instruction about bot messages",
              ],
              handler: this.onForgetInstruction,
            },
          ],
        },
      }),
    };
  }

  async activate(_priority: Pick<Priority, "id">) {
    // Auth and channel selection are now handled in the twist edit modal.
  }

  async onSlackThread(thread: NewThreadWithNotes): Promise<void> {
    const channelId = thread.meta?.syncableId as string;
    return this.onMessageThread(thread, "slack", channelId);
  }

  async onGmailThread(thread: NewThreadWithNotes): Promise<void> {
    const channelId = thread.meta?.syncableId as string;
    return this.onMessageThread(thread, "gmail", channelId);
  }

  async onSyncableDisabled(filter: ThreadFilter): Promise<void> {
    await this.tools.plot.updateThread({ match: filter, archived: true });
  }

  // ============================================================================
  // Thread Task Storage
  // ============================================================================

  private async getThreadTask(threadId: string): Promise<ThreadTask | null> {
    const tasks = (await this.get<ThreadTask[]>("thread_tasks")) || [];
    return tasks.find((t) => t.threadId === threadId) || null;
  }

  private async storeThreadTask(threadId: string, taskId: Uuid): Promise<void> {
    const tasks = (await this.get<ThreadTask[]>("thread_tasks")) || [];
    tasks.push({
      threadId,
      taskId,
      created: new Date().toISOString(),
      lastChecked: new Date().toISOString(),
    });
    await this.set("thread_tasks", tasks);
  }

  private async updateThreadTaskCheck(threadId: string): Promise<void> {
    const tasks = (await this.get<ThreadTask[]>("thread_tasks")) || [];
    const task = tasks.find((t) => t.threadId === threadId);
    if (task) {
      task.lastChecked = new Date().toISOString();
      await this.set("thread_tasks", tasks);
    }
  }

  // ============================================================================
  // Instruction Storage
  // ============================================================================

  private async getInstructions(): Promise<Instruction[]> {
    return (await this.get<Instruction[]>("instructions")) ?? [];
  }

  private async setInstructions(instructions: Instruction[]): Promise<void> {
    await this.set("instructions", instructions);
  }

  // ============================================================================
  // Intent Handlers
  // ============================================================================

  async onInstruct(note: Note): Promise<void> {
    const content = note.content?.trim();
    if (!content) return;

    const instructions = await this.getInstructions();
    if (instructions.length >= 20) {
      await this.tools.plot.createNote({
        thread: { id: note.thread.id },
        content:
          "You've reached the limit of 20 instructions. Remove one first with \"forget instruction\" before adding more.",
      });
      return;
    }

    const response = await this.tools.ai.prompt({
      model: { speed: "fast", cost: "low" },
      system: `Summarize the user's instruction as a concise directive starting with a verb (e.g. "Ignore", "Always", "Never", "Only"). Keep it to one short sentence. If the input is unclear or not an instruction, respond with exactly "UNCLEAR".`,
      prompt: content,
    });

    const summary = response.text.trim();

    if (summary === "UNCLEAR") {
      await this.tools.plot.createNote({
        thread: { id: note.thread.id },
        content: `I didn't understand that as an instruction. Try something like:\n- "Ignore threads from #random"\n- "Always create tasks for messages from Sarah"\n- "Never create tasks for bot messages"`,
      });
      return;
    }

    const instruction: Instruction = {
      id: crypto.randomUUID().slice(0, 8),
      text: content,
      summary,
      authorId: note.author?.id as string,
      created: new Date().toISOString(),
    };

    instructions.push(instruction);
    await this.setInstructions(instructions);

    await this.tools.plot.createNote({
      thread: { id: note.thread.id },
      content: `Saved: "${summary}"`,
    });
  }

  async onListInstructions(note: Note): Promise<void> {
    const instructions = await this.getInstructions();

    if (instructions.length === 0) {
      await this.tools.plot.createNote({
        thread: { id: note.thread.id },
        content: `No instructions yet. Mention me with an instruction like "Ignore threads from #random" to add one.`,
      });
      return;
    }

    const list = instructions
      .map((inst, i) => `${i + 1}. ${inst.summary} \`${inst.id}\``)
      .join("\n");

    await this.tools.plot.createNote({
      thread: { id: note.thread.id },
      content: `**Instructions:**\n${list}`,
    });
  }

  async onForgetInstruction(note: Note): Promise<void> {
    const content = note.content?.trim();
    if (!content) return;

    const instructions = await this.getInstructions();

    if (instructions.length === 0) {
      await this.tools.plot.createNote({
        thread: { id: note.thread.id },
        content: "No instructions to remove.",
      });
      return;
    }

    let target: Instruction | undefined;

    // Strategy 1: Match a number (e.g. "forget instruction 3")
    const numMatch = content.match(/\d+/);
    if (numMatch) {
      const idx = parseInt(numMatch[0], 10) - 1;
      if (idx >= 0 && idx < instructions.length) {
        target = instructions[idx];
      }
    }

    // Strategy 2: Match a short ID substring
    if (!target) {
      target = instructions.find((inst) =>
        content.toLowerCase().includes(inst.id.toLowerCase())
      );
    }

    // Strategy 3: AI fuzzy match
    if (!target) {
      const summaries = instructions
        .map((inst, i) => `${i + 1}. ${inst.summary}`)
        .join("\n");

      const schema = Type.Object({
        matchIndex: Type.Number({
          description:
            "1-based index of the best matching instruction, or 0 if none match",
        }),
      });

      try {
        const response = await this.tools.ai.prompt({
          model: { speed: "fast", cost: "low" },
          system: `The user wants to remove one of these instructions:\n${summaries}\n\nReturn the 1-based index of the instruction that best matches the user's request. Return 0 if none match.`,
          prompt: content,
          outputSchema: schema,
        });

        const idx = (response.output?.matchIndex ?? 0) - 1;
        if (idx >= 0 && idx < instructions.length) {
          target = instructions[idx];
        }
      } catch {
        // Fall through to "no match" handling
      }
    }

    if (!target) {
      const list = instructions
        .map((inst, i) => `${i + 1}. ${inst.summary} \`${inst.id}\``)
        .join("\n");

      await this.tools.plot.createNote({
        thread: { id: note.thread.id },
        content: `Couldn't find a matching instruction. Here are the current ones:\n${list}`,
      });
      return;
    }

    await this.setInstructions(instructions.filter((i) => i.id !== target.id));

    await this.tools.plot.createNote({
      thread: { id: note.thread.id },
      content: `Removed: "${target.summary}"`,
    });
  }

  // ============================================================================
  // Message Thread Processing
  // ============================================================================

  async onMessageThread(
    thread: NewThreadWithNotes,
    provider: MessageProvider,
    channelId: string
  ): Promise<void> {
    if (!thread.notes || thread.notes.length === 0) return;

    const threadId = "source" in thread ? thread.source : undefined;
    if (!threadId) {
      console.warn("Thread has no source, skipping");
      return;
    }

    // Check if we already have a task for this thread
    const existingTask = await this.getThreadTask(threadId);

    if (existingTask) {
      // Thread already has a task - check if it needs updating
      await this.checkThreadForCompletion(thread, existingTask);
      await this.updateThreadTaskCheck(threadId);
      return;
    }

    // Analyze thread with AI to see if it needs a task
    const analysis = await this.analyzeThread(thread);

    if (!analysis.needsTask || analysis.confidence < 0.6) {
      return;
    }

    // Create task from thread
    await this.createTaskFromThread(thread, analysis, provider, channelId);
  }

  private async analyzeThread(thread: NewThreadWithNotes): Promise<{
    needsTask: boolean;
    taskTitle: string | null;
    taskNote: string | null;
    confidence: number;
    isCompleted: boolean;
  }> {
    // Load user instructions
    const instructions = await this.getInstructions();
    const instructionBlock =
      instructions.length > 0
        ? `\n\nUser instructions (follow these as rules):\n${instructions.map((i) => `- ${i.summary}`).join("\n")}`
        : "";

    // Build conversation for AI
    const messages: AIMessage[] = [
      {
        role: "system",
        content: `You are analyzing message threads to determine if they need action items from the user.

Look for threads that require:
- Responses to questions directed at the user
- Decisions the user needs to make
- Work or tasks the user committed to do
- Requests for help or action from the user
- Problems the user needs to solve
- Action items assigned to the user

DO NOT create tasks for:
- Pure information sharing or FYI messages
- Casual conversation without action items
- Messages where others are handling the work
- Questions not directed at the user
- Already completed or resolved discussions
- Automatic notifications or bot messages

If a task is needed, create a clear, actionable title that describes what the user needs to do.${instructionBlock}`,
      },
      ...thread.notes.map((note, idx) => {
        const author: NewContact | null =
          note.author && "email" in note.author ? note.author : null;
        return {
          role: "user" as const,
          content: `[Message ${idx + 1}] From ${
            author?.name || author?.email || "someone"
          }: ${note.content || "(empty message)"}`,
        };
      }),
    ];

    const schema = Type.Object({
      needsTask: Type.Boolean({
        description:
          "Whether this thread requires a task to be created for the user",
      }),
      taskTitle: Type.Optional(
        Type.String({
          description:
            "Clear, actionable task title starting with a verb (e.g., 'Respond to feedback request', 'Review PR #123')",
        })
      ),
      taskNote: Type.Optional(
        Type.String({
          description: "Detailed task description with context from the thread",
        })
      ),
      confidence: Type.Number({
        minimum: 0,
        maximum: 1,
        description: "Confidence level that a task is needed (0-1)",
      }),
      isCompleted: Type.Boolean({
        description: "Whether the action item appears to be already completed",
      }),
    });

    try {
      const response = await this.tools.ai.prompt({
        model: { speed: "balanced", cost: "medium" },
        messages,
        outputSchema: schema,
      });

      const output = response.output || {
        needsTask: false,
        taskTitle: undefined,
        taskNote: undefined,
        confidence: 0,
        isCompleted: false,
      };

      return {
        needsTask: output.needsTask,
        taskTitle: output.taskTitle ?? null,
        taskNote: output.taskNote ?? null,
        confidence: output.confidence,
        isCompleted: output.isCompleted,
      };
    } catch (error) {
      console.error("Failed to analyze thread with AI:", error);
      return {
        needsTask: false,
        taskTitle: null,
        taskNote: null,
        confidence: 0,
        isCompleted: false,
      };
    }
  }

  private formatSourceReference(
    thread: NewThreadWithNotes,
    provider: MessageProvider,
    channelId: string
  ): string {
    if (provider === "gmail") {
      const firstNote = thread.notes?.[0];
      const author: NewContact | null =
        firstNote?.author && "email" in firstNote.author
          ? firstNote.author
          : null;
      const senderName = author?.name || author?.email;
      const subject = thread.title;
      if (senderName && subject) return `From ${senderName}: ${subject}`;
      if (senderName) return `From ${senderName}`;
      if (subject) return `Re: ${subject}`;
      return `From Gmail`;
    }
    return `From #${channelId}`;
  }

  private async createTaskFromThread(
    thread: NewThreadWithNotes,
    analysis: {
      needsTask: boolean;
      taskTitle: string | null;
      taskNote: string | null;
      confidence: number;
    },
    provider: MessageProvider,
    channelId: string
  ): Promise<void> {
    const threadId = "source" in thread ? thread.source : undefined;
    if (!threadId) {
      console.warn("Thread has no source, skipping task creation");
      return;
    }

    const sourceRef = this.formatSourceReference(thread, provider, channelId);

    // Create task thread - database handles upsert automatically
    const taskId = await this.tools.plot.createThread({
      source: `message-tasks:${threadId}`,
      type: ThreadType.Action,
      title: analysis.taskTitle || thread.title || "Action needed from message",
      start: new Date(),
      notes: analysis.taskNote
        ? [
            {
              content: `${analysis.taskNote}\n\n---\n${sourceRef}`,
            },
          ]
        : [
            {
              content: sourceRef,
            },
          ],
      preview: analysis.taskNote
        ? `${analysis.taskNote}\n\n---\n${sourceRef}`
        : sourceRef,
      meta: {
        originalThreadId: threadId,
        channelId,
      },
      // Use pickPriority for automatic priority matching
      pickPriority: { content: 50, mentions: 50 },
    });

    // Store mapping
    await this.storeThreadTask(threadId, taskId);
  }

  private async checkThreadForCompletion(
    thread: NewThreadWithNotes,
    taskInfo: ThreadTask
  ): Promise<void> {
    // Only check the last few messages for completion signals
    const recentMessages = thread.notes.slice(-3);

    // Build a simple prompt to check for completion
    const messages: AIMessage[] = [
      {
        role: "system",
        content: `You are checking if a task appears to be completed based on recent messages in a thread.

Look for signals like:
- "Done", "Completed", "Finished"
- "Thanks!", "Perfect!", "Got it!"
- Confirmation that the action was taken
- Resolution of the original issue
- Explicit completion statements

Return true only if there's clear evidence the task is done.`,
      },
      ...recentMessages.map((note) => ({
        role: "user" as const,
        content: `User: ${note.content || ""}`,
      })),
    ];

    const schema = Type.Object({
      isCompleted: Type.Boolean({
        description: "Whether the task appears to be completed",
      }),
      confidence: Type.Number({
        minimum: 0,
        maximum: 1,
        description: "Confidence level (0-1)",
      }),
    });

    try {
      const response = await this.tools.ai.prompt({
        model: { speed: "fast", cost: "low" },
        messages,
        outputSchema: schema,
      });

      const result = response.output || {
        isCompleted: false,
        confidence: 0,
      };

      if (result.isCompleted && result.confidence >= 0.7) {
        await this.tools.plot.updateThread({
          id: taskInfo.taskId,
          done: new Date(),
        });
      }
    } catch (error) {
      console.error("Failed to check thread for completion:", error);
    }
  }
}
