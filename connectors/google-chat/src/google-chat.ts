import GoogleContacts from "@plotday/connector-google-contacts";
import {
  Connector,
  type CreateLinkDraft,
  type NoteWriteBackResult,
  type ToolBuilder,
} from "@plotday/twister";
import type { Actor, ContentType, NewActor, NewContact, NewLinkWithNotes, Note, Thread } from "@plotday/twister/plot";
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
  type EmojiReaction,
  type Message,
  type MemberInfo,
  type Subscription,
  type SyncState,
  extractMessageId,
  extractSpaceId,
  extractThreadKey,
  googleUserIdToAccountId,
  toSpaceName,
  syncChatSpace,
  transformChatThread,
} from "./google-chat-api";

const DM_CHANNEL_ID = "__direct_messages__";
const MAX_SYNC_BATCHES = 50;

/**
 * Returns true when a Google Chat API error indicates missing OAuth scopes or
 * a revoked/expired token — i.e. the user must re-authorize to fix it.
 *
 * The GoogleChatApi client throws errors with messages like:
 *   "Google Chat API error: 401 Unauthorized - ..."
 *   "Google Chat API error: 403 Forbidden - ... PERMISSION_DENIED ..."
 */
function isGoogleAuthError(error: unknown): boolean {
  if (!(error instanceof Error)) return false;
  return (
    error.message.includes("Google Chat API error: 401") ||
    error.message.includes("Google Chat API error: 403")
  );
}

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
    "https://www.googleapis.com/auth/chat.spaces.create",
    "https://www.googleapis.com/auth/chat.messages",
    "https://www.googleapis.com/auth/chat.memberships.readonly",
    "https://www.googleapis.com/auth/chat.users.readstate",
  ];

  readonly provider = AuthProvider.Google;
  readonly scopes = Integrations.MergeScopes(
    GoogleChat.SCOPES,
    GoogleContacts.SCOPES
  );
  readonly reactionCapabilities = {
    mode: "open-unicode" as const,
    // Custom workspace emojis are skipped on sync-in and not yet pushed
    // on write-back; flip to "workspace" once the custom_emoji image
    // cache lands.
    customEmoji: "none" as const,
  };
  readonly linkTypes = [
    {
      type: "thread",
      label: "Thread",
      noteLabel: "Message",
      sharingModel: "channel" as const,
      // Logo: full-color SVG from static assets (iconify has no logos/google-chat)
      // logoMono: monochrome version from simple-icons (works fine on iconify)
      logo: "https://plot.day/assets/logo-google-chat.svg",
      logoMono: "https://api.iconify.design/simple-icons/googlechat.svg",
      compose: {
        targets: "channels" as const,
      },
    },
    {
      type: "dm",
      label: "Direct messages",
      noteLabel: "Message",
      sharingModel: "thread" as const,
      logo: "https://plot.day/assets/logo-google-chat.svg",
      logoMono: "https://api.iconify.design/simple-icons/googlechat.svg",
      compose: {
        targets: "contacts" as const,
      },
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
        // user ID resolves to the user's Plot identity. We use the bare
        // numeric `sub` (not the `users/…` resource name) as the
        // accountId so it matches what Drive emits as `permissionId`,
        // letting Drive comments and Chat messages from the same person
        // dedupe to one contact via `contact_external_account`.
        if (authUser.email) {
          await this.tools.integrations.saveContacts([{
            email: authUser.email,
            name: authUser.name ?? undefined,
            source: { accountId: userInfo.sub },
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
    const syncHistoryMin = context?.syncHistoryMin;
    if (context?.recovering) {
      // Recovery dispatch after re-auth: drop persisted sync state so the
      // next pass re-walks history and picks up messages that arrived
      // during the auth gap.
      await this.clear(`sync_state_${channel.id}`);
      await this.clear(`dm_initial_sync_remaining`);
    } else if (syncHistoryMin) {
      // Skip when stored window is already at least as wide. Bypassed on
      // recovery so the recovery pass re-walks even when the window
      // hasn't widened.
      const storedMin = await this.get<string>(`sync_history_min_${channel.id}`);
      if (storedMin && new Date(storedMin) <= syncHistoryMin) {
        return;
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

    // Sync workspace members once per day for the recipient picker.
    // Gated inside syncMembers to at most once per 24 hours, so enabling
    // multiple channels only hits the directory once.
    const membersCallback = await this.callback(this.syncMembers, channel.id);
    await this.runTask(membersCallback);

    // observeOnly = the channel was auto-observed because a Plot thread was
    // composed into it. Still register the realtime watch (below) so inbound
    // replies/reactions sync back, but skip the historical message backfill —
    // the user didn't opt to sync this channel's existing history.
    const observeOnly = context?.observeOnly === true;

    if (channel.id === DM_CHANNEL_ID) {
      // For DMs, list all DM spaces and sync each (batch only, no realtime)
      if (!observeOnly) {
        const syncCallback = await this.callback(this.syncDmSpaces, true);
        await this.runTask(syncCallback);
      }
    } else {
      // For named spaces, sync directly and setup realtime via Workspace Events
      if (!observeOnly) {
        const syncCallback = await this.callback(
          this.syncBatch,
          1,
          "full",
          channel.id,
          true
        );
        await this.runTask(syncCallback);
      }

      // Setup realtime incremental sync via Workspace Events API + Pub/Sub
      // Must run as a separate task — setupRealtimeSync makes multiple GCP/Google
      // API calls that can exceed the CPU time limit if run inline in onChannelEnabled.
      // Registered unconditionally (even for observeOnly) so go-forward events sync.
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

      const token = await this.tools.integrations.get(channelId);
      if (!token) {
        // Auth token was cleared (channel disabled, OAuth revoked,
        // integration deleted) — abort instead of throwing to prevent
        // infinite queue retries.
        console.warn(
          `Auth token missing for channel ${channelId} at batch ${batchNumber}, skipping`
        );
        return;
      }
      const api = new GoogleChatApi(token.token);
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
          // Initial backfill complete for this named space — clear the indicator.
          if (isInitial) {
            await this.tools.integrations.channelSyncCompleted(channelId);
          }
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
      const token = await this.tools.integrations.get(DM_CHANNEL_ID);
      if (!token) {
        // Auth token was cleared (channel disabled, OAuth revoked,
        // integration deleted) — abort instead of throwing to prevent
        // infinite queue retries.
        console.warn(
          `Auth token missing for DM channel during syncDmSpaces, skipping`
        );
        return;
      }
      const api = new GoogleChatApi(token.token);
      const spaces = await api.listSpaces(
        'spaceType = "DIRECT_MESSAGE" OR spaceType = "GROUP_CHAT"'
      );

      // Track how many DM spaces still need to finish their initial sync, so
      // syncDmBatch can clear the channel-level "syncing…" indicator only
      // when the last one drains. Reset on each entry to syncDmSpaces.
      const dmSpacesToSync = spaces.filter((s) => !s.singleUserBotDm);
      if (isInitial && dmSpacesToSync.length > 0) {
        await this.set(
          `dm_initial_sync_remaining`,
          dmSpacesToSync.length
        );
      } else if (isInitial) {
        // No DM spaces to sync — clear the indicator immediately.
        await this.tools.integrations.channelSyncCompleted(DM_CHANNEL_ID);
      }

      for (const space of dmSpacesToSync) {
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

      const token = await this.tools.integrations.get(DM_CHANNEL_ID);
      if (!token) {
        // Auth token was cleared (channel disabled, OAuth revoked,
        // integration deleted) — abort instead of throwing to prevent
        // infinite queue retries.
        console.warn(
          `Auth token missing for DM channel during syncDmBatch ${batchNumber} for ${spaceName}, skipping`
        );
        return;
      }
      const api = new GoogleChatApi(token.token);
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

        // Initial backfill done for this DM space. If this was the last
        // outstanding space, clear the channel-level "syncing…" indicator.
        if (isInitial) {
          const remaining =
            (await this.get<number>(`dm_initial_sync_remaining`)) ?? 0;
          const next = Math.max(0, remaining - 1);
          if (next === 0) {
            await this.clear(`dm_initial_sync_remaining`);
            await this.tools.integrations.channelSyncCompleted(DM_CHANNEL_ID);
          } else {
            await this.set(`dm_initial_sync_remaining`, next);
          }
        }
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

      // Request a Workspace Events Pub/Sub webhook — returns a topic name
      // instead of a URL.
      console.log(`[google-chat] Setting up realtime sync for ${channelId}`);
      const topicName = await this.tools.network.createWebhook(
        { pubsub: "workspace" },
        this.onChatWebhook,
        channelId
      );
      console.log(`[google-chat] Created Pub/Sub topic: ${topicName}`);

      const token = await this.tools.integrations.get(channelId);
      if (!token) {
        // Auth token was cleared (channel disabled, OAuth revoked,
        // integration deleted) — abort instead of throwing to prevent
        // infinite queue retries.
        console.warn(
          `Auth token missing for channel ${channelId} during setupRealtimeSync, skipping`
        );
        return;
      }
      const api = new GoogleChatApi(token.token);
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
    const token = await this.tools.integrations.get(channelId);
    if (!token) {
      // Auth token was cleared (channel disabled, OAuth revoked,
      // integration deleted) — abort instead of throwing to prevent
      // infinite queue retries.
      console.warn(
        `Auth token missing for channel ${channelId} during onChatWebhook, skipping`
      );
      return;
    }
    const api = new GoogleChatApi(token.token);
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
        type: "thread",
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
      const token = await this.tools.integrations.get(channelId);
      if (!token) {
        // Auth token was cleared (channel disabled, OAuth revoked,
        // integration deleted) — abort instead of throwing to prevent
        // infinite queue retries.
        console.warn(
          `Auth token missing for channel ${channelId} during handleReactionEvent, skipping`
        );
        return;
      }
      const api = new GoogleChatApi(token.token);

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

      const token = await this.tools.integrations.get(channelId);
      if (!token) {
        // Auth token was cleared (channel disabled, OAuth revoked,
        // integration deleted) — abort instead of throwing to prevent
        // infinite queue retries.
        console.warn(
          `Auth token missing for channel ${channelId} during renewSubscription, skipping`
        );
        return;
      }
      const api = new GoogleChatApi(token.token);
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

  /**
   * Pushes note-level updates back to Google Chat.
   *
   * Two channels of state are syncable here:
   * 1. Reactions — mirrored from `note.tags` to Chat reactions owned by the
   *    authenticated user (pre-existing behavior).
   * 2. Content — if `note.content` changed, PATCH the message's `text`
   *    via `messages.patch`. We only return a `NoteWriteBackResult` when
   *    we actually pushed content; otherwise baseline tracking stays
   *    untouched for this call.
   *
   * Content push runs before reactions so a failed text patch (e.g. user
   * isn't the message author) doesn't block reaction sync.
   */
  async onNoteUpdated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
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

    // --- Content sync (best-effort; only the message author can patch) ---
    let writeBack: NoteWriteBackResult | undefined;
    if (note.content !== null && note.content !== undefined) {
      try {
        const updated = await api.updateMessage(messageName, note.content);
        // Mirror sync-in: prefer formattedText + "html", else text + "text".
        // `updateMessage` returns whatever Google stored for this message,
        // which is what the next list/fetch will also return.
        const hasFormatted =
          typeof updated.formattedText === "string" && updated.formattedText.length > 0;
        const externalContent = hasFormatted
          ? updated.formattedText!
          : (updated.text ?? note.content);
        writeBack = { externalContent };
      } catch (error) {
        // Non-fatal: user may not own the message, or the message may be
        // gone. Fall through to reaction sync and skip baseline update.
        console.warn(
          "[google-chat] messages.patch failed; skipping content write-back:",
          error
        );
      }
    }

    // Get current reactions from Google Chat for this message
    let currentReactions: EmojiReaction[];
    try {
      currentReactions = await api.listReactions(messageName);
    } catch {
      return writeBack; // Message may not exist anymore
    }

    // Plot-side: any emoji with at least one reactor is "present in Plot".
    // Currently writes back as the connected (authenticated) user for every
    // reaction. For correct per-actor attribution, migrate to
    // `onNoteReactionChanged` — that callback is dispatched on the reacting
    // user's own connector instance via `twist_instance_for_actor`, so each
    // emoji add/remove runs under the right user's token.
    const plotEmojis = new Set<string>();
    for (const [emoji, actorIds] of Object.entries(note.reactions)) {
      // Only Unicode emoji round-trip today (custom emoji are skipped
      // on sync-in and have no createReaction path here yet).
      if (emoji.includes(":")) continue;
      if (actorIds && actorIds.length > 0) plotEmojis.add(emoji);
    }

    // Google Chat side: the authenticated user's existing reactions on
    // this message, keyed by unicode → reaction resource name.
    const chatEmojis = new Map<string, string>();
    for (const reaction of currentReactions) {
      if (reaction.user.name !== authUser.googleUserId) continue;
      const unicode = reaction.emoji.unicode;
      if (!unicode) continue;
      chatEmojis.set(unicode, reaction.name);
    }

    // Add reactions present in Plot but not in Google Chat
    for (const emoji of plotEmojis) {
      if (chatEmojis.has(emoji)) continue;
      try {
        await api.createReaction(messageName, emoji);
      } catch (error) {
        console.error(`[google-chat] Failed to create reaction ${emoji}:`, error);
      }
    }

    // Remove reactions present in Google Chat but not in Plot
    for (const [emoji, reactionName] of chatEmojis) {
      if (plotEmojis.has(emoji)) continue;
      try {
        await api.deleteReaction(reactionName);
      } catch (error) {
        console.error("[google-chat] Failed to delete reaction:", error);
      }
    }

    return writeBack;
  }

  // ---- Write-back: reply from Plot ----

  /**
   * Sends a Plot note as a Google Chat message via `messages.create`.
   *
   * Returns a {@link NoteWriteBackResult} whose `externalContent` mirrors
   * the sync-in representation (see `transformChatThread`): prefer
   * `formattedText` + `"html"` when Chat computed one, else `text` +
   * `"text"`. That keeps the baseline hash aligned with the next
   * `listMessages` read so the round-trip preserves Plot's markdown.
   */
  async onNoteCreated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
    const meta = thread.meta ?? {};
    const channelId = (meta.channelId ?? meta.syncableId) as string;
    const spaceName = meta.spaceName as string;
    const threadName = meta.threadName as string;

    if (!spaceName) {
      console.error("No spaceName in meta for Google Chat reply");
      return;
    }

    const api = await this.getApi(channelId ?? DM_CHANNEL_ID);

    const body = note.content ?? "";
    const result = await api.createMessage(spaceName, body, threadName);

    const msgId = `message-${extractMessageId(result.name)}`;
    // Store sent message ID for dedup when synced back
    await this.set(`sent:${msgId}`, true);

    const hasFormatted =
      typeof result.formattedText === "string" && result.formattedText.length > 0;
    const externalContent = hasFormatted
      ? result.formattedText!
      : (result.text ?? body);

    return {
      key: msgId,
      externalContent,
    };
  }

  // ---- Compose new messages from Plot ----

  /**
   * Creates a new Google Chat message from Plot via `onCreateLink`.
   *
   * - `thread`: posts to `draft.channelId` (the space resource id
   *   like "AAAA…"). Uses the existing channel token directly.
   * - `dm`: finds or creates the DM space for the selected recipients,
   *   then posts there.
   *
   * The returned `meta` matches what `onNoteCreated` reads so replies via
   * the existing write-back path work with zero extra wiring.
   */
  override async onCreateLink(
    draft: CreateLinkDraft
  ): Promise<NewLinkWithNotes | null> {
    if (draft.type === "thread") {
      return this.createSpacePost(draft);
    }
    if (draft.type === "dm") {
      return this.createDirectMessage(draft);
    }
    return null;
  }

  private async createSpacePost(
    draft: CreateLinkDraft
  ): Promise<NewLinkWithNotes | null> {
    const channelId = draft.channelId;
    const spaceName = toSpaceName(channelId);
    const api = await this.getApi(channelId);

    const body = (draft.noteContent ?? draft.title ?? "").trim();
    if (!body) {
      console.error("[google-chat] Cannot create space post: body is empty");
      return null;
    }

    let result: Awaited<ReturnType<typeof api.createMessage>>;
    try {
      result = await api.createMessage(spaceName, body);
    } catch (error) {
      if (isGoogleAuthError(error)) {
        console.warn("[google-chat] createSpacePost: missing scope or revoked token; flagging re-auth", error);
        await this.tools.integrations.markNeedsReauth(channelId);
      } else {
        console.error("[google-chat] createSpacePost: failed to send message", error);
      }
      return null;
    }
    const msgId = `message-${extractMessageId(result.name)}`;
    // Store sent message ID for dedup when synced back
    await this.set(`sent:${msgId}`, true);

    const threadKey = extractThreadKey(result.thread.name);

    return {
      source: `google-chat:${channelId}:thread:${threadKey}`,
      type: "thread",
      title: draft.title,
      status: null,
      created: new Date(result.createTime),
      sourceUrl: `https://chat.google.com/room/${channelId}/${threadKey}`,
      channelId,
      meta: {
        syncProvider: "google-chat",
        syncableId: channelId,
        spaceId: channelId,
        spaceName,
        threadName: result.thread.name,
        threadKey,
      },
      // Bind the opening note to this Chat message so reactions/edits on it
      // route back. key + externalContent match what onNoteCreated returns
      // for a reply (and what sync-in emits).
      originatingNote: {
        key: msgId,
        externalContent:
          typeof result.formattedText === "string" &&
          result.formattedText.length > 0
            ? result.formattedText
            : (result.text ?? body),
      },
    };
  }

  private async createDirectMessage(
    draft: CreateLinkDraft
  ): Promise<NewLinkWithNotes | null> {
    const recipients = draft.recipients;
    if (!recipients || recipients.length === 0) {
      console.error("[google-chat] dm onCreateLink: no recipients provided");
      return null;
    }

    const body = (draft.noteContent ?? draft.title ?? "").trim();
    if (!body) {
      console.error("[google-chat] Cannot create direct message: body is empty");
      return null;
    }

    // Retrieve the authenticated user's Google user ID.
    const authUser = await this.get<{ googleUserId: string }>("auth_google_user");
    const callerName = authUser?.googleUserId;
    if (!callerName) {
      console.error("[google-chat] dm: no auth_google_user stored; re-auth required");
      return null;
    }

    // externalAccountId is the bare numeric Google user ID (without "users/" prefix).
    const recipientIds = recipients.map((r) => r.externalAccountId);

    // Use the DM_CHANNEL_ID token if available, otherwise fall back to draft.channelId.
    // The DM channel is not a "space" channel but shares the same Google auth token.
    let api: GoogleChatApi;
    let tokenChannelId: string;
    try {
      api = await this.getApi(DM_CHANNEL_ID);
      tokenChannelId = DM_CHANNEL_ID;
    } catch {
      // Fall back to the picker's channelId token (any enabled space works).
      api = await this.getApi(draft.channelId);
      tokenChannelId = draft.channelId;
    }

    let dmSpaceName: string;
    let result: Awaited<ReturnType<typeof api.createMessage>>;

    try {
      if (recipientIds.length === 1) {
        // 1:1 DM — use spaces.setup to find or create the DM space.
        const recipientName = `users/${recipientIds[0]}`;
        const space = await api.setupDmSpace(callerName, recipientName);
        dmSpaceName = space.name;
      } else {
        // Group DM (>1 recipient) — create a GROUP_CHAT space and add all members.
        // Google Chat distinguishes unnamed group chats (spaceType=GROUP_CHAT) from
        // named spaces (spaceType=SPACE). We use GROUP_CHAT here.
        const membershipEntries = [
          { member: { name: callerName, type: "HUMAN" as const } },
          ...recipientIds.map((id) => ({
            member: { name: `users/${id}`, type: "HUMAN" as const },
          })),
        ];
        const space = await api.createSpace(undefined, "GROUP_CHAT", membershipEntries);
        dmSpaceName = space.name;
      }

      result = await api.createMessage(dmSpaceName, body);
    } catch (error) {
      if (isGoogleAuthError(error)) {
        console.warn("[google-chat] createDirectMessage: missing scope or revoked token; flagging re-auth", error);
        await this.tools.integrations.markNeedsReauth(tokenChannelId);
      } else {
        console.error("[google-chat] createDirectMessage: failed to send DM", error);
      }
      return null;
    }

    const msgId = `message-${extractMessageId(result.name)}`;
    // Store sent message ID for dedup when synced back
    await this.set(`sent:${msgId}`, true);

    const threadKey = extractThreadKey(result.thread.name);
    const spaceId = extractSpaceId(dmSpaceName);

    return {
      source: `google-chat:${spaceId}:thread:${threadKey}`,
      type: "dm",
      title: draft.title,
      status: null,
      created: new Date(result.createTime),
      sourceUrl: `https://chat.google.com/dm/${spaceId}/${threadKey}`,
      // Route DM threads to the DM channel so onNoteCreated can resolve a token.
      channelId: DM_CHANNEL_ID,
      meta: {
        syncProvider: "google-chat",
        // channelId is the actual DM space — needed by onNoteCreated / onNoteUpdated.
        channelId: DM_CHANNEL_ID,
        syncableId: DM_CHANNEL_ID,
        spaceId,
        spaceName: dmSpaceName,
        threadName: result.thread.name,
        threadKey,
      },
      // Bind the opening note to this Chat message (see createSpacePost).
      originatingNote: {
        key: msgId,
        externalContent:
          typeof result.formattedText === "string" &&
          result.formattedText.length > 0
            ? result.formattedText
            : (result.text ?? body),
      },
    };
  }

  // ---- Workspace member sync ----

  /**
   * Syncs Google Chat space members as Plot contacts so the recipient picker
   * can show reachable Google Chat users.
   *
   * Google Chat's `chat.memberships.readonly` scope allows listing members
   * of spaces the user is in, but there is no directory-wide "list all users"
   * endpoint available under user OAuth (that would require Workspace Admin SDK
   * or the People API with domain delegation, which are beyond the scopes we
   * request). Instead, we gather members from already-synced spaces:
   * each batch sync calls `getMemberInfo()` which already calls `listMembers()`,
   * so contacts accumulate organically as messages are synced.
   *
   * This method provides a proactive pass: it iterates all enabled named spaces
   * and saves their members so the picker is populated even before messages
   * arrive. Gated to at most once per 24 hours per connection.
   */
  async syncMembers(channelId: string): Promise<void> {
    const now = Date.now();
    const lastSyncedAt = await this.get<number>("googleChatMembersSyncedAt");
    const ONE_DAY_MS = 24 * 60 * 60 * 1000;
    if (lastSyncedAt && now - lastSyncedAt < ONE_DAY_MS) {
      return; // Already synced recently; skip.
    }

    // Prepare the daily callback token before any API calls so we can schedule
    // it in a finally block even if the sync throws. Rate-limit and
    // permanent-error branches set scheduleDaily = false to suppress reschedule.
    const nextRunAt = new Date(now + ONE_DAY_MS);
    const dailyCallback = await this.callback(this.syncMembers, channelId);
    let scheduleDaily = true;

    try {
      // Enumerate members from all enabled named spaces.
      // We iterate spaces rather than calling a hypothetical directory endpoint
      // because user OAuth doesn't grant domain-wide contact enumeration.
      const tokenChannelId = channelId !== DM_CHANNEL_ID ? channelId : null;
      const token = tokenChannelId
        ? await this.tools.integrations.get(tokenChannelId)
        : await this.tools.integrations.get(DM_CHANNEL_ID);
      if (!token) {
        console.warn("[google-chat] syncMembers: no token available, skipping");
        return;
      }

      const api = new GoogleChatApi(token.token);
      const spaces = await api.listSpaces();
      const contacts: NewContact[] = [];
      const seen = new Set<string>();

      for (const space of spaces) {
        if (space.spaceType !== "SPACE") continue;
        try {
          const members = await api.listMembers(space.name);
          for (const m of members) {
            if (m.member.type !== "HUMAN") continue;
            const accountId = googleUserIdToAccountId(m.member.name);
            if (seen.has(accountId)) continue;
            seen.add(accountId);

            const email = m.member.email;
            const name = m.member.displayName || undefined;
            if (!email && !name) continue;

            const contact: NewContact = {
              ...(email ? { email } : {}),
              ...(name ? { name } : {}),
              source: { accountId },
            } as NewContact;
            contacts.push(contact);
          }
        } catch {
          // Non-fatal: skip spaces we can't list members for.
        }
      }

      if (contacts.length > 0) {
        await this.tools.integrations.saveContacts(contacts);
      }

      await this.set("googleChatMembersSyncedAt", now);
    } catch (error) {
      if (isGoogleAuthError(error)) {
        // Permanent auth failure (revoked token or missing scope) — flag re-auth
        // and suppress daily reschedule so we don't keep hammering a broken token.
        scheduleDaily = false;
        console.warn("[google-chat] syncMembers stopped: auth error; flagging re-auth", error);
        const tokenChannelId = channelId !== DM_CHANNEL_ID ? channelId : DM_CHANNEL_ID;
        await this.tools.integrations.markNeedsReauth(tokenChannelId);
        return;
      }
      console.error("[google-chat] syncMembers: unexpected error", error);
      throw error;
    } finally {
      // Permanent-error path sets scheduleDaily = false and returns early above,
      // so it is not double-scheduled here.
      if (scheduleDaily) {
        await this.runTask(dailyCallback, { runAt: nextRunAt });
      }
    }
  }
}

export default GoogleChat;
