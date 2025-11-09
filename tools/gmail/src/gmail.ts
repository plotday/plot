import {
  type Activity,
  type ActivityLink,
  Tool,
  type ToolBuilder,
} from "@plotday/twister";
import {
  type MessageChannel,
  type MessageSyncOptions,
  type MessagingAuth,
  type MessagingTool,
} from "@plotday/twister/common/messaging";
import { type Callback } from "@plotday/twister/tools/callbacks";
import {
  AuthLevel,
  AuthProvider,
  type Authorization,
  Integrations,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { ActivityAccess, ContactAccess, Plot } from "@plotday/twister/tools/plot";

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
 *   async activate() {
 *     const authLink = await this.gmail.requestAuth(this.onGmailAuth);
 *
 *     await this.plot.createActivity({
 *       type: ActivityType.Task,
 *       title: "Connect Gmail",
 *       links: [authLink]
 *     });
 *   }
 *
 *   async onGmailAuth(auth: MessagingAuth) {
 *     const channels = await this.gmail.getChannels(auth.authToken);
 *
 *     // Start syncing inbox
 *     const inbox = channels.find(c => c.primary);
 *     if (inbox) {
 *       await this.gmail.startSync(
 *         auth.authToken,
 *         inbox.id,
 *         this.onGmailThread,
 *         {
 *           timeMin: new Date(Date.now() - 7 * 24 * 60 * 60 * 1000) // Last 7 days
 *         }
 *       );
 *     }
 *   }
 *
 *   async onGmailThread(thread: Activity[]) {
 *     // Process Gmail email threads
 *     for (const message of thread) {
 *       await this.plot.createActivity(message);
 *     }
 *   }
 * }
 * ```
 */
export class Gmail extends Tool<Gmail> implements MessagingTool {
  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
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

  async requestAuth<
    TCallback extends (auth: MessagingAuth, ...args: any[]) => any
  >(callback: TCallback, ...extraArgs: any[]): Promise<ActivityLink> {
    console.log("Requesting Gmail auth");

    // Gmail OAuth scopes for read-only access
    const gmailScopes = [
      "https://www.googleapis.com/auth/gmail.readonly",
      "https://www.googleapis.com/auth/gmail.modify",
    ];

    // Generate opaque token for authorization
    const authToken = crypto.randomUUID();

    const callbackToken = await this.tools.callbacks.createFromParent(
      callback,
      ...extraArgs
    );

    // Request auth and return the activity link
    // Use User level for user-scoped Gmail authorization
    return await this.tools.integrations.request(
      {
        provider: AuthProvider.Google,
        level: AuthLevel.User,
        scopes: gmailScopes,
      },
      this.onAuthSuccess,
      authToken,
      callbackToken
    );
  }

  private async getApi(authToken: string): Promise<GmailApi> {
    const authorization = await this.get<Authorization>(
      `authorization:${authToken}`
    );
    if (!authorization) {
      throw new Error("Authorization no longer available");
    }

    const token = await this.tools.integrations.get(authorization);
    if (!token) {
      throw new Error("Authorization no longer available");
    }

    return new GmailApi(token.token);
  }

  async getChannels(authToken: string): Promise<MessageChannel[]> {
    console.log("Fetching Gmail labels");
    const api = await this.getApi(authToken);
    const labels = await api.getLabels();
    console.log("Got Gmail labels", labels);

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
    TCallback extends (thread: Activity[], ...args: any[]) => any
  >(
    authToken: string,
    channelId: string,
    callback: TCallback,
    options?: MessageSyncOptions,
    ...extraArgs: any[]
  ): Promise<void> {
    console.log("Starting Gmail sync for channel", channelId);

    // Create callback token for parent
    const callbackToken = await this.tools.callbacks.createFromParent(
      callback,
      ...extraArgs
    );
    await this.set(`thread_callback_token_${channelId}`, callbackToken);

    // Store auth token for channel
    await this.set(`auth_token_${channelId}`, authToken);

    // Setup webhook for this channel (Gmail Push Notifications)
    await this.setupChannelWebhook(authToken, channelId);

    const initialState: SyncState = {
      channelId,
      lastSyncTime: options?.timeMin
        ? typeof options.timeMin === "string"
          ? new Date(options.timeMin)
          : options.timeMin
        : undefined,
    };

    await this.set(`sync_state_${channelId}`, initialState);

    console.log("Starting initial Gmail sync");
    // Start sync batch using run tool for long-running operation
    const syncCallback = await this.callback(
      this.syncBatch,
      1,
      "full",
      authToken,
      channelId
    );
    await this.run(syncCallback);
  }

  async stopSync(authToken: string, channelId: string): Promise<void> {
    console.log("Stopping Gmail sync for channel", channelId);

    // Stop watching for push notifications
    const api = await this.getApi(authToken);
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
    await this.clear(`thread_callback_token_${channelId}`);

    // Clear auth token
    await this.clear(`auth_token_${channelId}`);
  }

  private async setupChannelWebhook(
    authToken: string,
    channelId: string
  ): Promise<void> {
    // Retrieve the authorization for this auth token
    const authorization = await this.get<Authorization>(
      `authorization:${authToken}`
    );
    if (!authorization) {
      throw new Error("Authorization not found for Gmail webhook setup");
    }

    // Create Gmail webhook (returns Pub/Sub topic name, not a URL)
    // When provider is Google with Gmail scopes, createWebhook returns a Pub/Sub topic name
    const topicName = await this.tools.network.createWebhook({
      callback: this.onGmailWebhook,
      extraArgs: [channelId, authToken],
      provider: AuthProvider.Google,
      authorization,
    });

    const api = await this.getApi(authToken);

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
        createdAt: new Date().toISOString(),
      });

      console.log("Gmail webhook setup complete", {
        channelId,
        topicName,
        expiration: watchResult.expiration,
      });
    } catch (error) {
      console.error("Failed to setup Gmail webhook:", error);
      console.log(
        "Continuing without webhooks - only manual/scheduled syncs will work"
      );
    }
  }

  async syncBatch(
    _args: any,
    batchNumber: number,
    mode: "full" | "incremental",
    authToken: string,
    channelId: string
  ): Promise<void> {
    console.log(
      `Starting Gmail sync batch ${batchNumber} (${mode}) for channel ${channelId}`
    );

    try {
      const state = await this.get<SyncState>(`sync_state_${channelId}`);
      if (!state) {
        throw new Error("No sync state found");
      }

      const api = await this.getApi(authToken);

      // Use smaller batch size for Gmail (20 threads) to avoid timeouts
      const result = await syncGmailChannel(api, state, 20);

      if (result.threads.length > 0) {
        await this.processEmailThreads(result.threads, channelId, authToken);
        console.log(
          `Synced ${result.threads.length} threads in batch ${batchNumber} for channel ${channelId}`
        );
      }

      await this.set(`sync_state_${channelId}`, result.state);

      if (result.hasMore) {
        const syncCallback = await this.callback(
          this.syncBatch,
          batchNumber + 1,
          mode,
          authToken,
          channelId
        );
        await this.run(syncCallback);
      } else {
        console.log(
          `Gmail ${mode} sync completed after ${batchNumber} batches for channel ${channelId}`
        );
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
    channelId: string,
    authToken: string
  ): Promise<void> {
    for (const thread of threads) {
      try {
        // Transform Gmail thread to Activity array
        const activities = transformGmailThread(thread);

        if (activities.length === 0) continue;

        // Extract email addresses from all messages and create contacts
        const emailAddresses = new Set<string>();

        for (const activity of activities) {
          const meta = activity.meta as any;
          if (meta?.from?.email) {
            emailAddresses.add(meta.from.email);
          }
        }

        // Create contacts for all unique email addresses
        if (emailAddresses.size > 0) {
          const contacts = Array.from(emailAddresses).map((email) => {
            // Try to find the name from the activity meta
            const activity = activities.find(
              (act: any) => act.meta?.from?.email === email
            );
            const name = (activity?.meta as any)?.from?.name || null;

            return {
              email,
              name: name || undefined,
            };
          });

          await this.tools.plot.addContacts(contacts);
        }

        // Call parent callback with the thread
        const callbackToken = await this.get<string>(
          `thread_callback_token_${channelId}`
        );
        if (callbackToken) {
          // Pass activities as-is - the callback will handle conversion if needed
          await this.run(callbackToken as any, activities);
        }
      } catch (error) {
        console.error(`Failed to process Gmail thread ${thread.id}:`, error);
        // Continue processing other threads
      }
    }
  }

  async onGmailWebhook(
    request: WebhookRequest,
    channelId: string,
    authToken: string
  ): Promise<void> {
    console.log("Received Gmail webhook notification", {
      body: request.body,
      channelId,
    });

    // Gmail sends push notifications via Cloud Pub/Sub
    // The message body is base64-encoded
    const message = request.body?.message;
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

    console.log("Decoded Gmail notification:", data);

    // Gmail notifications contain historyId for incremental sync
    if (data.historyId) {
      await this.startIncrementalSync(channelId, authToken, data.historyId);
    }
  }

  private async startIncrementalSync(
    channelId: string,
    authToken: string,
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
      console.log("Gmail watch expired, renewing...");
      await this.setupChannelWebhook(authToken, channelId);
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
      authToken,
      channelId
    );
    await this.run(syncCallback);
  }

  async onAuthSuccess(
    authResult: Authorization,
    authToken: string,
    callback: Callback
  ): Promise<void> {
    // Store the actual auth token using opaque token as key
    await this.set(`authorization:${authToken}`, authResult);

    const authSuccessResult: MessagingAuth = {
      authToken,
    };

    await this.run(callback, authSuccessResult);

    // Clean up the callback token
    await this.clear(`auth_callback_token:${authToken}`);
  }
}

export default Gmail;
