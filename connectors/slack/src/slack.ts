import {
  Connector,
  type CreateLinkDraft,
  type NoteWriteBackResult,
  type ToolBuilder,
} from "@plotday/twister";
import { ActionType } from "@plotday/twister/plot";
import type { Action, Actor, ActorId, Link, NewContact, NewLinkWithNotes, Note, Thread } from "@plotday/twister/plot";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { Files } from "@plotday/twister/tools/files";


type MessageChannel = {
  id: string;
  name: string;
  description: string | null;
  primary: boolean;
};

import {
  SLACK_AUTH_ERRORS,
  SLACK_UNICODE_TO_SHORTCODE,
  SlackApi,
  SlackPermanentError,
  SlackRateLimitedError,
  formatSlackText,
  type SlackChannel,
  type SlackMessage,
  type SlackUserInfo,
  type SlackUserInfoMap,
  slackUserInfoFromUser,
  type SyncState,
  syncSlackChannel,
  transformSlackThread,
} from "./slack-api";

/**
 * Slack integration source.
 *
 * Each Plot user authorizes their own Slack account via OAuth v2 with
 * **user-token scopes only** — no bot user is installed in the workspace.
 * Slack delivers events based on what the authorizing user can see, and
 * all Plot-initiated actions (reading history, posting replies, starring
 * messages) are attributed to that user.
 *
 * **Features:**
 * - OAuth 2.0 authentication with Slack (user token)
 * - Per-user authorization; no workspace bot required
 * - Real-time message synchronization via Slack Events API (user events)
 * - Support for threaded messages, mentions, and reactions
 * - Batch processing for large channels
 * - Star-based to-do sync against the user's saved items
 *
 * **Required OAuth User Scopes:**
 * - `channels:history` - Read public channel messages
 * - `channels:read` - View basic channel info
 * - `groups:history` - Read private channel messages
 * - `groups:read` - View basic private channel info
 * - `users:read` - View users in workspace
 * - `users:read.email` - View user email addresses
 * - `chat:write` - Post messages as the user (for Plot → Slack replies)
 * - `im:history` - Read direct messages
 * - `mpim:history` - Read group direct messages
 * - `stars:read` / `stars:write` - Read and manage the user's saved items
 */
export class Slack extends Connector<Slack> {
  static readonly PROVIDER = AuthProvider.Slack;
  static readonly handleReplies = true;
  static readonly SCOPES = [
    "channels:history",
    "channels:read",
    "groups:history",
    "groups:read",
    "users:read",
    "users:read.email",
    "chat:write",
    "im:history",
    "im:write",
    "mpim:history",
    "mpim:write",
    "stars:read",
    "stars:write",
  ];

  readonly provider = AuthProvider.Slack;
  readonly reactionCapabilities = {
    mode: "open-unicode" as const,
    // Custom workspace emoji are skipped on both sync directions for
    // v1; flip to "workspace" once the custom_emoji image cache lands.
    customEmoji: "none" as const,
  };
  readonly scopes = Slack.SCOPES;
  readonly linkTypes = [
    {
      type: "thread",
      label: "Thread",
      noteLabel: "Message",
      sharingModel: "channel" as const,
      supportsFileAttachments: true,
      logo: "https://api.iconify.design/logos/slack-icon.svg",
      logoMono: "https://api.iconify.design/simple-icons/slack.svg",
      statuses: [
        { status: "inbox", label: "Inbox" },
        { status: "later", label: "Later", active: true },
        { status: "sent", label: "Sent" },
      ],
      compose: {
        targets: "channels" as const,
        status: "sent",
      },
    },
    {
      type: "dm",
      label: "Direct messages",
      noteLabel: "Message",
      sharingModel: "thread" as const,
      supportsFileAttachments: true,
      logo: "https://api.iconify.design/logos/slack-icon.svg",
      logoMono: "https://api.iconify.design/simple-icons/slack.svg",
      statuses: [
        { status: "inbox", label: "Inbox" },
        { status: "later", label: "Later", active: true },
        { status: "sent", label: "Sent" },
      ],
      compose: {
        targets: "contacts" as const,
        status: "sent",
      },
    },
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, { urls: ["https://slack.com/api/*"] }),
      files: build(Files),
    };
  }

  override async activate(context: { auth: Authorization; actor: Actor }): Promise<void> {
    await this.set("auth_actor_id", context.actor.id);
    await this.set("auth", context.auth);
  }

  /**
   * Schedule `callback` at `runAt`, logging why. Used to defer work when
   * Slack rate-limits a call (typically 1 rpm for `conversations.*` under
   * the 2025-05-29 non-Marketplace app limits).
   */
  private async rescheduleAt(
    callback: Parameters<typeof this.runTask>[0],
    runAt: Date,
    reason: string
  ): Promise<void> {
    console.log(`Slack: rescheduling ${reason} at ${runAt.toISOString()}`);
    await this.runTask(callback, { runAt });
  }

  async getChannels(
    _auth: Authorization,
    token: AuthToken
  ): Promise<Channel[]> {
    const api = new SlackApi(token.token);
    const channels = await api.getChannels();
    const filtered = channels.filter(
      (c: SlackChannel) => c.is_member && !c.is_archived
    );
    // Surface "general" first so the channel-default scorer (which gives a +1
    // index-0 bonus) auto-enables it on install rather than picking whichever
    // channel Slack happens to list first (commonly "random").
    filtered.sort((a: SlackChannel, b: SlackChannel) => {
      if (a.name === "general") return -1;
      if (b.name === "general") return 1;
      return 0;
    });
    return filtered.map((c: SlackChannel) => ({ id: c.id, title: c.name }));
  }

  async onChannelEnabled(channel: Channel): Promise<void> {
    await this.set(`sync_enabled_${channel.id}`, true);

    // Pin the forward-sync floor to enable-time so the first webhook-driven
    // incremental sync doesn't backfill the preceding hour (see
    // `startIncrementalSync`). Stored in Slack ts format (seconds).
    await this.set(
      `enabled_at_${channel.id}`,
      (Date.now() / 1000).toString()
    );

    // No historical message backfill. Slack reduced `conversations.history`
    // and `conversations.replies` rate limits for non-Marketplace apps to
    // 1 rpm / 15 objects per call (2025-05-29 changelog), which makes
    // bulk-importing a channel's history impractical. Instead we watch for
    // new messages via the webhook and only backfill starred ("later")
    // items so users keep their saved-for-later.

    // Webhook registration is queued as a separate task so it doesn't block
    // the HTTP response from `onChannelEnabled`.
    const webhookCallback = await this.callback(
      this.setupChannelWebhook,
      channel.id
    );
    await this.runTask(webhookCallback);

    const backfillCallback = await this.callback(
      this.backfillStars,
      channel.id,
      null
    );
    await this.runTask(backfillCallback);

    // Sync workspace members so the DM recipient picker can filter to
    // reachable Slack contacts. Gated inside syncMembers to once per day,
    // so repeated onChannelEnabled calls (e.g. multiple channels enabled)
    // only hit users.list once.
    const membersCallback = await this.callback(this.syncMembers, channel.id);
    await this.runTask(membersCallback);
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.stopSync(channel.id);
    await this.clear(`sync_enabled_${channel.id}`);
  }

  private async getApi(channelId: string): Promise<SlackApi> {
    const token = await this.tools.integrations.get(channelId);
    if (!token) {
      throw new Error("No Slack authentication token available");
    }
    return new SlackApi(token.token);
  }

  /**
   * Resolves a workspace-scoped Slack API client, falling back to any other
   * currently-enabled channel's token if the preferred one is unavailable.
   *
   * Slack user-token scopes are workspace-wide: any token from the same OAuth
   * grant can address any DM the user is in. So when the channel a DM was
   * opened against is later disabled, we can still post by enumerating other
   * enabled channels in this connector instance's store. Enabled channels are
   * tracked under `sync_enabled_<channelId>` keys by `onChannelEnabled` /
   * `onChannelDisabled`.
   *
   * Use this on DM write-back paths (where the original `tokenChannelId` is
   * just a hint, not a hard binding). Regular per-channel paths should
   * continue to use {@link getApi} — disabling a channel intentionally
   * disables operations on threads from that channel.
   */
  private async getWorkspaceApi(preferredChannelId: string): Promise<SlackApi> {
    const preferred = await this.tools.integrations.get(preferredChannelId);
    if (preferred) return new SlackApi(preferred.token);

    const keys = await this.tools.store.list("sync_enabled_");
    for (const key of keys) {
      const channelId = key.substring("sync_enabled_".length);
      if (channelId === preferredChannelId) continue;
      const token = await this.tools.integrations.get(channelId);
      if (token) return new SlackApi(token.token);
    }

    throw new Error(
      "No Slack authentication token available (no enabled channels for this workspace)"
    );
  }

  async listWorkspaceChannels(channelId: string): Promise<MessageChannel[]> {
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

  async startSync(options: { channelId: string }): Promise<void> {
    // Historical sync is no longer performed (see `onChannelEnabled` for
    // context on Slack's 2025-05-29 rate-limit change). Just (re)register
    // the webhook so new messages flow in.
    await this.setupChannelWebhook(options.channelId);
  }

  async stopSync(channelId: string): Promise<void> {
    const webhook = await this.get<{ url: string }>(`channel_webhook_${channelId}`);
    if (webhook?.url) {
      try {
        await this.tools.network.deleteWebhook(webhook.url);
      } catch (error) {
        console.warn("Failed to delete Slack webhook:", error);
      }
    }
    await this.clear(`channel_webhook_${channelId}`);
    await this.clear(`sync_state_${channelId}`);
    await this.clear(`enabled_at_${channelId}`);

    // Sweep per-thread state for this channel so a re-enable starts clean.
    const starredKeys = await this.tools.store.list(`starred:${channelId}:`);
    for (const key of starredKeys) await this.clear(key);

    const skipKeys = await this.tools.store.list(`skip_todo_writeback:${channelId}:`);
    for (const key of skipKeys) await this.clear(key);
  }

  async setupChannelWebhook(channelId: string): Promise<void> {
    // Slack events arrive at a single app-wide URL (/hook/slack) and are
    // routed to a callback by team_id. Passing { provider, authorization }
    // makes createWebhook register this callback under the team's
    // CallbacksState DO; with empty options the callback would be keyed by
    // twist_instance_id and /hook/slack would never find it.
    const authorization = await this.get<Authorization>("auth");
    if (!authorization) {
      console.error(
        "Slack connector missing stored Authorization; cannot register webhook. Reconnect the account."
      );
      return;
    }

    const webhookUrl = await this.tools.network.createWebhook(
      { provider: AuthProvider.Slack, authorization },
      this.onSlackWebhook,
      channelId
    );

    await this.set(`channel_webhook_${channelId}`, {
      url: webhookUrl,
      channelId,
      created: new Date().toISOString(),
    });
  }

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
      const result = await syncSlackChannel(api, state);

      if (result.threads.length > 0) {
        await this.processMessageThreads(result.threads, channelId, isInitial);
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
      } else {
        if (mode === "full") {
          await this.clear(`sync_state_${channelId}`);
        }
      }
    } catch (error) {
      if (error instanceof SlackRateLimitedError) {
        const runAt = new Date(Date.now() + error.retryAfterMs);
        const retry = await this.callback(
          this.syncBatch,
          batchNumber,
          mode,
          channelId,
          isInitial
        );
        await this.rescheduleAt(
          retry,
          runAt,
          `syncBatch ${batchNumber} ${channelId} (${error.method})`
        );
        return;
      }
      if (error instanceof SlackPermanentError) {
        console.warn(
          `syncBatch ${batchNumber} for ${channelId} stopped: ${error.method} → ${error.slackError}`
        );
        if (SLACK_AUTH_ERRORS.has(error.slackError)) {
          await this.tools.integrations.markNeedsReauth(channelId);
        }
        if (mode === "full") await this.clear(`sync_state_${channelId}`);
        return;
      }
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
    initialSync: boolean
  ): Promise<void> {
    // Collect every unique Slack user id referenced by these threads
    // (message authors + reaction users) and resolve them up front via
    // `users.info` with a persistent cache. Without this, actors are
    // built with `name: userId`, which poisons the Plot contact row
    // (and the connector's own account label) with an opaque `U…` id.
    const userIds = new Set<string>();
    for (const thread of threads) {
      for (const message of thread) {
        const author = message.user;
        if (author) userIds.add(author);
        if (message.reactions) {
          for (const reaction of message.reactions) {
            for (const userId of reaction.users) userIds.add(userId);
          }
        }
      }
    }

    let userInfos: SlackUserInfoMap | undefined;
    try {
      const api = await this.getApi(channelId);
      userInfos = await this.resolveUserInfos(api, [...userIds]);
    } catch (error) {
      console.warn(
        "Failed to resolve Slack user info; proceeding without real names",
        error
      );
    }

    for (const thread of threads) {
      try {
        // Cache file → channel so downloadAttachment can resolve the right API
        // token later. Do this before the transform so even failed transforms
        // don't lose the mapping.
        for (const message of thread) {
          for (const f of message.files ?? []) {
            await this.set(`slack:file-channel:${f.id}`, channelId);
          }
        }

        // Transform Slack thread to NewLinkWithNotes
        const activityThread = transformSlackThread(
          thread,
          channelId,
          userInfos,
          initialSync
        );

        if (!activityThread.notes || activityThread.notes.length === 0) continue;

        // Inject sync metadata for the parent to identify the source
        activityThread.channelId = channelId;
        activityThread.meta = {
          ...activityThread.meta,
          syncProvider: "slack",
          syncableId: channelId,
        };

        // Save link directly via integrations
        await this.tools.integrations.saveLink(activityThread);
      } catch (error) {
        console.error(`Failed to process thread:`, error);
        // Continue processing other threads
      }
    }
  }

  /**
   * Resolve Slack user ids to `{ name, email }` using a persistent per-user
   * cache. A single id is stored under `user_info:<userId>` so repeat syncs
   * and webhook-driven incremental syncs don't re-hit `users.info`.
   *
   * Bot ids (`B…`) are not served by `users.info`; we skip them and let
   * callers fall back to the id as the actor name. Failures on individual
   * ids are non-fatal — missing entries are simply omitted from the map.
   */
  private async resolveUserInfos(
    api: SlackApi,
    userIds: string[]
  ): Promise<SlackUserInfoMap> {
    const result: SlackUserInfoMap = new Map();
    for (const userId of userIds) {
      if (!userId.startsWith("U") && !userId.startsWith("W")) continue;
      const cached = await this.get<SlackUserInfo>(`user_info:${userId}`);
      if (cached) {
        result.set(userId, cached);
        continue;
      }
      try {
        const user = await api.getUser(userId);
        if (!user) continue;
        const info = slackUserInfoFromUser(user);
        if (!info.name && !info.email) continue;
        await this.set(`user_info:${userId}`, info);
        result.set(userId, info);
      } catch (error) {
        console.warn(`users.info failed for ${userId}`, error);
      }
    }
    return result;
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

    const bodyObj = body as { challenge?: string; event?: any };
    if (bodyObj.challenge) {
      return; // URL verification challenge handled by infra
    }

    const event = bodyObj.event;
    if (!event) return;

    if (event.type === "star_added" || event.type === "star_removed") {
      await this.handleStarEvent(event, event.type === "star_added");
      return;
    }

    if (event.type === "reaction_added" || event.type === "reaction_removed") {
      await this.handleReactionEvent(event);
      return;
    }

    if (
      event.type === "message" &&
      event.channel === channelId &&
      !event.subtype
    ) {
      await this.startIncrementalSync(channelId);
    }
  }

  /**
   * Re-sync a single Slack thread on reaction_added / reaction_removed.
   *
   * The reaction event payload only carries the reacted message's ts.
   * Resolve its parent thread_ts via `conversations.history` so
   * `getThread` walks the right tree; fall back to the message ts as
   * thread_ts if the lookup fails (covers top-level messages).
   */
  private async handleReactionEvent(event: any): Promise<void> {
    const item = event.item;
    if (!item || item.type !== "message") return;

    const channelId = item.channel as string | undefined;
    const messageTs = item.ts as string | undefined;
    if (!channelId || !messageTs) return;

    if (!(await this.get<boolean>(`sync_enabled_${channelId}`))) return;

    let api: SlackApi;
    try {
      api = await this.getApi(channelId);
    } catch {
      return;
    }

    let parentTs = messageTs;
    try {
      const { messages } = await api.getConversationHistory(
        channelId,
        undefined,
        messageTs,
        messageTs
      );
      const m = messages.find((x) => x.ts === messageTs);
      if (m?.thread_ts) parentTs = m.thread_ts;
    } catch {
      // Continue with messageTs — top-level messages match this anyway.
    }

    try {
      await this.refreshSlackThread(api, channelId, parentTs);
    } catch (error) {
      if (error instanceof SlackRateLimitedError) {
        console.warn(
          `handleReactionEvent: rate limited on ${error.method}; dropping ${channelId}/${parentTs}`
        );
        return;
      }
      console.warn(
        `handleReactionEvent failed for ${channelId}/${parentTs}`,
        error
      );
    }
  }

  /**
   * Re-fetch a Slack thread and upsert it (notes + per-message reactions).
   * Idempotent via `source`/`key` upsert; safe to call repeatedly.
   * Unlike {@link saveStarredThread} this does not touch the link's
   * status or set the skipKey echo guard — it's purely a refresh path.
   */
  private async refreshSlackThread(
    api: SlackApi,
    channelId: string,
    threadTs: string
  ): Promise<void> {
    const messages = await api.getThread(channelId, threadTs);
    if (messages.length === 0) return;

    const userIds = new Set<string>();
    for (const message of messages) {
      if (message.user) userIds.add(message.user);
      if (message.reactions) {
        for (const reaction of message.reactions) {
          for (const userId of reaction.users) userIds.add(userId);
        }
      }
    }

    let userInfos: SlackUserInfoMap | undefined;
    try {
      userInfos = await this.resolveUserInfos(api, [...userIds]);
    } catch (error) {
      console.warn(
        "refreshSlackThread: resolveUserInfos failed; proceeding without real names",
        error
      );
    }

    const link = transformSlackThread(messages, channelId, userInfos, false);
    if (!link.notes || link.notes.length === 0) return;
    link.channelId = channelId;
    link.meta = {
      ...link.meta,
      syncProvider: "slack",
      syncableId: channelId,
    };
    await this.tools.integrations.saveLink(link);
  }

  private async handleStarEvent(event: any, isStarred: boolean): Promise<void> {
    const item = event.item;
    if (!item || item.type !== "message") return;

    const channelId = item.channel as string | undefined;
    const messageTs = item.message?.ts as string | undefined;
    const parentTs = (item.message?.thread_ts as string | undefined) ?? messageTs;
    if (!channelId || !parentTs) return;

    // Gate on enabled channels: ignore stars in channels the user hasn't
    // opted into for Plot sync (v1 scope).
    if (!(await this.get<boolean>(`sync_enabled_${channelId}`))) return;

    const wasStarred = !!(await this.get<boolean>(
      this.starredKey(channelId, parentTs)
    ));
    if (wasStarred === isStarred) return; // our own echo

    const actorId = await this.get<ActorId>("auth_actor_id");
    if (!actorId) {
      console.error("No auth_actor_id; cannot apply star event");
      return;
    }

    const canonicalUrl = `https://slack.com/app_redirect?channel=${channelId}&message_ts=${parentTs}`;

    try {
      if (isStarred) {
        // Since we no longer backfill history, the starred thread may not
        // exist in Plot yet. Fetching + saving is idempotent (saveLink
        // upserts by source) and ensures status="later" regardless of prior
        // state.
        const api = await this.getApi(channelId);
        await this.saveStarredThread(api, channelId, parentTs);
      } else {
        await this.tools.integrations.setThreadToDo(
          canonicalUrl,
          actorId,
          false
        );
      }
    } catch (error) {
      if (error instanceof SlackRateLimitedError) {
        // Drop the event rather than queue a retry: Slack will redeliver the
        // webhook, and we have no per-star task to reschedule.
        console.warn(
          `handleStarEvent: rate limited on ${error.method}; dropping event for ${channelId}/${parentTs}`
        );
        return;
      }
      console.warn(
        `handleStarEvent failed for ${channelId}/${parentTs}`,
        error
      );
    }

    // Block the onThreadToDo/onLinkUpdated callback that Plot will queue.
    await this.set(this.skipKey(channelId, parentTs), true);

    // Record the new state so subsequent duplicate events short-circuit.
    await this.set(this.starredKey(channelId, parentTs), isStarred);
  }

  async backfillStars(
    channelId: string,
    resumeCursor?: string | null
  ): Promise<void> {
    const actorId = await this.get<ActorId>("auth_actor_id");
    if (!actorId) return;

    let api: SlackApi;
    try {
      api = await this.getApi(channelId);
    } catch (error) {
      console.warn("backfillStars: Slack token unavailable", error);
      return;
    }

    let cursor: string | undefined = resumeCursor ?? undefined;
    try {
      do {
        const { items, nextCursor } = await api.listStars(cursor);

        for (const item of items) {
          if (item.type !== "message") continue;
          if (item.channel !== channelId) continue;

          const messageTs = item.message?.ts;
          const parentTs = item.message?.thread_ts ?? messageTs;
          if (!parentTs) continue;

          const alreadyStarred = await this.get<boolean>(
            this.starredKey(channelId, parentTs)
          );
          if (alreadyStarred) continue;

          try {
            await this.saveStarredThread(api, channelId, parentTs);
          } catch (error) {
            if (error instanceof SlackRateLimitedError) throw error;
            if (error instanceof SlackPermanentError) {
              if (SLACK_AUTH_ERRORS.has(error.slackError)) {
                // Auth is broken — every remaining star will fail the same
                // way. Flag reauth and stop the backfill instead of looping.
                await this.tools.integrations.markNeedsReauth(channelId);
                throw error;
              }
              console.warn(
                `backfillStars: skipping ${channelId}/${parentTs}: ${error.method} → ${error.slackError}`
              );
              continue;
            }
            console.warn(
              `backfillStars: failed to save starred thread ${channelId}/${parentTs}`,
              error
            );
            // Continue with other items.
          }

          await this.set(this.starredKey(channelId, parentTs), true);
        }

        cursor = nextCursor;
      } while (cursor);
    } catch (error) {
      if (error instanceof SlackRateLimitedError) {
        const runAt = new Date(Date.now() + error.retryAfterMs);
        const retry = await this.callback(
          this.backfillStars,
          channelId,
          cursor ?? null
        );
        await this.rescheduleAt(
          retry,
          runAt,
          `backfillStars ${channelId} (${error.method})`
        );
        return;
      }
      if (error instanceof SlackPermanentError) {
        console.warn(
          `backfillStars stopped for ${channelId}: ${error.method} → ${error.slackError}`
        );
        if (SLACK_AUTH_ERRORS.has(error.slackError)) {
          await this.tools.integrations.markNeedsReauth(channelId);
        }
        return;
      }
      throw error;
    }
  }

  /**
   * Fetch a Slack thread by its parent ts, resolve author identities, and
   * save it as a Plot link with status="later" (i.e. saved-for-later /
   * todo). `saveLink` upserts by `source`, so this is idempotent and safe
   * to call on a thread we've already seen.
   */
  private async saveStarredThread(
    api: SlackApi,
    channelId: string,
    threadTs: string
  ): Promise<void> {
    const messages = await api.getThread(channelId, threadTs);
    if (messages.length === 0) return;

    const userIds = new Set<string>();
    for (const message of messages) {
      if (message.user) userIds.add(message.user);
      if (message.reactions) {
        for (const reaction of message.reactions) {
          for (const userId of reaction.users) userIds.add(userId);
        }
      }
    }

    let userInfos: SlackUserInfoMap | undefined;
    try {
      userInfos = await this.resolveUserInfos(api, [...userIds]);
    } catch (error) {
      console.warn(
        "saveStarredThread: resolveUserInfos failed; proceeding without real names",
        error
      );
    }

    const link = transformSlackThread(messages, channelId, userInfos, true);
    if (!link.notes || link.notes.length === 0) return;

    link.status = "later";
    link.channelId = channelId;
    link.meta = {
      ...link.meta,
      syncProvider: "slack",
      syncableId: channelId,
    };

    // Suppress the onLinkUpdated echo Plot will fire from this write;
    // handleStarEvent / backfillStars is already the source of truth.
    await this.set(this.skipKey(channelId, threadTs), true);
    await this.tools.integrations.saveLink(link);
  }

  private async startIncrementalSync(channelId: string): Promise<void> {
    const webhookData = await this.get<any>(`channel_webhook_${channelId}`);
    if (!webhookData) {
      console.error("No channel webhook data found");
      return;
    }

    const nowSec = Date.now() / 1000;
    const enabledAtStr = await this.get<string>(`enabled_at_${channelId}`);
    const enabledAt = enabledAtStr ? parseFloat(enabledAtStr) : 0;

    // Fetch from max(enabled_at, now - 15min) so we don't backfill messages
    // from before the user enabled this channel. The 15-minute cap gives us
    // slack for delayed webhook delivery without dragging in yesterday.
    const windowFloor = nowSec - 15 * 60;
    const oldest = Math.max(enabledAt, windowFloor);

    const incrementalState: SyncState = {
      channelId,
      latest: nowSec.toString(),
      oldest: oldest.toString(),
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

  private starredKey(channelId: string, threadTs: string): string {
    return `starred:${channelId}:${threadTs}`;
  }

  private skipKey(channelId: string, threadTs: string): string {
    return `skip_todo_writeback:${channelId}:${threadTs}`;
  }

  async onThreadToDo(
    thread: Thread,
    _actor: Actor,
    todo: boolean,
    _options: { date?: Date }
  ): Promise<void> {
    const meta = thread.meta ?? {};
    const channelId = meta.channelId as string | undefined;
    const threadTs = meta.threadTs as string | undefined;
    if (!channelId || !threadTs) return;

    if (await this.get(this.skipKey(channelId, threadTs))) {
      await this.clear(this.skipKey(channelId, threadTs));
      return;
    }

    // Update local state BEFORE calling Slack so the webhook fired by our
    // own write sees isStarred === wasStarred and doesn't re-propagate.
    await this.set(this.starredKey(channelId, threadTs), todo);

    const api = await this.getApi(channelId);
    if (todo) {
      await api.addStar(channelId, threadTs);
    } else {
      await api.removeStar(channelId, threadTs);
    }
  }

  async onLinkUpdated(link: Link): Promise<void> {
    const channelId = link.meta?.channelId as string | undefined;
    const threadTs = link.meta?.threadTs as string | undefined;
    if (!channelId || !threadTs) return;

    if (await this.get(this.skipKey(channelId, threadTs))) {
      await this.clear(this.skipKey(channelId, threadTs));
      return;
    }

    const isLater = link.status === "later";
    await this.set(this.starredKey(channelId, threadTs), isLater);

    const api = await this.getApi(channelId);
    if (isLater) {
      await api.addStar(channelId, threadTs);
    } else {
      await api.removeStar(channelId, threadTs);
    }
  }

  // ---- Compose new messages from Plot ----

  /**
   * Creates a new Slack message from Plot via `onCreateLink`.
   *
   * - `thread`: posts to the enabled channel (`draft.channelId`).
   * - `dm`: opens or retrieves the DM/MPIM channel for the selected
   *   recipients, then posts there.
   *
   * The returned `meta` matches what `onNoteCreated` reads so replies via
   * the existing write-back path work with zero extra wiring.
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
    const api = await this.getApi(channelId);

    const body = (draft.noteContent ?? draft.title ?? "").trim();
    if (!body) {
      console.error("[slack] Cannot create channel post: body is empty");
      return null;
    }
    const result = await api.postMessage(channelId, body);
    if (!result?.ts) return null;

    const ts = result.ts;
    const canonicalUrl = `https://slack.com/app_redirect?channel=${channelId}&message_ts=${ts}`;

    return {
      source: `slack:channel:${channelId}:ts:${ts}`,
      type: "thread",
      title: draft.title,
      status: draft.status,
      created: new Date(parseFloat(ts) * 1000),
      sourceUrl: canonicalUrl,
      channelId,
      meta: {
        syncProvider: "slack",
        channelId,
        threadTs: ts,
        syncableId: channelId,
      },
    };
  }

  private async createDirectMessage(
    draft: CreateLinkDraft
  ): Promise<NewLinkWithNotes | null> {
    const recipients = draft.recipients;
    if (!recipients || recipients.length === 0) {
      console.error("slack dm onCreateLink: no recipients provided");
      return null;
    }

    const userIds = recipients.map((r) => r.externalAccountId);

    // Use any enabled channel's token to reach the workspace API.
    const api = await this.getWorkspaceApi(draft.channelId);

    // Open (or retrieve existing) DM/MPIM conversation.
    const dmChannelId = await api.openConversation(userIds);

    const body = (draft.noteContent ?? draft.title ?? "").trim();
    if (!body) {
      console.error("[slack] Cannot create direct message: body is empty");
      return null;
    }
    const result = await api.postMessage(dmChannelId, body);
    if (!result?.ts) return null;

    const ts = result.ts;
    const canonicalUrl = `https://slack.com/app_redirect?channel=${dmChannelId}&message_ts=${ts}`;

    return {
      source: `slack:channel:${dmChannelId}:ts:${ts}`,
      type: "dm",
      title: draft.title,
      status: draft.status,
      created: new Date(parseFloat(ts) * 1000),
      sourceUrl: canonicalUrl,
      channelId: draft.channelId,
      meta: {
        syncProvider: "slack",
        // channelId is the actual DM conversation to post into.
        channelId: dmChannelId,
        threadTs: ts,
        // tokenChannelId is an *enabled* workspace channel (C… / G…) whose
        // OAuth token grants workspace-wide access. DM channel ids (D… / G…
        // for MPIMs) are not registered as "enabled" channels, so the token
        // must resolve through a channel that is. We capture the channel the
        // user selected when composing the DM and store it as a preferred
        // hint — onNoteCreated / onNoteUpdated use getWorkspaceApi(), which
        // tries this channel first and falls back to any other enabled
        // channel in the workspace if it's been disabled. Replies keep
        // working as long as the user has at least one Slack channel
        // enabled.
        tokenChannelId: draft.channelId,
        syncableId: draft.channelId,
      },
    };
  }

  // ---- Workspace member sync ----

  /**
   * Syncs all active human workspace members as Plot contacts so the
   * recipient picker can filter to reachable Slack users.
   *
   * Gated to run at most once per 24 hours per workspace (connection) to
   * avoid re-hitting `users.list` on every `onChannelEnabled` call.
   */
  async syncMembers(channelId: string): Promise<void> {
    const now = Date.now();
    const lastSyncedAt = await this.get<number>("membersSyncedAt");
    const ONE_DAY_MS = 24 * 60 * 60 * 1000;
    if (lastSyncedAt && now - lastSyncedAt < ONE_DAY_MS) {
      return; // Already synced recently for this workspace; skip.
    }

    let api: SlackApi;
    try {
      api = await this.getApi(channelId);
    } catch (error) {
      console.warn("syncMembers: Slack token unavailable", error);
      return;
    }

    // Prepare the daily callback token before the pagination loop so we can
    // schedule it in a finally block. This ensures the chain persists even
    // when the loop throws an unexpected error (e.g. a transient network
    // failure). Rate-limit and permanent-error branches handle their own
    // scheduling (or skip rescheduling) and set scheduleDaily = false.
    const nextRunAt = new Date(now + ONE_DAY_MS);
    const dailyCallback = await this.callback(this.syncMembers, channelId);
    let scheduleDaily = true;

    const contacts: NewContact[] = [];
    let cursor: string | undefined;

    try {
      do {
        const { members, nextCursor } = await api.listUsers(cursor);

        for (const member of members) {
          // Skip deleted users, bots, and Slackbot.
          if ((member as any).deleted) continue;
          if ((member as any).is_bot) continue;
          if (member.id === "USLACKBOT") continue;

          const profile = member.profile;
          const name =
            profile?.display_name ||
            profile?.real_name ||
            member.real_name ||
            member.name ||
            null;
          const email = profile?.email ?? null;
          const avatar = profile?.image_72 ?? undefined;

          if (!name && !email) continue; // Need at least one identifier.

          const contact: NewContact = {
            ...(email ? { email } : {}),
            ...(name ? { name } : {}),
            ...(avatar ? { avatar } : {}),
            source: { accountId: member.id },
          } as NewContact;

          contacts.push(contact);
        }

        cursor = nextCursor;
      } while (cursor);

      if (contacts.length > 0) {
        await this.tools.integrations.saveContacts(contacts);
      }

      await this.set("membersSyncedAt", now);
    } catch (error) {
      if (error instanceof SlackRateLimitedError) {
        // Reschedule after the rate-limit window (shorter than one day).
        // Suppress the daily finally-schedule so we don't queue two tasks.
        scheduleDaily = false;
        const runAt = new Date(Date.now() + error.retryAfterMs);
        const retry = await this.callback(this.syncMembers, channelId);
        await this.rescheduleAt(retry, runAt, `syncMembers (${error.method})`);
        return;
      }
      if (error instanceof SlackPermanentError) {
        // Permanent errors are not retried; suppress daily reschedule too.
        scheduleDaily = false;
        console.warn(
          `syncMembers stopped: ${error.method} → ${error.slackError}`
        );
        if (SLACK_AUTH_ERRORS.has(error.slackError)) {
          await this.tools.integrations.markNeedsReauth(channelId);
        }
        return;
      }
      console.error("syncMembers: unexpected error", error);
      throw error;
    } finally {
      // Persist the daily chain even when an unexpected error is thrown. Rate-
      // limit and permanent-error paths set scheduleDaily = false and return
      // early above, so they are not double-scheduled here.
      if (scheduleDaily) {
        await this.runTask(dailyCallback, { runAt: nextRunAt });
      }
    }
  }

  // ---- Write-back: reply from Plot ----

  /**
   * Posts a Plot note as a Slack message via `chat.postMessage`.
   *
   * Returns a {@link NoteWriteBackResult} whose `externalContent` matches
   * what sync-in stores for the same message: `formatSlackText(message.text)`.
   * That parity is what lets the runtime-hash baseline recognize the
   * round-trip on the next `conversations.history` read and preserve
   * Plot's original (richer) content.
   *
   * The note `key` matches the sync-in convention — the bare Slack `ts` —
   * so subsequent sync-ins upsert the same note row.
   */
  async onNoteCreated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
    const meta = thread.meta ?? {};
    const channelId = meta.channelId as string;
    const threadTs = meta.threadTs as string | undefined;
    // For dm threads, tokenChannelId is an enabled workspace channel
    // whose OAuth token grants workspace access. Falls back to channelId for
    // regular channel threads where the channel IS the enabled resource.
    const tokenChannelId = (meta.tokenChannelId as string | undefined) ?? channelId;

    if (!channelId) {
      console.error("No channelId in meta for Slack reply");
      return;
    }

    const api = await this.getWorkspaceApi(tokenChannelId);

    const body = note.content ?? "";
    const result = await api.postMessage(channelId, body, threadTs);
    if (!result?.ts) return;

    // Upload each file action and attach to the same thread
    const fileActions = (note.actions ?? []).filter(
      (a): a is Extract<Action, { type: typeof ActionType.file }> =>
        a.type === ActionType.file,
    );
    for (const action of fileActions) {
      try {
        const file = await this.tools.files.read(action.fileId);
        const { upload_url, file_id } = await api.getUploadURLExternal(
          file.fileName,
          file.fileSize,
        );
        const putRes = await fetch(upload_url, {
          method: "PUT",
          // Cast to bypass TS confusion between Uint8Array and URLSearchParams
          // (the latter is from the form-encoded Slack API call helper).
          body: file.data as unknown as BodyInit,
        });
        if (!putRes.ok) {
          console.error(
            "Slack file PUT failed",
            action.fileId,
            putRes.status,
          );
          continue;
        }
        await api.completeUploadExternal(
          file_id,
          file.fileName,
          channelId,
          result.ts,
        );
      } catch (e) {
        console.error("Failed to send Slack attachment", action.fileId, e);
      }
    }

    const externalContent = formatSlackText(result.text ?? body);
    return {
      key: result.ts,
      externalContent,
    };
  }

  /**
   * Pushes an edited Plot note to Slack via `chat.update` and refreshes
   * the sync baseline from Slack's echoed `text`. Also reconciles
   * reactions: any emoji present in `note.reactions` but missing on the
   * Slack message is added; any reaction on the Slack message not
   * present in Plot is removed.
   *
   * The note's `key` is the Slack `ts` (set on create). If it's missing
   * or the thread lacks routing metadata we no-op.
   */
  async onNoteUpdated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
    const meta = thread.meta ?? {};
    const channelId = meta.channelId as string | undefined;
    if (!channelId) return;
    if (!note.key) return;
    // Only the original author can edit content; bail if there's nothing
    // to push. Reactions are handled separately via onNoteReactionChanged
    // so each emoji change is attributed to the user who made it.
    if (note.content === null || note.content === undefined) return;

    const tokenChannelId = (meta.tokenChannelId as string | undefined) ?? channelId;
    const api = await this.getWorkspaceApi(tokenChannelId);

    try {
      const body = note.content ?? "";
      const result = await api.updateMessage(channelId, note.key, body);
      const externalContent = formatSlackText(result.text ?? body);
      return { externalContent };
    } catch (error) {
      console.warn(
        "[slack] chat.update failed; skipping content baseline:",
        error
      );
      return;
    }
  }

  /**
   * Push a single emoji add/remove to Slack. The runtime dispatches this
   * callback on the reacting user's own Slack connector instance (routed
   * via `twist_instance_for_actor`), so `getWorkspaceApi` resolves to
   * that user's token and the `reactions.add` / `reactions.remove` call
   * is attributed correctly in Slack.
   */
  async onNoteReactionChanged(
    note: Note,
    thread: Thread,
    _actor: Actor,
    emoji: string,
    added: boolean
  ): Promise<void> {
    const meta = thread.meta ?? {};
    const channelId = meta.channelId as string | undefined;
    if (!channelId || !note.key) return;

    const shortcode = SLACK_UNICODE_TO_SHORTCODE[emoji];
    if (!shortcode) return; // unmapped Unicode / custom emoji — no Slack equivalent yet

    const tokenChannelId = (meta.tokenChannelId as string | undefined) ?? channelId;
    const api = await this.getWorkspaceApi(tokenChannelId);

    try {
      if (added) {
        await api.addReaction(channelId, note.key, shortcode);
      } else {
        await api.removeReaction(channelId, note.key, shortcode);
      }
    } catch (error) {
      console.warn(
        `[slack] reactions.${added ? "add" : "remove"} failed for ${shortcode}`,
        error
      );
    }
  }

  // ---- Inbound attachment downloads ----

  /**
   * Downloads a Slack file attachment identified by its Slack file id (`ref`).
   *
   * The `ref` is the Slack `file.id` emitted as an `ActionType.fileRef` action
   * during inbound sync. We look up the channel → API token from the cache
   * written in `processMessageThreads`, then use `files.info` to get the
   * download URL and fetch the bytes.
   */
  override async downloadAttachment(ref: string): Promise<
    | { redirectUrl: string }
    | { body: ReadableStream; mimeType: string; fileName?: string }
  > {
    const channelId = await this.findChannelForFile(ref);
    if (!channelId) {
      throw new Error(`No Slack channel found for file ${ref}`);
    }
    const api = await this.getApi(channelId);

    const info = await api.call("files.info", { file: ref });
    const f = info.file as {
      permalink_public?: string;
      url_private?: string;
      mimetype?: string;
      name?: string;
    };

    // Prefer the public permalink when available (no auth header needed).
    if (f.permalink_public) {
      return { redirectUrl: f.permalink_public };
    }

    // Fall back to url_private with a bearer token.
    const privateUrl = f.url_private;
    if (!privateUrl) {
      throw new Error(`Slack file ${ref} has no download URL`);
    }

    const res = await fetch(privateUrl, {
      headers: { Authorization: `Bearer ${api.accessToken}` },
    });
    if (!res.ok || !res.body) {
      throw new Error(`Slack file fetch failed: ${res.status}`);
    }

    return {
      body: res.body,
      mimeType: f.mimetype ?? "application/octet-stream",
      fileName: f.name,
    };
  }

  /**
   * Looks up which enabled channel saw a given Slack file id.
   *
   * Fast path: the file → channel mapping is cached by `processMessageThreads`
   * when the message containing the file is synced in.
   *
   * Slow path: probes each enabled channel via `files.info` — first success
   * wins and the result is cached for future calls.
   */
  private async findChannelForFile(fileId: string): Promise<string | null> {
    const cached = await this.get<string>(`slack:file-channel:${fileId}`);
    if (cached) return cached;

    // Slow path: probe each enabled channel.
    const channelIds = await this.listEnabledChannelIds();
    for (const channelId of channelIds) {
      try {
        const api = await this.getApi(channelId);
        const info = await api.call("files.info", { file: fileId });
        if (info?.file) {
          await this.set(`slack:file-channel:${fileId}`, channelId);
          return channelId;
        }
      } catch {
        // Try next channel — file not visible from this token.
      }
    }
    return null;
  }

  /** Returns the channel ids of all currently-enabled channels. */
  private async listEnabledChannelIds(): Promise<string[]> {
    const keys = await this.tools.store.list("sync_enabled_");
    return keys.map((key) => key.substring("sync_enabled_".length));
  }
}

export default Slack;
