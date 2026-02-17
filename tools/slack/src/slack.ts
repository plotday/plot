import {
  type ActivityFilter,
  type NewActivityWithNotes,
  Serializable,
  type SyncToolOptions,
  Tool,
  type ToolBuilder,
} from "@plotday/twister";
import {
  type MessageChannel,
  type MessageSyncOptions,
  type MessagingTool,
} from "@plotday/twister/common/messaging";
import { type Callback } from "@plotday/twister/tools/callbacks";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Syncable,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import {
  ActivityAccess,
  ContactAccess,
  Plot,
} from "@plotday/twister/tools/plot";

import {
  SlackApi,
  type SlackChannel,
  type SlackMessage,
  type SyncState,
  syncSlackChannel,
  transformSlackThread,
} from "./slack-api";

/**
 * Slack integration tool.
 *
 * Provides seamless integration with Slack, supporting message
 * synchronization, real-time updates via webhooks, and thread handling.
 * Designed for multitenant "Add to Slack" installations.
 *
 * **Features:**
 * - OAuth 2.0 authentication with Slack (bot token)
 * - Workspace-level installations with bot scopes
 * - Real-time message synchronization
 * - Webhook-based change notifications via Slack Events API
 * - Support for threaded messages
 * - User mentions and reactions
 * - Batch processing for large channels
 *
 * **Required OAuth Bot Scopes:**
 * - `channels:history` - Read public channel messages
 * - `channels:read` - View basic channel info
 * - `groups:history` - Read private channel messages
 * - `groups:read` - View basic private channel info
 * - `users:read` - View users in workspace
 * - `users:read.email` - View user email addresses
 * - `chat:write` - Send messages as the bot
 * - `im:history` - Read direct messages with the bot
 * - `mpim:history` - Read group direct messages
 *
 * @example
 * ```typescript
 * class MessagesTwist extends Twist {
 *   private slack: Slack;
 *
 *   constructor(id: string, tools: Tools) {
 *     super();
 *     this.slack = tools.get(Slack);
 *   }
 *
 *   async activate() {
 *     const authLink = await this.slack.requestAuth(this.onSlackAuth);
 *
 *     await this.plot.createActivity({
 *       type: ActivityType.Action,
 *       title: "Connect Slack",
 *       links: [authLink]
 *     });
 *   }
 *
 *   async onSlackAuth(auth: MessagingAuth) {
 *     const channels = await this.slack.getChannels(auth.authToken);
 *
 *     // Start syncing a channel
 *     const general = channels.find(c => c.name === "general");
 *     if (general) {
 *       await this.slack.startSync(
 *         auth.authToken,
 *         general.id,
 *         this.onSlackThread,
 *         {
 *           timeMin: new Date(Date.now() - 7 * 24 * 60 * 60 * 1000) // Last 7 days
 *         }
 *       );
 *     }
 *   }
 *
 *   async onSlackThread(thread: ActivityWithNotes) {
 *     // Process Slack message thread
 *     // thread contains the Activity with thread.notes containing each message
 *     console.log(`Thread: ${thread.title}`);
 *     console.log(`${thread.notes.length} messages`);
 *   }
 * }
 * ```
 */
export class Slack extends Tool<Slack> implements MessagingTool {
  static readonly PROVIDER = AuthProvider.Slack;
  static readonly Options: SyncToolOptions;
  declare readonly Options: SyncToolOptions;
  static readonly SCOPES = [
    "channels:history",
    "channels:read",
    "groups:history",
    "groups:read",
    "users:read",
    "users:read.email",
    "chat:write",
    "im:history",
    "mpim:history",
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations, {
        providers: [{
          provider: Slack.PROVIDER,
          scopes: Slack.SCOPES,
          getSyncables: this.getSyncables,
          onSyncEnabled: this.onSyncEnabled,
          onSyncDisabled: this.onSyncDisabled,
        }],
      }),
      network: build(Network, { urls: ["https://slack.com/api/*"] }),
      plot: build(Plot, {
        contact: { access: ContactAccess.Write },
        activity: { access: ActivityAccess.Create },
      }),
    };
  }

  async getSyncables(_auth: Authorization, token: AuthToken): Promise<Syncable[]> {
    const api = new SlackApi(token.token);
    const channels = await api.getChannels();
    return channels
      .filter((c: SlackChannel) => c.is_member && !c.is_archived)
      .map((c: SlackChannel) => ({ id: c.id, title: c.name }));
  }

  async onSyncEnabled(syncable: Syncable): Promise<void> {
    await this.set(`sync_enabled_${syncable.id}`, true);

    // Create item callback token from parent's onItem handler
    const itemCallbackToken = await this.tools.callbacks.createFromParent(
      this.options.onItem
    );
    await this.set(`item_callback_${syncable.id}`, itemCallbackToken);

    // Create disable callback if parent provided onSyncableDisabled
    if (this.options.onSyncableDisabled) {
      const filter: ActivityFilter = {
        meta: { syncProvider: "slack", syncableId: syncable.id },
      };
      const disableCallbackToken = await this.tools.callbacks.createFromParent(
        this.options.onSyncableDisabled,
        filter
      );
      await this.set(`disable_callback_${syncable.id}`, disableCallbackToken);
    }

    // Auto-start sync: setup webhook and queue first batch
    await this.setupChannelWebhook(syncable.id);

    let oldest: string | undefined;
    // Default to 30 days of history
    const timeMin = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
    oldest = (timeMin.getTime() / 1000).toString();

    const initialState: SyncState = {
      channelId: syncable.id,
      oldest,
    };

    await this.set(`sync_state_${syncable.id}`, initialState);

    const syncCallback = await this.callback(
      this.syncBatch,
      1,
      "full",
      syncable.id
    );
    await this.run(syncCallback);
  }

  async onSyncDisabled(syncable: Syncable): Promise<void> {
    await this.stopSync(syncable.id);

    // Run and clean up disable callback
    const disableCallbackToken = await this.get<Callback>(
      `disable_callback_${syncable.id}`
    );
    if (disableCallbackToken) {
      await this.tools.callbacks.run(disableCallbackToken);
      await this.deleteCallback(disableCallbackToken);
      await this.clear(`disable_callback_${syncable.id}`);
    }

    // Clean up item callback
    const itemCallbackToken = await this.get<Callback>(
      `item_callback_${syncable.id}`
    );
    if (itemCallbackToken) {
      await this.deleteCallback(itemCallbackToken);
      await this.clear(`item_callback_${syncable.id}`);
    }

    await this.clear(`sync_enabled_${syncable.id}`);
  }

  private async getApi(channelId: string): Promise<SlackApi> {
    const token = await this.tools.integrations.get(Slack.PROVIDER, channelId);
    if (!token) {
      throw new Error("No Slack authentication token available");
    }
    return new SlackApi(token.token);
  }

  async getChannels(channelId: string): Promise<MessageChannel[]> {
    const api = await this.getApi(channelId);
    const channels = await api.getChannels();

    return channels
      .filter(
        (channel: SlackChannel) => channel.is_member && !channel.is_archived
      )
      .map((channel: SlackChannel) => ({
        id: channel.id,
        name: channel.name,
        description: channel.topic?.value || channel.purpose?.value || null,
        primary: channel.name === "general", // Slack convention
      }));
  }

  async startSync<
    TArgs extends Serializable[],
    TCallback extends (thread: NewActivityWithNotes, ...args: TArgs) => any
  >(
    options: {
      channelId: string;
    } & MessageSyncOptions,
    callback: TCallback,
    ...extraArgs: TArgs
  ): Promise<void> {
    const { channelId } = options;

    // Create callback token for parent
    const callbackToken = await this.tools.callbacks.createFromParent(
      callback,
      ...extraArgs
    );
    await this.set(`item_callback_${channelId}`, callbackToken);

    // Setup webhook for this channel (Slack Events API)
    await this.setupChannelWebhook(channelId);

    // Calculate oldest timestamp for sync
    let oldest: string | undefined;
    if (options?.timeMin) {
      const timeMin =
        typeof options.timeMin === "string"
          ? new Date(options.timeMin)
          : options.timeMin;
      oldest = (timeMin.getTime() / 1000).toString();
    }

    const initialState: SyncState = {
      channelId,
      oldest,
    };

    await this.set(`sync_state_${channelId}`, initialState);

    // Start sync batch using run tool for long-running operation
    const syncCallback = await this.callback(
      this.syncBatch,
      1,
      "full",
      channelId
    );
    await this.run(syncCallback);
  }

  async stopSync(channelId: string): Promise<void> {
    // Clear webhook
    await this.clear(`channel_webhook_${channelId}`);

    // Clear sync state
    await this.clear(`sync_state_${channelId}`);

    // Clear callback token
    await this.clear(`item_callback_${channelId}`);
  }

  private async setupChannelWebhook(
    channelId: string
  ): Promise<void> {
    const webhookUrl = await this.tools.network.createWebhook(
      {},
      this.onSlackWebhook,
      channelId
    );

    // Check if webhook URL is localhost
    if (URL.parse(webhookUrl)?.hostname === "localhost") {
      return;
    }

    // Store webhook URL for this channel
    // Note: Slack Events API setup typically requires manual configuration
    // in the Slack app settings to point to this webhook URL
    await this.set(`channel_webhook_${channelId}`, {
      url: webhookUrl,
      channelId,
      created: new Date().toISOString(),
    });

  }

  async syncBatch(
    batchNumber: number,
    mode: "full" | "incremental",
    channelId: string
  ): Promise<void> {
    try {
      const state = await this.get<SyncState>(`sync_state_${channelId}`);
      if (!state) {
        throw new Error("No sync state found");
      }

      const api = await this.getApi(channelId);
      const result = await syncSlackChannel(api, state);

      if (result.threads.length > 0) {
        await this.processMessageThreads(result.threads, channelId);
      }

      await this.set(`sync_state_${channelId}`, result.state);

      if (result.state.more) {
        const syncCallback = await this.callback(
          this.syncBatch,
          batchNumber + 1,
          mode,
          channelId
        );
        await this.run(syncCallback);
      } else {
        if (mode === "full") {
          await this.clear(`sync_state_${channelId}`);
        }
      }
    } catch (error) {
      console.error(
        `Error in sync batch ${batchNumber} for channel ${channelId}:`,
        error
      );

      throw error;
    }
  }

  private async processMessageThreads(
    threads: SlackMessage[][],
    channelId: string
  ): Promise<void> {
    const callbackToken = await this.get<Callback>(
      `item_callback_${channelId}`
    );

    if (!callbackToken) {
      console.error("No callback token found for channel", channelId);
      return;
    }

    for (const thread of threads) {
      try {
        // Transform Slack thread to NewActivityWithNotes
        const activityThread = transformSlackThread(thread, channelId);

        if (activityThread.notes.length === 0) continue;

        // Inject sync metadata for the parent to identify the source
        activityThread.meta = { ...activityThread.meta, syncProvider: "slack", syncableId: channelId };

        // Call parent callback with the thread (contacts will be created by the API)
        await this.run(callbackToken, activityThread);
      } catch (error) {
        console.error(`Failed to process thread:`, error);
        // Continue processing other threads
      }
    }
  }

  async onSlackWebhook(
    request: WebhookRequest,
    channelId: string
  ): Promise<void> {
    const body = request.body;
    if (!body || typeof body !== "object" || Array.isArray(body)) {
      console.warn("Invalid webhook body format");
      return;
    }

    // Slack sends a challenge parameter for URL verification
    const bodyObj = body as { challenge?: string; event?: any };
    if (bodyObj.challenge) {
      // Note: The webhook infrastructure should handle responding with the challenge
      return;
    }

    // Validate webhook authenticity
    // In production, you should verify the request signature
    // using the signing secret from your Slack app

    const event = bodyObj.event;
    if (!event) {
      console.warn("No event in webhook body");
      return;
    }

    // Only process message events for the specific channel
    if (
      event.type === "message" &&
      event.channel === channelId &&
      !event.subtype // Ignore bot messages and special subtypes
    ) {
      // Trigger incremental sync
      await this.startIncrementalSync(channelId);
    }
  }

  private async startIncrementalSync(
    channelId: string
  ): Promise<void> {
    const webhookData = await this.get<any>(`channel_webhook_${channelId}`);
    if (!webhookData) {
      console.error("No channel webhook data found");
      return;
    }

    // For incremental sync, we only fetch recent messages
    const incrementalState: SyncState = {
      channelId,
      latest: (Date.now() / 1000).toString(),
      oldest: ((Date.now() - 60 * 60 * 1000) / 1000).toString(), // Last hour
    };

    await this.set(`sync_state_${channelId}`, incrementalState);
    const syncCallback = await this.callback(
      this.syncBatch,
      1,
      "incremental",
      channelId
    );
    await this.run(syncCallback);
  }

}

export default Slack;
