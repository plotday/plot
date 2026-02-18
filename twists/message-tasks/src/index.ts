import { Type } from "typebox";

import { Slack } from "@plotday/tool-slack";
import {
  type ActivityFilter,
  ActivityType,
  type NewActivityWithNotes,
  type Priority,
  type ToolBuilder,
  Twist,
} from "@plotday/twister";
import { AI, type AIMessage } from "@plotday/twister/tools/ai";
import { ActivityAccess, Plot } from "@plotday/twister/tools/plot";
import { Uuid } from "@plotday/twister/utils/uuid";

type MessageProvider = "slack";

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
      ai: build(AI),
      plot: build(Plot, {
        activity: {
          access: ActivityAccess.Create,
        },
      }),
    };
  }

  async activate(_priority: Pick<Priority, "id">) {
    // Auth and channel selection are now handled in the twist edit modal.
  }

  async onSlackThread(thread: NewActivityWithNotes): Promise<void> {
    const channelId = thread.meta?.syncableId as string;
    return this.onMessageThread(thread, "slack", channelId);
  }

  async onSyncableDisabled(filter: ActivityFilter): Promise<void> {
    await this.tools.plot.updateActivity({ match: filter, archived: true });
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
  // Message Thread Processing
  // ============================================================================

  async onMessageThread(
    thread: NewActivityWithNotes,
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

  private async analyzeThread(thread: NewActivityWithNotes): Promise<{
    needsTask: boolean;
    taskTitle: string | null;
    taskNote: string | null;
    confidence: number;
    isCompleted: boolean;
  }> {
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

If a task is needed, create a clear, actionable title that describes what the user needs to do.`,
      },
      ...thread.notes.map((note, idx) => ({
        role: "user" as const,
        content: `[Message ${idx + 1}] User: ${
          note.content || "(empty message)"
        }`,
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

  private async createTaskFromThread(
    thread: NewActivityWithNotes,
    analysis: {
      needsTask: boolean;
      taskTitle: string | null;
      taskNote: string | null;
      confidence: number;
    },
    _provider: MessageProvider,
    channelId: string
  ): Promise<void> {
    const threadId = "source" in thread ? thread.source : undefined;
    if (!threadId) {
      console.warn("Thread has no source, skipping task creation");
      return;
    }

    // Create task activity - database handles upsert automatically
    const taskId = await this.tools.plot.createActivity({
      source: `message-tasks:${threadId}`,
      type: ActivityType.Action,
      title: analysis.taskTitle || thread.title || "Action needed from message",
      start: new Date(),
      notes: analysis.taskNote
        ? [
            {
              content: `${analysis.taskNote}\n\n---\nFrom #${channelId}`,
            },
          ]
        : [
            {
              content: `From #${channelId}`,
            },
          ],
      preview: analysis.taskNote
        ? `${analysis.taskNote}\n\n---\nFrom #${channelId}`
        : `From #${channelId}`,
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
    thread: NewActivityWithNotes,
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
        await this.tools.plot.updateActivity({
          id: taskInfo.taskId,
          done: new Date(),
        });
      }
    } catch (error) {
      console.error("Failed to check thread for completion:", error);
    }
  }
}
