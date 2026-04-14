import { Type } from "typebox";

import {
  type Link,
  type Note,
  type ToolBuilder,
  Twist,
} from "@plotday/twister";
import { AI, type AIMessage } from "@plotday/twister/tools/ai";
import { ThreadAccess, Plot } from "@plotday/twister/tools/plot";
import { Uuid } from "@plotday/twister/utils/uuid";

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
      ai: build(AI),
      plot: build(Plot, {
        link: true,
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

  async activate() {
    // Auth and channel selection are now handled in the twist edit modal.
  }

  // ============================================================================
  // Link Lifecycle
  // ============================================================================

  async onLinkCreated(link: Link, notes: Note[]): Promise<void> {
    if (!notes.length) return;

    const threadId = link.source;
    if (!threadId) {
      console.warn("Link has no source, skipping");
      return;
    }

    // Check if we already have a task for this thread
    const existingTask = await this.getThreadTask(threadId);

    if (existingTask) {
      // Already has a task — check latest note for completion
      const lastNote = notes[notes.length - 1];
      if (lastNote) {
        await this.checkNoteForCompletion(lastNote, existingTask);
        await this.updateThreadTaskCheck(threadId);
      }
      return;
    }

    // Analyze link with AI to see if it needs a task
    const analysis = await this.analyzeLink(link, notes);

    if (!analysis.needsTask || analysis.confidence < 0.6) {
      return;
    }

    await this.createTaskFromLink(link, notes, analysis);
  }

  async onLinkNoteCreated(note: Note, link: Link): Promise<void> {
    const threadId = link.source;
    if (!threadId) return;

    const existingTask = await this.getThreadTask(threadId);
    if (!existingTask) return;

    await this.checkNoteForCompletion(note, existingTask);
    await this.updateThreadTaskCheck(threadId);
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
  // Link Analysis & Task Creation
  // ============================================================================

  private async analyzeLink(link: Link, notes: Note[]): Promise<{
    needsTask: boolean;
    taskTitle: string | null;
    taskNote: string | null;
    confidence: number;
    isCompleted: boolean;
  }> {
    const instructions = await this.getInstructions();
    const instructionBlock =
      instructions.length > 0
        ? `\n\nUser instructions (follow these as rules):\n${instructions.map((i) => `- ${i.summary}`).join("\n")}`
        : "";

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
      ...notes.map((note, idx) => ({
        role: "user" as const,
        content: `[Message ${idx + 1}] From ${
          note.author?.name || note.author?.email || "someone"
        }: ${note.content || "(empty message)"}`,
      })),
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
      console.error("Failed to analyze link with AI:", error);
      return {
        needsTask: false,
        taskTitle: null,
        taskNote: null,
        confidence: 0,
        isCompleted: false,
      };
    }
  }

  private formatSourceReference(link: Link, notes: Note[]): string {
    if (link.type === "email") {
      const firstNote = notes[0];
      const senderName = firstNote?.author?.name || firstNote?.author?.email;
      const subject = link.title;
      if (senderName && subject) return `From ${senderName}: ${subject}`;
      if (senderName) return `From ${senderName}`;
      if (subject) return `Re: ${subject}`;
      return `From email`;
    }
    if (link.type === "message") {
      return link.channelId ? `From #${link.channelId}` : "From message";
    }
    return link.title || "From linked source";
  }

  private async createTaskFromLink(
    link: Link,
    notes: Note[],
    analysis: {
      needsTask: boolean;
      taskTitle: string | null;
      taskNote: string | null;
      confidence: number;
    }
  ): Promise<void> {
    const threadId = link.source;
    if (!threadId) {
      console.warn("Link has no source, skipping task creation");
      return;
    }

    const sourceRef = this.formatSourceReference(link, notes);

    const taskId = await this.tools.plot.createThread({
      title: analysis.taskTitle || link.title || "Action needed from message",
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
    });

    await this.storeThreadTask(threadId, taskId);
  }

  private async checkNoteForCompletion(
    note: Note,
    taskInfo: ThreadTask
  ): Promise<void> {
    const messages: AIMessage[] = [
      {
        role: "system",
        content: `You are checking if a task appears to be completed based on a message in a thread.

Look for signals like:
- "Done", "Completed", "Finished"
- "Thanks!", "Perfect!", "Got it!"
- Confirmation that the action was taken
- Resolution of the original issue
- Explicit completion statements

Return true only if there's clear evidence the task is done.`,
      },
      {
        role: "user",
        content: `User: ${note.content || ""}`,
      },
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
          archived: true,
        });
      }
    } catch (error) {
      console.error("Failed to check note for completion:", error);
    }
  }
}
