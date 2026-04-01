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
  type MemberInfo,
  type SyncState,
  extractMessageId,
  extractSpaceId,
  toSpaceName,
  syncChatSpace,
  transformChatThread,
} from "./google-chat-api";

const DM_CHANNEL_ID = "__direct_messages__";
const MAX_SYNC_BATCHES = 50;

/** Workspace Events event types for Google Chat messages. */
const CHAT_EVENT_TYPES = [
  "google.workspace.chat.message.v1.created",
  "google.workspace.chat.message.v1.updated",
  "google.workspace.chat.message.v1.deleted",
];

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
      // Logo: full-color SVG from static assets (iconify has no logos/google-chat)
      // logoMono: monochrome version from simple-icons (works fine on iconify)
      logo: "https://plot.day/assets/logo-google-chat.svg",
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
    const channels: Channel[] = [];

    // Named spaces as individual channels
    try {
      const spaces = await api.listSpaces();
      for (const space of spaces) {
        if (space.spaceType === "SPACE") {
          channels.push({
            id: extractSpaceId(space.name),
            title: space.displayName || extractSpaceId(space.name),
          });
        }
      }
    } catch {
      // Chat API may not be configured — still return the DM channel
    }

    // Synthetic channel for all DMs and group DMs (always included)
    channels.push({
      id: DM_CHANNEL_ID,
      title: "Direct Messages",
    });

    return channels;
  }

  async onChannelEnabled(channel: Channel): Promise<void> {
    await this.set(`sync_enabled_${channel.id}`, true);

    // Start initial sync
    const initialState: SyncState = {
      channelId: channel.id,
      initialSync: true,
    };
    await this.set(`sync_state_${channel.id}`, initialState);

    if (channel.id === DM_CHANNEL_ID) {
      // For DMs, list all DM spaces and sync each (batch only, no realtime)
      const syncCallback = await this.callback(this.syncDmSpaces, true);
      await this.run(syncCallback);
    } else {
      // For named spaces, sync directly and setup realtime via Workspace Events
      const syncCallback = await this.callback(
        this.syncBatch,
        1,
        "full",
        channel.id,
        true
      );
      await this.run(syncCallback);

      // Setup realtime incremental sync via Workspace Events API + Pub/Sub
      await this.setupRealtimeSync(channel.id);
    }
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    // Tear down realtime sync for named spaces
    if (channel.id !== DM_CHANNEL_ID) {
      await this.teardownRealtimeSync(channel.id);
    }

    await this.clear(`sync_state_${channel.id}`);
    await this.clear(`sync_enabled_${channel.id}`);
    await this.clear(`member_emails_${channel.id}`);
    await this.clear(`member_info_${channel.id}`);
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

  // ---- Batch sync ----

  async syncBatch(
    batchNumber: number,
    mode: "full" | "incremental",
    channelId: string,
    initialSync?: boolean
  ): Promise<void> {
    if (batchNumber > MAX_SYNC_BATCHES) {
      console.warn(`Sync batch limit reached for channel ${channelId}`);
      return;
    }
    const isInitial = initialSync ?? mode === "full";

    try {
      const state = await this.get<SyncState>(`sync_state_${channelId}`);
      if (!state) {
        throw new Error("No sync state found");
      }

      const api = await this.getApi(channelId);
      const result = await syncChatSpace(api, state, 100);

      if (result.threads.length > 0) {
        // Resolve member info for contact matching and private thread mentions
        const memberInfo = await this.getMemberInfo(api, channelId);
        const members: NewActor[] = [];
        for (const [, info] of memberInfo) {
          if (info.email) members.push({ email: info.email });
        }
        await this.processMessageThreads(
          result.threads,
          channelId,
          isInitial,
          memberInfo,
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
    memberInfo?: Map<string, MemberInfo>,
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
          memberInfo,
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
   * Fetches and caches member info (email + displayName) for a space,
   * used to resolve Google Chat user IDs to contact details.
   */
  private async getMemberInfo(
    api: GoogleChatApi,
    channelId: string
  ): Promise<Map<string, MemberInfo>> {
    // Check cache
    const cached = await this.get<Record<string, MemberInfo>>(
      `member_info_${channelId}`
    );
    if (cached) {
      return new Map(Object.entries(cached));
    }

    try {
      const members = await api.listMembers(toSpaceName(channelId));
      const info = new Map<string, MemberInfo>();
      for (const m of members) {
        if (m.member.email || m.member.displayName) {
          info.set(m.member.name, {
            ...(m.member.email ? { email: m.member.email } : {}),
            ...(m.member.displayName ? { displayName: m.member.displayName } : {}),
          });
        }
      }

      // Cache for future batches
      await this.set(
        `member_info_${channelId}`,
        Object.fromEntries(info)
      );
      return info;
    } catch (error) {
      console.error("Failed to fetch member info:", error);
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
    if (batchNumber > MAX_SYNC_BATCHES) {
      console.warn(`DM sync batch limit reached for ${spaceName}`);
      return;
    }
    const isInitial = initialSync ?? true;

    try {
      const state = await this.get<SyncState>(`sync_state_${spaceName}`);
      if (!state) {
        throw new Error("No sync state found for DM space");
      }

      const api = await this.getApi(DM_CHANNEL_ID);
      const result = await syncChatSpace(api, state, 100);

      if (result.threads.length > 0) {
        const memberInfo = await this.getMemberInfo(api, spaceName);
        const spaceId = extractSpaceId(spaceName);

        // Build members list for private thread mentions
        const members: NewActor[] = [];
        for (const [, info] of memberInfo) {
          if (info.email) members.push({ email: info.email });
        }

        for (const threadMessages of result.threads) {
          try {
            const plotThread = transformChatThread(
              threadMessages,
              spaceId,
              isInitial,
              memberInfo,
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

  // ---- Realtime sync via Workspace Events API + Pub/Sub ----

  /**
   * Sets up a Workspace Events subscription for a named space.
   * Creates a Pub/Sub topic (via createWebhook) and registers a subscription
   * that delivers Chat message events to the onChatWebhook handler.
   */
  private async setupRealtimeSync(channelId: string): Promise<void> {
    try {
      // Request a Pub/Sub-backed webhook — returns a topic name instead of a URL
      const topicName = await this.tools.network.createWebhook(
        { pubsub: true },
        this.onChatWebhook,
        channelId
      );

      // Skip if localhost (development environment)
      if (topicName.includes("localhost") || topicName.includes("127.0.0.1")) {
        return;
      }

      const api = await this.getApi(channelId);
      const subscription = await api.createSubscription(
        toSpaceName(channelId),
        topicName,
        CHAT_EVENT_TYPES
      );

      await this.set(`ws_subscription_${channelId}`, {
        subscriptionName: subscription.name,
        topicName,
        expireTime: subscription.expireTime,
        created: new Date().toISOString(),
      });

      // Schedule renewal before the 7-day TTL expires
      await this.scheduleSubscriptionRenewal(channelId);
    } catch (error) {
      console.error(
        `Failed to setup realtime sync for ${channelId}:`,
        error
      );
      // Non-fatal: batch sync still works without realtime
    }
  }

  /**
   * Tears down the Workspace Events subscription and Pub/Sub resources.
   */
  private async teardownRealtimeSync(channelId: string): Promise<void> {
    // Cancel scheduled renewal
    const taskToken = await this.get<string>(
      `ws_renewal_task_${channelId}`
    );
    if (taskToken) {
      try {
        await this.cancelTask(taskToken);
      } catch {
        // Task may already have executed
      }
      await this.clear(`ws_renewal_task_${channelId}`);
    }

    const subData = await this.get<{
      subscriptionName: string;
      topicName: string;
    }>(`ws_subscription_${channelId}`);

    if (subData) {
      // Delete Workspace Events subscription
      if (subData.subscriptionName) {
        try {
          const api = await this.getApi(channelId);
          await api.deleteSubscription(subData.subscriptionName);
        } catch (error) {
          console.error(
            "Failed to delete Workspace Events subscription:",
            error
          );
        }
      }

      // Delete Pub/Sub topic and push subscription
      if (subData.topicName) {
        try {
          await this.tools.network.deleteWebhook(subData.topicName);
        } catch (error) {
          console.error("Failed to delete Pub/Sub webhook:", error);
        }
      }

      await this.clear(`ws_subscription_${channelId}`);
    }
  }

  /**
   * Handles incoming Workspace Events delivered via Pub/Sub push.
   * Parses the CloudEvent and triggers incremental sync for affected messages.
   */
  async onChatWebhook(
    request: WebhookRequest,
    channelId: string
  ): Promise<void> {
    const body = request.body as {
      message?: { data: string };
      decodedData?: {
        type?: string;
        data?: {
          message?: Message;
          name?: string;
        };
      };
    };

    const decodedData = body?.decodedData;
    if (!decodedData) {
      // Try decoding from raw Pub/Sub message
      const message = body?.message;
      if (!message?.data) {
        console.warn("No data in Google Chat webhook");
        return;
      }
      // The webhook route already decodes this, but handle edge cases
      console.warn("No decodedData in Google Chat webhook body");
      return;
    }

    const eventType = decodedData.type;
    if (!eventType) {
      console.warn("No event type in Workspace Events notification");
      return;
    }

    // Only handle message events
    if (!eventType.startsWith("google.workspace.chat.message.v1.")) {
      return;
    }

    // Handle message deletion: archive the corresponding Plot thread
    if (eventType === "google.workspace.chat.message.v1.deleted") {
      const messageName = decodedData.data?.name;
      if (messageName) {
        await this.handleMessageDeleted(messageName, channelId);
      }
      return;
    }

    // Handle message created/updated: sync the message
    const api = await this.getApi(channelId);
    let message: Message | null = null;

    if (decodedData.data?.message) {
      message = decodedData.data.message;
    } else if (decodedData.data?.name) {
      // Event only includes resource name; fetch the message
      try {
        const spaceName = toSpaceName(channelId);
        const result = await api.listMessages(spaceName, {
          pageSize: 1,
          filter: `name = "${decodedData.data.name}"`,
        });
        if (result.messages.length > 0) {
          message = result.messages[0];
        }
      } catch (error) {
        console.error("Failed to fetch message for Chat event:", error);
        return;
      }
    }

    if (!message) {
      console.warn("Cannot extract message from Chat event");
      return;
    }

    // Process as a single-message thread (incremental sync)
    const memberInfo = await this.getMemberInfo(api, channelId);
    const members: NewActor[] = [];
    for (const [, info] of memberInfo) {
      if (info.email) members.push({ email: info.email });
    }

    await this.processMessageThreads(
      [[message]],
      channelId,
      false, // incremental sync: don't set unread/archived
      memberInfo,
      members
    );
  }

  /**
   * Archives a Plot thread when the corresponding Google Chat message is deleted.
   */
  private async handleMessageDeleted(
    messageName: string,
    channelId: string
  ): Promise<void> {
    try {
      // Extract thread key from message name to construct the source identifier
      // Message name format: spaces/{spaceId}/messages/{messageId}
      // Thread source format: google-chat:{spaceId}:thread:{threadKey}
      // For single messages, the threadKey equals the messageId
      const spaceId = extractSpaceId(channelId);
      const messageId = extractMessageId(messageName);
      const source = `google-chat:${spaceId}:thread:${messageId}`;

      await this.tools.integrations.saveLink({
        source,
        type: "message",
        archived: true,
        channelId,
        meta: {
          syncProvider: "google-chat",
          syncableId: channelId,
        },
      });
    } catch (error) {
      console.error("Failed to archive deleted Chat message:", error);
    }
  }

  // ---- Subscription renewal ----

  /**
   * Schedules a task to renew the Workspace Events subscription
   * before its 7-day TTL expires (renews 1 day before expiry).
   */
  private async scheduleSubscriptionRenewal(
    channelId: string
  ): Promise<void> {
    const subData = await this.get<{ expireTime?: string }>(
      `ws_subscription_${channelId}`
    );
    if (!subData?.expireTime) return;

    const expiry = new Date(subData.expireTime);
    // Renew 1 day before expiry
    const renewalTime = new Date(expiry.getTime() - 24 * 60 * 60 * 1000);

    if (renewalTime <= new Date()) {
      // Already past renewal window, renew immediately
      await this.renewSubscription(channelId);
      return;
    }

    const renewalCallback = await this.callback(
      this.renewSubscription,
      channelId
    );
    const taskToken = await this.runTask(renewalCallback, {
      runAt: renewalTime,
    });
    if (taskToken) {
      await this.set(`ws_renewal_task_${channelId}`, taskToken);
    }
  }

  /**
   * Renews the Workspace Events subscription before it expires.
   * If renewal fails, falls back to recreating the entire setup.
   */
  async renewSubscription(channelId: string): Promise<void> {
    try {
      const subData = await this.get<{
        subscriptionName: string;
        topicName: string;
        expireTime: string;
      }>(`ws_subscription_${channelId}`);

      if (!subData?.subscriptionName) {
        console.warn(
          `No subscription found for channel ${channelId}, recreating`
        );
        await this.setupRealtimeSync(channelId);
        return;
      }

      const api = await this.getApi(channelId);
      const renewed = await api.renewSubscription(subData.subscriptionName);

      // Update stored data with new expiry
      await this.set(`ws_subscription_${channelId}`, {
        ...subData,
        expireTime: renewed.expireTime,
      });

      // Schedule next renewal
      await this.scheduleSubscriptionRenewal(channelId);
    } catch (error) {
      console.error(
        `Failed to renew subscription for ${channelId}:`,
        error
      );
      // Try recreating from scratch
      try {
        await this.teardownRealtimeSync(channelId);
        await this.setupRealtimeSync(channelId);
      } catch (retryError) {
        console.error("Failed to recreate realtime sync:", retryError);
      }
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
