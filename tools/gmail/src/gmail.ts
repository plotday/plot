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
  GmailApi,
  type GmailThread,
  type SyncState,
  syncGmailChannel,
  transformGmailThread,
} from "./gmail-api";

/**
 * Gmail integration tool implementing the MessagingTool interface.
 *
 * Supports inbox, labels, and search filters as channels.
 * Auth is managed declaratively via provider config in build() and
 * handled through the twist edit modal.
 *
 * **Required OAuth Scopes:**
 * - `https://www.googleapis.com/auth/gmail.readonly` - Read emails
 * - `https://www.googleapis.com/auth/gmail.modify` - Modify labels
 *
 * @example
 * ```typescript
 * class MessagesTwist extends Twist {
 *   private gmail: Gmail;
 *
 *   constructor(id: string, tools: Tools) {
 *     super();
 *     this.gmail = tools.get(Gmail);
 *   }
 *
 *   // Auth is handled via the twist edit modal.
 *   // When sync is enabled on a channel, onSyncEnabled fires and
 *   // the twist can start syncing:
 *
 *   async onGmailSyncEnabled(channelId: string) {
 *     await this.gmail.startSync(
 *       { channelId, timeMin: new Date(Date.now() - 7 * 24 * 60 * 60 * 1000) },
 *       this.onGmailThread
 *     );
 *   }
 *
 *   async onGmailThread(thread: ActivityWithNotes) {
 *     // Process Gmail email thread
 *     // Each thread is an Activity with Notes for each email
 *     console.log(`Email thread: ${thread.title}`);
 *     console.log(`${thread.notes.length} messages`);
 *
 *     // Access individual messages as Notes
 *     for (const note of thread.notes) {
 *       console.log(`From: ${note.author.email}, To: ${note.mentions?.join(", ")}`);
 *     }
 *   }
 * }
 * ```
 */
export class Gmail extends Tool<Gmail> implements MessagingTool {
  static readonly PROVIDER = AuthProvider.Google;
  static readonly Options: SyncToolOptions;
  declare readonly Options: SyncToolOptions;
  static readonly SCOPES = [
    "https://www.googleapis.com/auth/gmail.readonly",
    "https://www.googleapis.com/auth/gmail.modify",
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations, {
        providers: [
          {
            provider: Gmail.PROVIDER,
            scopes: Gmail.SCOPES,
            getSyncables: this.getSyncables,
            onSyncEnabled: this.onSyncEnabled,
            onSyncDisabled: this.onSyncDisabled,
          },
        ],
      }),
      network: build(Network, {
        urls: ["https://gmail.googleapis.com/gmail/v1/*"],
      }),
      plot: build(Plot, {
        contact: {
          access: ContactAccess.Write,
        },
        activity: {
          access: ActivityAccess.Create,
        },
      }),
    };
  }

  async getSyncables(
    _auth: Authorization,
    token: AuthToken
  ): Promise<Syncable[]> {
    const api = new GmailApi(token.token);
    const labels = await api.getLabels();
    return labels
      .filter(
        (l: any) =>
          l.type !== "system" ||
          ["INBOX", "SENT", "DRAFT", "IMPORTANT", "STARRED"].includes(l.id)
      )
      .map((l: any) => ({ id: l.id, title: l.name }));
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
        meta: { syncProvider: "google", syncableId: syncable.id },
      };
      const disableCallbackToken = await this.tools.callbacks.createFromParent(
        this.options.onSyncableDisabled,
        filter
      );
      await this.set(`disable_callback_${syncable.id}`, disableCallbackToken);
    }

    // Auto-start sync: setup webhook and queue first batch
    await this.setupChannelWebhook(syncable.id);

    const initialState: SyncState = {
      channelId: syncable.id,
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

  private async getApi(channelId: string): Promise<GmailApi> {
    const token = await this.tools.integrations.get(Gmail.PROVIDER, channelId);
    if (!token) {
      throw new Error("No Google authentication token available");
    }
    return new GmailApi(token.token);
  }

  async getChannels(channelId: string): Promise<MessageChannel[]> {
    const api = await this.getApi(channelId);
    const labels = await api.getLabels();

    const channels: MessageChannel[] = [];

    // Add standard labels as channels
    for (const label of labels) {
      // Filter out system labels that don't make sense as channels
      if (
        label.type === "system" &&
        !["INBOX", "SENT", "DRAFT", "IMPORTANT", "STARRED"].includes(label.id)
      ) {
        continue;
      }

      channels.push({
        id: label.id,
        name: label.name,
        description: `${label.messagesTotal || 0} messages, ${
          label.messagesUnread || 0
        } unread`,
        primary: label.id === "INBOX",
      });
    }

    // Add a special "search" channel option
    channels.push({
      id: "search:from:important@example.com",
      name: "Search (Custom Query)",
      description: "Use custom Gmail search queries as channels",
      primary: false,
    });

    return channels;
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
    const { channelId, timeMin } = options;

    // Create callback token for parent
    const callbackToken = await this.tools.callbacks.createFromParent(
      callback,
      ...extraArgs
    );
    await this.set(`item_callback_${channelId}`, callbackToken);

    // Setup webhook for this channel (Gmail Push Notifications)
    await this.setupChannelWebhook(channelId);

    const initialState: SyncState = {
      channelId,
      lastSyncTime: timeMin
        ? typeof timeMin === "string"
          ? new Date(timeMin)
          : timeMin
        : undefined,
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
    // Stop watching for push notifications
    const api = await this.getApi(channelId);
    try {
      await api.stopWatch();
    } catch (error) {
      console.error("Failed to stop Gmail watch:", error);
    }

    // Clear webhook
    await this.clear(`channel_webhook_${channelId}`);

    // Clear sync state
    await this.clear(`sync_state_${channelId}`);

    // Clear callback token
    await this.clear(`item_callback_${channelId}`);
  }

  private async setupChannelWebhook(channelId: string): Promise<void> {
    // Create Gmail webhook (returns Pub/Sub topic name, not a URL)
    // When provider is Google with Gmail scopes, createWebhook returns a Pub/Sub topic name
    const topicName = await this.tools.network.createWebhook(
      {},
      this.onGmailWebhook,
      channelId
    );

    const api = await this.getApi(channelId);

    try {
      // Setup Gmail watch with the Pub/Sub topic name
      // topicName format: projects/{project_id}/topics/{topic_name}
      const watchResult = await api.setupWatch(channelId, topicName);

      // Store webhook data including expiration
      await this.set(`channel_webhook_${channelId}`, {
        topicName,
        channelId,
        historyId: watchResult.historyId,
        expiration: new Date(parseInt(watchResult.expiration)),
        created: new Date().toISOString(),
      });
    } catch (error) {
      console.error("Failed to setup Gmail webhook:", error);
    }
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

      // Use smaller batch size for Gmail (20 threads) to avoid timeouts
      const result = await syncGmailChannel(api, state, 20);

      if (result.threads.length > 0) {
        await this.processEmailThreads(result.threads, channelId);
      }

      await this.set(`sync_state_${channelId}`, result.state);

      if (result.hasMore) {
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

  private async processEmailThreads(
    threads: GmailThread[],
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
        // Transform Gmail thread to NewActivityWithNotes
        const activityThread = transformGmailThread(thread);

        if (activityThread.notes.length === 0) continue;

        // Inject sync metadata for the parent to identify the source
        activityThread.meta = {
          ...activityThread.meta,
          syncProvider: "google",
          syncableId: channelId,
        };

        // Call parent callback with the thread (contacts will be created by the API)
        await this.run(callbackToken, activityThread);
      } catch (error) {
        console.error(`Failed to process Gmail thread ${thread.id}:`, error);
        // Continue processing other threads
      }
    }
  }

  async onGmailWebhook(
    request: WebhookRequest,
    channelId: string
  ): Promise<void> {
    // Gmail sends push notifications via Cloud Pub/Sub
    // The message body is base64-encoded
    const body = request.body as { message?: { data: string } };
    const message = body?.message;
    if (!message) {
      console.warn("No message in webhook body");
      return;
    }

    // Decode the Pub/Sub message
    let data: any;
    try {
      const decoded = atob(message.data);
      data = JSON.parse(decoded);
    } catch (error) {
      console.error("Failed to decode Gmail webhook message:", error);
      return;
    }

    // Gmail notifications contain historyId for incremental sync
    if (data.historyId) {
      await this.startIncrementalSync(channelId, data.historyId);
    }
  }

  private async startIncrementalSync(
    channelId: string,
    historyId: string
  ): Promise<void> {
    const webhookData = await this.get<any>(`channel_webhook_${channelId}`);
    if (!webhookData) {
      console.error("No channel webhook data found");
      return;
    }

    // Check if watch has expired and renew if needed
    const expiration = new Date(webhookData.expiration);
    if (expiration < new Date()) {
      await this.setupChannelWebhook(channelId);
    }

    // For incremental sync, use the historyId from the notification
    const incrementalState: SyncState = {
      channelId,
      historyId,
      lastSyncTime: new Date(),
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

export default Gmail;
