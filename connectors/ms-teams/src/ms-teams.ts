import {
  Connector,
  type CreateLinkDraft,
  type NoteWriteBackResult,
  type ToolBuilder,
} from "@plotday/twister";
import type { NewActor, NewContact, NewLinkWithNotes, Note, Thread } from "@plotday/twister/plot";
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
  GraphApi,
  type OrgUser,
  type SyncState,
  type TeamsMessage,
  syncChannelMessages,
  transformChannelThread,
  transformDmThread,
} from "./graph-api";

const DM_CHANNEL_ID = "__direct_messages__";
const MAX_SYNC_BATCHES = 50;
/** Graph subscriptions for Teams channel messages max out at ~60 minutes. */
const SUBSCRIPTION_EXPIRY_MINUTES = 55;

/**
 * Returns true when a Graph API error indicates missing OAuth scopes or a
 * revoked/expired token — i.e. the user must re-authorize to fix it.
 *
 * Graph surfaces these as:
 *   - HTTP 401 → "Authentication failed - token may be expired"
 *   - HTTP 403 → "Access denied - insufficient permissions"
 */
function isGraphAuthError(error: unknown): boolean {
  if (!(error instanceof Error)) return false;
  return (
    error.message.includes("Authentication failed") ||
    error.message.includes("Access denied - insufficient permissions")
  );
}

export class MsTeams extends Connector<MsTeams> {
  static readonly PROVIDER = AuthProvider.Microsoft;
  static readonly handleReplies = true;
  static readonly SCOPES = [
    "https://graph.microsoft.com/Team.ReadBasic.All",
    "https://graph.microsoft.com/Channel.ReadBasic.All",
    "https://graph.microsoft.com/ChannelMessage.Read.All",
    "https://graph.microsoft.com/ChannelMessage.Send",
    "https://graph.microsoft.com/Chat.Create",
    "https://graph.microsoft.com/Chat.Read",
    "https://graph.microsoft.com/Chat.ReadWrite",
    "https://graph.microsoft.com/ChatMessage.Send",
    "https://graph.microsoft.com/User.Read",
    "https://graph.microsoft.com/User.Read.All",
  ];

  readonly provider = AuthProvider.Microsoft;
  readonly scopes = MsTeams.SCOPES;
  // Teams Graph API accepts both legacy enum reaction types (like,
  // heart, laugh, surprised, sad, angry) and Unicode emoji directly.
  // Teams allows only one reaction per user per message; bidirectional
  // write-back is wired through inbound today. For outbound, implement
  // `onNoteReactionChanged` — it dispatches per (note, actor, emoji)
  // on the reacting user's own connector instance, so the new
  // GraphApi.setChannelReaction / setChatReaction / unset* helpers
  // can be called under the right user's token.
  readonly reactionCapabilities = {
    mode: "open-unicode" as const,
    customEmoji: "none" as const,
  };
  readonly linkTypes = [
    {
      type: "thread",
      label: "Thread",
      noteLabel: "Message",
      sharingModel: "channel" as const,
      logo: "https://api.iconify.design/logos/microsoft-teams.svg",
      logoDark: "https://api.iconify.design/logos/microsoft-teams.svg",
      logoMono: "https://api.iconify.design/simple-icons/microsoftteams.svg",
      compose: {
        targets: "channels" as const,
      },
    },
    {
      type: "dm",
      label: "Direct messages",
      noteLabel: "Message",
      sharingModel: "thread" as const,
      logo: "https://api.iconify.design/logos/microsoft-teams.svg",
      logoDark: "https://api.iconify.design/logos/microsoft-teams.svg",
      logoMono: "https://api.iconify.design/simple-icons/microsoftteams.svg",
      compose: {
        targets: "contacts" as const,
      },
    },
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, { urls: ["https://graph.microsoft.com/*"] }),
    };
  }

  async getAccountName(
    _auth: Authorization | null,
    token: AuthToken | null
  ): Promise<string | null> {
    if (!token) return null;
    try {
      const api = new GraphApi(token.token);
      const me = await api.getMe();
      return me.displayName ?? null;
    } catch {
      return null;
    }
  }

  private async getApi(channelId: string): Promise<GraphApi> {
    const token = await this.tools.integrations.get(channelId);
    if (!token) {
      throw new Error("No Microsoft authentication token available");
    }
    return new GraphApi(token.token);
  }

  // ---- Channel discovery ----

  async getChannels(
    _auth: Authorization | null,
    token: AuthToken | null
  ): Promise<Channel[]> {
    if (!token) return [];
    const api = new GraphApi(token.token);

    const channels: Channel[] = [];

    // Get teams and their channels as a tree
    const teams = await api.getJoinedTeams();
    for (const team of teams) {
      const teamChannels = await api.getChannels(team.id);
      channels.push({
        id: team.id,
        title: team.displayName,
        // A team is a container, not a syncable resource — the user picks the
        // specific channels under it. Don't pre-select the team itself.
        enabledByDefault: false,
        children: teamChannels.map((ch) => ({
          id: ch.id,
          title: ch.displayName,
        })),
      });
    }

    // Synthetic DM channel
    channels.push({
      id: DM_CHANNEL_ID,
      title: "Direct Messages",
    });

    return channels;
  }

  // ---- Channel lifecycle ----

  async onChannelEnabled(
    channel: Channel,
    context?: SyncContext
  ): Promise<void> {
    await this.set(`sync_enabled_${channel.id}`, true);

    // When the channel is auto-observed because the user composed a Plot
    // thread into it (observeOnly), still register the change-notification
    // subscription so inbound replies/reactions sync back, but skip the
    // historical/initial message backfill.
    const observeOnly = context?.observeOnly ?? false;

    if (channel.id === DM_CHANNEL_ID) {
      // The DM path is purely historical backfill (no Graph subscription is
      // registered here), so it is skipped entirely under observeOnly.
      if (!observeOnly) {
        const syncCallback = await this.callback(this.syncDmSpaces, true);
        await this.runTask(syncCallback);
      }
    } else {
      // Queue all initialization as a task so the HTTP response returns
      // quickly. initChannel resolves the team ID (Graph API call),
      // registers the webhook subscription, and — unless observeOnly —
      // kicks off the first historical sync batch.
      const initCallback = await this.callback(
        this.initChannel,
        channel.id,
        observeOnly
      );
      await this.runTask(initCallback);
    }

    // Sync org members so the DM recipient picker can filter to reachable
    // Teams contacts. Gated inside syncMembers to once per 24 hours, so
    // repeated onChannelEnabled calls only hit /users once.
    const membersCallback = await this.callback(this.syncMembers, channel.id);
    await this.runTask(membersCallback);
  }

  /**
   * Initializes a channel: resolves team ID, starts sync, sets up webhook.
   * Runs as a task so the HTTP response from onChannelEnabled stays fast.
   */
  async initChannel(
    channelId: string,
    observeOnly?: boolean
  ): Promise<void> {
    const teamId = await this.findTeamForChannel(channelId);
    if (!teamId) {
      console.error(`Could not find team for channel ${channelId}`);
      return;
    }
    await this.set(`team_for_channel_${channelId}`, teamId);

    // Skip the historical/initial message backfill when the channel was
    // auto-observed (observeOnly). Webhook/subscription registration below
    // still runs so go-forward replies/reactions sync back.
    if (!observeOnly) {
      const timeMin = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
      const initialState: SyncState = {
        channelId,
        oldest: timeMin.toISOString(),
        initialSync: true,
      };
      await this.set(`sync_state_${channelId}`, initialState);

      // Run first sync batch inline (already in task context), then queue
      // webhook setup as a separate task.
      await this.syncBatch(1, "full", channelId, true);
    }

    const webhookCallback = await this.callback(
      this.setupChannelWebhook,
      channelId
    );
    await this.runTask(webhookCallback);
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    if (channel.id === DM_CHANNEL_ID) {
      await this.clear(`sync_enabled_${channel.id}`);
      return;
    }

    // Cancel subscription renewal task
    const taskToken = await this.get<string>(
      `renewal_task_${channel.id}`
    );
    if (taskToken) {
      try {
        await this.cancelTask(taskToken);
      } catch {
        // Task may already have executed
      }
      await this.clear(`renewal_task_${channel.id}`);
    }

    // Delete Graph subscription
    const subData = await this.get<{
      id: string;
      webhookUrl: string;
    }>(`subscription_${channel.id}`);
    if (subData) {
      try {
        const api = await this.getApi(channel.id);
        await api.deleteSubscription(subData.id);
      } catch (error) {
        console.error("Failed to delete Teams subscription:", error);
      }

      if (subData.webhookUrl) {
        try {
          await this.tools.network.deleteWebhook(subData.webhookUrl);
        } catch (error) {
          console.error("Failed to delete webhook:", error);
        }
      }

      await this.clear(`subscription_${channel.id}`);
    }

    // Clear state
    await this.clear(`sync_state_${channel.id}`);
    await this.clear(`sync_enabled_${channel.id}`);
    await this.clear(`team_for_channel_${channel.id}`);
  }

  // ---- Team resolution ----

  private async findTeamForChannel(channelId: string): Promise<string | null> {
    const cached = await this.get<string>(`team_for_channel_${channelId}`);
    if (cached) return cached;

    const token = await this.tools.integrations.get(channelId);
    if (!token) return null;
    const api = new GraphApi(token.token);
    const teams = await api.getJoinedTeams();
    for (const team of teams) {
      const channels = await api.getChannels(team.id);
      for (const ch of channels) {
        if (ch.id === channelId) {
          await this.set(`team_for_channel_${channelId}`, team.id);
          return team.id;
        }
      }
    }
    return null;
  }

  // ---- Channel message batch sync ----

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
      if (!state) throw new Error("No sync state found");

      const teamId = await this.get<string>(`team_for_channel_${channelId}`);
      if (!teamId) throw new Error("No team ID found for channel");

      const api = await this.getApi(channelId);
      const result = await syncChannelMessages(api, teamId, state);

      for (const { parent, replies } of result.threads) {
        try {
          const link = transformChannelThread(
            parent,
            replies,
            teamId,
            channelId,
            isInitial
          );

          link.channelId = channelId;
          link.meta = {
            ...link.meta,
            syncProvider: "teams",
            syncableId: channelId,
          };

          await this.tools.integrations.saveLink(link);
        } catch (error) {
          console.error("Failed to process Teams thread:", error);
        }
      }

      await this.set(`sync_state_${channelId}`, result.state);

      if (result.state.more) {
        const syncCallback = await this.callback(
          this.syncBatch,
          batchNumber + 1,
          mode,
          channelId,
          isInitial
        );
        await this.runTask(syncCallback);
      } else if (mode === "full") {
        await this.clear(`sync_state_${channelId}`);
      }
    } catch (error) {
      console.error(
        `Error in sync batch ${batchNumber} for channel ${channelId}:`,
        error
      );
      throw error;
    }
  }

  // ---- Webhook setup & handler ----

  async setupChannelWebhook(channelId: string): Promise<void> {
    try {
      const webhookUrl = await this.tools.network.createWebhook(
        {},
        this.onTeamsWebhook,
        channelId
      );

      // Localhost guard
      if (webhookUrl.includes("localhost") || webhookUrl.includes("127.0.0.1")) {
        return;
      }

      const teamId = await this.get<string>(`team_for_channel_${channelId}`);
      if (!teamId) {
        console.error("No team ID found for webhook setup");
        return;
      }

      const api = await this.getApi(channelId);
      const resource = `/teams/${teamId}/channels/${channelId}/messages`;
      const subscription = await api.createSubscription(
        resource,
        webhookUrl,
        "created,updated",
        SUBSCRIPTION_EXPIRY_MINUTES
      );

      await this.set(`subscription_${channelId}`, {
        id: subscription.id,
        expiry: subscription.expirationDateTime,
        webhookUrl,
      });

      // Schedule renewal before expiry
      await this.scheduleSubscriptionRenewal(channelId);
    } catch (error) {
      console.error("Failed to setup Teams webhook:", error);
    }
  }

  async onTeamsWebhook(
    request: WebhookRequest,
    channelId: string
  ): Promise<void> {
    // Handle Graph subscription validation handshake
    const validationToken = request.params?.validationToken;
    if (validationToken) {
      return;
    }

    const body = request.body as {
      value?: Array<{
        changeType: string;
        resource: string;
        clientState?: string;
      }>;
    };

    if (!body?.value?.length) return;

    // Trigger incremental sync for this channel
    await this.startIncrementalSync(channelId);
  }

  private async startIncrementalSync(channelId: string): Promise<void> {
    const incrementalState: SyncState = {
      channelId,
      oldest: new Date(Date.now() - 60 * 60 * 1000).toISOString(),
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
    await this.runTask(syncCallback);
  }

  // ---- Subscription renewal ----

  private async scheduleSubscriptionRenewal(
    channelId: string
  ): Promise<void> {
    const subData = await this.get<{ expiry: string }>(
      `subscription_${channelId}`
    );
    if (!subData?.expiry) return;

    const expiry = new Date(subData.expiry);
    // Renew 5 minutes before expiry
    const renewalTime = new Date(expiry.getTime() - 5 * 60 * 1000);

    if (renewalTime <= new Date()) {
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
      await this.set(`renewal_task_${channelId}`, taskToken);
    }
  }

  async renewSubscription(channelId: string): Promise<void> {
    try {
      const subData = await this.get<{
        id: string;
        expiry: string;
        webhookUrl: string;
      }>(`subscription_${channelId}`);

      if (!subData?.id) {
        await this.setupChannelWebhook(channelId);
        return;
      }

      const api = await this.getApi(channelId);
      const renewed = await api.renewSubscription(
        subData.id,
        SUBSCRIPTION_EXPIRY_MINUTES
      );

      await this.set(`subscription_${channelId}`, {
        ...subData,
        expiry: renewed.expirationDateTime,
      });

      await this.scheduleSubscriptionRenewal(channelId);
    } catch (error) {
      console.error(`Failed to renew subscription for ${channelId}:`, error);
      try {
        await this.setupChannelWebhook(channelId);
      } catch (retryError) {
        console.error("Failed to recreate subscription:", retryError);
      }
    }
  }

  // ---- DM sync ----

  async syncDmSpaces(initialSync?: boolean): Promise<void> {
    const isInitial = initialSync ?? true;

    try {
      const api = await this.getApi(DM_CHANNEL_ID);
      const chats = await api.getChats();

      for (const chat of chats) {
        const dmState: SyncState = {
          channelId: chat.id,
          initialSync: isInitial,
        };
        await this.set(`sync_state_dm_${chat.id}`, dmState);

        const syncCallback = await this.callback(
          this.syncDmBatch,
          1,
          chat.id,
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
    chatId: string,
    initialSync?: boolean
  ): Promise<void> {
    if (batchNumber > MAX_SYNC_BATCHES) {
      console.warn(`DM sync batch limit reached for ${chatId}`);
      return;
    }
    const isInitial = initialSync ?? true;

    try {
      const api = await this.getApi(DM_CHANNEL_ID);

      const state = await this.get<SyncState>(`sync_state_dm_${chatId}`);
      if (!state) throw new Error("No sync state found for DM");

      const result = await api.getChatMessages(chatId, {
        top: 50,
        skipToken: state.cursor,
      });

      const messages = result.value.filter(
        (msg) => msg.messageType === "message"
      );

      if (messages.length > 0) {
        const memberData = await this.getChatMembersAsActors(api, chatId);

        const link = transformDmThread(
          messages,
          chatId,
          memberData,
          isInitial
        );

        link.channelId = DM_CHANNEL_ID;
        link.meta = {
          ...link.meta,
          syncProvider: "teams",
          syncableId: DM_CHANNEL_ID,
        };

        await this.tools.integrations.saveLink(link);
      }

      const nextLink = result["@odata.nextLink"];
      const newState: SyncState = {
        channelId: chatId,
        cursor: nextLink,
        more: !!nextLink,
        initialSync: isInitial,
      };
      await this.set(`sync_state_dm_${chatId}`, newState);

      if (nextLink) {
        const syncCallback = await this.callback(
          this.syncDmBatch,
          batchNumber + 1,
          chatId,
          isInitial
        );
        await this.runTask(syncCallback);
      } else {
        await this.clear(`sync_state_dm_${chatId}`);
      }
    } catch (error) {
      console.error(
        `Error in DM sync batch ${batchNumber} for ${chatId}:`,
        error
      );
      throw error;
    }
  }

  private async getChatMembersAsActors(
    api: GraphApi,
    chatId: string
  ): Promise<NewActor[]> {
    const cached = await this.get<NewActor[]>(`chat_members_${chatId}`);
    if (cached) return cached;

    try {
      const members = await api.getChatMembers(chatId);
      const actors: NewActor[] = members
        .filter((m) => m.userId)
        .map((m) => ({
          name: m.displayName ?? m.userId!,
          email: m.email ?? undefined,
          source: { accountId: m.userId! },
        }));

      await this.set(`chat_members_${chatId}`, actors);
      return actors;
    } catch (error) {
      console.error("Failed to fetch chat members:", error);
      return [];
    }
  }

  // ---- Compose new messages from Plot ----

  /**
   * Creates a new Teams message from Plot via `onCreateLink`.
   *
   * - `thread`: posts a new top-level message to the enabled channel.
   * - `dm`: opens (or creates) a 1:1 or group chat with the selected
   *   recipients, then posts there.
   *
   * The returned `meta` matches exactly what `onNoteCreated` reads so replies
   * work via the existing write-back path with zero extra wiring.
   */
  override async onCreateLink(
    draft: CreateLinkDraft
  ): Promise<NewLinkWithNotes | null> {
    if (draft.type === "thread") {
      return this.createChannelPost(draft);
    }
    if (draft.type === "dm") {
      return this.createDirectMessage(draft);
    }
    return null;
  }

  private async createChannelPost(
    draft: CreateLinkDraft
  ): Promise<NewLinkWithNotes | null> {
    const channelId = draft.channelId;

    const body = (draft.noteContent ?? draft.title ?? "").trim();
    if (!body) {
      console.error("[ms-teams] Cannot create channel post: body is empty");
      return null;
    }

    const teamId = await this.findTeamForChannel(channelId);
    if (!teamId) {
      console.error(`[ms-teams] Cannot create channel post: no team for channel ${channelId}`);
      return null;
    }

    const api = await this.getApi(channelId);
    let result: Awaited<ReturnType<typeof api.sendChannelMessage>>;
    try {
      result = await api.sendChannelMessage(teamId, channelId, body);
    } catch (error) {
      if (isGraphAuthError(error)) {
        console.warn("[ms-teams] createChannelPost: missing scope or revoked token; flagging re-auth", error);
        await this.tools.integrations.markNeedsReauth(channelId);
      } else {
        console.error("[ms-teams] createChannelPost: failed to send message", error);
      }
      return null;
    }
    if (!result?.id) return null;

    return {
      source: `ms-teams:channel:${channelId}:message:${result.id}`,
      type: "thread",
      title: draft.title,
      status: draft.status,
      created: new Date(result.createdDateTime),
      channelId,
      meta: {
        syncProvider: "teams",
        syncableId: channelId,
        teamId,
        channelId,
        messageId: result.id,
      },
      // Bind the opening note to this Teams message so reactions/edits on it
      // route back (same key/baseline a reply gets from onNoteCreated).
      originatingNote: this.buildWriteBackResult(result, body),
    };
  }

  private async createDirectMessage(
    draft: CreateLinkDraft
  ): Promise<NewLinkWithNotes | null> {
    const recipients = draft.recipients;
    if (!recipients || recipients.length === 0) {
      console.error("[ms-teams] Cannot create DM: no recipients provided");
      return null;
    }

    const body = (draft.noteContent ?? draft.title ?? "").trim();
    if (!body) {
      console.error("[ms-teams] Cannot create DM: body is empty");
      return null;
    }

    // Resolve the token via the DM synthetic channel (always registered when
    // the user has DMs enabled). If the user hasn't enabled DMs, fall back to
    // whatever enabled channel draft.channelId references.
    let api: GraphApi;
    let tokenChannelId: string;
    try {
      api = await this.getApi(DM_CHANNEL_ID);
      tokenChannelId = DM_CHANNEL_ID;
    } catch {
      api = await this.getApi(draft.channelId);
      tokenChannelId = draft.channelId;
    }

    // Look up the caller's own AAD object id so we can include them in the
    // chat members list (required by Graph).
    let me: Awaited<ReturnType<typeof api.getMe>>;
    let chatId: string;
    let result: Awaited<ReturnType<typeof api.sendChatMessage>>;
    try {
      me = await api.getMe();
      const myAadId = me.id;

      const aadUserIds = recipients.map((r) => r.externalAccountId);
      chatId = await api.createChat(aadUserIds, myAadId);

      result = await api.sendChatMessage(chatId, body);
    } catch (error) {
      if (isGraphAuthError(error)) {
        console.warn("[ms-teams] createDirectMessage: missing scope or revoked token; flagging re-auth", error);
        await this.tools.integrations.markNeedsReauth(tokenChannelId);
      } else {
        console.error("[ms-teams] createDirectMessage: failed to send DM", error);
      }
      return null;
    }
    if (!result?.id) return null;

    return {
      source: `ms-teams:dm:${chatId}:message:${result.id}`,
      type: "dm",
      title: draft.title,
      status: draft.status,
      created: new Date(result.createdDateTime),
      // Store under the DM synthetic channel so token resolution works
      // for future replies via onNoteCreated.
      channelId: DM_CHANNEL_ID,
      meta: {
        syncProvider: "teams",
        syncableId: DM_CHANNEL_ID,
        chatId,
      },
      // Bind the opening note to this Teams message (see createChannelPost).
      originatingNote: this.buildWriteBackResult(result, body),
    };
  }

  // ---- Workspace member sync ----

  /**
   * Syncs all active org users from Microsoft Graph as Plot contacts so the
   * recipient picker can surface reachable Teams users.
   *
   * Gated to run at most once per 24 hours to avoid hammering /users on
   * every onChannelEnabled call. Uses Graph pagination via @odata.nextLink.
   * Rate-limit (HTTP 429 / Retry-After) reschedules via runTask in finally.
   */
  async syncMembers(channelId: string): Promise<void> {
    const now = Date.now();
    const lastSyncedAt = await this.get<number>("teamsMembersSyncedAt");
    const ONE_DAY_MS = 24 * 60 * 60 * 1000;
    if (lastSyncedAt && now - lastSyncedAt < ONE_DAY_MS) {
      return; // Already synced recently; skip.
    }

    let api: GraphApi;
    try {
      // Prefer any enabled channel's token; DM_CHANNEL_ID works if DMs are enabled.
      api = await this.getApi(channelId);
    } catch {
      try {
        api = await this.getApi(DM_CHANNEL_ID);
      } catch (error) {
        console.warn("[ms-teams] syncMembers: no token available", error);
        return;
      }
    }

    const nextRunAt = new Date(now + ONE_DAY_MS);
    const dailyCallback = await this.callback(this.syncMembers, channelId);
    let scheduleDaily = true;

    const contacts: NewContact[] = [];

    try {
      let nextLink: string | undefined;
      do {
        const page = await api.getOrgUsers(nextLink);
        nextLink = page.nextLink;

        for (const user of page.users) {
          // Skip disabled accounts.
          if (user.accountEnabled === false) continue;

          const name = user.displayName ?? null;
          const email = user.mail ?? user.userPrincipalName ?? null;

          if (!name && !email) continue;

          const contact: NewContact = {
            ...(name ? { name } : {}),
            ...(email ? { email } : {}),
            source: { accountId: user.id },
          } as NewContact;

          contacts.push(contact);
        }
      } while (nextLink);

      if (contacts.length > 0) {
        await this.tools.integrations.saveContacts(contacts);
      }

      await this.set("teamsMembersSyncedAt", now);
    } catch (error) {
      // Check for Graph rate-limit: HTTP 429 surfaces as an Error with message
      // "Rate limit exceeded - too many requests".
      const isRateLimit =
        error instanceof Error &&
        error.message.includes("Rate limit exceeded");

      if (isRateLimit) {
        // Retry after 60 seconds (Graph's Retry-After header is not directly
        // available here; use a conservative default).
        scheduleDaily = false;
        const runAt = new Date(Date.now() + 60 * 1000);
        console.log(`[ms-teams] syncMembers: rate limited; retrying at ${runAt.toISOString()}`);
        const retry = await this.callback(this.syncMembers, channelId);
        await this.runTask(retry, { runAt });
        return;
      }

      console.error("[ms-teams] syncMembers: unexpected error", error);
      throw error;
    } finally {
      if (scheduleDaily) {
        await this.runTask(dailyCallback, { runAt: nextRunAt });
      }
    }
  }

  // ---- Write-back: reply from Plot ----

  /**
   * Build a NoteWriteBackResult from the Graph API response so the runtime
   * can hash what Teams stored as the sync baseline. The body returned by
   * Graph may be normalized (e.g. HTML sanitized), so we use the response
   * `body.content`/`body.contentType` verbatim — that is what the next
   * sync-in pass will re-ingest as the note's content/contentType.
   */
  private buildWriteBackResult(
    result: TeamsMessage,
    fallbackContent: string
  ): NoteWriteBackResult {
    const body = result.body;
    const content = body?.content ?? fallbackContent;
    return {
      key: result.id,
      externalContent: content,
    };
  }

  async onNoteCreated(
    note: Note,
    thread: Thread
  ): Promise<NoteWriteBackResult | void> {
    const meta = thread.meta ?? {};
    const syncableId = meta.syncableId as string;
    const body = note.content ?? "";

    if (syncableId === DM_CHANNEL_ID) {
      // DM reply
      const chatId = meta.chatId as string;
      if (!chatId) {
        console.error("No chatId in meta for Teams DM reply");
        return;
      }

      const api = await this.getApi(DM_CHANNEL_ID);
      try {
        const result = await api.sendChatMessage(chatId, body);
        if (result?.id) {
          return this.buildWriteBackResult(result, body);
        }
      } catch (error) {
        console.error("Failed to send Teams DM reply:", error);
      }
    } else {
      // Channel reply
      const channelId = meta.channelId as string;
      const teamId = meta.teamId as string;
      const messageId = meta.messageId as string;

      if (!channelId || !teamId || !messageId) {
        console.error("Missing meta for Teams channel reply");
        return;
      }

      const api = await this.getApi(channelId);
      try {
        const result = await api.sendChannelReply(
          teamId,
          channelId,
          messageId,
          body
        );
        if (result?.id) {
          return this.buildWriteBackResult(result, body);
        }
      } catch (error) {
        console.error("Failed to send Teams channel reply:", error);
      }
    }
  }

  /**
   * Pushes Plot-side edits of an existing Teams-owned note back to Graph.
   * DMs are routed through `/chats/{chatId}/messages/{messageId}`; channel
   * messages and their replies both use the channel PATCH endpoint (Teams
   * replies are messages addressable by id).
   */
  async onNoteUpdated(
    note: Note,
    thread: Thread
  ): Promise<NoteWriteBackResult | void> {
    if (!note.key) return;

    // Reaction write-back: deferred to a follow-up. Teams allows only
    // one reaction per user per message via Graph, so a diff-and-apply
    // pass needs each reaction dispatched on the acting user's own
    // connector instance to attribute it correctly. Wire the new
    // GraphApi.setChannelReaction / setChatReaction / unset* helpers
    // once note-reaction dispatch is routed per-actor (parallel to
    // the schedule_contact → twist_instance_for_actor pattern).

    const meta = thread.meta ?? {};
    const syncableId = meta.syncableId as string;
    const body = note.content ?? "";
    const messageId = note.key;

    if (syncableId === DM_CHANNEL_ID) {
      const chatId = meta.chatId as string;
      if (!chatId) {
        console.error("No chatId in meta for Teams DM update");
        return;
      }

      const api = await this.getApi(DM_CHANNEL_ID);
      try {
        const result = await api.updateChatMessage(chatId, messageId, body);
        if (result) {
          return this.buildWriteBackResult(result, body);
        }
      } catch (error) {
        console.error("Failed to update Teams DM message:", error);
      }
    } else {
      const channelId = meta.channelId as string;
      const teamId = meta.teamId as string;

      if (!channelId || !teamId) {
        console.error("Missing meta for Teams channel message update");
        return;
      }

      const api = await this.getApi(channelId);
      try {
        const result = await api.updateChannelMessage(
          teamId,
          channelId,
          messageId,
          body
        );
        if (result) {
          return this.buildWriteBackResult(result, body);
        }
      } catch (error) {
        console.error("Failed to update Teams channel message:", error);
      }
    }
  }
}

export default MsTeams;
