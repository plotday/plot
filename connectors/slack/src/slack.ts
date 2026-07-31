import {
  Connector,
  type CreateLinkDraft,
  type NoteWriteBackResult,
  type ScopeConfig,
  type ToolBuilder,
} from "@plotday/twister";
import { ActionType } from "@plotday/twister/plot";
import type { Action, Actor, ActorId, NewContact, NewLinkWithNotes, Note, Thread } from "@plotday/twister/plot";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
  type SyncContext,
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
  SlackApi,
  SlackPermanentError,
  SlackRateLimitedError,
  formatSlackText,
  type SlackChannel,
  type SlackDMConversation,
  type SlackMessage,
  type SlackUserInfo,
  type SlackUserInfoMap,
  slackUserInfoFromUser,
  type SyncState,
  syncSlackChannel,
  transformSlackThread,
} from "./slack-api";
import { assembleSlackDmLink, slackConversationIdentity } from "./slack-dm";
import { unicodeToSlackName } from "./slack-emoji";
import { slackFacets } from "./slack-facets";
import { mentionsUser, type MentionContext } from "./slack-mentions";
import {
  channelReadVerdict,
  deriveReadAnchor,
  type SlackReadAnchor,
  threadReadVerdict,
} from "./slack-read-state";

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
 * - Direct and group conversations, each as one ongoing thread
 * - Channel threads that mention the user (directly, via a user group, or
 *   through `@here`/`@channel`) or that the user saved — never whole channels
 * - Star-based to-do sync against the user's saved items
 * - Reactions round-trip on everything that is synced
 * - Read state synced from Slack: a conversation you have read in Slack is
 *   read in Plot, and reading a direct conversation in Plot marks it read in
 *   Slack
 *
 * **Required OAuth User Scopes** (each backs a shipped, user-visible feature —
 * kept in sync with the authoritative {@link Slack.SCOPES} array below):
 * - `channels:history` — read messages in public channels the user syncs
 * - `channels:read` — list/enumerate public channels the user is in
 * - `groups:history` — read messages in private channels the user syncs
 * - `groups:read` — list/enumerate private channels the user is in
 * - `users:read` — resolve message authors/reactors to names + avatars
 * - `users:read.email` — match Slack users to Plot contacts by email
 * - `chat:write` — post the replies and messages the user writes in Plot
 * - `files:write` — upload the file attachments the user adds to a message
 *   (both link types advertise `supportsFileAttachments`)
 * - `stars:read` / `stars:write` — read and manage the user's saved (starred)
 *   items, surfaced as Plot to-dos
 * - `reactions:read` / `reactions:write` — read reactions during sync and
 *   round-trip the emoji reactions the user adds/removes in Plot
 *
 * **Optional** (connect-time toggle):
 * - `emoji:read` — render the workspace's custom emoji in reactions
 * - `usergroups:read` — recognise mentions of a user group the connected user
 *   belongs to (`@engineering`) as mentions of that user
 * - `im:history`, `im:write`, `mpim:history`, `mpim:write` — read and compose
 *   direct messages and group DMs
 * - `im:read`, `mpim:read` — enumerate/list the user's DM and group-DM
 *   conversations (`conversations.list` with `types=im,mpim`), which is how
 *   {@link listDMChannels} discovers DM/MPIM conversation ids. Distinct from
 *   `im:history`/`mpim:history`, which only grant reading message content
 *   within a conversation whose id is already known — they do not grant
 *   enumeration, so `listDMChannels` needs both.
 *
 * Read state uses only scopes the connector already holds: `conversations.info`
 * is covered by `channels:read`/`groups:read` (required) or `im:read`/`mpim:read`
 * (the optional `dms` group), and `conversations.mark` for direct conversations
 * by `im:write`/`mpim:write` (also `dms`). Channel threads are read-in only —
 * Slack's public API exposes no per-thread mark, and `conversations.mark` would
 * move the whole channel's cursor.
 */

/**
 * Delay before an event-triggered incremental sync runs. The pass is
 * scheduled as a keyed coalescing task, so a burst of message events
 * collapses into one pass that fires at most this long after the first one.
 */
const INCREMENTAL_SYNC_COALESCE_MS = 10_000;

/**
 * How long an unresolved read anchor is swept before it is dropped.
 *
 * Past this point Plot's own read state is the one that matters, and a link
 * the user has left unread for a month is not going to be settled by Slack's
 * cursor. Dropping it keeps the sweep bounded by live work.
 */
const READ_ANCHOR_RETENTION_MS = 30 * 24 * 60 * 60 * 1000;

/**
 * How far back an event-triggered incremental sync reads. Wide enough to
 * absorb delayed webhook delivery and the coalescing delay above, narrow
 * enough that it never drags in yesterday's conversation.
 */
const INCREMENTAL_SYNC_WINDOW_SEC = 15 * 60;

/**
 * Pages of `conversations.history` one incremental pass will read before
 * giving up on the rest of the window. `conversations.history` is limited to
 * 1 rpm for non-Marketplace apps, so paging further would stall the pass for
 * minutes; the next message event opens a fresh, overlapping window anyway.
 */
const INCREMENTAL_SYNC_MAX_PAGES = 5;

/**
 * How long a queued once-per-connection task stays "claimed".
 *
 * Only long enough to dedupe a fan-out of near-simultaneous
 * `onChannelEnabled` calls (a multi-channel reconnect, a "refresh channels",
 * a stuck-sync watchdog retry). NOT a substitute for each task's own gate —
 * those are owned by the tasks themselves and set only on their own success.
 * A claim expiring after a few minutes means a permanently-failed queued task
 * doesn't silently suppress a legitimate retry; it just means a fan-out
 * inside the claim window won't double-queue.
 */
const WORKSPACE_TASK_CLAIM_TTL_MS = 5 * 60 * 1000;

/**
 * Coalescing delay for reaction-triggered thread refreshes. A burst of
 * reaction events (several people reacting to the same thread) collapses
 * into one drain pass.
 */
const REACTION_REFRESH_COALESCE_MS = 10_000;

/**
 * Per-id retry cap for the reaction-refresh drain. Slack limits
 * `conversations.history`/`conversations.replies` to 1 rpm for
 * non-Marketplace apps with Retry-After typically ~60s, while retry passes
 * are spaced only {@link REACTION_REFRESH_COALESCE_MS} apart — so an id must
 * survive many rate-limited passes before the limiter clears. 20 attempts
 * ≈ 3+ minutes of sustained rate limiting before an id is dropped.
 */
const REACTION_REFRESH_MAX_ATTEMPTS = 20;

/**
 * Extra-arg value used to register ONE webhook callback per Slack
 * connection that covers ALL of the user's DM/MPIM conversations, instead of
 * one callback per conversation (which would require enumerating and
 * tracking hundreds of `channel` rows with no corresponding Settings UI to
 * manage them). `GetSlackCallbacks` (workers/api/src/twist/tools/network.ts)
 * broadcasts every incoming Slack event to every callback registered for the
 * team whose granted scopes cover the event type — this sentinel is just
 * another registered callback's extraArg, distinguished from a real
 * channelId by never matching a Slack conversation id format.
 */
const DM_WEBHOOK_SENTINEL = "__dm_workspace__";

/**
 * Extra-arg value for the single workspace-wide callback that observes channel
 * messages for at-mentions and replies on already-subscribed threads. Mirrors
 * {@link DM_WEBHOOK_SENTINEL}: there is no per-channel registration because
 * there is no channel selection.
 */
const MENTION_WEBHOOK_SENTINEL = "__mentions__";

/**
 * How long to wait before re-attempting a webhook registration that could not
 * go ahead. Long enough to cost nothing, short enough that a connection whose
 * token was momentarily unresolvable starts observing again the same day.
 */
const WEBHOOK_REGISTER_RETRY_MS = 60 * 60 * 1000;

/** Task keys for the two registration retry chains. */
const DM_WEBHOOK_RETRY_KEY = "dm-webhook-register";
const MENTION_WEBHOOK_RETRY_KEY = "mention-webhook-register";

export class Slack extends Connector<Slack> {
  static readonly PROVIDER = AuthProvider.Slack;
  static readonly DM_WEBHOOK_SENTINEL = DM_WEBHOOK_SENTINEL;
  static readonly MENTION_WEBHOOK_SENTINEL = MENTION_WEBHOOK_SENTINEL;
  static readonly handleReplies = true;
  static readonly SCOPES: ScopeConfig = {
    required: [
      "channels:history",
      "channels:read",
      "groups:history",
      "groups:read",
      "users:read",
      "users:read.email",
      "chat:write",
      // File attachments: both link types advertise `supportsFileAttachments`,
      // and onNoteCreated uploads them via files.getUploadURLExternal /
      // files.completeUploadExternal. Without this scope those calls fail with
      // `missing_scope` and the attachment is silently dropped (the text still
      // sends). Existing connections must reconnect to grant it; the upload
      // path already degrades gracefully (logs + continues) when it's absent.
      "files:write",
      "stars:read",
      "stars:write",
      // Emoji reaction round-trip: reactions:write to add/remove reactions on
      // write-back (onNoteReactionChanged → reactions.add/remove), reactions:read
      // to read reactions during sync and receive reaction_added/reaction_removed
      // events. Without reactions:write, write-back fails with `missing_scope`.
      "reactions:write",
      "reactions:read",
    ],
    optional: [
      {
        id: "emoji",
        label: "Sync this workspace's custom emoji",
        description:
          "Show your workspace's custom emoji (like :party_parrot:) in Plot's reaction picker and round-trip them as reactions.",
        scopes: ["emoji:read"],
        default: true,
      },
      {
        id: "dms",
        label: "Sync direct messages",
        description:
          "Bring your Slack DMs and group DMs into Plot, and let you send new ones from Plot.",
        scopes: [
          "im:history",
          "im:write",
          "mpim:history",
          "mpim:write",
          // Enumeration scopes: conversations.list with types=im,mpim (used by
          // listDMChannels to discover conversation ids) requires these, not
          // the *:history scopes above — see the class doc comment.
          "im:read",
          "mpim:read",
        ],
        default: true,
      },
      {
        id: "usergroups",
        label: "Notice @-mentions of your groups",
        description:
          "Bring in messages that mention a Slack user group you belong to, like @engineering, as well as messages that mention you directly.",
        scopes: ["usergroups:read"],
        default: true,
      },
    ],
  };

  readonly provider = AuthProvider.Slack;
  // Channels are internal detail here: this connector decides what to sync
  // from the message itself (a direct conversation, an at-mention, a saved
  // thread), not from a channel the user picked. Channels are still mirrored
  // so links carry channel attribution and compose has targets.
  readonly hiddenChannels = true;
  // Not a user-facing preference: this connector hides its channels, so
  // nothing else ever enables one. Auto-enabling on discovery is what makes
  // `onChannelEnabled` fire, which is where this connector anchors its
  // workspace-level setup (sentinel webhooks, saved-item backfill, daily
  // roster refreshes).
  readonly autoEnableNewChannelsByDefault = true;
  readonly reactionCapabilities = {
    mode: "open-unicode" as const,
    // Workspace custom emoji sync both ways: inbound reactions become
    // `slack:<teamId>/<name>` refs (see extractSlackMessageReactions), the
    // cache is populated by syncCustomEmoji, and onNoteReactionChanged
    // unwraps refs back to the bare name for reactions.add/remove.
    customEmoji: "workspace" as const,
  };
  readonly scopes = Slack.SCOPES;
  readonly access = [
    "Reads messages in the channels and DMs you sync",
    "Sends messages and replies you write in Plot",
    "Adds and removes emoji reactions you make in Plot",
  ];
  readonly linkTypes = [
    {
      type: "thread",
      label: "Thread",
      noteLabel: "Message",
      sharingModel: "channel" as const,
      supportsFileAttachments: true,
      logo: "https://api.iconify.design/logos/slack-icon.svg",
      logoMono: "https://api.iconify.design/simple-icons/slack.svg",
      compose: {
        targets: "channels" as const,
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
      compose: {
        targets: "contacts" as const,
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

  /**
   * Runs once per active connection when a new connector version deploys —
   * the standard hook for a one-time migration (see `upgradeToScopedSync`).
   * This is the primary trigger: it fires for every existing connection on
   * deploy regardless of channel activity, unlike `onChannelEnabled`, which
   * only re-dispatches for a channel that changes state (a stable, already-
   * enabled workspace produces none). `onChannelEnabled` still calls the
   * same routine as a backstop for connections that connect or finish
   * enabling around the deploy boundary and so might miss this dispatch.
   */
  override async upgrade(): Promise<void> {
    await this.upgradeToScopedSync();
  }

  async onChannelEnabled(channel: Channel, context?: SyncContext): Promise<void> {
    // Channels are not individually synced any more (see `hiddenChannels`).
    // This still fires when channels are mirrored, so it is where the
    // workspace-wide setup is anchored — the sentinel webhooks and the daily
    // roster refreshes, each internally gated to run once per connection.
    //
    // The one piece of per-channel state left is the marker below. It is NOT
    // a sync gate: it is the connector's only record of which channel ids its
    // OAuth token can be resolved against, which `getWorkspaceApi` walks to
    // send a reply on a direct conversation (DM ids are never channels) and
    // `findChannelForFile` walks to locate an attachment.
    await this.set(`token_channel_${channel.id}`, true);

    // Slack does no historical backfill (see below), so there is no "still
    // syncing" period. Signal completion here, unconditionally and before
    // queuing anything else, so it fires even if this call is a stuck-sync
    // watchdog retry re-running an already-complete channel, and even if a
    // later step in this method throws. Without this call,
    // `initial_sync_completed_at` never gets set for ANY Slack connection —
    // the stuck-sync watchdog treats every connection as permanently
    // orphaned, retries a handful of times, then forces a re-auth prompt on a
    // perfectly healthy connection.
    await this.tools.integrations.channelSyncCompleted(channel.id);

    // Backstop for the one-time cleanup normally run from `upgrade()` (fires
    // once per connection when a new connector version deploys). A
    // connection that was mid-enable across that deploy, or a fresh connect,
    // never gets an `upgrade()` dispatch of its own, so this catches those.
    // Placed AFTER `channelSyncCompleted` above and made fully non-throwing
    // internally: nothing here may be allowed to skip that call or the
    // queuing below, or a healthy connection reads as permanently stuck to
    // the sync watchdog.
    await this.upgradeToScopedSync();

    // No historical message backfill. Slack reduced `conversations.history`
    // and `conversations.replies` rate limits for non-Marketplace apps to
    // 1 rpm / 15 objects per call (2025-05-29 changelog), which makes
    // bulk-importing history impractical. Instead we watch for new messages
    // via the two workspace-wide webhooks (queued by
    // `queueWorkspaceDailyTasks` below) and only backfill saved items so
    // users keep their to-do (starred) threads.

    // observeOnly = the channel was auto-observed because a Plot thread was
    // composed into it. Register the webhooks (above) for go-forward events
    // but skip the saved-items backfill — nothing about composing a message
    // asks for the user's history.
    if (!context?.observeOnly) {
      await this.queueStarBackfill(channel.id);
    }

    // Queue the workspace-scoped work — both webhook registrations, member
    // sync, custom emoji sync, user groups, DM roster — at most once per
    // fan-out instead of once per channel.
    await this.queueWorkspaceDailyTasks(channel.id);
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    // There is no per-channel sync to stop — nothing is synced per channel.
    // Disabling a channel is not a supported operation on a connector that
    // hides its channels, so this only runs when a channel becomes
    // unreachable or the connection is torn down.
    await this.clear(`token_channel_${channel.id}`);

    // Cancel the daily recurring chains keyed to this channel, and drop any
    // pending event-driven drains (and their backlogs) for it.
    // Every recurring chain and drain keyed to this channel has to be listed
    // here. A chain left running fires daily forever and calls
    // `integrations.get(channel.id)`, whose migration fallback rewrites the
    // channel config as enabled — so a leak does not merely waste work, it
    // resurrects the channel.
    await this.cancelScheduledTask(`members-sync:${channel.id}`);
    await this.cancelScheduledTask(`custom-emoji-sync:${channel.id}`);
    await this.cancelScheduledTask(`user-groups-sync:${channel.id}`);
    await this.cancelScheduledTask(`dm-channels-sync:${channel.id}`);
    await this.cancelScheduledTask(`read-state-sync:${channel.id}`);
    await this.cancelDrain(`incremental-sync:${channel.id}`);
    await this.cancelDrain(`reaction-refresh:${channel.id}`);
    await this.cancelDrain(`subscribed-thread:${channel.id}`);

    // `queueReactionRefresh`'s rate-limit retry (see there) is keyed per
    // message rather than per channel, so it cannot be cancelled by a single
    // fixed key like the chains above. It records a listable marker instead;
    // walk those to cancel every retry still pending for this channel.
    const reactionScopePrefix = `reaction-scope-pending:${channel.id}:`;
    const reactionScopeKeys = await this.tools.store.list(reactionScopePrefix);
    for (const key of reactionScopeKeys) {
      const messageTs = key.substring(reactionScopePrefix.length);
      await this.cancelScheduledTask(`reaction-scope:${channel.id}:${messageTs}`);
      await this.clear(key);
    }

    // Sweep per-thread saved-state for this channel. Subscriptions
    // (`sync_thread:`) are deliberately NOT swept — they are permanent, so a
    // thread that already earned its place in Plot keeps updating.
    const starredKeys = await this.tools.store.list(`starred:${channel.id}:`);
    for (const key of starredKeys) await this.clear(key);

    // Read anchors are per-conversation reconciliation state, not a record of
    // what earned a place in Plot, so unlike `sync_thread:` they are swept.
    const anchorKeys = await this.tools.store.list(`read_anchor:${channel.id}:`);
    for (const key of anchorKeys) await this.clear(key);
  }

  /**
   * One-time cleanup for connections created under the old per-channel sync
   * model. Called from `upgrade()` (primary trigger, once per connection on
   * deploy) and from `onChannelEnabled` (backstop); gated on
   * `scoped_sync_upgraded` so it does real work exactly once and is a single
   * cheap read on every call after.
   *
   * `channel_webhook_<channelId>` and its registered Slack webhook, plus
   * `sync_state_<channelId>` and `enabled_at_<channelId>`, are pure leftovers
   * from the old model — nothing reads them any more, so they are removed
   * outright. Duplicate deliveries from a webhook that outlives its
   * deregistration are idempotent (every downstream path already handles
   * them), so the webhook removal itself is best-effort.
   *
   * `sync_enabled_<channelId>` is different: its gating read is gone, but the
   * key is still the ONLY record of which channel ids this connection's
   * OAuth token can be resolved against — `getWorkspaceApi` walks it to reach
   * a direct conversation, and `findChannelForFile` walks it to locate an
   * uncached attachment. Dropping it outright (rather than renaming it) would
   * silently break both: replies on synced DMs would stop sending and
   * inbound file attachments would stop resolving, with no error anywhere.
   * So it is RENAMED to `token_channel_<channelId>`, the name
   * `onChannelEnabled` now writes going forward.
   *
   * The entire body below runs inside one try/catch: this is genuinely
   * best-effort, not just documented as such. A store blip partway through
   * (a large workspace's first post-deploy pass can be dozens of Durable
   * Object round-trips) must not throw out of here — `onChannelEnabled`
   * calls this AFTER `channelSyncCompleted`, so a throw at that call site
   * would be harmless to the stuck-sync watchdog either way, but `upgrade()`
   * has no such downstream step to protect and no caller that tolerates a
   * rejected lifecycle hook well. Catching here, once, covers both callers
   * uniformly. `scoped_sync_upgraded` is set only as the LAST statement
   * inside the try, so a failure anywhere above it — caught here or not —
   * never marks the upgrade done with the work incomplete; the next call
   * (from either trigger) resumes from whatever `store.list` still finds.
   */
  private async upgradeToScopedSync(): Promise<void> {
    try {
      // Inside the try: this read is a Durable Object round-trip like every
      // other statement below, and it is the one that runs on EVERY call
      // forever. Left outside, a blip on it would throw out of here — and
      // out of `onChannelEnabled`, skipping the saved-items backfill and the
      // workspace task queuing (webhook registration included) that follow
      // the call.
      if (await this.get<boolean>("scoped_sync_upgraded")) return;

      for (const key of await this.tools.store.list("channel_webhook_")) {
        const webhook = await this.get<{ url?: string }>(key);
        if (webhook?.url) {
          try {
            await this.tools.network.deleteWebhook(webhook.url);
          } catch (error) {
            console.warn(`[slack] failed to remove webhook for ${key}`, error);
          }
        }
        await this.clear(key);
      }

      // Rename, not drop: write the new key before clearing the old one, so
      // a partial pass leaves at worst both keys present for a channel
      // (harmless — only `token_channel_` is read going forward) and never
      // neither. Re-running the whole loop on a retry is safe: any channel
      // already renamed no longer has a `sync_enabled_` key to find, and
      // re-writing `token_channel_<id>` = true for one still pending is a
      // no-op overwrite of the same value.
      for (const key of await this.tools.store.list("sync_enabled_")) {
        const channelId = key.substring("sync_enabled_".length);
        await this.set(`token_channel_${channelId}`, true);
        await this.clear(key);
      }

      for (const prefix of ["sync_state_", "enabled_at_"]) {
        for (const key of await this.tools.store.list(prefix)) {
          await this.clear(key);
        }
      }

      await this.set("scoped_sync_upgraded", true);
    } catch (error) {
      console.warn(
        "[slack] upgradeToScopedSync failed; will retry on the next pass",
        error
      );
    }
  }

  private async getApi(channelId: string): Promise<SlackApi> {
    const token = await this.tools.integrations.get(channelId);
    if (!token) {
      throw new Error("No Slack authentication token available");
    }
    return new SlackApi(token.token);
  }

  /**
   * Resolves the workspace teamId and the cached set of custom-emoji names for
   * a channel, so the inbound transform can recognise custom reactions and emit
   * `slack:<teamId>/<name>` refs. The name set is populated by
   * {@link syncCustomEmoji}; both are best-effort (a missing token or
   * un-synced workspace just means no custom refs are emitted).
   */
  private async customEmojiContext(channelId: string): Promise<{
    teamId?: string;
    customEmojiNames?: ReadonlySet<string>;
  }> {
    const token = await this.tools.integrations.get(channelId);
    const teamId = token?.provider?.team_id;
    if (!teamId) return {};
    const names = await this.get<string[]>(`custom_emoji_${teamId}`);
    return {
      teamId,
      customEmojiNames: names ? new Set(names) : undefined,
    };
  }

  /**
   * Resolves a workspace-scoped Slack API client, falling back to any other
   * currently-enabled channel's token if the preferred one is unavailable.
   *
   * Slack user-token scopes are workspace-wide: any token from the same OAuth
   * grant can address any conversation the user is in. A direct conversation
   * is not a channel, so its id can never resolve a token on its own — we
   * fall back to enumerating the channel ids this connection has seen, which
   * `onChannelEnabled` records under `token_channel_<channelId>`.
   *
   * Use this on every write-back path that targets a conversation rather than
   * a channel. {@link getApi} remains the direct path when the id in hand is
   * known to be a real channel.
   */
  private async getWorkspaceApi(preferredChannelId: string): Promise<SlackApi> {
    const preferred = await this.tools.integrations.get(preferredChannelId);
    if (preferred) return new SlackApi(preferred.token);

    const keys = await this.tools.store.list("token_channel_");
    for (const key of keys) {
      const channelId = key.substring("token_channel_".length);
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

    const { teamId, customEmojiNames } =
      await this.customEmojiContext(channelId);

    // Cache file → channel so downloadAttachment can resolve the right API
    // token later. Done up front, before anything that can fail or take an
    // early exit, so no attachment loses its mapping.
    for (const thread of threads) {
      for (const message of thread) {
        for (const f of message.files ?? []) {
          await this.set(`slack:file-channel:${f.id}`, channelId);
        }
      }
    }

    if (await this.isKnownDMChannel(channelId)) {
      // One permanent link for the whole conversation: flatten the thread
      // grouping `syncSlackChannel` applied, since a direct conversation
      // reads as one running conversation and its occasional threaded reply
      // becomes a note reply.
      const link = await this.buildConversationLink({
        channelId,
        messages: threads.flat(),
        initialSync,
        userInfos,
        teamId,
        customEmojiNames,
      });
      if (link) await this.tools.integrations.saveLink(link);
      return;
    }

    for (const thread of threads) {
      try {
        const link = await this.buildConversationLink({
          channelId,
          messages: thread,
          initialSync,
          userInfos,
          teamId,
          customEmojiNames,
        });
        if (link) await this.tools.integrations.saveLink(link);
      } catch (error) {
        console.error(`Failed to process thread:`, error);
        // Continue processing other threads
      }
    }
  }

  /**
   * Build the link for a set of Slack messages in the shape their
   * conversation uses.
   *
   * A direct or group conversation is ONE permanent, ever-growing link (see
   * {@link assembleSlackDmLink}); anywhere else, Slack's own reply threads are
   * a real, user-visible grouping and each thread stays its own link. Every
   * path that saves fetched messages goes through here, so a conversation
   * can never be saved in two different shapes and end up duplicated in Plot.
   *
   * Returns `null` when nothing is left to save.
   */
  private async buildConversationLink(opts: {
    channelId: string;
    messages: SlackMessage[];
    initialSync: boolean;
    userInfos?: SlackUserInfoMap;
    teamId?: string;
    customEmojiNames?: ReadonlySet<string>;
    /**
     * Whether to drop messages Plot itself sent. Defaults to `true`. Pass
     * `false` on paths that are re-reading a conversation for a reason other
     * than new inbound content: the marker is consumed on first read, so
     * spending it here would let the real inbound echo through as a duplicate.
     */
    dropSentEchoes?: boolean;
    /**
     * Whether these messages are the newest the conversation has. Defaults to
     * `true`. Pass `false` when the messages were selected by something other
     * than recency — a reaction or a save can name a message of any age — so
     * a direct conversation's running head is not rewritten backwards.
     */
    advanceConversationHead?: boolean;
  }): Promise<NewLinkWithNotes | null> {
    const {
      channelId,
      messages,
      initialSync,
      userInfos,
      teamId,
      customEmojiNames,
      dropSentEchoes = true,
      advanceConversationHead = true,
    } = opts;

    if (await this.isKnownDMChannel(channelId)) {
      const kept = dropSentEchoes
        ? await this.dropSentEchoNotes(messages, (message) => message.ts)
        : messages;
      const link = assembleSlackDmLink({
        channelId,
        counterpartyUserId: await this.dmCounterpartyUserId(channelId),
        messages: kept,
        initialSync,
        userInfos,
        teamId,
        customEmojiNames,
      });
      if (!link) return null;
      if (advanceConversationHead) {
        // These messages ARE the conversation head, so the link carries it.
        // Record that fact for the branch below, which must be able to tell
        // "preserve the stored head" from "there is no stored head yet".
        // Written here rather than at each of the several save sites: if the
        // save that follows fails, the marker is merely optimistic and the
        // next inbound message rewrites both it and the head.
        await this.set(this.dmHeadKey(channelId), true);
      } else if (await this.get<boolean>(this.dmHeadKey(channelId))) {
        // This link is permanent and ever-growing, and every field below
        // describes where the conversation currently STANDS — the latest
        // message's text, an "open in Slack" anchor on it, when the
        // conversation began, and which message a to-do star should land on.
        // Rebuilt from an arbitrary older message they would each move
        // backwards, so reacting to a month-old message would regress the
        // whole conversation's preview (and re-point new stars at a stale
        // message). Leaving them out of the upsert keeps whatever is already
        // stored — `meta` merges key-by-key (see upsert_link), so omitting
        // `threadTs` here does not disturb any other key already in `meta`.
        //
        // Only when there IS something stored to keep. Saving or reacting to
        // an old message in a conversation Plot has never synced CREATES the
        // link, and dropping these fields from a create leaves a thread with
        // no preview, no "open in Slack" anchor and a `created` that defaults
        // to now, until the next inbound message heals it.
        delete link.preview;
        delete link.sourceUrl;
        delete link.created;
        if (link.meta) delete link.meta.threadTs;
      } else {
        // No stored head, and this message is not the conversation head
        // either — so this save/reaction is what's creating the link,
        // exactly like the branch above describes. Stamp the marker now so a
        // SECOND old-message save on this still-never-advanced conversation
        // takes the "preserve what's stored" branch above instead of
        // repeating this create with a different, possibly older, message
        // and rewinding what this one just wrote.
        await this.set(this.dmHeadKey(channelId), true);
      }
      // Anchor the conversation for the daily sweep via the shared helper
      // below (see `applyReadAnchor`). A direct conversation is never
      // `threaded`: this one permanent link flattens Slack's reply threads
      // into a running conversation, so the CONVERSATION cursor is the only
      // cursor that describes it, and it is keyed on the conversation id in
      // both positions — there is no thread root to key on. There is no
      // live, cursor-informed "read" verdict for a DM (the channel cursor is
      // settled only by the daily `reconcileReadState` sweep), so `read` is
      // always `false` here; the helper's write gate
      // (`advanceConversationHead && link.unread !== false`) still applies,
      // covering both "these messages are not the conversation head" (a
      // reaction or save naming an older message, which must not rewind the
      // anchor) and "the link is already read" (`assembleSlackDmLink` sets
      // `unread: false` for `initialSync`, so an anchor for it could only
      // ever re-assert what is already true and would outlive a later manual
      // "mark unread" in Plot).
      await this.applyReadAnchor({
        channelId,
        anchorId: channelId,
        messages: kept,
        direct: true,
        link,
        read: false,
        advanceConversationHead,
      });
      return link;
    }

    const link = transformSlackThread(
      messages,
      channelId,
      userInfos,
      initialSync,
      teamId,
      customEmojiNames
    );
    // Echo guard: drop notes for messages Plot itself sent (composed or
    // replied). They come back through the webhook and would otherwise
    // round-trip as duplicate notes. Filter by note.key (the bare ts) rather
    // than the raw messages so the link still upserts by source (thread
    // identity is preserved).
    if (dropSentEchoes) {
      link.notes = await this.dropSentEchoNotes(link.notes);
    }
    if (!link.notes || link.notes.length === 0) return null;
    link.meta = {
      ...link.meta,
      syncProvider: "slack",
      syncableId: channelId,
    };
    if (messages[0]) link.facets = slackFacets(messages[0], channelId);
    // Apply Slack's per-thread read cursor via the same shared helper the DM
    // branch above uses (see `applyReadAnchor`). A root-only channel message
    // has no thread cursor of its own — only the daily sweep's
    // `conversations.info` can speak for it — so `threaded` and the read
    // verdict below are both false, and the helper's write gate
    // (`advanceConversationHead && link.unread !== false`) is what stops a
    // stale anchor from being recreated when nothing new actually arrived
    // (e.g. `refreshSlackThread`'s reaction refresh, which re-fetches with
    // `advanceConversationHead: false`).
    //
    // Read from THIS response, never from a cache: the parent's
    // `unread_count` is computed after the reply we are saving landed, so a
    // genuine new-message unread can never be suppressed by a stale cursor.
    //
    // `initialSync` already asserts read (it sets `unread: false`), so those
    // links need no anchor at all — the sweep would only re-assert what is
    // already true.
    const threadTs =
      (link.meta?.threadTs as string | undefined) ?? messages[0]?.ts;
    if (threadTs) {
      const threaded = Boolean(
        deriveReadAnchor(messages, { direct: false, at: Date.now() })?.threaded
      );
      const read =
        link.unread === false ||
        (threaded && threadReadVerdict(messages[0]) === "read");
      await this.applyReadAnchor({
        channelId,
        anchorId: threadTs,
        messages,
        direct: false,
        link,
        read,
        advanceConversationHead,
      });
    }
    return link;
  }

  /**
   * Settle one link's read-anchor bookkeeping: mark it read (and drop the
   * anchor) when the caller already has a cursor-backed verdict, or decide
   * whether an anchor still needs to be (re)written to track it.
   *
   * The anchor's EXISTENCE is the transition gate for
   * {@link reconcileReadState}: present means "not yet marked read for this
   * `newest` ts". Deleting it on a successful mark-read is what makes a later
   * manual "mark unread" in Plot stick — the sweep has nothing left to act on
   * until new content recreates the anchor.
   *
   * Shared by both {@link buildConversationLink} branches (direct
   * conversation and channel thread) so one gating rule governs both writes.
   * They used to each inline their own version of this and drifted apart: the
   * channel-thread copy wrote an anchor unconditionally whenever the verdict
   * wasn't "read", even on a `refreshSlackThread` reaction refresh that asked
   * `advanceConversationHead: false` — a root-only message has no thread
   * cursor, so that verdict is always "unknown", and the anchor was
   * recreated with the same `newest` even though no new content had arrived,
   * letting the next sweep re-assert read over a user's manual unread.
   *
   * `advanceConversationHead` gates the WRITE only, never the read-clear:
   * solid evidence that a cursor already says read is safe to act on no
   * matter why the caller fetched these messages, but recreating a "not yet
   * read" anchor is only valid when the caller is reporting the
   * conversation's actual current head.
   */
  private async applyReadAnchor(opts: {
    channelId: string;
    /** Thread root ts, or the conversation id for a direct conversation. */
    anchorId: string;
    messages: SlackMessage[];
    direct: boolean;
    link: { unread?: boolean };
    /** Did a cursor say this link is read? */
    read: boolean;
    advanceConversationHead: boolean;
  }): Promise<void> {
    const {
      channelId,
      anchorId,
      messages,
      direct,
      link,
      read,
      advanceConversationHead,
    } = opts;
    const anchorKey = this.readAnchorKey(channelId, anchorId);
    if (read) {
      link.unread = false;
      await this.clear(anchorKey);
      return;
    }
    if (advanceConversationHead && link.unread !== false) {
      const anchor = deriveReadAnchor(messages, { direct, at: Date.now() });
      if (anchor) await this.set(anchorKey, anchor);
    }
  }

  /**
   * The `source` the link for this conversation is keyed on — the same value
   * {@link buildConversationLink} produces, so any path addressing an
   * already-saved link resolves the one that path wrote.
   */
  private async conversationSource(
    channelId: string,
    threadTs: string
  ): Promise<string> {
    if (await this.isKnownDMChannel(channelId)) {
      return slackConversationIdentity({
        channelId,
        counterpartyUserId: await this.dmCounterpartyUserId(channelId),
      }).source;
    }
    return `https://slack.com/app_redirect?channel=${channelId}&message_ts=${threadTs}`;
  }

  /**
   * The other party's Slack user id for a 1:1 conversation, or `null` for a
   * group conversation (and for a 1:1 whose counterparty isn't cached yet).
   * Cached alongside the conversation roster by {@link listDMChannels}.
   */
  private async dmCounterpartyUserId(channelId: string): Promise<string | null> {
    const conversations = await this.get<Record<string, { user?: string }>>(
      "dm_conversations"
    );
    return conversations?.[channelId]?.user ?? null;
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

    // Deauthorization events. `app_uninstalled` fires when a workspace admin
    // removes Plot (team-wide); `tokens_revoked` fires when a user revokes their
    // own token and lists the affected user ids in `event.tokens.oauth`. Both
    // are fanned out to every callback registered for the team, so gate
    // `tokens_revoked` on THIS connection's own Slack user id to avoid tearing
    // down other users who are still connected. The action mirrors what the
    // connector already does lazily when a later API call returns an auth error
    // (integrations.markNeedsReauth) — doing it here just makes the reconnect
    // prompt appear immediately instead of on the next sync attempt. Delivery
    // requires `app_uninstalled` / `tokens_revoked` to be enabled in the Slack
    // app's Event Subscriptions.
    if (event.type === "app_uninstalled") {
      await this.tools.integrations.markNeedsReauth(channelId);
      return;
    }
    if (event.type === "tokens_revoked") {
      const revokedUserIds: string[] = event.tokens?.oauth ?? [];
      const token = await this.tools.integrations.get(channelId);
      const ownUserId = token?.provider?.authed_user_id;
      if (ownUserId && revokedUserIds.includes(ownUserId)) {
        await this.tools.integrations.markNeedsReauth(channelId);
      }
      return;
    }

    if (event.type === "star_added" || event.type === "star_removed") {
      await this.handleStarEvent(event, event.type === "star_added");
      return;
    }

    if (event.type === "reaction_added" || event.type === "reaction_removed") {
      await this.handleReactionEvent(event);
      return;
    }

    // Messages arrive through exactly two workspace-wide callbacks: one for
    // direct conversations, one for everything else. There is no per-channel
    // registration, so a message is never routed by matching the channel a
    // callback was registered for.
    if (event.type === "message" && !event.subtype) {
      if (
        channelId === DM_WEBHOOK_SENTINEL &&
        typeof event.channel === "string" &&
        (await this.isKnownDMChannel(event.channel))
      ) {
        await this.startIncrementalSync(event.channel);
      } else if (channelId === MENTION_WEBHOOK_SENTINEL) {
        await this.handleChannelMessage(event);
      }
    }
  }

  /**
   * Re-sync a single Slack thread on reaction_added / reaction_removed.
   *
   * The refresh needs `conversations.history` + `conversations.replies`,
   * both limited to 1 rpm for non-Marketplace apps — far too slow to run
   * inline in the webhook handler (Slack gets a 200 either way, so a
   * rate-limited event would be lost forever, never redelivered). Record
   * the reacted message ts in a per-channel drain instead: a burst of
   * reactions on the same message coalesces into one id, and rate-limited
   * ids are retried on later passes ({@link drainReactionRefresh}).
   */
  private async handleReactionEvent(event: any): Promise<void> {
    const item = event.item;
    if (!item || item.type !== "message") return;

    const channelId = item.channel as string | undefined;
    const messageTs = item.ts as string | undefined;
    if (!channelId || !messageTs) return;

    await this.queueReactionRefresh(channelId, messageTs);
  }

  /**
   * Decide whether one reacted message is in scope and, if it is, queue its
   * thread for refresh.
   *
   * Public and primitive-argumented because a rate limit reschedules it
   * through a callback token: the scope decision itself can need
   * `conversations.history`, and dropping it would lose the reaction for good
   * (Slack never redelivers an acked event).
   */
  async queueReactionRefresh(
    channelId: string,
    messageTs: string
  ): Promise<void> {
    // Clear any pending-retry marker for this message: this call is either
    // the first attempt (no marker set, a no-op clear) or a rate-limit retry
    // firing (see below) — either way any previously recorded marker is now
    // stale. A retry that hits the rate limit again re-records it below.
    await this.clear(`reaction-scope-pending:${channelId}:${messageTs}`);

    // Refresh reactions on anything we actually sync: any direct
    // conversation, and any channel thread the user is subscribed to.
    //
    // Every reaction anywhere in the workspace reaches this handler, so the
    // store-only checks come first. Resolving a reply's parent costs a
    // `conversations.history` call, and that method is limited to 1 rpm — it
    // is only worth spending on a channel that already has a subscription,
    // which is also the only case where the id in hand is known to be a real
    // channel we can resolve a token against.
    let inScope =
      (await this.isKnownDMChannel(channelId)) ||
      (await this.isSubscribedThread(channelId, messageTs));
    if (!inScope && (await this.hasSubscribedThreads(channelId))) {
      let api: SlackApi;
      try {
        api = await this.getApi(channelId);
      } catch (error) {
        // Expected: no token for this channel, so the parent is unresolvable
        // and will stay so. Nothing unexpected to report.
        console.warn("queueReactionRefresh: Slack token unavailable", error);
        return;
      }
      try {
        const threadTs = await this.resolveThreadTs(api, channelId, messageTs);
        inScope = await this.isSubscribedThread(channelId, threadTs);
      } catch (error) {
        if (error instanceof SlackRateLimitedError) {
          // `conversations.history` is 1 rpm, so a busy channel hits this
          // routinely. Without the parent we cannot tell whether this
          // reaction belongs to a subscribed thread, and syncing an
          // unsubscribed one would put a thread in Plot the user never asked
          // for — so re-run the whole decision once the limiter clears rather
          // than dropping an event Slack will never send again. The keyed
          // task coalesces repeat reactions on the same message.
          const runAt = new Date(Date.now() + error.retryAfterMs);
          const retry = await this.callback(
            this.queueReactionRefresh,
            channelId,
            messageTs
          );
          console.log(
            `queueReactionRefresh: rate limited on ${error.method}; retrying ${channelId}/${messageTs} at ${runAt.toISOString()}`
          );
          // Recorded under a listable prefix so `onChannelDisabled` can find
          // and cancel this specific scheduled retry: it is keyed per
          // message, so — unlike the per-channel recurring chains, which
          // each have one fixed key — there is no single key `onChannelDisabled`
          // could target directly.
          await this.set(`reaction-scope-pending:${channelId}:${messageTs}`, true);
          await this.scheduleTask(
            `reaction-scope:${channelId}:${messageTs}`,
            retry,
            { runAt }
          );
          return;
        }
        // Unexpected. `resolveThreadTs` already absorbs every Slack-reported
        // failure except a rate limit (falling back to the message's own ts),
        // so anything else reaching here is a bug or a store failure — and
        // every reaction in the workspace reaches this path now that channel
        // gating is gone, so swallowing it would be both silent and constant.
        // Rethrow so the platform captures it.
        throw error;
      }
    }
    if (!inScope) return;

    await this.scheduleDrain(
      `reaction-refresh:${channelId}`,
      this.drainReactionRefresh,
      {
        ids: [messageTs],
        handlerArgs: [channelId],
        delayMs: REACTION_REFRESH_COALESCE_MS,
        maxAttempts: REACTION_REFRESH_MAX_ATTEMPTS,
      }
    );
  }

  /**
   * Drain handler: refresh the thread of each reacted message.
   *
   * The reaction event payload only carries the reacted message's ts.
   * Resolve its parent thread_ts via `conversations.history` so
   * `getThread` walks the right tree; fall back to the message ts as
   * thread_ts if the lookup fails (covers top-level messages).
   *
   * Returns rate-limited ids via `{ retry }` so the platform re-runs them
   * on a later pass instead of dropping the sync event.
   */
  async drainReactionRefresh(
    ids: string[],
    channelId: string
  ): Promise<{ retry?: string[] } | void> {
    if (ids.length === 0) return;

    let api: SlackApi;
    try {
      api = await this.getApi(channelId);
    } catch (error) {
      console.warn("drainReactionRefresh: Slack token unavailable", error);
      return;
    }

    // Several reacted messages often share one parent thread — refresh each
    // parent at most once per pass.
    const refreshedParents = new Set<string>();
    for (let i = 0; i < ids.length; i++) {
      const messageTs = ids[i]!;
      try {
        const parentTs = await this.resolveThreadTs(api, channelId, messageTs);
        if (refreshedParents.has(parentTs)) continue;
        await this.refreshSlackThread(api, channelId, parentTs);
        refreshedParents.add(parentTs);
      } catch (error) {
        if (error instanceof SlackRateLimitedError) {
          // Every remaining id needs the same rate-limited methods, so stop
          // the pass and retry them all once the limiter clears.
          console.log(
            `drainReactionRefresh: rate limited on ${error.method}; retrying ${
              ids.length - i
            } id(s) for ${channelId} later`
          );
          return { retry: ids.slice(i) };
        }
        if (error instanceof SlackPermanentError) {
          if (SLACK_AUTH_ERRORS.has(error.slackError)) {
            await this.tools.integrations.markNeedsReauth(channelId);
            return { retry: ids.slice(i) };
          }
          console.warn(
            `drainReactionRefresh: skipping ${channelId}/${messageTs}: ${error.method} → ${error.slackError}`
          );
          continue;
        }
        console.warn(
          `drainReactionRefresh failed for ${channelId}/${messageTs}`,
          error
        );
      }
    }
  }

  /**
   * Resolve the parent `thread_ts` of a message.
   *
   * A reaction event carries only the reacted message's own ts, and a reply
   * has to be handled through its parent — a reply on its own is not a
   * thread. Falls back to `messageTs`, which is the right answer for a
   * top-level message and the safe answer when the lookup comes back empty.
   * A rate limit is rethrown: the caller decides whether to retry the whole
   * pass or to treat the message as unresolvable.
   */
  private async resolveThreadTs(
    api: SlackApi,
    channelId: string,
    messageTs: string
  ): Promise<string> {
    try {
      const { messages } = await api.getConversationHistory(
        channelId,
        undefined,
        messageTs,
        messageTs
      );
      return messages.find((m) => m.ts === messageTs)?.thread_ts ?? messageTs;
    } catch (error) {
      if (error instanceof SlackRateLimitedError) throw error;
      // Continue with messageTs — top-level messages match this anyway.
      return messageTs;
    }
  }

  /**
   * Re-fetch a Slack thread and upsert it (notes + per-message reactions).
   * Idempotent via `source`/`key` upsert; safe to call repeatedly.
   * Unlike {@link saveStarredThread} this does not touch the link's
   * to-do status — it's purely a refresh path.
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

    const { teamId, customEmojiNames } =
      await this.customEmojiContext(channelId);
    const link = await this.buildConversationLink({
      channelId,
      messages,
      initialSync: false,
      userInfos,
      teamId,
      customEmojiNames,
      // A refresh is triggered by a reaction, which can name a message of any
      // age — these are not necessarily the newest messages.
      advanceConversationHead: false,
    });
    if (!link) return;
    await this.tools.integrations.saveLink(link);
  }

  /**
   * Drops items for Slack messages Plot itself sent (composed via onCreateLink
   * or replied via onNoteCreated), marked with `sent:<ts>` at write-back time.
   * Those messages come back through the webhook and would round-trip as
   * duplicate notes.
   *
   * `keyOf` reads each item's Slack `ts`: it defaults to `.key` for already-
   * transformed notes, and callers filtering raw messages pass `(m) => m.ts`.
   * Filtering items rather than dropping the whole batch keeps the link's
   * identity intact (it still upserts by source). Clears the marker on first
   * read so a later genuine edit/reaction on the same message re-syncs.
   */
  private async dropSentEchoNotes<T>(
    items: T[] | undefined,
    keyOf: (item: T) => string | null | undefined = (item) =>
      (item as { key?: string | null })?.key
  ): Promise<T[]> {
    if (!items) return [];
    const kept: T[] = [];
    for (const item of items) {
      const key = keyOf(item);
      if (key && (await this.get<boolean>(`sent:${key}`))) {
        await this.clear(`sent:${key}`);
        continue;
      }
      kept.push(item);
    }
    return kept;
  }

  private async handleStarEvent(event: any, isStarred: boolean): Promise<void> {
    const item = event.item;
    if (!item || item.type !== "message") return;

    const channelId = item.channel as string | undefined;
    const messageTs = item.message?.ts as string | undefined;
    const parentTs = (item.message?.thread_ts as string | undefined) ?? messageTs;
    if (!channelId || !parentTs) return;

    // Saving a message in Slack subscribes its thread permanently, whatever
    // channel it lives in — there is no channel selection any more. A direct
    // conversation is already synced in full and is one link rather than a
    // set of threads, so it has nothing to record in a per-thread ledger.
    if (!(await this.isKnownDMChannel(channelId))) {
      await this.subscribeThread(channelId, parentTs);
    }

    const wasStarred = !!(await this.get<boolean>(
      this.starredKey(channelId, parentTs)
    ));
    if (wasStarred === isStarred) return; // our own echo

    await this.applyStarEvent(channelId, parentTs, isStarred);
  }

  /**
   * Apply a star/unstar change to Plot. On rate limit (Slack's
   * `conversations.*` methods are 1 rpm for non-Marketplace apps), the apply
   * is rescheduled under a per-thread task key at Slack's Retry-After —
   * Slack never redelivers an acked webhook, so dropping the event here
   * would lose the star. The keyed task means duplicate events coalesce and
   * the latest desired state wins.
   */
  async applyStarEvent(
    channelId: string,
    parentTs: string,
    isStarred: boolean
  ): Promise<void> {
    try {
      if (isStarred) {
        // Since we no longer backfill history, the starred thread may not
        // exist in Plot yet. Fetching + saving is idempotent (saveLink
        // upserts by source) and ensures the thread is saved and marked as
        // the owner's to-do regardless of prior state.
        let api: SlackApi;
        try {
          api = await this.getApi(channelId);
        } catch (error) {
          // Expected: the connection's token can be gone by the time a queued
          // event runs. Nothing to apply, and nothing unexpected to report —
          // kept out of the classifier below so it isn't rethrown as a bug.
          console.warn("applyStarEvent: Slack token unavailable", error);
          return;
        }
        await this.saveStarredThread(api, channelId, parentTs);
        // Record the anchor here too, not just in onThreadToDo — a star set
        // directly in Slack (rather than from Plot) needs the same anchor so
        // a later unstar FROM PLOT targets the message Slack actually has
        // starred, not wherever the conversation's meta.threadTs has since
        // moved to. See starAnchorKey.
        if (await this.isKnownDMChannel(channelId)) {
          await this.set(this.starAnchorKey(channelId), parentTs);
        }
      } else {
        const actorId = await this.get<ActorId>("auth_actor_id");
        if (!actorId) {
          console.error("No auth_actor_id; cannot apply star event");
          return;
        }
        // Resolve the SAME link the star path wrote the to-do onto. A direct
        // conversation is one permanent link keyed on the person, not a link
        // per message, so addressing it by the message's canonical URL would
        // target a source that does not exist and silently clear nothing.
        await this.tools.integrations.setThreadToDo(
          await this.conversationSource(channelId, parentTs),
          actorId,
          false
        );
        if (await this.isKnownDMChannel(channelId)) {
          await this.clear(this.starAnchorKey(channelId));
        }
      }
    } catch (error) {
      if (error instanceof SlackRateLimitedError) {
        const runAt = new Date(Date.now() + error.retryAfterMs);
        const retry = await this.callback(
          this.applyStarEvent,
          channelId,
          parentTs,
          isStarred
        );
        console.log(
          `applyStarEvent: rate limited on ${error.method}; rescheduling ${channelId}/${parentTs} at ${runAt.toISOString()}`
        );
        await this.scheduleTask(`star-apply:${channelId}:${parentTs}`, retry, {
          runAt,
        });
        // Leave the starred state unrecorded so the retry isn't skipped as
        // an echo and duplicate events keep coalescing onto the keyed task.
        return;
      }
      if (error instanceof SlackPermanentError) {
        if (SLACK_AUTH_ERRORS.has(error.slackError)) {
          // The grant itself is bad; every later event fails the same way.
          // Left unrecorded so a reconnect can still apply this star.
          await this.tools.integrations.markNeedsReauth(channelId);
          return;
        }
        // A deleted message, a conversation we were removed from: this star
        // will never apply. Fall through to record the state so duplicate
        // events for it short-circuit instead of re-failing.
        console.warn(
          `applyStarEvent: skipping ${channelId}/${parentTs}: ${error.method} → ${error.slackError}`
        );
      } else {
        // Unexpected. Every star and reaction in the workspace reaches this
        // path now that channel gating is gone, so a swallowed bug here would
        // be both silent and constant. Rethrow so the platform's queue
        // consumer classifies it and captures it. The state stays unrecorded,
        // which is what a retry needs.
        throw error;
      }
    }

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

          // Every saved item counts, wherever it lives. There is no channel
          // selection any more, and `stars.list` is workspace-wide, so a
          // channel filter here would both re-walk the same list once per
          // enabled channel and — because a DM id is never an enabled
          // channel — never backfill a saved DM message at all.
          // `channelId` stays the token-bearing channel: Slack user tokens
          // are workspace-wide, so one client addresses every conversation.
          const itemChannelId = item.channel;
          if (!itemChannelId) continue;

          const messageTs = item.message?.ts;
          const parentTs = item.message?.thread_ts ?? messageTs;
          if (!parentTs) continue;

          const alreadyStarred = await this.get<boolean>(
            this.starredKey(itemChannelId, parentTs)
          );
          if (alreadyStarred) continue;

          try {
            await this.saveStarredThread(api, itemChannelId, parentTs);
            // Same anchor `applyStarEvent` records for a star set directly in
            // Slack: without it, unstarring this item FROM PLOT later would
            // target wherever the conversation's `meta.threadTs` has since
            // moved to rather than the message Slack actually has starred.
            if (await this.isKnownDMChannel(itemChannelId)) {
              await this.set(this.starAnchorKey(itemChannelId), parentTs);
            }
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
                `backfillStars: skipping ${itemChannelId}/${parentTs}: ${error.method} → ${error.slackError}`
              );
              continue;
            }
            console.warn(
              `backfillStars: failed to save starred thread ${itemChannelId}/${parentTs}`,
              error
            );
            // Continue with other items.
          }

          await this.set(this.starredKey(itemChannelId, parentTs), true);
        }

        cursor = nextCursor;
      } while (cursor);

      // The whole list walked without a rate limit or a permanent stop, so
      // this connection never needs the backfill again. Written only here, at
      // real completion: every early return above leaves it unset so the next
      // enable retries.
      await this.set("stars_backfilled", true);
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
   * save it as a Plot link marking the owner's thread as to-do via the
   * `todo` flag. `saveLink` upserts by `source`, so this is idempotent and
   * safe to call on a thread we've already seen.
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

    const { teamId, customEmojiNames } =
      await this.customEmojiContext(channelId);
    // `initialSync` sets `unread: false, archived: false` on the link. For a
    // channel thread that is right: the link IS the saved thread, and saving
    // something is not a reason to notify about it. For a direct conversation
    // it is not: there is ONE permanent link for the whole conversation, so
    // the same flags would mark every unread message in it read (for every
    // user with access) and un-archive it — save one message from someone who
    // has written five, and the conversation goes read in Plot.
    const isDirect = await this.isKnownDMChannel(channelId);
    const link = await this.buildConversationLink({
      channelId,
      messages,
      initialSync: !isDirect,
      userInfos,
      teamId,
      customEmojiNames,
      // Saving a message is not new inbound content: it re-reads a
      // conversation Plot may itself have written into. Spending the
      // `sent:` markers here would let the real inbound echo through later
      // as a duplicate note.
      dropSentEchoes: false,
      // A saved message can be of any age, so it says nothing about where the
      // conversation currently stands.
      advanceConversationHead: false,
    });
    if (!link) return;

    // Mark the thread as the owner's to-do atomically with the save. This
    // replaces the old status="later" + active:true bridge — the connector
    // save path does not run status `active` propagation.
    link.todo = true;

    await this.tools.integrations.saveLink(link);
  }

  private async startIncrementalSync(channelId: string): Promise<void> {
    // Signal-only per-conversation drain: Slack delivers one event per
    // message, so enqueueing an immediate task per event turns a busy
    // conversation into a flood of duplicate passes (each re-fetching the
    // same window) that run concurrently in one worker. scheduleDrain
    // collapses an event burst into a single pass; an event arriving mid-pass
    // schedules exactly one follow-up. The window is computed at drain time
    // inside the handler, so the delayed pass still covers every notified
    // message — and the webhook path writes no state at all.
    await this.scheduleDrain(
      `incremental-sync:${channelId}`,
      this.drainChannelSync,
      { handlerArgs: [channelId], delayMs: INCREMENTAL_SYNC_COALESCE_MS }
    );
  }

  /**
   * Drain handler: sync the recent window of one direct conversation.
   *
   * Only direct conversations reach this path — channel content arrives
   * thread-at-a-time through the mention/subscription route instead, so there
   * is no per-channel cursor to keep and the window is derived entirely from
   * the clock.
   */
  async drainChannelSync(_ids: string[], channelId: string): Promise<void> {
    const nowSec = Date.now() / 1000;
    // A fixed window gives room for delayed webhook delivery without
    // dragging in yesterday's conversation.
    let state: SyncState = {
      channelId,
      latest: nowSec.toString(),
      oldest: (nowSec - INCREMENTAL_SYNC_WINDOW_SEC).toString(),
    };

    try {
      const api = await this.getApi(channelId);
      for (let page = 0; page < INCREMENTAL_SYNC_MAX_PAGES; page++) {
        const result = await syncSlackChannel(api, state);
        if (result.threads.length > 0) {
          await this.processMessageThreads(result.threads, channelId, false);
        }
        state = result.state;
        if (!state.more) return;
      }
      // More than a full window's worth of pages: the remainder is dropped
      // rather than paged forever against a 1 rpm method. The next message
      // event opens a fresh window that overlaps this one.
      console.warn(
        `drainChannelSync: ${channelId} still had more after ${INCREMENTAL_SYNC_MAX_PAGES} pages`
      );
    } catch (error) {
      if (error instanceof SlackRateLimitedError) {
        // Re-arm the same coalescing drain past the retry window rather than
        // dropping the pass: Slack never redelivers the message event that
        // triggered it.
        console.log(
          `drainChannelSync: rate limited on ${error.method}; retrying ${channelId} in ${error.retryAfterMs}ms`
        );
        await this.scheduleDrain(
          `incremental-sync:${channelId}`,
          this.drainChannelSync,
          { handlerArgs: [channelId], delayMs: error.retryAfterMs }
        );
        return;
      }
      if (error instanceof SlackPermanentError) {
        console.warn(
          `drainChannelSync stopped for ${channelId}: ${error.method} → ${error.slackError}`
        );
        if (SLACK_AUTH_ERRORS.has(error.slackError)) {
          await this.tools.integrations.markNeedsReauth(channelId);
        }
        return;
      }
      console.error(`drainChannelSync failed for ${channelId}`, error);
      throw error;
    }
  }

  private starredKey(channelId: string, threadTs: string): string {
    return `starred:${channelId}:${threadTs}`;
  }

  /**
   * Key recording that a direct conversation's permanent link already carries
   * a head — a preview, an "open in Slack" anchor, a `created`, and the
   * `meta.threadTs` a to-do star anchors on.
   *
   * Paths that re-read a conversation by something other than recency (a
   * reaction, a saved message) deliberately omit those fields so an old
   * message cannot rewind them. That is only correct as an UPDATE: on a
   * CREATE — no head recorded yet — those fields are exactly what the new
   * link needs, so they're kept. There is no way to ask the platform whether
   * the link exists, so the connector records this marker itself, on both
   * paths that can be establishing one: the normal recency-driven sync, and
   * that same old-message create.
   *
   * Not backfilled for conversations synced before this marker existed. A
   * connector-local list of known DM channel ids exists (`dm_channels`), but
   * it says nothing about whether any of them already has a link — a
   * channel can be a known DM the connector has never actually synced a
   * message for, and stamping this marker for one of those would wrongly
   * withhold its legitimate first preview/anchor/created on create,
   * trading this bug for a smaller version of the same one. So an old
   * conversation's first old-message reaction or save after this ships can
   * still rewind it exactly as before — but only until its next ordinary
   * inbound message, which stamps the marker through the normal path above;
   * a quiet conversation with no new activity stays exposed indefinitely.
   */
  private dmHeadKey(channelId: string): string {
    return `dm_head:${channelId}`;
  }

  /**
   * Key for the message actually holding a direct conversation's Slack star.
   *
   * A DM's `meta.threadTs` (see `assembleSlackDmLink`) is the conversation's
   * newest message and MOVES as new messages arrive — `link.meta` merges
   * key-by-key on every upsert, so the stored value really does advance.
   * Slack's star, once set, stays on whichever message it was set on. If
   * unstarring re-read `meta.threadTs` instead of this anchor, a star set
   * earlier and left in place while the conversation grew would be
   * unstarred at the WRONG message — `stars.remove` on a never-starred
   * message either errors or (for the common case) returns `not_starred`,
   * which is treated as idempotent success, so the mismatch is silent: the
   * real star is orphaned in Slack forever, and the stale `starredKey` entry
   * for it would drop a genuine later star of that same message as an echo.
   *
   * Scoped to `channelId` alone (no `threadTs`) because a DM channel id
   * identifies exactly one conversation and so exactly one anchor — unlike a
   * regular channel, where one id can host many independently-starred
   * threads. This key is only ever read/written for direct conversations;
   * a channel thread's `threadTs` is already fixed for the life of that
   * thread's link and needs no extra bookkeeping.
   */
  private starAnchorKey(channelId: string): string {
    return `star_anchor:${channelId}`;
  }

  /**
   * Key for the append-only subscription ledger. A thread lands here the first
   * time it qualifies for sync — an at-mention, or the user saving it — and is
   * NEVER removed. Unstarring in Slack or completing the to-do in Plot changes
   * state, not subscription: a thread that stopped syncing would sit in Plot
   * permanently misrepresenting what it looks like in Slack.
   */
  private subscriptionKey(channelId: string, threadTs: string): string {
    return `sync_thread:${channelId}:${threadTs}`;
  }

  /**
   * Key for one link's read anchor. Keyed on the thread root (the same id
   * `subscriptionKey` uses) so a new reply REPLACES the anchor rather than
   * accumulating one per message.
   *
   * A direct conversation is one permanent link, so it anchors on the
   * conversation id in both positions.
   */
  private readAnchorKey(channelId: string, threadTs: string): string {
    return `read_anchor:${channelId}:${threadTs}`;
  }

  private async subscribeThread(
    channelId: string,
    threadTs: string
  ): Promise<void> {
    await this.set(this.subscriptionKey(channelId, threadTs), true);
  }

  private async isSubscribedThread(
    channelId: string,
    threadTs: string
  ): Promise<boolean> {
    return (
      (await this.get<boolean>(this.subscriptionKey(channelId, threadTs))) ===
      true
    );
  }

  /**
   * Whether this channel has any subscribed thread at all. A cheap
   * store-only pre-check for paths that would otherwise pay a rate-limited
   * API call to find out which thread a message belongs to.
   */
  private async hasSubscribedThreads(channelId: string): Promise<boolean> {
    const keys = await this.tools.store.list(`sync_thread:${channelId}:`);
    return keys.length > 0;
  }

  /**
   * Decide whether a channel message belongs in Plot. A message qualifies when
   * it mentions the user, or when it replies on a thread already subscribed.
   * Either way the SLACK THREAD is the unit: a mention buried in a reply pulls
   * in the whole thread, because a reply without its parent cannot be read.
   */
  private async handleChannelMessage(event: {
    channel?: string;
    channel_type?: string;
    ts?: string;
    thread_ts?: string;
    text?: string;
  }): Promise<void> {
    const channelId = event.channel;
    const ts = event.ts;
    if (!channelId || !ts) return;

    // DM/MPIM traffic is the DM webhook's job (see DM_WEBHOOK_SENTINEL), not
    // this one. Both webhooks are registered from the same authorization, so
    // they carry identical granted scopes, and the platform fans every
    // message-shaped event out to every callback whose granted scopes cover
    // it — regardless of which sentinel registered the callback. Without this
    // guard, a routine `<!here>` in a group DM would subscribeThread() it
    // into the append-only channel-thread ledger, which can never be
    // un-subscribed, permanently duplicating the DM as a second Plot thread.
    // Checked via `event.channel_type` ("im" / "mpim" / "channel" / "group"),
    // which Slack stamps on every message event, rather than
    // `isKnownDMChannel`: that helper trusts `dm_channels`, a once-daily
    // mirror that can be empty or stale (e.g. before the first
    // `listDMChannels` run, or for a group DM created since), where
    // `channel_type` is Slack's own authoritative classification of THIS
    // event and needs no store lookup.
    if (event.channel_type === "im" || event.channel_type === "mpim") return;
    // Fail CLOSED when the field is absent. The consequence of letting a
    // group DM through is unrecoverable — the ledger is append-only — so an
    // event that carries no classification falls back to the stale-but-real
    // DM roster rather than being treated as a channel by default.
    if (!event.channel_type && (await this.isKnownDMChannel(channelId))) return;

    const threadTs = event.thread_ts || ts;

    if (await this.isSubscribedThread(channelId, threadTs)) {
      await this.syncSubscribedThread(channelId, threadTs);
      return;
    }

    const ctx = await this.cachedMentionContext();
    if (!ctx) return;
    if (!mentionsUser(event.text, ctx)) return;

    await this.subscribeThread(channelId, threadTs);
    await this.syncSubscribedThread(channelId, threadTs);
  }

  /**
   * Queue a refresh of one subscribed Slack thread. A burst of replies on the
   * same thread coalesces into a single `conversations.replies` call, and a
   * rate-limited id is retried on a later pass rather than being dropped —
   * webhook events are never redelivered, so dropping one loses the message.
   */
  private async syncSubscribedThread(
    channelId: string,
    threadTs: string
  ): Promise<void> {
    await this.scheduleDrain(
      `subscribed-thread:${channelId}`,
      this.drainSubscribedThreads,
      {
        ids: [threadTs],
        handlerArgs: [channelId],
        delayMs: REACTION_REFRESH_COALESCE_MS,
        maxAttempts: REACTION_REFRESH_MAX_ATTEMPTS,
      }
    );
  }

  /**
   * Drain handler: refresh each queued thread.
   *
   * Mirrors {@link drainReactionRefresh}'s error handling: a token failure or
   * a rate limit keeps every not-yet-processed id pending for a later pass
   * (webhook events are never redelivered, so dropping one loses the
   * message) instead of silently releasing it; an auth-shaped permanent
   * error flags the connection for reconnect; any other error is unexpected
   * and is rethrown so the platform's queue consumer classifies it and, if
   * genuinely unexpected, captures it to error tracking (see
   * {@link syncUserGroups} for the same rethrow-for-capture rationale) — the
   * drain framework itself keeps every id in this pass pending across the
   * throw, so nothing is lost.
   */
  async drainSubscribedThreads(
    ids: string[],
    channelId: string
  ): Promise<{ retry?: string[] } | void> {
    if (ids.length === 0) return;

    let api: SlackApi;
    try {
      api = await this.getApi(channelId);
    } catch (error) {
      console.warn("drainSubscribedThreads: Slack token unavailable", error);
      return { retry: ids };
    }

    for (let i = 0; i < ids.length; i++) {
      const threadTs = ids[i]!;
      try {
        await this.refreshSlackThread(api, channelId, threadTs);
      } catch (error) {
        if (error instanceof SlackRateLimitedError) {
          // Every remaining id needs the same 1rpm-limited method, so
          // issuing per-id retries would just re-issue guaranteed-429
          // calls — stop the pass and retry them all once the limiter
          // clears (mirrors drainReactionRefresh).
          console.log(
            `drainSubscribedThreads: rate limited on ${error.method}; retrying ${
              ids.length - i
            } id(s) for ${channelId} later`
          );
          return { retry: ids.slice(i) };
        }
        if (error instanceof SlackPermanentError) {
          if (SLACK_AUTH_ERRORS.has(error.slackError)) {
            await this.tools.integrations.markNeedsReauth(channelId);
            return { retry: ids.slice(i) };
          }
          console.warn(
            `drainSubscribedThreads: skipping ${channelId}/${threadTs}: ${error.method} → ${error.slackError}`
          );
          continue;
        }
        console.error(
          `drainSubscribedThreads failed for ${channelId}/${threadTs}`,
          error
        );
        throw error;
      }
    }
  }

  /**
   * Daily reconciliation of Slack's CHANNEL-level read cursor into Plot.
   *
   * Slack has no push signal for read state — `channel_marked`/`im_marked` are
   * RTM-only — so this is the only way a link that has gone quiet ever learns
   * the user read it. It uses `conversations.info` (Tier 3) exclusively and
   * never touches `conversations.history`/`conversations.replies`, which are
   * limited to 1 rpm and are what live message ingestion runs on: a sweep that
   * spent that budget would starve inbound messages.
   *
   * Threaded anchors are skipped — a channel cursor says nothing about whether
   * a thread was opened. Those are settled for free on the live path, where
   * the thread's own cursor arrives with the messages.
   *
   * `channelId` is only used to resolve a token; Slack tokens are
   * workspace-wide, and the conversations to sweep come from the anchors.
   *
   * Gated to run at most once per 24 hours per WORKSPACE (like `syncMembers`,
   * placed the same way — before the `try`, so a redundant call skips the
   * `finally` below too and never arms a chain of its own). The sweep itself
   * is workspace-scoped (`listEntries("read_anchor:")`, no channel filter),
   * but the caller, `queueWorkspaceDailyTasks`, dispatches it once per
   * ENABLED CHANNEL, and Slack auto-observes new channels as the user
   * composes into them. Without this guard, every newly-enabled channel would
   * arm its own daily recurring chain (`read-state-sync:<channelId>` is keyed
   * per channel, so `scheduleRecurring` cannot dedupe them against each
   * other) — N chains sweeping the same anchors once a day each means N times
   * the `conversations.info` calls and N duplicate writes per anchor that
   * actually resolves.
   */
  async reconcileReadState(channelId: string): Promise<void> {
    const now = Date.now();
    const ONE_DAY_MS = 24 * 60 * 60 * 1000;
    const lastReadSync = await this.get<number>("readStateSyncedAt");
    if (lastReadSync && now - lastReadSync < ONE_DAY_MS) return;

    try {
      const entries = await this.tools.store.listEntries<SlackReadAnchor>(
        "read_anchor:"
      );
      if (entries.length === 0) return;

      // Drop anything past retention before spending an API call on it.
      const expired = entries.filter(
        ([, anchor]) => now - anchor.at >= READ_ANCHOR_RETENTION_MS
      );
      if (expired.length > 0) {
        await this.tools.store.clearMany(expired.map(([key]) => key));
      }

      // Threaded anchors are the live path's job; grouping by conversation is
      // what keeps this to one `conversations.info` per conversation rather
      // than one per link.
      const byConversation = new Map<string, [string, SlackReadAnchor][]>();
      for (const [key, anchor] of entries) {
        if (anchor.threaded) continue;
        if (now - anchor.at >= READ_ANCHOR_RETENTION_MS) continue;
        const rest = key.slice("read_anchor:".length);
        const separator = rest.indexOf(":");
        if (separator <= 0) continue;
        const conversationId = rest.slice(0, separator);
        const existing = byConversation.get(conversationId);
        if (existing) existing.push([key, anchor]);
        else byConversation.set(conversationId, [[key, anchor]]);
      }
      if (byConversation.size === 0) return;

      let api: SlackApi;
      try {
        api = await this.getApi(channelId);
      } catch (error) {
        console.warn("reconcileReadState: Slack token unavailable", error);
        return;
      }

      const conversations = [...byConversation];
      for (let i = 0; i < conversations.length; i++) {
        const [conversationId, anchors] = conversations[i]!;
        let lastRead: string | null;
        try {
          ({ lastRead } = await api.getConversationInfo(conversationId));
        } catch (error) {
          if (error instanceof SlackRateLimitedError) {
            // Every remaining conversation needs the same method, so carrying
            // on would just re-issue guaranteed-429s. Anchors are durable —
            // tomorrow's pass (or the retry below) picks up exactly where this
            // one stopped. `conversations.length - i` is what's actually left
            // — this one included, since it never got resolved — not the
            // conversation-count total the map started with.
            const remaining = conversations.length - i;
            console.log(
              `reconcileReadState: rate limited on ${error.method}; ${remaining} conversation(s) left for a later pass`
            );
            return;
          }
          if (error instanceof SlackPermanentError) {
            if (error.slackError === "missing_scope") {
              // The optional `dms` scope group was declined at connect time.
              // That is a user decision, not a broken connection — mirrors
              // `onThreadRead`'s handling of the same error, so a user who
              // opted out of DM sync doesn't get a spurious reconnect prompt
              // while the channels behind this DM in `byConversation` go
              // unswept.
              console.warn(
                `reconcileReadState: skipping ${conversationId}: ${error.method} → missing_scope`
              );
              continue;
            }
            if (error.slackError === "no_permission") {
              // This conversation specifically is unreachable (e.g. the user
              // was removed from it) — not evidence the token itself is dead.
              console.warn(
                `reconcileReadState: skipping ${conversationId}: ${error.method} → no_permission`
              );
              continue;
            }
            if (SLACK_AUTH_ERRORS.has(error.slackError)) {
              await this.tools.integrations.markNeedsReauth(channelId);
              return;
            }
            // A single gone/forbidden conversation must not abandon the rest.
            console.warn(
              `reconcileReadState: skipping ${conversationId}: ${error.method} → ${error.slackError}`
            );
            continue;
          }
          throw error;
        }

        const resolved: string[] = [];
        for (const [key, anchor] of anchors) {
          if (channelReadVerdict(lastRead, anchor.newest) !== "read") continue;
          const threadTs = key.slice(
            `read_anchor:${conversationId}:`.length
          );
          // Minimal upsert. `created` is omitted deliberately: `saveLink`
          // reads `unread === false` as the initial-sync signal and DROPS the
          // save outright when the item's date predates the plan's sync
          // history limit. Title/preview/notes are omitted so the upsert
          // preserves whatever is stored rather than rewriting content.
          // `author: null` documents that this upsert is genuinely
          // authorless — it only flips `unread`, never introduces content —
          // and silences `saveLink`'s development-time unattributed-link
          // warning that would otherwise fire on every reconciled link.
          await this.tools.integrations.saveLink({
            // Reuse the connector's own source helper — a reconcile upsert
            // that guessed the key would create a second, empty thread
            // instead of updating the one the save path wrote.
            source: await this.conversationSource(conversationId, threadTs),
            channelId: conversationId,
            type: (await this.isKnownDMChannel(conversationId)) ? "dm" : "thread",
            unread: false,
            author: null,
          });
          resolved.push(key);
        }
        if (resolved.length > 0) await this.tools.store.clearMany(resolved);
      }

      // Stamped on completion, not entry — matches `membersSyncedAt` /
      // `customEmojiSyncedAt`. A pass that returned early above (nothing to
      // sweep, no token, rate limited) skips this: that's correct, since
      // suppressing `queueWorkspaceDailyTasks`'s backstop for 24h on a pass
      // that did no real work would leave anchors unreconciled with nothing
      // to re-trigger it sooner.
      await this.set("readStateSyncedAt", Date.now());
    } catch (error) {
      // Unlike the rate-limit/permanent-error branches above (which return
      // early and set nothing here), an unexpected error still lets the
      // `finally` re-arm the daily chain below — mirrors `syncMembers`: a
      // sweep that dies silently would leave read state unreconciled forever
      // with no recovery signal, which is worse than retrying tomorrow.
      console.error("reconcileReadState: unexpected error", error);
      throw error;
    } finally {
      // Unconditional: nothing in this function suppresses the daily
      // reschedule (unlike `syncMembers`, which stops its own chain on a
      // permanent error) — even a dead-token pass is worth retrying
      // tomorrow, since the user may have reauthed by then. The top-of-
      // function guard above is what stops a REDUNDANT chain from ever being
      // armed; this always re-arms the one chain that got past it.
      const daily = await this.callback(this.reconcileReadState, channelId);
      await this.scheduleRecurring(`read-state-sync:${channelId}`, daily, {
        intervalMs: ONE_DAY_MS,
      });
    }
  }

  async onThreadToDo(
    thread: Thread,
    _actor: Actor,
    todo: boolean,
    _options: { date?: Date }
  ): Promise<void> {
    const meta = thread.meta ?? {};
    const channelId = meta.channelId as string | undefined;
    if (!channelId) return;

    // `direct` is stamped by assembleSlackDmLink — see starAnchorKey for why
    // a direct conversation needs the extra anchor bookkeeping below and a
    // channel thread doesn't.
    const isDirect = meta.direct === true;

    let threadTs: string | undefined;
    if (todo) {
      // Star lands on whichever message meta.threadTs currently names — the
      // conversation's newest for a DM, the fixed parent for a channel
      // thread. Record it as this conversation's anchor so a later unstar
      // targets the SAME message even if the conversation has grown by then.
      threadTs = meta.threadTs as string | undefined;
      if (!threadTs) return;
      if (isDirect) await this.set(this.starAnchorKey(channelId), threadTs);
    } else {
      // Unstar must hit the message that was ACTUALLY starred, not wherever
      // a DM's anchor has since moved to (see starAnchorKey). Falling back to
      // meta.threadTs covers a channel thread (whose threadTs never moves)
      // and a DM starred before this anchor existed.
      threadTs = isDirect
        ? ((await this.get<string>(this.starAnchorKey(channelId))) ??
            (meta.threadTs as string | undefined))
        : (meta.threadTs as string | undefined);
      if (!threadTs) return;
    }

    // Update local state BEFORE calling Slack so the webhook fired by our
    // own write sees isStarred === wasStarred and doesn't re-propagate.
    await this.set(this.starredKey(channelId, threadTs), todo);

    const api = await this.getApi(channelId);
    if (todo) {
      await api.addStar(channelId, threadTs);
    } else {
      await api.removeStar(channelId, threadTs);
      if (isDirect) await this.clear(this.starAnchorKey(channelId));
    }
  }

  /**
   * Write a Plot read back to Slack — direct conversations only.
   *
   * `conversations.mark` is CONVERSATION-scoped and Slack's public Web API has
   * no per-thread equivalent, so this is only coherent where the Plot link IS
   * the whole conversation. For a channel thread the same call would move that
   * channel's cursor: forward, clearing unread on every other message in it;
   * backward, re-unreading messages the user had already read. Both are wrong,
   * so channel threads write back nothing.
   *
   * Marking a thread UNREAD is likewise not propagated — Slack offers no
   * un-mark, and re-pointing the cursor at an older message would un-read
   * unrelated conversation history.
   *
   * Whichever direction Plot's read state changed, that's the user's final
   * word — any outstanding {@link reconcileReadState} anchor for this link is
   * cleared FIRST, before either the `unread` or `meta.direct` guard below.
   * Skipping this for a DM read used to let the very `conversations.mark` call
   * a few lines down move Slack's cursor to `anchor.newest` without ever
   * clearing the anchor Slack was catching up to — so marking the thread
   * unread again in Plot right after left a stale anchor in place, and the
   * next sweep saw a cursor it had itself advanced and reverted the user's
   * unread. Clearing here — for both link shapes and both directions — keeps
   * a manual mark-unread from being undone the same way even without a
   * write-back to trigger it.
   */
  override async onThreadRead(
    thread: Thread,
    _actor: Actor,
    unread: boolean
  ): Promise<void> {
    const meta = thread.meta ?? {};
    const channelId = meta.channelId as string | undefined;
    const threadTs = meta.threadTs as string | undefined;
    if (channelId && threadTs) {
      // A DM's `meta.threadTs` is the conversation's latest message, not its
      // anchor key — `buildConversationLink` anchors a direct conversation on
      // the conversation id in both positions (see `readAnchorKey`), so using
      // `threadTs` directly here would clear nothing.
      const anchorId = meta.direct === true ? channelId : threadTs;
      await this.clear(this.readAnchorKey(channelId, anchorId));
    }

    if (unread) return;
    if (meta.direct !== true) return;
    if (!channelId || !threadTs) return;

    let api: SlackApi;
    try {
      api = await this.getApi(channelId);
    } catch (error) {
      // Read state already lives in Plot; a missing token is not worth failing
      // the dispatch over.
      console.warn("onThreadRead: Slack token unavailable", error);
      return;
    }

    try {
      await api.markConversationRead(channelId, threadTs);
    } catch (error) {
      if (error instanceof SlackRateLimitedError) {
        // The read is already recorded in Plot and the next inbound message
        // re-establishes the cursor; a deferred write-back is not worth the
        // bookkeeping for a marker the user cannot see.
        console.log("onThreadRead: rate limited; skipping write-back");
        return;
      }
      if (error instanceof SlackPermanentError) {
        if (error.slackError === "missing_scope") {
          // The optional `dms` scope group was declined at connect time.
          // That is a user decision, not a broken connection — degrade
          // quietly rather than prompting a pointless reconnect.
          console.warn(
            `onThreadRead: ${error.method} → missing_scope; skipping write-back`
          );
          return;
        }
        if (SLACK_AUTH_ERRORS.has(error.slackError)) {
          // A genuinely dead token. Flag it the same way every other write-back
          // path in this connector does, so the user is prompted to reconnect.
          await this.tools.integrations.markNeedsReauth(channelId);
          return;
        }
        console.warn(
          `onThreadRead: ${error.method} → ${error.slackError}; skipping write-back`
        );
        return;
      }
      throw error;
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
    // Echo guard (see onNoteCreated): skip re-importing this message when it
    // comes back via the webhook.
    await this.set(`sent:${ts}`, true);

    // Posting into a channel from Plot is as clear a statement of interest as
    // an at-mention. Nothing else would bring the replies back: channel
    // content reaches Plot only through the subscription ledger or a fresh
    // mention, and a reply to your own post carries neither.
    await this.subscribeThread(channelId, ts);

    const canonicalUrl = `https://slack.com/app_redirect?channel=${channelId}&message_ts=${ts}`;

    return {
      // MUST match the source transformSlackThread emits on sync-in
      // (canonicalUrl), so the composed thread dedups against its own inbound
      // echo and against later Slack-side replies — otherwise each round-trips
      // as a duplicate thread.
      source: canonicalUrl,
      type: "thread",
      title: draft.title,
      status: null,
      created: new Date(parseFloat(ts) * 1000),
      sourceUrl: canonicalUrl,
      channelId,
      meta: {
        syncProvider: "slack",
        channelId,
        threadTs: ts,
        syncableId: channelId,
      },
      // Bind the opening note to this Slack message so reactions/edits on it
      // route back. `key` is the bare ts (same convention sync-in uses);
      // externalContent matches what onNoteCreated returns for replies.
      originatingNote: {
        key: ts,
        externalContent: formatSlackText(result.text ?? body),
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
    // A 1:1 is keyed on the person; a group conversation has no single
    // counterparty. Same rule the inbound roster applies.
    const counterpartyUserId =
      userIds.length === 1 && userIds[0] ? userIds[0] : null;

    // Use any enabled channel's token to reach the workspace API.
    const api = await this.getWorkspaceApi(draft.channelId);

    // Open (or retrieve existing) DM/MPIM conversation.
    const dmChannelId = await api.openConversation(userIds);

    // Register immediately so a reply from the other side is recognized by
    // the DM webhook handler (see isKnownDMChannel) without waiting for the
    // next daily listDMChannels run. Record the counterparty in the same
    // breath: the two are read together, and a 1:1 whose counterparty is
    // missing would key on the conversation instead of the person until the
    // next roster refresh — a different, permanent link for the same chat.
    const knownDMChannels = (await this.get<string[]>("dm_channels")) ?? [];
    if (!knownDMChannels.includes(dmChannelId)) {
      await this.set("dm_channels", [...knownDMChannels, dmChannelId]);
    }
    const knownConversations =
      (await this.get<Record<string, { user?: string }>>("dm_conversations")) ??
      {};
    if (!(dmChannelId in knownConversations)) {
      await this.set("dm_conversations", {
        ...knownConversations,
        [dmChannelId]: counterpartyUserId ? { user: counterpartyUserId } : {},
      });
    }

    const body = (draft.noteContent ?? draft.title ?? "").trim();
    if (!body) {
      console.error("[slack] Cannot create direct message: body is empty");
      return null;
    }
    const result = await api.postMessage(dmChannelId, body);
    if (!result?.ts) return null;

    const ts = result.ts;
    // Echo guard (see onNoteCreated): skip re-importing this message when it
    // comes back via the DM webhook.
    await this.set(`sent:${ts}`, true);
    const canonicalUrl = `https://slack.com/app_redirect?channel=${dmChannelId}&message_ts=${ts}`;

    return {
      // A direct conversation has ONE permanent link however it started, so
      // this has to be keyed exactly as the sync path keys the same
      // conversation — hence the shared helper rather than a second
      // construction here. Get this wrong and starting a chat from Plot,
      // then receiving a reply, leaves two permanent threads for one
      // conversation.
      ...slackConversationIdentity({
        channelId: dmChannelId,
        counterpartyUserId,
      }),
      type: "dm",
      title: draft.title,
      status: null,
      created: new Date(parseFloat(ts) * 1000),
      sourceUrl: canonicalUrl,
      channelId: draft.channelId,
      meta: {
        syncProvider: "slack",
        // The DM conversation this thread stands for. NOT what the reply path
        // reads: the platform rebuilds `thread.meta.channelId` from the saved
        // link ROW's channel_id — the top-level `channelId` below, an enabled
        // workspace channel — and that overwrite wins. So a reply typed in
        // Plot before the first inbound sync of this conversation posts to
        // the workspace channel instead of here; the first inbound sync
        // rewrites the row's channel_id to the DM and it self-corrects.
        // Pre-existing behaviour, recorded so this key is not mistaken for
        // the value the reply path resolves.
        channelId: dmChannelId,
        threadTs: ts,
        // `direct: true` is what the write-back path keys on to decide that a
        // reply with no explicit target posts top-level rather than nesting
        // under this link's anchor message — same as the sync path sets.
        direct: true,
        ...(counterpartyUserId ? { profileId: counterpartyUserId } : {}),
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
      // Bind the opening note to this Slack message (see createChannelPost).
      originatingNote: {
        key: ts,
        externalContent: formatSlackText(result.text ?? body),
      },
    };
  }

  // ---- Workspace member sync ----

  /**
   * Queue the saved-items backfill, at most once per connection.
   *
   * `stars.list` is workspace-wide and {@link backfillStars} now saves every
   * item it finds, so the backfill is a property of the CONNECTION, not of a
   * channel. Queuing it per enabled channel would re-walk the same list — and
   * re-save the same items — once per channel on every fan-out.
   *
   * `stars_backfilled` is the permanent gate, written by `backfillStars` only
   * when it completes a full walk. `starsBackfillClaimedAt` covers the window
   * before that flag exists, the same way {@link queueWorkspaceDailyTasks}
   * dedupes a fan-out of near-simultaneous `onChannelEnabled` calls; it
   * expires so a backfill that failed outright is retried by a later enable
   * rather than being suppressed forever.
   */
  private async queueStarBackfill(channelId: string): Promise<void> {
    if (await this.get<boolean>("stars_backfilled")) return;

    const now = Date.now();
    const claimedAt = await this.get<number>("starsBackfillClaimedAt");
    if (
      claimedAt !== null &&
      claimedAt !== undefined &&
      now - claimedAt < WORKSPACE_TASK_CLAIM_TTL_MS
    ) {
      return;
    }
    await this.set("starsBackfillClaimedAt", now);

    await this.runTask(await this.callback(this.backfillStars, channelId, null));
  }

  /**
   * Queue the workspace-scoped work — the two webhook registrations plus the
   * once-per-24h refreshes (members, custom emoji, user groups, DM roster) —
   * at most once per fan-out, instead of once per channel.
   *
   * `syncMembers`/`syncCustomEmoji` already no-op internally if run within
   * the last 24h, but that no-op still costs a full queue dispatch + worker
   * invocation + store read — which counts against the platform's
   * burst-rate/execution-quota limits. A connection with N enabled channels
   * previously queued 2N of these on every `onChannelEnabled` fan-out
   * (initial connect, "refresh channels", or a stuck-sync watchdog retry),
   * of which at most 2 ever did real work. Checking the same gate here,
   * before queuing, cuts that down to at most 2 total.
   *
   * `channelId` is just which channel's token to use if a task does need to
   * run — any enabled channel's token works (Slack tokens are workspace-wide).
   */
  private async queueWorkspaceDailyTasks(channelId: string): Promise<void> {
    const ONE_DAY_MS = 24 * 60 * 60 * 1000;
    const CLAIM_TTL_MS = WORKSPACE_TASK_CLAIM_TTL_MS;
    const now = Date.now();

    const lastMembersSync = await this.get<number>("membersSyncedAt");
    const membersClaimedAt = await this.get<number>("membersSyncClaimedAt");
    const membersClaimed =
      membersClaimedAt !== null &&
      membersClaimedAt !== undefined &&
      now - membersClaimedAt < CLAIM_TTL_MS;
    if ((!lastMembersSync || now - lastMembersSync >= ONE_DAY_MS) && !membersClaimed) {
      await this.set("membersSyncClaimedAt", now);
      const membersCallback = await this.callback(this.syncMembers, channelId);
      await this.runTask(membersCallback);
    }

    const lastEmojiSync = await this.get<number>("customEmojiSyncedAt");
    const emojiClaimedAt = await this.get<number>("customEmojiSyncClaimedAt");
    const emojiClaimed =
      emojiClaimedAt !== null &&
      emojiClaimedAt !== undefined &&
      now - emojiClaimedAt < CLAIM_TTL_MS;
    if ((!lastEmojiSync || now - lastEmojiSync >= ONE_DAY_MS) && !emojiClaimed) {
      await this.set("customEmojiSyncClaimedAt", now);
      const emojiCallback = await this.callback(this.syncCustomEmoji, channelId);
      await this.runTask(emojiCallback);
    }

    const lastUserGroupsSync = await this.get<number>("userGroupsSyncedAt");
    const userGroupsClaimedAt = await this.get<number>("userGroupsSyncClaimedAt");
    const userGroupsClaimed =
      userGroupsClaimedAt !== null &&
      userGroupsClaimedAt !== undefined &&
      now - userGroupsClaimedAt < CLAIM_TTL_MS;
    if (
      (!lastUserGroupsSync || now - lastUserGroupsSync >= ONE_DAY_MS) &&
      !userGroupsClaimed
    ) {
      await this.set("userGroupsSyncClaimedAt", now);
      const userGroupsCallback = await this.callback(this.syncUserGroups, channelId);
      await this.runTask(userGroupsCallback);
    }

    // registerDMWebhook is a one-time (not daily) registration, gated by the
    // permanent `dm_webhook_registered` flag rather than a 24h window — but
    // still needs the same short claim to dedupe a fan-out before that flag
    // is set (it's only written inside registerDMWebhook itself, on success).
    const dmWebhookRegistered = await this.get<boolean>("dm_webhook_registered");
    const dmWebhookClaimedAt = await this.get<number>("dmWebhookClaimedAt");
    const dmWebhookClaimed =
      dmWebhookClaimedAt !== null &&
      dmWebhookClaimedAt !== undefined &&
      now - dmWebhookClaimedAt < CLAIM_TTL_MS;
    if (!dmWebhookRegistered && !dmWebhookClaimed) {
      await this.set("dmWebhookClaimedAt", now);
      const dmWebhookCallback = await this.callback(this.registerDMWebhook, channelId);
      await this.runTask(dmWebhookCallback);
    }

    // The mention webhook is the other half of the pair, registered and gated
    // exactly the same way. Without it nothing observes channel messages at
    // all, so no at-mention is ever noticed — and since nothing else in this
    // connector registers a webhook, this is the only place it can happen.
    const mentionWebhookRegistered = await this.get<boolean>(
      "mention_webhook_registered"
    );
    const mentionWebhookClaimedAt = await this.get<number>(
      "mentionWebhookClaimedAt"
    );
    const mentionWebhookClaimed =
      mentionWebhookClaimedAt !== null &&
      mentionWebhookClaimedAt !== undefined &&
      now - mentionWebhookClaimedAt < CLAIM_TTL_MS;
    if (!mentionWebhookRegistered && !mentionWebhookClaimed) {
      await this.set("mentionWebhookClaimedAt", now);
      const mentionWebhookCallback = await this.callback(
        this.registerMentionWebhook,
        channelId
      );
      await this.runTask(mentionWebhookCallback);
    }

    const lastDMListSync = await this.get<number>("dmChannelsSyncedAt");
    const dmListClaimedAt = await this.get<number>("dmChannelsSyncClaimedAt");
    const dmListClaimed =
      dmListClaimedAt !== null &&
      dmListClaimedAt !== undefined &&
      now - dmListClaimedAt < CLAIM_TTL_MS;
    if ((!lastDMListSync || now - lastDMListSync >= ONE_DAY_MS) && !dmListClaimed) {
      await this.set("dmChannelsSyncClaimedAt", now);
      const dmListCallback = await this.callback(this.listDMChannels, channelId);
      await this.runTask(dmListCallback);
    }

    const lastReadSync = await this.get<number>("readStateSyncedAt");
    const readClaimedAt = await this.get<number>("readStateSyncClaimedAt");
    const readClaimed =
      readClaimedAt !== null &&
      readClaimedAt !== undefined &&
      now - readClaimedAt < CLAIM_TTL_MS;
    if ((!lastReadSync || now - lastReadSync >= ONE_DAY_MS) && !readClaimed) {
      await this.set("readStateSyncClaimedAt", now);
      const readCallback = await this.callback(this.reconcileReadState, channelId);
      await this.runTask(readCallback);
    }
  }

  /**
   * Registers ONE webhook callback covering all of this connection's DM/MPIM
   * traffic (see {@link DM_WEBHOOK_SENTINEL}). Gated by a stored flag so it's
   * only actually registered once per connection, regardless of how many
   * channels' `onChannelEnabled` runs. Requires the `im:history`/`mpim:history`
   * optional scope group to have been granted — no-ops otherwise (the user
   * declined DM sync at connect time).
   */
  private async registerDMWebhook(channelId: string): Promise<void> {
    if (await this.get<boolean>("dm_webhook_registered")) return;

    // The stored Authorization is written when the account is connected. If
    // it is not readable yet, or the token cannot be resolved this instant,
    // the registration is merely EARLY, not impossible — so re-arm rather
    // than return (see `deferWebhookRegistration`).
    const authorization = await this.get<Authorization>("auth");
    if (!authorization) {
      await this.deferWebhookRegistration(
        DM_WEBHOOK_RETRY_KEY,
        this.registerDMWebhook,
        channelId,
        "no stored authorization"
      );
      return;
    }

    // The stored Authorization survives token removal (it is written once at
    // connect time and never cleared), so its presence does NOT guarantee a
    // usable token. `createWebhook` does a direct token lookup and throws
    // when the token is gone, which then fails-and-retries forever on the
    // webhook queue. Confirm a live token first; `integrations.get()` also
    // flags the connection for re-auth when the token is missing.
    const token = await this.tools.integrations.get(channelId);
    if (!token) {
      await this.deferWebhookRegistration(
        DM_WEBHOOK_RETRY_KEY,
        this.registerDMWebhook,
        channelId,
        "no usable token"
      );
      return;
    }
    // Declining the optional grant is a decision, not a failure — nothing to
    // retry, so no chain is armed.
    if (!token.scopes?.includes("im:history")) return;

    await this.tools.network.createWebhook(
      { provider: AuthProvider.Slack, authorization },
      this.onSlackWebhook,
      DM_WEBHOOK_SENTINEL
    );
    await this.set("dm_webhook_registered", true);
    await this.cancelScheduledTask(DM_WEBHOOK_RETRY_KEY);
  }

  /**
   * Re-arm a webhook registration that could not go ahead yet.
   *
   * Both registrations are queued only when channels are mirrored, and a
   * fresh connection is a single burst of that. So an early return on a
   * condition that will clear on its own would leave the connection
   * observing NOTHING — silently, and with nothing scheduled to bring it
   * back. Keyed and recurring: re-scheduling atomically replaces any pending
   * attempt rather than stacking chains, and the chain is cancelled the
   * moment the registration takes.
   */
  private async deferWebhookRegistration(
    key: string,
    handler: (channelId: string) => Promise<void>,
    channelId: string,
    reason: string
  ): Promise<void> {
    console.warn(`Slack: ${key} deferred (${reason}); will retry`);
    const retry = await this.callback(handler, channelId);
    await this.scheduleRecurring(key, retry, {
      intervalMs: WEBHOOK_REGISTER_RETRY_MS,
      firstRunAt: new Date(Date.now() + WEBHOOK_REGISTER_RETRY_MS),
    });
  }

  /**
   * Register the single workspace-wide callback that observes channel messages
   * for at-mentions. Gated by a stored flag so it registers once per
   * connection however many times channels are mirrored. `channels:history` is
   * required (not optional), so unlike the DM webhook there is no grant to
   * decline — but the token is still checked, because a connection whose OAuth
   * token was cleared would otherwise fail-and-retry forever on the webhook
   * queue.
   *
   * Also caches `slack_user_id` (see {@link cachedMentionContext}) from the
   * same token lookup. `channelId` here is always a channel currently being
   * enabled (this runs from the `onChannelEnabled` fan-out), so resolving the
   * token against it is safe — unlike resolving a token per inbound message
   * against whatever arbitrary channel the event happened to name, which
   * would hit `integrations.get()`'s migration fallback and silently
   * re-enable a channel the user deliberately disabled.
   */
  private async registerMentionWebhook(channelId: string): Promise<void> {
    if (await this.get<boolean>("mention_webhook_registered")) return;

    // Both early exits below re-arm rather than return: this is the ONLY
    // callback that observes channel messages, so giving up here means the
    // connection never notices an at-mention again.
    const authorization = await this.get<Authorization>("auth");
    if (!authorization) {
      await this.deferWebhookRegistration(
        MENTION_WEBHOOK_RETRY_KEY,
        this.registerMentionWebhook,
        channelId,
        "no stored authorization"
      );
      return;
    }

    const token = await this.tools.integrations.get(channelId);
    if (!token) {
      await this.deferWebhookRegistration(
        MENTION_WEBHOOK_RETRY_KEY,
        this.registerMentionWebhook,
        channelId,
        "no usable token"
      );
      return;
    }
    if (!token.scopes?.includes("channels:history")) {
      // Required scope, so its absence means a stale or broken grant rather
      // than a choice — worth retrying in case the user reconnects.
      await this.deferWebhookRegistration(
        MENTION_WEBHOOK_RETRY_KEY,
        this.registerMentionWebhook,
        channelId,
        "grant is missing a required scope"
      );
      return;
    }

    const userId = token.provider?.authed_user_id;
    if (userId) await this.set("slack_user_id", userId);

    await this.tools.network.createWebhook(
      { provider: AuthProvider.Slack, authorization },
      this.onSlackWebhook,
      MENTION_WEBHOOK_SENTINEL
    );
    await this.set("mention_webhook_registered", true);
    await this.cancelScheduledTask(MENTION_WEBHOOK_RETRY_KEY);
  }

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
            source: {
              accountId: member.id,
              ...(member.name ? { descriptor: `@${member.name}` } : {}),
            },
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
        // Same per-channel key as the daily reschedule: the rate-limit retry
        // and the normal daily run are the one logical members-sync chain, so
        // keying them together guarantees they can never run in parallel.
        console.log(`Slack: rescheduling syncMembers (${error.method}) at ${runAt.toISOString()}`);
        await this.scheduleRecurring(`members-sync:${channelId}`, retry, {
          intervalMs: 24 * 60 * 60 * 1000,
          firstRunAt: runAt,
        });
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
        // Singleton keyed task: re-scheduling under this per-channel key
        // atomically replaces any pending members sync, so the daily chain
        // can never accumulate parallel copies even if syncMembers is entered
        // again (onChannelEnabled re-dispatch, recovery).
        await this.scheduleRecurring(`members-sync:${channelId}`, dailyCallback, {
          intervalMs: 24 * 60 * 60 * 1000,
          firstRunAt: nextRunAt,
        });
      }
    }
  }

  // ---- Workspace custom emoji sync ----

  /**
   * Fetches the workspace's custom emoji via `emoji.list`, resolves Slack
   * `alias:` chains, and upserts them into Plot's shared custom-emoji cache as
   * `slack:<teamId>/<name>` refs so they render as images and round-trip as
   * reactions. Also caches the workspace's emoji *name set* (`custom_emoji_<teamId>`)
   * so the inbound transform can recognise custom reactions.
   *
   * Gated to run at most once per 24 hours per workspace (connection), then
   * reschedules itself for the next daily refresh — mirrors {@link syncMembers}.
   * `emoji:read` is an optional scope; when it is not granted this no-ops.
   */
  async syncCustomEmoji(channelId: string): Promise<void> {
    const now = Date.now();
    const ONE_DAY_MS = 24 * 60 * 60 * 1000;
    const last = await this.get<number>("customEmojiSyncedAt");
    if (last && now - last < ONE_DAY_MS) return;

    const token = await this.tools.integrations.get(channelId);
    if (!token) return;
    if (!token.scopes?.includes("emoji:read")) return; // optional scope not granted
    const teamId = token.provider?.team_id;
    if (!teamId) return;

    const api = new SlackApi(token.token);
    const raw: Record<string, string> = {};
    let cursor: string | undefined;
    try {
      do {
        const { emoji, nextCursor } = await api.listEmoji(cursor);
        Object.assign(raw, emoji);
        cursor = nextCursor;
      } while (cursor);
    } catch (error) {
      if (error instanceof SlackRateLimitedError) {
        const retry = await this.callback(this.syncCustomEmoji, channelId);
        const runAt = new Date(now + error.retryAfterMs);
        // Same per-channel key as the daily reschedule: the rate-limit retry
        // and the normal daily run are the one logical custom-emoji-sync
        // chain, so keying them together prevents parallel chains.
        console.log(`Slack: rescheduling syncCustomEmoji ${channelId} at ${runAt.toISOString()}`);
        await this.scheduleRecurring(`custom-emoji-sync:${channelId}`, retry, {
          intervalMs: 24 * 60 * 60 * 1000,
          firstRunAt: runAt,
        });
        return;
      }
      if (error instanceof SlackPermanentError) {
        console.warn(
          `syncCustomEmoji stopped: ${error.method} → ${error.slackError}`
        );
        if (SLACK_AUTH_ERRORS.has(error.slackError)) {
          await this.tools.integrations.markNeedsReauth(channelId);
        }
        return;
      }
      console.warn("[slack] emoji.list failed", error);
      return;
    }

    const refFor = (name: string) => `slack:${teamId}/${name}`;
    // Workspaces can alias a custom name to a *standard* Slack emoji
    // shortcode (e.g. "party-parrot-2": "alias:thumbsup"). Standard emoji
    // never get their own custom_emoji row, so aliasOf must only point at
    // names that are themselves custom emoji in this workspace — otherwise
    // it dangles and violates the self-referencing alias_of foreign key.
    const customNames = new Set(Object.keys(raw));
    const buildRow = (name: string, value: string) => {
      const isAlias = value.startsWith("alias:");
      const aliasTarget = isAlias ? value.slice("alias:".length) : null;
      return {
        id: refFor(name),
        provider: "slack",
        workspace: teamId,
        name,
        imageUrl: isAlias ? null : value,
        aliasOf: aliasTarget && customNames.has(aliasTarget) ? refFor(aliasTarget) : null,
        archived: false,
      };
    };
    const entries = Object.entries(raw);
    // Save non-alias rows before alias rows: alias_of is not deferrable, so
    // a single batched insert checks each row's FK immediately — an alias
    // row would fail if its target hasn't been inserted yet in the same
    // batch.
    const targetRows = entries
      .filter(([, value]) => !value.startsWith("alias:"))
      .map(([name, value]) => buildRow(name, value));
    const aliasRows = entries
      .filter(([, value]) => value.startsWith("alias:"))
      .map(([name, value]) => buildRow(name, value));
    await this.tools.integrations.saveCustomEmoji(targetRows);
    await this.tools.integrations.saveCustomEmoji(aliasRows);

    // Cache the name set so the inbound transform can recognise custom
    // reactions (Slack reaction events carry the bare name, not the ref).
    await this.set(`custom_emoji_${teamId}`, Object.keys(raw));
    await this.set("customEmojiSyncedAt", now);

    // Schedule the next daily refresh. Singleton keyed task: re-scheduling
    // under this per-channel key atomically replaces any pending refresh, so
    // the daily chain can never accumulate parallel copies even if
    // syncCustomEmoji is entered again (onChannelEnabled re-dispatch, recovery).
    const next = await this.callback(this.syncCustomEmoji, channelId);
    await this.scheduleRecurring(`custom-emoji-sync:${channelId}`, next, {
      intervalMs: 24 * 60 * 60 * 1000,
      firstRunAt: new Date(now + ONE_DAY_MS),
    });
  }

  // ---- Mention identity ----

  /**
   * Who counts as "you" for mention detection on this connection: the
   * connected user plus every user group they belong to.
   *
   * Reads ONLY from the store, because it runs on every channel message in
   * the workspace ({@link handleChannelMessage}) and resolving a token per
   * message would mean an `integrations.get()` for whatever arbitrary channel
   * the event happened to name. `slack_user_id` is written by
   * {@link registerMentionWebhook} — before the webhook that delivers these
   * events exists — and refreshed on the daily cadence by
   * {@link syncUserGroups}. The group roster comes from the same daily
   * refresh; a cold or scope-less cache simply means only direct and
   * broadcast mentions match.
   *
   * A missing identity should be unreachable in steady state, but Slack never
   * redelivers a dropped event, so a miss is logged rather than silently
   * swallowed.
   */
  private async cachedMentionContext(): Promise<MentionContext | null> {
    const userId = await this.get<string>("slack_user_id");
    if (!userId) {
      console.warn(
        "cachedMentionContext: no cached Slack identity; dropping mention check"
      );
      return null;
    }
    const groups = (await this.get<string[]>("slack_user_groups")) ?? [];
    return { userId, userGroupIds: new Set(groups) };
  }

  /**
   * Refresh the cached user-group roster. No-op without the optional
   * `usergroups:read` grant — the user declined it (checked client-side,
   * below, before any API call — so a declined grant never reaches the
   * catch block and never triggers a reauth prompt), or their grant
   * predates the scope group.
   *
   * Gated to run at most once per 24 hours per workspace (connection), then
   * reschedules itself for the next daily refresh — mirrors
   * {@link syncCustomEmoji}. The timestamp is written only after a
   * successful refresh, so a rate-limited or errored pass stays retryable
   * (picked up again the next time {@link queueWorkspaceDailyTasks} fires,
   * or sooner for a rate limit — see below) instead of being marked done.
   *
   * Error handling follows {@link syncCustomEmoji} for the two expected
   * classes and deliberately DIVERGES from it on the third — do not copy that
   * sibling's final branch here:
   * - a rate limit reschedules itself for after the retry window;
   * - a permanent error tied to the auth grant itself (revoked/expired token,
   *   `missing_scope` surfaced by the API despite the client-side check
   *   above) flags the connection for reauth;
   * - anything else is unexpected and is RETHROWN, where `syncCustomEmoji`
   *   warns and returns. Rethrowing lets the platform's queue consumer
   *   classify it and, if it's not one of the recognized
   *   transient/rate-limit/auth classes, surface it to error tracking —
   *   otherwise a genuine bug here would fail silently forever.
   */
  async syncUserGroups(channelId: string): Promise<void> {
    const now = Date.now();
    const ONE_DAY_MS = 24 * 60 * 60 * 1000;
    const last = await this.get<number>("userGroupsSyncedAt");
    if (last && now - last < ONE_DAY_MS) return;

    const token = await this.tools.integrations.get(channelId);
    const userId = token?.provider?.authed_user_id;
    if (!token || !userId) return;

    // Refresh the cached identity on the daily cadence as well. The mention
    // router reads it from the store on every inbound channel message and it
    // is otherwise only ever written when the mention webhook first
    // registers — one write, at one moment, for the life of the connection.
    // Written before the optional-scope check below so a connection that
    // declined the group scope still keeps a fresh identity.
    await this.set("slack_user_id", userId);

    if (!token.scopes?.includes("usergroups:read")) {
      // Stamp the marker before returning. A declined optional grant cannot
      // change without a reconnect, and reconnecting re-runs the enable path
      // anyway — so leaving it unset only makes the daily fan-out re-queue a
      // pass that can do nothing but return here again.
      await this.set("userGroupsSyncedAt", now);
      return;
    }

    try {
      const api = new SlackApi(token.token);
      await this.set("slack_user_groups", await api.getUserGroupsForUser(userId));
    } catch (error) {
      if (error instanceof SlackRateLimitedError) {
        // Do NOT stamp userGroupsSyncedAt: leaving it unset keeps this pass
        // retryable. Reschedule sooner than the daily cadence, under the
        // same per-channel key as the daily chain so the two can never run
        // in parallel — re-scheduling atomically replaces any pending run.
        const retry = await this.callback(this.syncUserGroups, channelId);
        const runAt = new Date(now + error.retryAfterMs);
        console.log(`Slack: rescheduling syncUserGroups ${channelId} at ${runAt.toISOString()}`);
        await this.scheduleRecurring(`user-groups-sync:${channelId}`, retry, {
          intervalMs: ONE_DAY_MS,
          firstRunAt: runAt,
        });
        return;
      }
      if (error instanceof SlackPermanentError) {
        // Not retried; userGroupsSyncedAt intentionally left unset. Only
        // flag reauth for errors that indicate the auth grant itself is
        // bad — NOT for a plain missing_scope from a user who simply
        // declined this optional grant, which is already filtered out
        // above before any API call is made.
        console.warn(
          `syncUserGroups stopped: ${error.method} → ${error.slackError}`
        );
        if (SLACK_AUTH_ERRORS.has(error.slackError)) {
          await this.tools.integrations.markNeedsReauth(channelId);
        }
        return;
      }
      // Unexpected: rethrow so the platform's queue consumer classifies it
      // and, if genuinely unexpected, captures it to error tracking. A bare
      // console.warn here would let a real bug fail silently forever.
      console.error("syncUserGroups: unexpected error", error);
      throw error;
    }

    await this.set("userGroupsSyncedAt", now);

    // Schedule the next daily refresh. Singleton keyed task: re-scheduling
    // under this per-channel key atomically replaces any pending refresh, so
    // the daily chain can never accumulate parallel copies even if
    // syncUserGroups is entered again (onChannelEnabled re-dispatch, recovery).
    const next = await this.callback(this.syncUserGroups, channelId);
    await this.scheduleRecurring(`user-groups-sync:${channelId}`, next, {
      intervalMs: ONE_DAY_MS,
      firstRunAt: new Date(now + ONE_DAY_MS),
    });
  }

  // ---- DM/MPIM conversation discovery ----

  /**
   * Discovers the user's current DM and group-DM conversation ids and caches
   * them under `dm_channels`, so the DM webhook handler (see
   * {@link isKnownDMChannel}) can distinguish "a DM/MPIM this user is in" from
   * "a private channel this user has access to but chose not to enable" —
   * both can share the legacy `G…` id prefix, so prefix-matching alone isn't
   * reliable.
   *
   * Gated to run at most once per 24 hours per workspace (connection),
   * mirroring {@link syncMembers} / {@link syncCustomEmoji}. A brand-new
   * incoming DM conversation is picked up on the next daily run, or
   * immediately if proactively registered (see `createDirectMessage`).
   *
   * Requires the `im:read` optional scope (part of the `dms` group) to have
   * been granted. Without that guard, a token missing `im:read` would hit
   * `conversations.list`, get back `missing_scope` (a permanent error in
   * `SLACK_AUTH_ERRORS`), and force-flag the entire connection as needing
   * reconnection even though nothing is actually broken.
   *
   * When `im:read` is absent, `im:history` disambiguates why: both come from
   * the `dms` group, so having `im:history` alone means the user opted into DM
   * sync on a grant made before `im:read` joined that group. That grant can
   * never enumerate DMs, so re-auth is flagged to prompt a reconnect. A user
   * who declined DM sync has neither scope and is left alone.
   */
  async listDMChannels(channelId: string): Promise<void> {
    const now = Date.now();
    const ONE_DAY_MS = 24 * 60 * 60 * 1000;
    const last = await this.get<number>("dmChannelsSyncedAt");
    if (last && now - last < ONE_DAY_MS) return;

    const token = await this.tools.integrations.get(channelId);
    if (!token) {
      console.warn("listDMChannels: Slack token unavailable");
      return;
    }
    if (!token.scopes?.includes("im:read")) {
      // im:read and im:history are granted together by the `dms` group, so a
      // token carrying im:history WITHOUT im:read predates im:read joining
      // that group — the user opted into DM sync but their grant can't
      // enumerate DMs. Returning quietly would strand them permanently: the
      // DM webhook registers (im:history is enough), but `dm_channels` stays
      // empty, so isKnownDMChannel drops every incoming DM while the
      // connection still reports healthy. Prompt a reconnect to re-consent.
      // A user who declined DMs has neither scope and is left alone.
      if (token.scopes?.includes("im:history")) {
        await this.tools.integrations.markNeedsReauth(channelId);
      }
      return;
    }

    const api = new SlackApi(token.token);

    const ids: string[] = [];
    // The counterparty of each 1:1, kept alongside the roster so the sync
    // path can key a conversation on the person without a second API call.
    // A group conversation has no single counterparty and records `{}`.
    const conversationsById: Record<string, { user?: string }> = {};
    let cursor: string | undefined;
    try {
      do {
        const { conversations, nextCursor } = await api.getDMConversations(cursor);
        for (const c of conversations as SlackDMConversation[]) {
          if (c.is_im || c.is_mpim) {
            ids.push(c.id);
            conversationsById[c.id] = c.is_im && c.user ? { user: c.user } : {};
          }
        }
        cursor = nextCursor;
      } while (cursor);
    } catch (error) {
      if (error instanceof SlackRateLimitedError) {
        const retry = await this.callback(this.listDMChannels, channelId);
        const runAt = new Date(now + error.retryAfterMs);
        console.log(`Slack: rescheduling listDMChannels at ${runAt.toISOString()}`);
        await this.scheduleRecurring(`dm-channels-sync:${channelId}`, retry, {
          intervalMs: ONE_DAY_MS,
          firstRunAt: runAt,
        });
        return;
      }
      if (error instanceof SlackPermanentError) {
        console.warn(`listDMChannels stopped: ${error.method} → ${error.slackError}`);
        if (SLACK_AUTH_ERRORS.has(error.slackError)) {
          await this.tools.integrations.markNeedsReauth(channelId);
        }
        return;
      }
      console.warn("[slack] listDMChannels failed", error);
      return;
    }

    await this.set("dm_channels", ids);
    await this.set("dm_conversations", conversationsById);
    await this.set("dmChannelsSyncedAt", now);

    const next = await this.callback(this.listDMChannels, channelId);
    await this.scheduleRecurring(`dm-channels-sync:${channelId}`, next, {
      intervalMs: ONE_DAY_MS,
      firstRunAt: new Date(now + ONE_DAY_MS),
    });
  }

  /** Returns true if `channelId` is a currently-known DM/MPIM conversation. */
  private async isKnownDMChannel(channelId: string): Promise<boolean> {
    const ids = await this.get<string[]>("dm_channels");
    return ids?.includes(channelId) ?? false;
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
    const reNoteKey = meta.reNoteKey as string | undefined;
    // A direct conversation is one permanent Plot thread with no lasting
    // parent message to nest a reply under — `threadTs` is just a to-do
    // star's anchor (see starAnchorKey) and, for a DM, moves as the
    // conversation grows. Reply to the note being answered when there is
    // one, otherwise post top-level. Channel threads keep Slack's own
    // threading, where `threadTs` IS a stable parent.
    // `direct` is stamped by assembleSlackDmLink, so it covers group DMs too —
    // a `D…` prefix check alone would miss them, and MPIM ids are not
    // distinguishable from private channels by prefix.
    const isDirect = meta.direct === true;
    const replyTs = reNoteKey ?? (isDirect ? undefined : (meta.threadTs as string | undefined));
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
    const result = await api.postMessage(channelId, body, replyTs);
    if (!result?.ts) return;

    // Echo guard: skip re-importing this message when it comes back via the
    // channel's webhook (the channel is observed once a thread is composed
    // into it). Without this the reply round-trips as a duplicate note. See
    // processMessageThreads / refreshSlackThread, which clear+skip on read.
    await this.set(`sent:${result.ts}`, true);

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
    let shortcode = unicodeToSlackName(emoji);
    if (!shortcode && emoji.startsWith("slack:")) {
      // Custom workspace emoji ref `slack:<teamId>/<name>` → bare name, which
      // Slack's reactions.add/remove accepts directly.
      const m = emoji.match(/^slack:[^/]+\/(.+)$/);
      if (m) shortcode = m[1];
    }
    if (!channelId || !note.key) {
      return;
    }

    if (!shortcode) {
      return; // unmapped Unicode / unknown custom emoji — no Slack equivalent
    }

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
    const keys = await this.tools.store.list("token_channel_");
    return keys.map((key) => key.substring("token_channel_".length));
  }
}

export default Slack;
