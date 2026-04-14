import GoogleContacts from "@plotday/connector-google-contacts";
import {
  Connector,
  type ToolBuilder,
} from "@plotday/twister";
import type { Actor, NewActor, Note, Thread } from "@plotday/twister/plot";
import { Tag } from "@plotday/twister/tag";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";

import {
  GoogleChatApi,
  EMOJI_TO_TAG,
  TAG_TO_EMOJI,
  type EmojiReaction,
  type Message,
  type MemberInfo,
  type Subscription,
  type SyncState,
  extractMessageId,
  extractSpaceId,
  toSpaceName,
  syncChatSpace,
  transformChatThread,
} from "./google-chat-api";

const DM_CHANNEL_ID = "__direct_messages__";
const MAX_SYNC_BATCHES = 50;

/** Workspace Events event types for Google Chat messages and reactions. */
const CHAT_EVENT_TYPES = [
  "google.workspace.chat.message.v1.created",
  "google.workspace.chat.message.v1.updated",
  "google.workspace.chat.message.v1.deleted",
  "google.workspace.chat.reaction.v1.created",
  "google.workspace.chat.reaction.v1.deleted",
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
 * - `chat.users.readstate` — Read and sync read/unread state
 */
export class GoogleChat extends Connector<GoogleChat> {
  static readonly PROVIDER = AuthProvider.Google;
  static readonly handleReplies = true;
  static readonly SCOPES = [
    "https://www.googleapis.com/auth/chat.spaces.readonly",
    "https://www.googleapis.com/auth/chat.messages",
    "https://www.googleapis.com/auth/chat.memberships.readonly",
    "https://www.googleapis.com/auth/chat.users.readstate",
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
          "https://www.googleapis.com/*",
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

    // Store the auth actor's email for later use in resolving Google user profiles.
    // The actual Google user ID mapping happens in getChannels when we have a token.
    if (context.auth.actor.email) {
      await this.set("auth_actor_email", context.auth.actor.email);
    }
    if (context.auth.actor.name) {
      await this.set("auth_actor_name", context.auth.actor.name);
    }
  }

  // ---- Channel lifecycle ----

  async getChannels(
    _auth: Authorization,
    token: AuthToken
  ): Promise<Channel[]> {
    const api = new GoogleChatApi(token.token);

    // Capture the authenticated user's Google profile on every getChannels call.
    // This maps the Google Chat user ID (users/{sub}) to the user's email,
    // which is essential for resolving message authors to Plot users.
    // getChannels is called after auth and on every channel refresh.
    try {
      const userInfo = await api.getUserInfo();
      if (userInfo.sub) {
        const authActorEmail = await this.get<string>("auth_actor_email");
        const authActorName = await this.get<string>("auth_actor_name");
        const authUser = {
          googleUserId: `users/${userInfo.sub}`,
          email: userInfo.email ?? authActorEmail ?? null,
          name: userInfo.name ?? authActorName ?? null,
        };
        await this.set("auth_google_user", authUser);

        // Save a contact with both email and source so the Google Chat
        // user ID resolves to the user's Plot identity
        if (authUser.email) {
          await this.tools.integrations.saveContacts([{
            email: authUser.email,
            name: authUser.name ?? undefined,
            source: { provider: AuthProvider.Google, accountId: authUser.googleUserId },
          }]);
        }
      }
    } catch {
      // Non-fatal: user resolution will fall back to display names
    }

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

  async onChannelEnabled(channel: Channel, context?: SyncContext): Promise<void> {
    // Check if we've already synced with a wider or equal range
    const syncHistoryMin = context?.syncHistoryMin;
    if (syncHistoryMin) {
      const storedMin = await this.get<string>(`sync_history_min_${channel.id}`);
      if (storedMin && new Date(storedMin) <= syncHistoryMin) {
        return; // Already synced with wider range
      }
      await this.set(`sync_history_min_${channel.id}`, syncHistoryMin.toISOString());
    }

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
      await this.runTask(syncCallback);
    } else {
      // For named spaces, sync directly and setup realtime via Workspace Events
      const syncCallback = await this.callback(
        this.syncBatch,
        1,
        "full",
        channel.id,
        true
      );
      await this.runTask(syncCallback);

      // Setup realtime incremental sync via Workspace Events API + Pub/Sub
      // Must run as a separate task — setupRealtimeSync makes multiple GCP/Google
      // API calls that can exceed the CPU time limit if run inline in onChannelEnabled.
      const realtimeCallback = await this.callback(
        this.setupRealtimeSync,
        channel.id
      );
      await this.runTask(realtimeCallback);
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
        await this.runTask(syncCallback);
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
   * Ensures the stored auth user's info is injected into a memberInfo map.
   * The Google Chat membership API doesn't reliably return email/name,
   * so we supplement with the profile captured during getChannels.
   */
  private async injectAuthUser(info: Map<string, MemberInfo>): Promise<void> {
    const authUser = await this.get<{
      googleUserId: string;
      email: string | null;
      name: string | null;
    }>("auth_google_user");
    if (!authUser?.googleUserId) return;

    const existing = info.get(authUser.googleUserId);
    // Always inject auth user — they should always have the best data
    if (!existing?.email && authUser.email) {
      info.set(authUser.googleUserId, {
        email: authUser.email ?? existing?.email,
        displayName: existing?.displayName ?? authUser.name ?? undefined,
      });
    }
  }

  /**
   * Fetches and caches member info (email + displayName) for a space.
   * Injects the authenticated user's profile from stored data.
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
      const info = new Map(Object.entries(cached));
      // Always inject auth user even from cache — the cache may have been
      // built before the user's profile was captured
      await this.injectAuthUser(info);
      return info;
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

      // Inject auth user's profile from stored data (captured during getChannels)
      await this.injectAuthUser(info);

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
        await this.runTask(syncCallback);
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
        await this.runTask(syncCallback);
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
  async setupRealtimeSync(channelId: string): Promise<void> {
    try {
      // Tear down any existing realtime sync first (handles reconnect/retry)
      await this.teardownRealtimeSync(channelId);

      // Request a Pub/Sub-backed webhook — returns a topic name instead of a URL
      console.log(`[google-chat] Setting up realtime sync for ${channelId}`);
      const topicName = await this.tools.network.createWebhook(
        { pubsub: true },
        this.onChatWebhook,
        channelId
      );
      console.log(`[google-chat] Created Pub/Sub topic: ${topicName}`);

      const api = await this.getApi(channelId);
      let subscription: Subscription;
      try {
        subscription = await api.createSubscription(
          toSpaceName(channelId),
          topicName,
          CHAT_EVENT_TYPES
        );
      } catch (error) {
        // Handle 409: a stale subscription exists for this resource.
        // Extract its name from the error, delete it, and retry.
        const msg = error instanceof Error ? error.message : String(error);
        const match = msg.match(/"current_subscription":\s*"([^"]+)"/);
        if (match) {
          console.log(`[google-chat] Deleting stale subscription: ${match[1]}`);
          await api.deleteSubscription(match[1]);
          subscription = await api.createSubscription(
            toSpaceName(channelId),
            topicName,
            CHAT_EVENT_TYPES
          );
        } else {
          throw error;
        }
      }
      console.log(
        `[google-chat] Created Workspace Events subscription: ${subscription.name}, ` +
        `state: ${subscription.state ?? "unknown"}, expires: ${subscription.expireTime}`
      );

      await this.set(`ws_subscription_${channelId}`, {
        subscriptionName: subscription.name,
        topicName,
        expireTime: subscription.expireTime,
        eventTypes: CHAT_EVENT_TYPES,
        created: new Date().toISOString(),
      });

      // Schedule renewal before the 7-day TTL expires
      await this.scheduleSubscriptionRenewal(channelId);
      console.log(`[google-chat] Realtime sync setup complete for ${channelId}`);
    } catch (error) {
      console.error(
        `[google-chat] Failed to setup realtime sync for ${channelId}:`,
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
        // Workspace Events puts the resource directly (e.g. message.name)
        message?: Partial<Message> & { name: string };
        // Reaction events include a reaction object with parent message name
        reaction?: EmojiReaction & { message?: { name: string } };
        name?: string;
        // Legacy expected shape (data.message / data.name)
        data?: {
          message?: Message;
          name?: string;
        };
      };
    };

    console.log(`[google-chat] Webhook received for channel ${channelId}`);

    const decodedData = body?.decodedData;
    if (!decodedData) {
      // Try decoding from raw Pub/Sub message
      const message = body?.message;
      if (!message?.data) {
        console.warn("[google-chat] No data in webhook body");
        return;
      }
      // The webhook route already decodes this, but handle edge cases
      console.warn("[google-chat] No decodedData in webhook body");
      return;
    }

    const eventType = decodedData.type;
    if (!eventType) {
      console.warn("[google-chat] No event type in Workspace Events notification");
      return;
    }

    console.log(`[google-chat] Event type: ${eventType}`);

    // Handle reaction events
    if (eventType.startsWith("google.workspace.chat.reaction.v1.")) {
      await this.handleReactionEvent(decodedData, channelId);
      return;
    }

    // Only handle message events from here
    if (!eventType.startsWith("google.workspace.chat.message.v1.")) {
      return;
    }

    // The Workspace Events payload puts the resource directly in decodedData
    // (e.g. decodedData.message.name), not wrapped in a "data" field.
    const eventMessage = decodedData.message ?? decodedData.data?.message;
    const eventName = eventMessage?.name ?? decodedData.data?.name ?? decodedData.name;

    // Handle message deletion: archive the corresponding Plot thread
    if (eventType === "google.workspace.chat.message.v1.deleted") {
      if (eventName) {
        await this.handleMessageDeleted(eventName as string, channelId);
      }
      return;
    }

    // Handle message created/updated: sync the message
    const api = await this.getApi(channelId);
    let message: Message | null = null;

    if (eventMessage && eventMessage.text !== undefined) {
      // Full message object included in the event
      message = eventMessage as Message;
    } else if (eventName) {
      // Event only includes resource name; fetch the full message
      try {
        message = await api.getMessage(eventName as string);
      } catch (error) {
        console.error("[google-chat] Failed to fetch message for Chat event:", error);
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

  /**
   * Handles a reaction created/deleted event by re-syncing the parent message
   * with updated reaction data.
   */
  private async handleReactionEvent(
    decodedData: {
      type?: string;
      reaction?: EmojiReaction & { message?: { name: string } };
      name?: string;
      data?: { name?: string };
    },
    channelId: string
  ): Promise<void> {
    // Extract the parent message name from the reaction event
    const reaction = decodedData.reaction;
    const reactionName = reaction?.name ?? decodedData.name ?? decodedData.data?.name;

    // Reaction name format: spaces/{spaceId}/messages/{messageId}/reactions/{reactionId}
    // Parent message name: spaces/{spaceId}/messages/{messageId}
    let messageName = reaction?.message?.name;
    if (!messageName && reactionName) {
      const parts = (reactionName as string).split("/");
      // Extract "spaces/{spaceId}/messages/{messageId}" from the reaction name
      if (parts.length >= 4) {
        messageName = parts.slice(0, 4).join("/");
      }
    }

    if (!messageName) {
      console.warn("[google-chat] Cannot extract message name from reaction event");
      return;
    }

    try {
      const api = await this.getApi(channelId);

      // Fetch the parent message and its reactions
      const [message, reactions] = await Promise.all([
        api.getMessage(messageName),
        api.listReactions(messageName),
      ]);

      // Re-process as a single-message thread with per-user reaction data
      const memberInfo = await this.getMemberInfo(api, channelId);
      const members: NewActor[] = [];
      for (const [, info] of memberInfo) {
        if (info.email) members.push({ email: info.email });
      }
      const spaceId = extractSpaceId(channelId);

      const plotThread = transformChatThread(
        [message],
        spaceId,
        false,
        memberInfo,
        members,
        reactions
      );

      plotThread.channelId = channelId;
      plotThread.meta = {
        ...plotThread.meta,
        syncProvider: "google-chat",
        syncableId: channelId,
      };

      await this.tools.integrations.saveLink(plotThread);
    } catch (error) {
      console.error("[google-chat] Failed to handle reaction event:", error);
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
   * If the subscription was created with outdated event types (e.g. missing
   * reaction events), recreates it from scratch. Otherwise extends the TTL.
   */
  async renewSubscription(channelId: string): Promise<void> {
    try {
      const subData = await this.get<{
        subscriptionName: string;
        topicName: string;
        expireTime: string;
        eventTypes?: string[];
      }>(`ws_subscription_${channelId}`);

      if (!subData?.subscriptionName) {
        console.warn(
          `No subscription found for channel ${channelId}, recreating`
        );
        await this.setupRealtimeSync(channelId);
        return;
      }

      // If subscription was created without reaction events, recreate it
      const hasAllEventTypes = CHAT_EVENT_TYPES.every(
        (et) => subData.eventTypes?.includes(et)
      );
      if (!hasAllEventTypes) {
        console.log(
          `[google-chat] Subscription for ${channelId} missing event types, recreating`
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

  // ---- Write-back: read state ----

  async onThreadRead(
    thread: Thread,
    _actor: Actor,
    unread: boolean
  ): Promise<void> {
    const meta = thread.meta ?? {};
    const channelId = (meta.channelId ?? meta.syncableId) as string;
    const spaceName = meta.spaceName as string;
    if (!spaceName) return;

    try {
      const api = await this.getApi(channelId ?? DM_CHANNEL_ID);
      if (unread) {
        // Set last read time to epoch to mark as unread
        await api.updateSpaceReadState(spaceName, "1970-01-01T00:00:00Z");
      } else {
        // Mark as read by setting last read time to now
        await api.updateSpaceReadState(spaceName, new Date().toISOString());
      }
    } catch (error) {
      console.error("Failed to sync read state to Google Chat:", error);
    }
  }

  // ---- Write-back: reactions from Plot ----

  async onNoteUpdated(note: Note, thread: Thread): Promise<void> {
    const meta = thread.meta ?? {};
    const channelId = (meta.channelId ?? meta.syncableId) as string;

    // Extract message name from note key (format: "message-{messageId}")
    const noteKey = note.key;
    if (!noteKey?.startsWith("message-")) return;
    const messageId = noteKey.substring("message-".length);
    const spaceName = meta.spaceName as string;
    if (!spaceName) return;
    const messageName = `${spaceName}/messages/${messageId}`;

    const api = await this.getApi(channelId ?? DM_CHANNEL_ID);

    // Identify the authenticated user's Google user ID
    const authUser = await this.get<{ googleUserId: string }>("auth_google_user");
    if (!authUser?.googleUserId) return;

    // Get current reactions from Google Chat for this message
    let currentReactions: EmojiReaction[];
    try {
      currentReactions = await api.listReactions(messageName);
    } catch {
      return; // Message may not exist anymore
    }

    // Build set of Plot tags that have emoji mappings (any actor)
    const plotTags = new Set<Tag>();
    for (const [tagIdStr, actorIds] of Object.entries(note.tags)) {
      const tagId = parseInt(tagIdStr) as Tag;
      if (!TAG_TO_EMOJI[tagId]) continue;
      if (actorIds && actorIds.length > 0) {
        plotTags.add(tagId);
      }
    }

    // Build set of the authenticated user's current reactions in Google Chat
    const chatTags = new Map<Tag, string>(); // Tag → reaction resource name
    for (const reaction of currentReactions) {
      if (reaction.user.name !== authUser.googleUserId) continue;
      const unicode = reaction.emoji.unicode;
      if (!unicode) continue;
      const tag = EMOJI_TO_TAG[unicode];
      if (!tag) continue;
      chatTags.set(tag, reaction.name);
    }

    // Add reactions present in Plot but not in Google Chat
    for (const tag of plotTags) {
      if (chatTags.has(tag)) continue;
      const emoji = TAG_TO_EMOJI[tag];
      if (!emoji) continue;
      try {
        await api.createReaction(messageName, emoji);
      } catch (error) {
        console.error(`[google-chat] Failed to create reaction ${emoji}:`, error);
      }
    }

    // Remove reactions present in Google Chat but not in Plot
    for (const [tag, reactionName] of chatTags) {
      if (plotTags.has(tag)) continue;
      try {
        await api.deleteReaction(reactionName);
      } catch (error) {
        console.error("[google-chat] Failed to delete reaction:", error);
      }
    }
  }

  // ---- Write-back: reply from Plot ----

  async onNoteCreated(note: Note, thread: Thread): Promise<string | void> {
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
      return msgId;
    } catch (error) {
      console.error("Failed to send Google Chat reply:", error);
    }
  }
}

export default GoogleChat;
