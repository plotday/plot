import { Type } from "typebox";

import { Slack } from "@plotday/tool-slack";
import {
  type Activity,
  type ActivityLink,
  ActivityLinkType,
  ActivityType,
  type Priority,
  type ToolBuilder,
  Twist,
} from "@plotday/twister";
import type {
  MessageChannel,
  MessageSyncOptions,
  MessagingAuth,
  MessagingTool,
} from "@plotday/twister/common/messaging";
import { AI, type AIMessage } from "@plotday/twister/tools/ai";
import { ActivityAccess, Plot } from "@plotday/twister/tools/plot";

type MessageProvider = "slack";

type StoredMessagingAuth = {
  provider: MessageProvider;
  authToken: string;
};

type ChannelConfig = {
  provider: MessageProvider;
  channelId: string;
  channelName: string;
  authToken: string;
};

type ThreadTask = {
  threadId: string;
  taskId: string;
  createdAt: string;
  lastChecked: string;
};

export default class MessageTasksTwist extends Twist<MessageTasksTwist> {
  build(build: ToolBuilder) {
    return {
      slack: build(Slack),
      ai: build(AI),
      plot: build(Plot, {
        activity: {
          access: ActivityAccess.Create,
        },
      }),
    };
  }

  // ============================================================================
  // Provider Tool Helper
  // ============================================================================

  private getProviderTool(provider: MessageProvider): MessagingTool {
    switch (provider) {
      case "slack":
        return this.tools.slack;
      default:
        throw new Error(`Unknown messaging provider: ${provider}`);
    }
  }

  // ============================================================================
  // Storage Helpers
  // ============================================================================

  private async getOnboardingActivity(): Promise<
    Pick<Activity, "id"> | undefined
  > {
    const id = await this.get<string>("onboarding_activity_id");
    return id ? { id } : undefined;
  }

  private async getStoredAuths(): Promise<StoredMessagingAuth[]> {
    return (await this.get<StoredMessagingAuth[]>("messaging_auths")) || [];
  }

  private async addStoredAuth(
    provider: MessageProvider,
    authToken: string
  ): Promise<void> {
    const auths = await this.getStoredAuths();
    const existingIndex = auths.findIndex((a) => a.provider === provider);

    if (existingIndex >= 0) {
      auths[existingIndex].authToken = authToken;
    } else {
      auths.push({ provider, authToken });
    }

    await this.set("messaging_auths", auths);
  }

  private async getAuthToken(
    provider: MessageProvider
  ): Promise<string | null> {
    const auths = await this.getStoredAuths();
    const auth = auths.find((a) => a.provider === provider);
    return auth?.authToken || null;
  }

  private async getChannelConfigs(): Promise<ChannelConfig[]> {
    return (await this.get<ChannelConfig[]>("channel_configs")) || [];
  }

  private async addChannelConfig(config: ChannelConfig): Promise<void> {
    const configs = await this.getChannelConfigs();
    const existingIndex = configs.findIndex(
      (c) => c.provider === config.provider && c.channelId === config.channelId
    );

    if (existingIndex >= 0) {
      configs[existingIndex] = config;
    } else {
      configs.push(config);
    }

    await this.set("channel_configs", configs);
  }

  private async getThreadTask(threadId: string): Promise<ThreadTask | null> {
    const tasks = (await this.get<ThreadTask[]>("thread_tasks")) || [];
    return tasks.find((t) => t.threadId === threadId) || null;
  }

  private async storeThreadTask(
    threadId: string,
    taskId: string
  ): Promise<void> {
    const tasks = (await this.get<ThreadTask[]>("thread_tasks")) || [];
    tasks.push({
      threadId,
      taskId,
      createdAt: new Date().toISOString(),
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
  // Activation & Onboarding
  // ============================================================================

  async activate(_priority: Pick<Priority, "id">) {
    // Request auth from Slack
    const slackAuthLink = await this.tools.slack.requestAuth(
      this.onAuthComplete,
      "slack"
    );

    // Create onboarding activity with auth link
    const connectActivity = await this.tools.plot.createActivity({
      type: ActivityType.Task,
      title: "Connect messaging to create tasks",
      note: "I'll analyze your message threads and create tasks when action is needed.",
      start: new Date(),
      links: [slackAuthLink],
    });

    // Store for parent relationship
    await this.set("onboarding_activity_id", connectActivity.id);
  }

  // ============================================================================
  // Auth Flow
  // ============================================================================

  async onAuthComplete(
    authResult: MessagingAuth,
    provider: MessageProvider
  ): Promise<void> {
    if (!provider) {
      console.error("No provider specified in auth context");
      return;
    }

    // Store auth token
    await this.addStoredAuth(provider, authResult.authToken);

    try {
      // Fetch available channels
      const tool = this.getProviderTool(provider);
      const channels = await tool.getChannels(authResult.authToken);

      if (channels.length === 0) {
        await this.tools.plot.createActivity({
          type: ActivityType.Note,
          note: `No channels found for ${provider}.`,
          parent: await this.getOnboardingActivity(),
        });
        return;
      }

      // Create channel selection activity
      await this.createChannelSelectionActivity(
        provider,
        channels,
        authResult.authToken
      );
    } catch (error) {
      console.error(`Failed to fetch channels for ${provider}:`, error);
      await this.tools.plot.createActivity({
        type: ActivityType.Note,
        note: `Failed to connect to ${provider}. Please try again.`,
        parent: await this.getOnboardingActivity(),
      });
    }
  }

  private async createChannelSelectionActivity(
    provider: MessageProvider,
    channels: MessageChannel[],
    authToken: string
  ): Promise<void> {
    const links: ActivityLink[] = [];

    // Create callback link for each channel
    for (const channel of channels) {
      const token = await this.callback(
        this.onChannelSelected,
        provider,
        channel.id,
        channel.name,
        authToken
      );

      if (channel.primary) {
        links.unshift({
          title: `💬 ${channel.name} (Primary)`,
          type: ActivityLinkType.callback,
          callback: token,
        });
      } else {
        links.push({
          title: `💬 ${channel.name}`,
          type: ActivityLinkType.callback,
          callback: token,
        });
      }
    }

    // Create the channel selection activity
    await this.tools.plot.createActivity({
      type: ActivityType.Task,
      title: `Which ${provider} channels should I monitor?`,
      note: "Select channels where you want tasks created from actionable messages.",
      start: new Date(),
      links,
      parent: await this.getOnboardingActivity(),
    });
  }

  async onChannelSelected(
    _link: ActivityLink,
    provider: MessageProvider,
    channelId: string,
    channelName: string,
    authToken: string
  ): Promise<void> {
    console.log("Channel selected:", { provider, channelId, channelName });

    try {
      // Store channel config
      await this.addChannelConfig({
        provider,
        channelId,
        channelName,
        authToken,
      });

      // Start syncing the channel
      const tool = this.getProviderTool(provider);
      const syncOptions: MessageSyncOptions = {
        timeMin: new Date(Date.now() - 7 * 24 * 60 * 60 * 1000), // Last 7 days
      };

      await tool.startSync(
        authToken,
        channelId,
        this.onMessageThread,
        syncOptions,
        provider,
        channelId
      );

      console.log(`Started monitoring ${provider} channel: ${channelName}`);

      await this.tools.plot.createActivity({
        type: ActivityType.Note,
        note: `Now monitoring #${channelName} for actionable threads`,
        parent: await this.getOnboardingActivity(),
      });
    } catch (error) {
      console.error(
        `Failed to start monitoring channel ${channelName}:`,
        error
      );
      await this.tools.plot.createActivity({
        type: ActivityType.Note,
        note: `Failed to monitor #${channelName}. Please try again.`,
        parent: await this.getOnboardingActivity(),
      });
    }
  }

  // ============================================================================
  // Message Thread Processing
  // ============================================================================

  async onMessageThread(
    thread: Activity[],
    provider: MessageProvider,
    channelId: string
  ): Promise<void> {
    if (thread.length === 0) return;

    const threadId = thread[0].meta?.source as string;
    if (!threadId) {
      console.warn("Thread has no source meta, skipping");
      return;
    }

    console.log(
      `Processing thread: ${threadId} with ${thread.length} messages`
    );

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

    console.log(`Analysis for ${threadId}:`, analysis);

    if (!analysis.needsTask || analysis.confidence < 0.6) {
      // No task needed or low confidence
      console.log(
        `No task needed for thread ${threadId} (confidence: ${analysis.confidence})`
      );
      return;
    }

    // Create task from thread
    await this.createTaskFromThread(thread, analysis, provider, channelId);
  }

  private async analyzeThread(thread: Activity[]): Promise<{
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
      ...thread.map((activity, idx) => ({
        role: "user" as const,
        content: `[Message ${idx + 1}] ${activity.author?.name || "User"}: ${
          activity.note || activity.title || "(empty message)"
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
    thread: Activity[],
    analysis: {
      needsTask: boolean;
      taskTitle: string | null;
      taskNote: string | null;
      confidence: number;
    },
    provider: MessageProvider,
    channelId: string
  ): Promise<void> {
    const rootMessage = thread[0];
    const threadId = rootMessage.meta?.source as string;

    // Get channel name for context
    const configs = await this.getChannelConfigs();
    const channelConfig = configs.find(
      (c) => c.provider === provider && c.channelId === channelId
    );
    const channelName = channelConfig?.channelName || channelId;

    // Create task activity
    const task = await this.tools.plot.createActivity({
      type: ActivityType.Task,
      title:
        analysis.taskTitle || rootMessage.title || "Action needed from message",
      note: analysis.taskNote
        ? `${analysis.taskNote}\n\n---\nFrom #${channelName}`
        : `From #${channelName}`,
      start: new Date(),
      meta: {
        source: `message-tasks:${threadId}`,
        originalThreadId: threadId,
        provider,
        channelId,
        channelName,
      },
      // Use pickPriority for automatic priority matching
      pickPriority: { content: 50, mentions: 50 },
    });

    console.log(`Created task ${task.id} for thread ${threadId}`);

    // Store mapping
    await this.storeThreadTask(threadId, task.id);
  }

  private async checkThreadForCompletion(
    thread: Activity[],
    taskInfo: ThreadTask
  ): Promise<void> {
    // Only check the last few messages for completion signals
    const recentMessages = thread.slice(-3);

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
      ...recentMessages.map((activity) => ({
        role: "user" as const,
        content: `${activity.author?.name || "User"}: ${
          activity.note || activity.title || ""
        }`,
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
        console.log(
          `Marking task ${taskInfo.taskId} as complete (confidence: ${result.confidence})`
        );
        await this.tools.plot.updateActivity({
          id: taskInfo.taskId,
          doneAt: new Date(),
        });
      }
    } catch (error) {
      console.error("Failed to check thread for completion:", error);
    }
  }
}
