import GoogleContacts from "@plotday/connector-google-contacts";
import {
  Connector,
  type ToolBuilder,
} from "@plotday/twister";
import type { Actor, NewActor, Note, Thread } from "@plotday/twister/plot";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";

import {
  GoogleChatApi,
  type Message,
  type Space,
  type SyncState,
  extractMessageId,
  extractSpaceId,
  groupMessagesByThread,
  senderToNewActor,
  syncChatSpace,
  transformChatThread,
} from "./google-chat-api";

const DM_CHANNEL_ID = "__direct_messages__";

/**
 * Google Chat connector for syncing spaces and messages into Plot.
 *
 * Supports bidirectional sync: reads messages in, replies from Plot.
 * Named spaces appear as individual channels; all DMs are grouped under
 * a single "Direct Messages" channel.
 *
 * **Requires Google Workspace accounts.** Google Chat API with user
 * authentication is only available to Workspace users.
 *
 * **OAuth Scopes (Sensitive tier):**
 * - `chat.spaces.readonly` — List spaces
 * - `chat.messages` — Read and send messages
 * - `chat.memberships.readonly` — List space members (for contact resolution)
 * - `chat.users.readstate.readonly` — Read state for initial sync
 */
export class GoogleChat extends Connector<GoogleChat> {
  static readonly PROVIDER = AuthProvider.Google;
  static readonly handleReplies = true;
  static readonly SCOPES = [
    "https://www.googleapis.com/auth/chat.spaces.readonly",
    "https://www.googleapis.com/auth/chat.messages",
    "https://www.googleapis.com/auth/chat.memberships.readonly",
    "https://www.googleapis.com/auth/chat.users.readstate.readonly",
  ];

  readonly provider = AuthProvider.Google;
  readonly scopes = Integrations.MergeScopes(
    GoogleChat.SCOPES,
    GoogleContacts.SCOPES
  );
  readonly linkTypes = [
    {
      type: "message",
      label: "Message",
      logo: "https://api.iconify.design/logos/google-chat.svg",
      logoMono: "https://api.iconify.design/simple-icons/googlechat.svg",
    },
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, {
        urls: [
          "https://chat.googleapis.com/*",
          "https://workspaceevents.googleapis.com/*",
        ],
      }),
      googleContacts: build(GoogleContacts),
    };
  }

  override async activate(context: {
    auth: Authorization;
    actor: Actor;
  }): Promise<void> {
    await this.set("auth_actor_id", context.actor.id);
  }

  // ---- Channel lifecycle ----

  async getChannels(
    _auth: Authorization,
    token: AuthToken
  ): Promise<Channel[]> {
    const api = new GoogleChatApi(token.token);
    const spaces = await api.listSpaces();

    const channels: Channel[] = [];

    // Named spaces as individual channels
    for (const space of spaces) {
      if (space.spaceType === "SPACE") {
        channels.push({
          id: space.name,
          title: space.displayName || extractSpaceId(space.name),
        });
      }
    }

    // Synthetic channel for all DMs and group DMs
    channels.push({
      id: DM_CHANNEL_ID,
      title: "Direct Messages",
    });

    return channels;
  }

  async onChannelEnabled(channel: Channel): Promise<void> {
    await this.set(`sync_enabled_${channel.id}`, true);

    // Setup webhook for real-time updates
    await this.setupChannelWebhook(channel.id);

    // Start initial sync
    const initialState: SyncState = {
      channelId: channel.id,
      initialSync: true,
    };
    await this.set(`sync_state_${channel.id}`, initialState);

    if (channel.id === DM_CHANNEL_ID) {
      // For DMs, list all DM spaces and sync each
      const syncCallback = await this.callback(this.syncDmSpaces, true);
      await this.run(syncCallback);
    } else {
      // For named spaces, sync directly
      const syncCallback = await this.callback(
        this.syncBatch,
        1,
        "full",
        channel.id,
        true
      );
      await this.run(syncCallback);
    }
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    // Clean up subscription
    const subData = await this.get<{ subscriptionId: string }>(
      `subscription_${channel.id}`
    );
    if (subData?.subscriptionId) {
      try {
        const api = await this.getApi(channel.id);
        await api.deleteSubscription(subData.subscriptionId);
      } catch (error) {
        console.error("Failed to delete subscription:", error);
      }
    }
    await this.clear(`subscription_${channel.id}`);
    await this.clear(`channel_webhook_${channel.id}`);
    await this.clear(`sync_state_${channel.id}`);
    await this.clear(`sync_enabled_${channel.id}`);
    await this.clear(`member_emails_${channel.id}`);
  }

  // ---- Auth ----

  private async getApi(channelId: string): Promise<GoogleChatApi> {
    // For DM channel, use the first enabled channel's token via integrations
    const lookupId = channelId === DM_CHANNEL_ID ? DM_CHANNEL_ID : channelId;
    const token = await this.tools.integrations.get(lookupId);
    if (!token) {
      throw new Error("No Google authentication token available");
    }
    return new GoogleChatApi(token.token);
  }

  // ---- Webhook setup (Workspace Events API via Pub/Sub) ----

  private async setupChannelWebhook(channelId: string): Promise<void> {
    if (channelId === DM_CHANNEL_ID) {
      // DMs: we don't subscribe to individual DM spaces during initial setup.
      // Instead, we subscribe to each DM space as we discover them.
      return;
    }

    const topicName = await this.tools.network.createWebhook(
      {},
      this.onChatWebhook,
      channelId
    );

    // Localhost guard
    if (
      topicName.includes("localhost") ||
      topicName.includes("127.0.0.1")
    ) {
      return;
    }

    try {
      const api = await this.getApi(channelId);
      const subscription = await api.createSubscription(
        channelId,
        topicName,
        [
          "google.workspace.chat.message.v1.created",
          "google.workspace.chat.message.v1.updated",
          "google.workspace.chat.message.v1.deleted",
        ]
      );

      await this.set(`subscription_${channelId}`, {
        subscriptionId: subscription.name,
        expireTime: subscription.expireTime,
      });
      await this.set(`channel_webhook_${channelId}`, {
        topicName,
        channelId,
        created: new Date().toISOString(),
      });

      // Schedule renewal before expiry
      await this.scheduleSubscriptionRenewal(channelId);
    } catch (error) {
      console.error("Failed to setup Google Chat webhook:", error);
    }
  }

  private async scheduleSubscriptionRenewal(
    channelId: string
  ): Promise<void> {
    const subData = await this.get<{
      subscriptionId: string;
      expireTime: string;
    }>(`subscription_${channelId}`);
    if (!subData?.expireTime) return;

    // Renew 24 hours before expiry
    const expiry = new Date(subData.expireTime);
    const renewAt = new Date(expiry.getTime() - 24 * 60 * 60 * 1000);

    // Only schedule if renewal is in the future
    if (renewAt > new Date()) {
      const renewCallback = await this.callback(
        this.renewSubscription,
        channelId
      );
      await this.run(renewCallback);
    }
  }

  async renewSubscription(channelId: string): Promise<void> {
    const subData = await this.get<{
      subscriptionId: string;
      expireTime: string;
    }>(`subscription_${channelId}`);
    if (!subData?.subscriptionId) return;

    try {
      const api = await this.getApi(channelId);
      const renewed = await api.renewSubscription(subData.subscriptionId);
      await this.set(`subscription_${channelId}`, {
        subscriptionId: renewed.name ?? subData.subscriptionId,
        expireTime: renewed.expireTime,
      });

      // Schedule next renewal
      await this.scheduleSubscriptionRenewal(channelId);
    } catch (error) {
      console.error("Failed to renew subscription:", error);
      // Re-create the subscription from scratch
      await this.setupChannelWebhook(channelId);
    }
  }

  // ---- Webhook handler ----

  async onChatWebhook(
    request: WebhookRequest,
    channelId: string
  ): Promise<void> {
    // Workspace Events API delivers via Pub/Sub (base64-encoded JSON)
    const body = request.body as { message?: { data: string } };
    const message = body?.message;
    if (!message) {
      console.warn("No message in webhook body");
      return;
    }

    let data: any;
    try {
      const decoded = atob(message.data);
      data = JSON.parse(decoded);
    } catch (error) {
      console.error("Failed to decode webhook message:", error);
      return;
    }

    // Trigger incremental sync for any message event
    if (data) {
      await this.startIncrementalSync(channelId);
    }
  }

  private async startIncrementalSync(channelId: string): Promise<void> {
    const enabled = await this.get<boolean>(`sync_enabled_${channelId}`);
    if (!enabled) return;

    const incrementalState: SyncState = {
      channelId,
      initialSync: false,
    };
    await this.set(`sync_state_${channelId}`, incrementalState);

    const syncCallback = await this.callback(
      this.syncBatch,
      1,
      "incremental",
      channelId,
      false
    );
    await this.run(syncCallback);
  }

  // ---- Batch sync ----

  async syncBatch(
    batchNumber: number,
    mode: "full" | "incremental",
    channelId: string,
    initialSync?: boolean
  ): Promise<void> {
    const isInitial = initialSync ?? mode === "full";

    try {
      const state = await this.get<SyncState>(`sync_state_${channelId}`);
      if (!state) {
        throw new Error("No sync state found");
      }

      const api = await this.getApi(channelId);
      const result = await syncChatSpace(api, state, 100);

      if (result.threads.length > 0) {
        // Resolve member emails for contact matching and private thread mentions
        const memberEmails = await this.getMemberEmails(api, channelId);
        const members: NewActor[] = [];
        for (const [, email] of memberEmails) {
          members.push({ email });
        }
        await this.processMessageThreads(
          result.threads,
          channelId,
          isInitial,
          memberEmails,
          members
        );
      }

      await this.set(`sync_state_${channelId}`, result.state);

      if (result.hasMore) {
        const syncCallback = await this.callback(
          this.syncBatch,
          batchNumber + 1,
          mode,
          channelId,
          isInitial
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
    threads: Message[][],
    channelId: string,
    initialSync: boolean,
    memberEmails?: Map<string, string>,
    members?: NewActor[]
  ): Promise<void> {
    const spaceId = extractSpaceId(channelId);

    for (const threadMessages of threads) {
      try {
        // Filter out messages we sent (dedup)
        const filtered = [];
        for (const msg of threadMessages) {
          const msgId = `message-${extractMessageId(msg.name)}`;
          const wasSent = await this.get<boolean>(`sent:${msgId}`);
          if (wasSent) {
            await this.clear(`sent:${msgId}`);
            continue;
          }
          filtered.push(msg);
        }

        if (filtered.length === 0) continue;

        const plotThread = transformChatThread(
          filtered,
          spaceId,
          initialSync,
          memberEmails,
          members
        );

        // Inject channel routing and sync metadata
        plotThread.channelId = channelId;
        plotThread.meta = {
          ...plotThread.meta,
          syncProvider: "google-chat",
          syncableId: channelId,
        };

        await this.tools.integrations.saveLink(plotThread);
      } catch (error) {
        console.error("Failed to process chat thread:", error);
      }
    }
  }

  /**
   * Fetches and caches member emails for a space, used to resolve
   * Google Chat user IDs to email addresses for contact matching.
   */
  private async getMemberEmails(
    api: GoogleChatApi,
    channelId: string
  ): Promise<Map<string, string>> {
    // Check cache
    const cached = await this.get<Record<string, string>>(
      `member_emails_${channelId}`
    );
    if (cached) {
      return new Map(Object.entries(cached));
    }

    try {
      const members = await api.listMembers(channelId);
      const emails = new Map<string, string>();
      for (const m of members) {
        if (m.member.email) {
          emails.set(m.member.name, m.member.email);
        }
      }

      // Cache for future batches
      await this.set(
        `member_emails_${channelId}`,
        Object.fromEntries(emails)
      );
      return emails;
    } catch (error) {
      console.error("Failed to fetch member emails:", error);
      return new Map();
    }
  }

  // ---- DM sync ----

  /**
   * Lists all DM-type spaces and syncs recent messages from each.
   */
  async syncDmSpaces(initialSync?: boolean): Promise<void> {
    const isInitial = initialSync ?? true;

    try {
      const api = await this.getApi(DM_CHANNEL_ID);
      const spaces = await api.listSpaces(
        'spaceType = "DIRECT_MESSAGE" OR spaceType = "GROUP_CHAT"'
      );

      for (const space of spaces) {
        // Skip bot DMs
        if (space.singleUserBotDm) continue;

        const dmState: SyncState = {
          channelId: space.name,
          initialSync: isInitial,
        };
        await this.set(`sync_state_${space.name}`, dmState);

        const syncCallback = await this.callback(
          this.syncDmBatch,
          1,
          space.name,
          isInitial
        );
        await this.run(syncCallback);
      }
    } catch (error) {
      console.error("Failed to sync DM spaces:", error);
      throw error;
    }
  }

  async syncDmBatch(
    batchNumber: number,
    spaceName: string,
    initialSync?: boolean
  ): Promise<void> {
    const isInitial = initialSync ?? true;

    try {
      const state = await this.get<SyncState>(`sync_state_${spaceName}`);
      if (!state) {
        throw new Error("No sync state found for DM space");
      }

      const api = await this.getApi(DM_CHANNEL_ID);
      const result = await syncChatSpace(api, state, 100);

      if (result.threads.length > 0) {
        const memberEmails = await this.getMemberEmails(api, spaceName);
        const spaceId = extractSpaceId(spaceName);

        // Build members list for private thread mentions
        const members: NewActor[] = [];
        for (const [, email] of memberEmails) {
          members.push({ email });
        }

        for (const threadMessages of result.threads) {
          try {
            const plotThread = transformChatThread(
              threadMessages,
              spaceId,
              isInitial,
              memberEmails,
              members
            );

            // Route DMs to the DM channel
            plotThread.channelId = DM_CHANNEL_ID;
            plotThread.meta = {
              ...plotThread.meta,
              syncProvider: "google-chat",
              syncableId: DM_CHANNEL_ID,
            };

            await this.tools.integrations.saveLink(plotThread);
          } catch (error) {
            console.error("Failed to process DM thread:", error);
          }
        }
      }

      await this.set(`sync_state_${spaceName}`, result.state);

      if (result.hasMore) {
        const syncCallback = await this.callback(
          this.syncDmBatch,
          batchNumber + 1,
          spaceName,
          isInitial
        );
        await this.run(syncCallback);
      } else {
        await this.clear(`sync_state_${spaceName}`);
      }
    } catch (error) {
      console.error(
        `Error in DM sync batch ${batchNumber} for ${spaceName}:`,
        error
      );
      throw error;
    }
  }

  // ---- Write-back: reply from Plot ----

  async onNoteCreated(note: Note, thread: Thread): Promise<void> {
    const meta = thread.meta ?? {};
    const channelId = (meta.channelId ?? meta.syncableId) as string;
    const spaceName = meta.spaceName as string;
    const threadName = meta.threadName as string;

    if (!spaceName) {
      console.error("No spaceName in meta for Google Chat reply");
      return;
    }

    const api = await this.getApi(channelId ?? DM_CHANNEL_ID);

    try {
      const result = await api.createMessage(
        spaceName,
        note.content ?? "",
        threadName
      );

      // Store sent message ID for dedup when synced back
      const msgId = `message-${extractMessageId(result.name)}`;
      await this.set(`sent:${msgId}`, true);
    } catch (error) {
      console.error("Failed to send Google Chat reply:", error);
    }
  }
}

export default GoogleChat;
