import {
  type ActivityLink,
  type ActivityWithNotes,
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
  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, {
        urls: ["https://slack.com/api/*"],
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
    console.log("Requesting Slack auth");
    // Bot scopes for workspace-level "Add to Slack" installation
    // These are the scopes the bot token will have
    const slackScopes = [
      "channels:history", // Read messages in public channels
      "channels:read", // View basic channel info
      "groups:history", // Read messages in private channels (if bot is added)
      "groups:read", // View basic private channel info
      "users:read", // View users in workspace
      "users:read.email", // View user email addresses
      "chat:write", // Send messages as the bot
      "im:history", // Read direct messages with the bot
      "mpim:history", // Read group direct messages
    ];

    // Generate opaque token for authorization
    const authToken = crypto.randomUUID();

    const callbackToken = await this.tools.callbacks.createFromParent(
      callback,
      ...extraArgs
    );

    // Request auth and return the activity link
    // Use Priority level for workspace-scoped authorization
    return await this.tools.integrations.request(
      {
        provider: AuthProvider.Slack,
        level: AuthLevel.Priority,
        scopes: slackScopes,
      },
      this.onAuthSuccess,
      authToken,
      callbackToken
    );
  }

  private async getApi(authToken: string): Promise<SlackApi> {
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

    return new SlackApi(token.token);
  }

  async getChannels(authToken: string): Promise<MessageChannel[]> {
    console.log("Fetching Slack channels");
    const api = await this.getApi(authToken);
    const channels = await api.getChannels();
    console.log("Got Slack channels", channels);

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
    TCallback extends (thread: ActivityWithNotes, ...args: any[]) => any
  >(
    authToken: string,
    channelId: string,
    callback: TCallback,
    options?: MessageSyncOptions,
    ...extraArgs: any[]
  ): Promise<void> {
    console.log("Starting Slack sync for channel", channelId);

    // Create callback token for parent
    const callbackToken = await this.tools.callbacks.createFromParent(
      callback,
      ...extraArgs
    );
    await this.set(`thread_callback_token_${channelId}`, callbackToken);

    // Store auth token for channel
    await this.set(`auth_token_${channelId}`, authToken);

    // Setup webhook for this channel (Slack Events API)
    await this.setupChannelWebhook(authToken, channelId);

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

    console.log("Starting initial sync");
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
    console.log("Stopping Slack sync for channel", channelId);

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
    const webhookUrl = await this.tools.network.createWebhook({
      callback: this.onSlackWebhook,
      extraArgs: [channelId, authToken],
    });

    // Check if webhook URL is localhost
    if (URL.parse(webhookUrl)?.hostname === "localhost") {
      console.log("Skipping webhook setup for localhost URL");
      return;
    }

    // Store webhook URL for this channel
    // Note: Slack Events API setup typically requires manual configuration
    // in the Slack app settings to point to this webhook URL
    await this.set(`channel_webhook_${channelId}`, {
      url: webhookUrl,
      channelId,
      createdAt: new Date().toISOString(),
    });

    console.log("Channel webhook setup complete", { channelId, webhookUrl });
  }

  async syncBatch(
    batchNumber: number,
    mode: "full" | "incremental",
    authToken: string,
    channelId: string
  ): Promise<void> {
    console.log(
      `Starting Slack sync batch ${batchNumber} (${mode}) for channel ${channelId}`
    );

    try {
      const state = await this.get<SyncState>(`sync_state_${channelId}`);
      if (!state) {
        throw new Error("No sync state found");
      }

      const api = await this.getApi(authToken);
      const result = await syncSlackChannel(api, state);

      if (result.threads.length > 0) {
        await this.processMessageThreads(result.threads, channelId, authToken);
        console.log(
          `Synced ${result.threads.length} threads in batch ${batchNumber} for channel ${channelId}`
        );
      }

      await this.set(`sync_state_${channelId}`, result.state);

      if (result.state.more) {
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
          `Slack ${mode} sync completed after ${batchNumber} batches for channel ${channelId}`
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

  private async processMessageThreads(
    threads: SlackMessage[][],
    channelId: string,
    authToken: string
  ): Promise<void> {
    const api = await this.getApi(authToken);
    const callbackToken = await this.get<Callback>(
      `thread_callback_token_${channelId}`
    );

    if (!callbackToken) {
      console.error("No callback token found for channel", channelId);
      return;
    }

    for (const thread of threads) {
      try {
        // Transform Slack thread to ActivityWithNotes
        const activityThread = transformSlackThread(thread, channelId);

        if (activityThread.notes.length === 0) continue;

        // Extract unique Slack user IDs from notes
        const userIdSet = new Set<string>();

        for (const note of activityThread.notes) {
          // Add author if it's a Slack user
          if (note.author.id.startsWith("slack:")) {
            const userId = note.author.id.replace("slack:", "");
            userIdSet.add(userId);
          }

          // Add mentioned users
          if (note.mentions) {
            for (const mentionId of note.mentions) {
              if (mentionId.startsWith("slack:")) {
                const userId = mentionId.replace("slack:", "");
                userIdSet.add(userId);
              }
            }
          }
        }

        // Fetch user info and create contacts
        for (const userId of userIdSet) {
          const user = await api.getUser(userId);
          if (user && user.profile?.email) {
            await this.tools.plot.addContacts([
              {
                email: user.profile.email,
                name:
                  user.profile?.display_name ||
                  user.profile?.real_name ||
                  user.name,
              },
            ]);
          }
        }

        // Call parent callback with single thread
        await this.run(callbackToken, activityThread);
      } catch (error) {
        console.error(`Failed to process thread:`, error);
        // Continue processing other threads
      }
    }
  }

  async onSlackWebhook(
    request: WebhookRequest,
    channelId: string,
    authToken: string
  ): Promise<void> {
    console.log("Received Slack webhook notification", {
      body: request.body,
      channelId,
    });

    // Slack sends a challenge parameter for URL verification
    if (request.body?.challenge) {
      console.log("Responding to Slack challenge");
      return request.body.challenge;
    }

    // Validate webhook authenticity
    // In production, you should verify the request signature
    // using the signing secret from your Slack app

    const event = request.body?.event;
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
      await this.startIncrementalSync(channelId, authToken);
    }
  }

  private async startIncrementalSync(
    channelId: string,
    authToken: string
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

export default Slack;
