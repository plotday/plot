import {
  Source,
  type ToolBuilder,
} from "@plotday/twister";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";

type MessageChannel = {
  id: string;
  name: string;
  description: string | null;
  primary: boolean;
};

type MessageSyncOptions = {
  timeMin?: Date;
};

import {
  GmailApi,
  type GmailThread,
  type SyncState,
  syncGmailChannel,
  transformGmailThread,
} from "./gmail-api";

/**
 * Gmail integration source implementing the MessagingSource interface.
 *
 * Supports inbox, labels, and search filters as channels.
 * Auth is managed declaratively via provider config in build() and
 * handled through the twist edit modal.
 *
 * **Required OAuth Scopes:**
 * - `https://www.googleapis.com/auth/gmail.readonly` - Read emails
 * - `https://www.googleapis.com/auth/gmail.modify` - Modify labels
 */
export class Gmail extends Source<Gmail> {
  static readonly PROVIDER = AuthProvider.Google;
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
            getChannels: this.listSyncChannels,
            onChannelEnabled: this.onChannelEnabled,
            onChannelDisabled: this.onChannelDisabled,
            linkTypes: [{ type: "email", label: "Email", logo: "https://api.iconify.design/logos/google-gmail.svg" }],
          },
        ],
      }),
      network: build(Network, {
        urls: ["https://gmail.googleapis.com/gmail/v1/*"],
      }),
    };
  }

  async listSyncChannels(
    _auth: Authorization,
    token: AuthToken
  ): Promise<Channel[]> {
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

  async onChannelEnabled(channel: Channel): Promise<void> {
    await this.set(`sync_enabled_${channel.id}`, true);

    // Auto-start sync: setup webhook and queue first batch
    await this.setupChannelWebhook(channel.id);

    const initialState: SyncState = {
      channelId: channel.id,
    };

    await this.set(`sync_state_${channel.id}`, initialState);

    const syncCallback = await this.callback(
      this.syncBatch,
      1,
      "full",
      channel.id
    );
    await this.run(syncCallback);
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.stopSync(channel.id);
    await this.clear(`sync_enabled_${channel.id}`);
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

  async startSync(
    options: {
      channelId: string;
    } & MessageSyncOptions,
  ): Promise<void> {
    const { channelId, timeMin } = options;

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
    for (const thread of threads) {
      try {
        // Transform Gmail thread to NewLinkWithNotes
        const activityThread = transformGmailThread(thread);

        if (!activityThread.notes || activityThread.notes.length === 0) continue;

        // Inject channel ID for priority routing and sync metadata
        activityThread.channelId = channelId;
        activityThread.meta = {
          ...activityThread.meta,
          syncProvider: "google",
          syncableId: channelId,
        };

        // Save link directly via integrations
        await this.tools.integrations.saveLink(activityThread);
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
