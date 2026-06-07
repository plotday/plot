import {
  Connector,
  type CreateLinkDraft,
  type NoteWriteBackResult,
  type ToolBuilder,
} from "@plotday/twister";
import { ActionType } from "@plotday/twister/plot";
import type { Actor, ActorId, NewLinkWithNotes, Note, Thread, Link } from "@plotday/twister/plot";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  type Channel,
  Integrations,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { Files } from "@plotday/twister/tools/files";

import {
  GOOGLE_PEOPLE_SCOPES,
  enrichLinkContactsFromGoogle,
} from "@plotday/connector-google-contacts";

import {
  GmailApi,
  type GmailThread,
  type AttachmentData,
  type SyncState,
  buildNewEmailMessage,
  buildReplyMessage,
  getHeader,
  parseEmailAddresses,
  syncGmailChannel,
  syncGmailMailboxIncremental,
  transformGmailThread,
} from "./gmail-api";

/**
 * Persisted mailbox-wide watch state. Gmail allows one watch per (mailbox,
 * OAuth client); each call to `users.watch()` from the same OAuth client
 * replaces that client's previous registration. Different OAuth clients
 * (e.g. dev vs prod) maintain independent watches.
 */
type MailboxWebhookState = {
  topicName: string;
  historyId: string;
  expiration: Date;
  created: string;
};

/**
 * How often `selfHealCheck` runs while at least one channel is enabled. A
 * faster cadence improves recovery latency when push delivery breaks; a
 * slower one reduces Gmail API load. 1h is a comfortable middle.
 */
const SELF_HEAL_INTERVAL_MS = 60 * 60 * 1000;

/**
 * If a watch is within this window of expiry, `selfHealCheck` re-establishes
 * it preemptively rather than relying on `mailbox_renewal_task` (which can
 * fail to fire if the Durable Object alarm is dropped on deploy/eviction).
 * 36h gives the renewal task its scheduled run plus a safety margin.
 */
const WATCH_PREEMPTIVE_RENEW_MS = 36 * 60 * 60 * 1000;

/**
 * A thread whose full-fetch failed during an incremental sync and must be
 * re-attempted on a later sync. `attempts` bounds retries so a permanently
 * unfetchable thread (e.g. deleted) is eventually abandoned with a log line
 * rather than re-fetched forever.
 */
type PendingThread = { id: string; attempts: number };

/** Max times we re-attempt a failing thread fetch before giving up. */
const MAX_THREAD_FETCH_ATTEMPTS = 5;

/**
 * Persisted mailbox-wide incremental cursor. `pendingThreadIds` carries
 * thread fetches that failed on a prior sync so the next sync retries them —
 * without this, advancing `historyId` past a failed fetch silently loses that
 * mail.
 */
type IncrementalState = {
  historyId?: string;
  lastSyncTime?: Date;
  pendingThreadIds?: PendingThread[];
};

/**
 * Idempotency window for `onCreateLink`. A compose draft carries no stable
 * id, so we dedupe by a content hash; two dispatches with identical content
 * within this window are treated as a callback retry (suppress the resend),
 * while a genuine re-compose later than this still sends.
 */
const COMPOSE_DEDUP_WINDOW_MS = 10 * 60 * 1000;

/**
 * FNV-1a 32-bit hash → 8-char hex. Deterministic and dependency-free; used
 * only to derive a compact idempotency key from compose-draft content, not
 * for anything security-sensitive.
 */
function fnv1aHex(input: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < input.length; i++) {
    h ^= input.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return (h >>> 0).toString(16).padStart(8, "0");
}

/**
 * Compute the outbound email recipient list for a single role (To, Cc, or Bcc),
 * applying the per-note access_contacts constraint when set.
 *
 * @param args.accessContactEmails - Allowed email addresses derived from
 *   note.accessContacts (contact IDs resolved to emails via thread.accessContacts),
 *   or null when the note has no access restriction (send to everyone).
 * @param args.candidates - Email addresses for this role from the Gmail headers.
 * @param args.self - Sender email; always excluded regardless of constraint.
 * @returns Filtered list of email addresses for the role.
 *
 * @example
 * // Private note — accessContactEmails is an empty set → empty result
 * recipientsFor({ accessContactEmails: new Set(), candidates: ["a@b.com"], self: "me@b.com" })
 * // => []
 *
 * @example
 * // No constraint — send to all non-self candidates
 * recipientsFor({ accessContactEmails: null, candidates: ["a@b.com", "me@b.com"], self: "me@b.com" })
 * // => ["a@b.com"]
 */
export function recipientsFor(args: {
  accessContactEmails: Set<string> | null;
  candidates: string[];
  self: string;
}): string[] {
  const { accessContactEmails, candidates, self } = args;
  const selfLower = self.toLowerCase();
  return candidates.filter((email) => {
    const lower = email.toLowerCase();
    if (lower === selfLower) return false; // sender is never a recipient
    if (accessContactEmails === null) return true; // no constraint: include all
    return accessContactEmails.has(lower); // constrained: only allowed contacts
  });
}

/** Persisted per-channel initial-backfill cursor. */
type InitialSyncState = {
  pageToken?: string;
  lastSyncTime?: Date;
};

/**
 * Per-channel system labels we route through, in priority order (most
 * specific first). Threads with custom user labels are handled separately
 * (custom labels always win over system labels).
 */
const SYSTEM_LABEL_ORDER = ["STARRED", "IMPORTANT", "INBOX", "SENT", "DRAFT"];

type MessageChannel = {
  id: string;
  name: string;
  description: string | null;
  primary: boolean;
};

type MessageSyncOptions = {
  timeMin?: Date;
};

/**
 * Gmail integration source implementing the MessagingSource interface.
 *
 * Supports inbox, labels, and search filters as channels.
 * Auth is managed declaratively via provider config in build() and
 * handled through the twist edit modal.
 *
 * **Required OAuth Scope:**
 * - `https://www.googleapis.com/auth/gmail.modify` - Read messages, modify labels, send replies
 *
 * `gmail.modify` is a superset that grants all read/write operations except
 * permanent delete, so it covers reading threads, archiving, label changes,
 * and sending replies without needing `gmail.readonly` or `gmail.send`.
 */
export class Gmail extends Connector<Gmail> {
  static readonly PROVIDER = AuthProvider.Google;
  static readonly handleReplies = true;
  static readonly SCOPES = ["https://www.googleapis.com/auth/gmail.modify"];

  readonly provider = AuthProvider.Google;
  // Merge in People API scopes so we can enrich email-only contacts (Gmail
  // headers carry name + address but no avatar) with photos from the user's
  // Google Contacts and "other contacts" — without requiring the separate
  // Google Contacts connector to be installed.
  readonly scopes = Integrations.MergeScopes(
    Gmail.SCOPES,
    GOOGLE_PEOPLE_SCOPES,
  );
  readonly linkTypes = [
    {
      type: "email",
      label: "Thread",
      noteLabel: "Reply",
      sharingModel: "message" as const,
      composePlaceholder: "Send a Gmail email",
      composeVerb: "Send",
      replyPlaceholder: "Reply",
      replyVerb: "Send",
      supportsFileAttachments: true,
      logo: "https://api.iconify.design/logos/google-gmail.svg",
      logoMono: "https://api.iconify.design/simple-icons/gmail.svg",
      statuses: [
        { status: "inbox", label: "Inbox" },
        { status: "starred", label: "Starred", active: true },
        { status: "sent", label: "Sent" },
        { status: "archived", label: "Archived", done: true },
      ],
      contactRoles: [
        { id: "to", label: "To", default: true },
        { id: "cc", label: "CC" },
        { id: "bcc", label: "BCC", hidden: true },
      ],
      supportsContactChanges: true,
      // Gmail composes target any address — a Plot contact (with or without
      // a Gmail-connection row) or a free-form typed email delivered via
      // `inviteEmails`. The runtime fills `recipients` from the
      // connection-scoped row when available and falls back to
      // `contact.email` otherwise.
      compose: {
        targets: "addresses" as const,
        status: "sent",
      },
    },
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, {
        urls: [
          "https://gmail.googleapis.com/gmail/v1/*",
          "https://people.googleapis.com/v1/*",
        ],
      }),
      files: build(Files),
    };
  }

  override async activate(context: { auth: Authorization; actor: Actor }): Promise<void> {
    await this.set("auth_actor_id", context.actor.id);
  }

  /**
   * Migration from per-channel watches to a single mailbox-wide watch.
   *
   * Old layout (per-channel):
   *   - `channel_webhook_${id}`, `watch_renewal_task_${id}`, `sync_state_${id}`,
   *     `sync_enabled_${id}`
   * New layout (per-twist-instance):
   *   - `mailbox_webhook`, `mailbox_renewal_task`, `incremental_state`,
   *     `enabled_channels`, plus `initial_state_${id}` for in-flight backfills
   *
   * The Twist runtime API doesn't let connectors enumerate stored keys, so we
   * probe the system labels we know users can enable. Users with custom
   * Gmail labels enabled (e.g. `Label_14`) will need to re-toggle them after
   * this upgrade — without `list()` we can't discover their IDs.
   */
  override async upgrade(): Promise<void> {
    // Already migrated? `mailbox_webhook` is the canonical sentinel.
    const already = await this.get<MailboxWebhookState>("mailbox_webhook");
    if (already) {
      // Self-heal bootstrap for instances that migrated to mailbox-wide
      // before self-heal existed. Idempotent: skipped if already scheduled.
      const existingSelfHeal = await this.get<string>(
        "mailbox_self_heal_task"
      );
      if (!existingSelfHeal) {
        try {
          await this.scheduleSelfHealCheck();
        } catch (error) {
          console.error(
            `Gmail upgrade [${this.id}]: failed to bootstrap self-heal`,
            error
          );
        }
      }
      return;
    }

    // Stop whatever per-channel watch was last active. Gmail allows only
    // one watch per mailbox, so a single stopWatch() call covers all of
    // them — but the call needs an authed API client.
    const stopApi = await this.findAnyAuthApi();
    if (stopApi) {
      try {
        await stopApi.stopWatch();
      } catch {
        // Best effort — old watch may have already expired.
      }
    }

    // Probe known system labels for old per-channel state and migrate.
    let migratedAny = false;
    for (const labelId of SYSTEM_LABEL_ORDER) {
      const oldWebhook = await this.get<{ topicName?: string }>(
        `channel_webhook_${labelId}`
      );
      const oldEnabled = await this.get<boolean>(`sync_enabled_${labelId}`);
      const oldSyncState = await this.get<SyncState>(`sync_state_${labelId}`);
      const oldRenewalTask = await this.get<string>(
        `watch_renewal_task_${labelId}`
      );

      if (
        !oldWebhook &&
        !oldEnabled &&
        !oldSyncState &&
        !oldRenewalTask
      ) {
        continue;
      }

      // Channel was enabled (presence of any old per-channel key counts).
      if (oldEnabled || oldWebhook) {
        await this.addEnabledChannel(labelId);
        migratedAny = true;
      }

      // Carry over any in-flight initial-backfill cursor.
      if (oldSyncState?.pageToken) {
        await this.set<InitialSyncState>(`initial_state_${labelId}`, {
          pageToken: oldSyncState.pageToken,
          lastSyncTime: oldSyncState.lastSyncTime,
        });
        // Resume the backfill under the new callback.
        const next = await this.callback(this.initialSyncBatch, labelId, 1);
        await this.runTask(next);
      }

      // Cancel old per-channel renewal task.
      if (oldRenewalTask) {
        try {
          await this.cancelTask(oldRenewalTask);
        } catch {
          // Task may have already executed.
        }
        await this.clear(`watch_renewal_task_${labelId}`);
      }

      // Clean up old per-channel topic. The topic still receives no
      // notifications (Gmail's mailbox watch points elsewhere now), but
      // leaving it dangling wastes Pub/Sub resources.
      if (oldWebhook?.topicName) {
        try {
          await this.tools.network.deleteWebhook(oldWebhook.topicName);
        } catch (error) {
          console.warn(
            `Failed to delete old per-channel webhook ${labelId}:`,
            error
          );
        }
      }
      await this.clear(`channel_webhook_${labelId}`);
      await this.clear(`sync_state_${labelId}`);
      await this.clear(`sync_enabled_${labelId}`);
    }

    if (migratedAny) {
      await this.setupMailboxWebhook();
    }
  }

  private async findAnyAuthApi(): Promise<GmailApi | null> {
    // Try known system labels and any already-migrated channels in the new
    // enabled_channels list. Per-channel auth is just the Google account
    // token, so any channelId works.
    const candidates = new Set<string>(SYSTEM_LABEL_ORDER);
    for (const id of await this.getEnabledChannels()) candidates.add(id);
    for (const channelId of candidates) {
      try {
        const token = await this.tools.integrations.get(channelId);
        if (token?.token) return new GmailApi(token.token);
      } catch {
        // Channel unknown to integrations — skip.
      }
    }
    return null;
  }

  async getChannels(
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
      // Default to syncing the user's actual conversations: Inbox (incoming)
      // and Sent (outgoing). Important/Starred are overlapping views of mail
      // that's mostly already in the Inbox, so enabling them by default would
      // largely re-sync the same threads; Draft and user-created labels would
      // crowd the view. They're all still available to enable manually, and
      // Spam/Trash aren't even listed (filtered above).
      .map((l: any) => ({
        id: l.id,
        title: l.name,
        enabledByDefault: l.id === "INBOX" || l.id === "SENT",
      }));
  }

  async onChannelEnabled(channel: Channel, context?: SyncContext): Promise<void> {
    const syncHistoryMin = context?.syncHistoryMin;
    if (context?.recovering) {
      // Recovery dispatch after re-auth: drop the per-channel initial
      // cursor so this channel re-walks its label. Don't touch
      // `incremental_state` here — the mailbox-wide cursor is shared
      // across all channels, and incrementalSyncBatch already self-heals
      // a stale (>7 day) historyId via the 404 → reseed path.
      await this.clear(`initial_state_${channel.id}`);
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

    await this.addEnabledChannel(channel.id);

    // observeOnly: the channel is being auto-observed because a user composed
    // a Plot thread into it, not explicitly enabled. We still register the
    // mailbox watch below so inbound events sync back, but skip the historical
    // backfill — the user didn't ask to import this mailbox's history.
    if (!context?.observeOnly) {
      const initialState: InitialSyncState = {
        lastSyncTime: syncHistoryMin ?? undefined,
      };
      await this.set(`initial_state_${channel.id}`, initialState);

      // Queue per-channel initial backfill (label-scoped paginated thread list)
      // as a separate task so onChannelEnabled returns quickly.
      const initialCallback = await this.callback(
        this.initialSyncBatch,
        channel.id,
        1
      );
      await this.runTask(initialCallback);
    }

    // Queue mailbox-wide webhook setup as a separate task to avoid blocking
    // the HTTP response. ensureMailboxWebhook is idempotent: if the watch
    // already exists from a previously-enabled channel, this is a no-op
    // beyond bumping the renewal cadence.
    const webhookCallback = await this.callback(this.ensureMailboxWebhook);
    await this.runTask(webhookCallback);
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.removeEnabledChannel(channel.id);
    await this.clear(`initial_state_${channel.id}`);
    await this.clear(`sync_history_min_${channel.id}`);

    // If no enabled channels remain, tear the mailbox watch down. The next
    // onChannelEnabled will rebuild it.
    const enabled = await this.getEnabledChannels();
    if (enabled.size === 0) {
      await this.teardownMailboxWebhook();
    }
  }

  private async getApi(channelId: string): Promise<GmailApi> {
    const token = await this.tools.integrations.get(channelId);
    if (!token) {
      throw new Error("No Google authentication token available");
    }
    return new GmailApi(token.token);
  }

  async listLabels(channelId: string): Promise<MessageChannel[]> {
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
    } & MessageSyncOptions
  ): Promise<void> {
    const { channelId, timeMin } = options;

    const initialState: InitialSyncState = {
      lastSyncTime: timeMin
        ? typeof timeMin === "string"
          ? new Date(timeMin)
          : timeMin
        : undefined,
    };

    await this.set(`initial_state_${channelId}`, initialState);
    await this.addEnabledChannel(channelId);

    const initialCallback = await this.callback(
      this.initialSyncBatch,
      channelId,
      1
    );
    await this.runTask(initialCallback);

    const webhookCallback = await this.callback(this.ensureMailboxWebhook);
    await this.runTask(webhookCallback);
  }

  async stopSync(channelId: string): Promise<void> {
    await this.removeEnabledChannel(channelId);
    await this.clear(`initial_state_${channelId}`);

    // Tear down the mailbox watch only if this was the last enabled channel.
    const enabled = await this.getEnabledChannels();
    if (enabled.size === 0) {
      await this.teardownMailboxWebhook();
    }
  }

  /**
   * Idempotently set up the mailbox-wide Gmail watch + Pub/Sub topic.
   * Called every time a channel is enabled; first call creates the webhook,
   * subsequent calls are no-ops.
   *
   * The watch is registered with no `labelIds`, so Gmail notifies us on every
   * mailbox change — including replies in existing threads that don't carry
   * the label of any enabled channel. The connector decides per-thread which
   * enabled channel(s) the change is relevant to.
   */
  async ensureMailboxWebhook(): Promise<void> {
    const existing = await this.get<MailboxWebhookState>("mailbox_webhook");
    if (!existing) {
      await this.setupMailboxWebhook();
      return;
    }
    // Watch already established — make sure the self-heal cycle is running.
    // This handles upgrades from versions that didn't schedule self-heal.
    const existingSelfHeal = await this.get<string>("mailbox_self_heal_task");
    if (!existingSelfHeal) {
      await this.scheduleSelfHealCheck();
    }
  }

  private async setupMailboxWebhook(): Promise<void> {
    // Tear down any prior watch and topic before creating new ones. Gmail
    // enforces one watch per (mailbox, OAuth client) and returns 400
    // "Only one user push notification client allowed per developer (call
    // /stop then try again)" when users.watch() is called with a NEW topic
    // while a watch is already active. setupMailboxWebhook always creates
    // a fresh topic (createWebhook mints a new callback token → new topic
    // name), so the existing watch must be stopped first; the orphaned
    // Pub/Sub topic is also deleted to avoid leaking resources every
    // self-heal renewal.
    const existing = await this.get<MailboxWebhookState>("mailbox_webhook");
    await this.clear("mailbox_webhook");
    const cleanupApi = await this.getApiAny();
    if (cleanupApi) {
      try {
        await cleanupApi.stopWatch();
      } catch (error) {
        // Best-effort — old watch may have already expired or never existed.
        console.warn(
          `Gmail setupMailboxWebhook [${this.id}]: stopWatch (cleanup) failed`,
          error
        );
      }
    }
    if (existing?.topicName) {
      try {
        await this.tools.network.deleteWebhook(existing.topicName);
      } catch (error) {
        console.warn(
          `Gmail setupMailboxWebhook [${this.id}]: deleteWebhook (cleanup) failed`,
          error
        );
      }
    }

    // `pubsub: "gmail"` returns a Gmail-specific Pub/Sub topic name (instead
    // of a webhook URL) to hand to users.watch. This opt-in must be explicit
    // so a sibling Google connector's provider-less webhook (Calendar, Drive)
    // is never misrouted to a Gmail topic. The webhook delivers no extra
    // args — onGmailWebhook operates on the single mailbox-wide watch.
    const topicName = await this.tools.network.createWebhook(
      { pubsub: "gmail" },
      this.onGmailWebhook
    );

    const api = await this.getApiAny();
    if (!api) {
      console.warn(
        `Gmail setupMailboxWebhook [${this.id}]: no enabled channel to source auth from`
      );
      return;
    }

    // No labelId → mailbox-wide notifications. Failures here are surfaced
    // via throw so the runtime captures the exception in PostHog. The
    // caller (selfHealCheck or onChannelEnabled task) is responsible for
    // logging context and deciding whether to retry.
    const watchResult = await api.setupWatch(topicName);
    const expiration = new Date(parseInt(watchResult.expiration));

    await this.set<MailboxWebhookState>("mailbox_webhook", {
      topicName,
      historyId: watchResult.historyId,
      expiration,
      created: new Date().toISOString(),
    });

    // Seed the incremental cursor so the first webhook has somewhere to
    // start. Gmail's watch returns the current historyId; any change after
    // this point will appear in history.list from this seed.
    const existingIncremental =
      await this.get<{ historyId?: string }>("incremental_state");
    if (!existingIncremental?.historyId) {
      await this.set("incremental_state", {
        historyId: watchResult.historyId,
        lastSyncTime: new Date(),
      });
    }

    await this.scheduleMailboxRenewal(expiration);
    await this.scheduleSelfHealCheck();
    console.log(
      `Gmail setupMailboxWebhook [${this.id}]: watch established`,
      {
        topicName,
        historyId: watchResult.historyId,
        expiration: expiration.toISOString(),
      }
    );
  }

  /**
   * Cancel renewal, stop the Gmail watch, delete the Pub/Sub topic, and
   * clear all mailbox-watch state. Called when the last channel is disabled
   * (and from preUpgrade for stale per-channel state).
   */
  private async teardownMailboxWebhook(): Promise<void> {
    const renewalTaskToken = await this.get<string>("mailbox_renewal_task");
    if (renewalTaskToken) {
      try {
        await this.cancelTask(renewalTaskToken);
      } catch {
        // Task may have already executed
      }
      await this.clear("mailbox_renewal_task");
    }

    const selfHealTaskToken = await this.get<string>("mailbox_self_heal_task");
    if (selfHealTaskToken) {
      try {
        await this.cancelTask(selfHealTaskToken);
      } catch {
        // Task may have already executed
      }
      await this.clear("mailbox_self_heal_task");
    }

    const api = await this.getApiAny();
    if (api) {
      try {
        await api.stopWatch();
      } catch (error) {
        console.error(`Gmail teardownMailboxWebhook [${this.id}]: stopWatch failed`, error);
      }
    }

    const webhook = await this.get<MailboxWebhookState>("mailbox_webhook");
    if (webhook?.topicName) {
      try {
        await this.tools.network.deleteWebhook(webhook.topicName);
      } catch (error) {
        console.error(`Gmail teardownMailboxWebhook [${this.id}]: deleteWebhook failed`, error);
      }
    }
    await this.clear("mailbox_webhook");
    await this.clear("incremental_state");
    await this.clear("last_webhook_received_at");
  }

  /**
   * Schedules a task to renew the Gmail watch before its 7-day expiry.
   * Renews 1 day before expiration.
   */
  private async scheduleMailboxRenewal(expiration: Date): Promise<void> {
    const existingTask = await this.get<string>("mailbox_renewal_task");
    if (existingTask) {
      try {
        await this.cancelTask(existingTask);
      } catch {
        // Task may have already executed
      }
      await this.clear("mailbox_renewal_task");
    }

    const renewalTime = new Date(expiration.getTime() - 24 * 60 * 60 * 1000);

    if (renewalTime <= new Date()) {
      // Already past renewal window, renew immediately
      await this.renewMailboxWatch();
      return;
    }

    const renewalCallback = await this.callback(this.renewMailboxWatch);
    const taskToken = await this.runTask(renewalCallback, {
      runAt: renewalTime,
    });
    if (taskToken) {
      await this.set("mailbox_renewal_task", taskToken);
    }
  }

  /**
   * Renews the Gmail mailbox watch before it expires. On primary-path
   * failure, falls back to a full mailbox-webhook re-setup. If both paths
   * fail the error is rethrown so the runtime captures it in PostHog —
   * `selfHealCheck` is the safety net that retries on the next interval.
   */
  async renewMailboxWatch(): Promise<void> {
    let primaryError: unknown;
    try {
      const api = await this.getApiAny();
      if (!api) {
        console.warn(
          `Gmail renewMailboxWatch [${this.id}]: no enabled channel to source auth from`
        );
        return;
      }

      const webhook = await this.get<MailboxWebhookState>("mailbox_webhook");
      if (!webhook?.topicName) {
        await this.setupMailboxWebhook();
        return;
      }

      const watchResult = await api.setupWatch(webhook.topicName);
      const expiration = new Date(parseInt(watchResult.expiration));

      await this.set<MailboxWebhookState>("mailbox_webhook", {
        ...webhook,
        historyId: watchResult.historyId,
        expiration,
      });

      await this.scheduleMailboxRenewal(expiration);
      await this.scheduleSelfHealCheck();
      console.log(
        `Gmail renewMailboxWatch [${this.id}]: watch renewed`,
        {
          historyId: watchResult.historyId,
          expiration: expiration.toISOString(),
        }
      );
      return;
    } catch (error) {
      primaryError = error;
      console.error(
        `Gmail renewMailboxWatch [${this.id}]: renewal failed, attempting full recreate`,
        error
      );
    }

    // Fallback path: tear down and recreate. If this also fails, throw so
    // the runtime surfaces the error to PostHog.
    try {
      await this.setupMailboxWebhook();
    } catch (retryError) {
      console.error(
        `Gmail renewMailboxWatch [${this.id}]: fallback setup also failed`,
        { primaryError, retryError }
      );
      throw retryError instanceof Error
        ? retryError
        : new Error(String(retryError));
    }
  }

  /**
   * Periodic safety net for the mailbox watch. Runs every
   * {@link SELF_HEAL_INTERVAL_MS} while at least one channel is enabled.
   *
   * The Gmail watch + Pub/Sub push pipeline can silently break in ways the
   * `mailbox_renewal_task` won't catch:
   *
   * - the renewal Durable-Object alarm gets dropped on a deploy or DO eviction,
   * - `users.watch()` succeeded but the Pub/Sub push subscription got
   *   tombstoned or tore itself down on consecutive delivery failures,
   * - notifications stopped arriving for an unrelated GCP-side reason.
   *
   * Each run does three things and always reschedules itself, so a single
   * failed run never permanently breaks the cycle:
   *
   * 1. Calls `users.history.list` against the stored
   *    `incremental_state.historyId`. If history is non-empty, push delivery
   *    skipped messages — process them and force a fresh watch setup.
   * 2. Verifies `mailbox_webhook` exists and isn't within
   *    {@link WATCH_PREEMPTIVE_RENEW_MS} of expiry. Recreates if not.
   * 3. Logs a structured heartbeat for observability (twist instance, watch
   *    state, time since last push, action taken).
   *
   * Throws on unrecoverable failures (e.g. the recreate retry exhausted) so
   * the runtime captures the exception in PostHog. Rescheduling happens
   * before the rethrow, so the next run still fires.
   */
  async selfHealCheck(): Promise<void> {
    const now = new Date();

    const enabled = await this.getEnabledChannels();
    if (enabled.size === 0) {
      // No channels enabled — let the cycle die. onChannelEnabled will
      // bootstrap a fresh self-heal next time a channel is enabled.
      await this.clear("mailbox_self_heal_task");
      console.log(
        `Gmail selfHealCheck [${this.id}]: no enabled channels, ending cycle`
      );
      return;
    }

    let unrecoverableError: unknown;
    let action: "healthy" | "renewed" | "recreated" | "missed_history" =
      "healthy";
    let missedThreads = 0;

    const webhook = await this.get<MailboxWebhookState>("mailbox_webhook");
    const incremental =
      await this.get<IncrementalState>("incremental_state");
    const lastWebhookAt = await this.get<string>(
      "last_webhook_received_at"
    );

    // 1. Catch any history we missed. Works even when the watch is broken
    //    because we're calling history.list directly, not waiting for a push.
    if (incremental?.historyId) {
      try {
        const api = await this.getApiAny();
        if (api) {
          const pending = incremental.pendingThreadIds ?? [];
          const result = await syncGmailMailboxIncremental(
            api,
            incremental.historyId,
            pending.map((p) => p.id)
          );
          if (result.expired) {
            // History window expired; reseed cursor (same fallback as
            // incrementalSyncBatch).
            if (webhook?.historyId) {
              await this.set("incremental_state", {
                historyId: webhook.historyId,
                lastSyncTime: now,
              });
            } else {
              await this.clear("incremental_state");
            }
            console.warn(
              `Gmail selfHealCheck [${this.id}]: history window expired, reseeded cursor`
            );
          } else {
            if (result.threads.length > 0) {
              missedThreads = result.threads.length;
              await this.processEmailThreads(result.threads, false);
              // Missed history while a watch existed = push delivery is
              // broken. Force a fresh watch setup below.
              action = "missed_history";
            }
            // Always advance the cursor and carry forward failed fetches so
            // we neither re-walk the whole window nor lose unfetched mail.
            await this.set("incremental_state", {
              historyId: result.historyId,
              lastSyncTime: now,
              pendingThreadIds: this.mergePendingThreads(
                pending,
                result.failedThreadIds
              ),
            });
          }
        }
      } catch (error) {
        // History check is best-effort; don't let it abort the rest of
        // self-heal — we still want to verify watch state.
        console.error(
          `Gmail selfHealCheck [${this.id}]: history check failed`,
          error
        );
      }
    }

    // 2. Verify watch state. Recreate if missing/expired/imminent-expiry.
    let needsReup = action === "missed_history";
    if (!webhook) {
      needsReup = true;
      if (action === "healthy") action = "recreated";
    } else {
      const expirationDate = new Date(webhook.expiration);
      const msToExpiry = expirationDate.getTime() - now.getTime();
      if (msToExpiry < 0) {
        needsReup = true;
        if (action === "healthy") action = "recreated";
        console.warn(
          `Gmail selfHealCheck [${this.id}]: watch expired ${-msToExpiry}ms ago`
        );
      } else if (msToExpiry < WATCH_PREEMPTIVE_RENEW_MS) {
        // <36h to expiry — preemptively renew (covers renewal alarm misses).
        needsReup = true;
        if (action === "healthy") action = "renewed";
      }
    }

    if (needsReup) {
      try {
        await this.setupMailboxWebhook();
      } catch (error) {
        // Setup failed permanently. Capture for PostHog by rethrowing AFTER
        // we've rescheduled the next self-heal run.
        unrecoverableError = error;
        console.error(
          `Gmail selfHealCheck [${this.id}]: setupMailboxWebhook failed`,
          error
        );
      }
    }

    // Heartbeat with resolved outcome so a single log line tells the full
    // story (action, thread count, watch state, push silence duration).
    console.log(`Gmail selfHealCheck [${this.id}]: ${action}`, {
      missedThreads,
      enabledChannels: Array.from(enabled),
      historyId: incremental?.historyId ?? null,
      watchTopic: webhook?.topicName ?? null,
      watchExpiration: webhook?.expiration
        ? new Date(webhook.expiration).toISOString()
        : null,
      lastWebhookAt: lastWebhookAt ?? null,
      minutesSinceLastWebhook: lastWebhookAt
        ? Math.round(
            (now.getTime() - new Date(lastWebhookAt).getTime()) / 60000
          )
        : null,
      now: now.toISOString(),
    });

    // 3. Always reschedule next run, even on failure, so a single error
    //    doesn't break the cycle. setupMailboxWebhook also schedules
    //    self-heal on success; scheduleSelfHealCheck cancels-and-replaces,
    //    so the duplicate scheduling is harmless.
    try {
      await this.scheduleSelfHealCheck();
    } catch (rescheduleError) {
      console.error(
        `Gmail selfHealCheck [${this.id}]: reschedule failed`,
        rescheduleError
      );
      if (!unrecoverableError) {
        unrecoverableError = rescheduleError;
      }
    }

    if (unrecoverableError) {
      throw unrecoverableError instanceof Error
        ? unrecoverableError
        : new Error(String(unrecoverableError));
    }
  }

  /**
   * (Re)schedules the next self-heal check. Cancels any existing task so
   * there's at most one outstanding self-heal task at a time. Idempotent:
   * safe to call from multiple bootstrap paths.
   */
  private async scheduleSelfHealCheck(): Promise<void> {
    const existing = await this.get<string>("mailbox_self_heal_task");
    if (existing) {
      try {
        await this.cancelTask(existing);
      } catch {
        // Task may have already executed.
      }
      await this.clear("mailbox_self_heal_task");
    }

    const callback = await this.callback(this.selfHealCheck);
    const taskToken = await this.runTask(callback, {
      runAt: new Date(Date.now() + SELF_HEAL_INTERVAL_MS),
    });
    if (taskToken) {
      await this.set("mailbox_self_heal_task", taskToken);
    }
  }

  /**
   * Per-channel initial backfill. Walks `users.threads.list?labelIds=<id>`
   * paginated and processes results. Used the FIRST time a channel is
   * enabled; ongoing changes flow through `incrementalSyncBatch` instead.
   */
  async initialSyncBatch(
    channelId: string,
    batchNumber: number
  ): Promise<void> {
    try {
      // Channel may have been disabled between scheduling and execution.
      if (!(await this.isChannelEnabled(channelId))) {
        await this.clear(`initial_state_${channelId}`);
        return;
      }

      const cursor = await this.get<InitialSyncState>(
        `initial_state_${channelId}`
      );
      if (!cursor) {
        // Already completed.
        return;
      }

      const token = await this.tools.integrations.get(channelId);
      if (!token) {
        console.warn(
          `Auth token missing for channel ${channelId} at initial batch ${batchNumber}, skipping`
        );
        return;
      }
      const api = new GmailApi(token.token);

      // Reuse the existing per-channel full-sync helper for label-scoped
      // pagination. We pass a shim SyncState matching its expectations.
      const syncState: SyncState = {
        channelId,
        pageToken: cursor.pageToken,
        lastSyncTime: cursor.lastSyncTime,
      };
      const result = await syncGmailChannel(api, syncState, 20);

      if (result.threads.length > 0) {
        // Initial backfill: every fetched thread is in this channel's label
        // (we asked Gmail for them by label), so route them all here.
        await this.processEmailThreads(result.threads, true, channelId);
      }

      if (result.hasMore) {
        await this.set<InitialSyncState>(`initial_state_${channelId}`, {
          pageToken: result.state.pageToken,
          lastSyncTime: result.state.lastSyncTime,
        });
        const next = await this.callback(
          this.initialSyncBatch,
          channelId,
          batchNumber + 1
        );
        await this.runTask(next);
      } else {
        // Backfill done. Drop the cursor and clear the "syncing…" UI.
        await this.clear(`initial_state_${channelId}`);
        await this.tools.integrations.channelSyncCompleted(channelId);
      }
    } catch (error) {
      console.error(
        `Error in initial sync batch ${batchNumber} for channel ${channelId}:`,
        error
      );
      throw error;
    }
  }

  /**
   * Mailbox-wide incremental sync. Triggered from a Pub/Sub webhook. Calls
   * Gmail's history.list with NO label filter so we see every change, then
   * routes each affected thread to whichever enabled channel(s) it actually
   * matches (based on its messages' labels). On 404 (history-window
   * expired), reseeds the cursor from the watch's current historyId — we
   * don't re-walk every label here, since label-scoped re-walks happen
   * via a fresh onChannelEnabled if needed.
   */
  async incrementalSyncBatch(): Promise<void> {
    try {
      const enabled = await this.getEnabledChannels();
      if (enabled.size === 0) return;

      const state = await this.get<IncrementalState>("incremental_state");
      if (!state?.historyId) {
        // Nothing to do — webhook will re-seed on next watch setup.
        return;
      }

      const api = await this.getApiAny();
      if (!api) {
        console.warn(
          "incrementalSyncBatch: no enabled channel to source auth from"
        );
        return;
      }

      const pending = state.pendingThreadIds ?? [];
      const result = await syncGmailMailboxIncremental(
        api,
        state.historyId,
        pending.map((p) => p.id)
      );
      if (result.expired) {
        // Recover by reseeding from the watch's most recent historyId.
        const webhook =
          await this.get<MailboxWebhookState>("mailbox_webhook");
        if (webhook?.historyId) {
          await this.set("incremental_state", {
            historyId: webhook.historyId,
            lastSyncTime: new Date(),
          });
        } else {
          await this.clear("incremental_state");
        }
        console.warn(
          "Gmail mailbox history expired; reseeded incremental cursor"
        );
        return;
      }

      if (result.threads.length > 0) {
        await this.processEmailThreads(result.threads, false);
      }

      // Advance the cursor, but carry forward any thread fetches that failed
      // so the next sync retries them — otherwise moving past them loses mail.
      await this.set("incremental_state", {
        historyId: result.historyId,
        lastSyncTime: new Date(),
        pendingThreadIds: this.mergePendingThreads(
          pending,
          result.failedThreadIds
        ),
      });
    } catch (error) {
      console.error("Error in Gmail incremental sync batch:", error);
      throw error;
    }
  }

  /**
   * Merges newly-failed thread fetches into the prior pending set, bumping a
   * per-thread attempt counter and dropping threads that have exhausted
   * {@link MAX_THREAD_FETCH_ATTEMPTS} retries (logged, since that change is
   * effectively lost). Threads that succeeded this round are simply absent
   * from `failedIds` and therefore fall out of the pending set.
   */
  private mergePendingThreads(
    prior: PendingThread[],
    failedIds: string[]
  ): PendingThread[] {
    const attemptsById = new Map(prior.map((p) => [p.id, p.attempts]));
    const merged: PendingThread[] = [];
    for (const id of failedIds) {
      const attempts = (attemptsById.get(id) ?? 0) + 1;
      if (attempts > MAX_THREAD_FETCH_ATTEMPTS) {
        console.error(
          `[gmail] giving up on thread ${id} after ${attempts - 1} failed fetch attempts; its change may be lost`
        );
        continue;
      }
      merged.push({ id, attempts });
    }
    return merged;
  }

  /**
   * Backwards-compatible shim for callbacks deployed under the old
   * per-channel sync architecture. New deploys should never produce this
   * callback; this exists so already-queued callbacks finish gracefully.
   */
  async syncBatch(
    _batchNumber: number,
    mode: "full" | "incremental",
    channelId: string,
    _initialSync?: boolean
  ): Promise<void> {
    if (mode === "full") {
      // Forward to the new per-channel initial backfill. Seed the cursor
      // so initialSyncBatch has something to read.
      const existing = await this.get<InitialSyncState>(
        `initial_state_${channelId}`
      );
      if (!existing) {
        await this.set<InitialSyncState>(`initial_state_${channelId}`, {});
      }
      await this.initialSyncBatch(channelId, 1);
      return;
    }
    // Old "incremental" callback — forward to mailbox-wide sync.
    await this.incrementalSyncBatch();
  }

  /**
   * Backwards-compatible shim for callbacks deployed under the old
   * per-channel webhook architecture. Forwards to mailbox-wide setup.
   */
  async setupChannelWebhook(_channelId: string): Promise<void> {
    await this.ensureMailboxWebhook();
  }

  /**
   * Backwards-compatible shim for old per-channel watch-renewal tasks.
   */
  async renewWatch(_channelId: string): Promise<void> {
    await this.renewMailboxWatch();
  }

  private async processEmailThreads(
    threads: GmailThread[],
    initialSync: boolean,
    forceChannelId?: string
  ): Promise<void> {
    // When forceChannelId is set we already know which channel owns these
    // threads (per-channel initial backfill). For mailbox-wide incremental
    // sync we pick a channel per thread by inspecting its message labels.
    const enabledChannels = forceChannelId
      ? new Set([forceChannelId])
      : await this.getEnabledChannels();
    if (enabledChannels.size === 0) return;

    // Pre-build all plot threads, then enrich every contact email across the
    // batch in one People API pass. Gmail headers don't carry avatars, so
    // without this every email-only contact lands with `avatar = undefined`
    // and shows initials forever.
    const transformed: {
      thread: GmailThread;
      plot: ReturnType<typeof transformGmailThread>;
      channelId: string;
    }[] = [];
    const allEmails = new Set<string>();
    for (const thread of threads) {
      const plot = transformGmailThread(thread);
      if (!plot.notes || plot.notes.length === 0) continue;

      const chosen =
        forceChannelId ?? pickChannelForThread(thread, enabledChannels);
      if (!chosen) continue; // Thread doesn't match any enabled channel.

      transformed.push({ thread, plot, channelId: chosen });
      for (const c of plot.accessContacts ?? []) {
        if (c && typeof c === "object" && "email" in c && c.email)
          allEmails.add(c.email);
      }
      for (const note of plot.notes) {
        const author = (note as { author?: { email?: string } }).author;
        if (author?.email) allEmails.add(author.email);
        const noteContacts = (note as { accessContacts?: Array<{ email?: string }> }).accessContacts;
        for (const c of noteContacts ?? []) {
          if (c?.email) allEmails.add(c.email);
        }
      }
    }

    if (allEmails.size > 0) {
      // Auth scope is per-account, not per-channel; any enabled channel ID
      // sources the same token.
      const authChannelId =
        forceChannelId ?? transformed[0]?.channelId ?? null;
      if (authChannelId) {
        try {
          const token = await this.tools.integrations.get(authChannelId);
          if (token) {
            await enrichLinkContactsFromGoogle(
              transformed.map((t) => t.plot),
              token.token,
              token.scopes,
            );
          }
        } catch (err) {
          // Enrichment is best-effort — Gravatar fallback in the client still
          // covers anyone the People API doesn't return.
          console.warn(
            "Failed to enrich Gmail contacts (non-blocking):",
            err
          );
        }
      }
    }

    for (const { thread, plot: plotThread, channelId } of transformed) {
      try {
        if (!plotThread.notes || plotThread.notes.length === 0) continue;

        // Cache message → channel mapping so downloadAttachment can look up
        // which channel owns a given Gmail message ID.
        for (const message of thread.messages ?? []) {
          await this.set(`gmail:msg-channel:${message.id}`, channelId);
        }

        // Filter out notes for messages we sent (dedup)
        const filtered = [];
        for (const note of plotThread.notes) {
          const noteKey = "key" in note ? (note as { key: string }).key : null;
          if (noteKey) {
            const wasSent = await this.get<boolean>(`sent:${noteKey}`);
            if (wasSent) {
              await this.clear(`sent:${noteKey}`);
              continue;
            }
          }
          filtered.push(note);
        }
        plotThread.notes = filtered;

        if (plotThread.notes.length === 0) continue;

        if (initialSync) {
          plotThread.unread = false;
          plotThread.archived = false;
        }

        // Inject channel ID for priority routing and sync metadata
        plotThread.channelId = channelId;
        plotThread.meta = {
          ...plotThread.meta,
          syncProvider: "google",
          syncableId: channelId,
        };

        // Star ↔ todo sync: detect star changes and update Plot todo status
        const isStarred = GmailApi.isStarred(thread);
        const isInInbox = thread.messages?.some((m) =>
          m.labelIds?.includes("INBOX")
        );
        // "Sent" is meaningful only when the thread isn't ALSO in the inbox
        // (e.g. self-CC, or recipient replied) — those should appear under
        // "inbox" so the user actions them like any other incoming thread.
        const isSentOnly = !isInInbox && thread.messages?.some((m) =>
          m.labelIds?.includes("SENT")
        );

        // Set status based on labels
        if (isStarred) {
          plotThread.status = "starred";
        } else if (isSentOnly) {
          // Plot-composed thread that just sent, or organic Gmail-sent
          // thread the user hasn't archived yet. Stays at "sent" until it
          // returns to inbox (reply) or the user archives it.
          plotThread.status = "sent";
        } else if (!isInInbox) {
          plotThread.status = "archived";
        } else {
          plotThread.status = "inbox";
        }

        // Save link directly via integrations
        const savedThreadId = await this.tools.integrations.saveLink(plotThread);
        if (!savedThreadId) continue; // Link was filtered (e.g., older than sync history) — skip star sync

        const wasStarred = await this.get<boolean>(`starred:${thread.id}`);

        // Echo suppression relies entirely on the `starred` state: when
        // Plot→Gmail writes STARRED, onThreadToDo/onLinkUpdated update this
        // state *before* the API call. The resulting Gmail webhook sees
        // isStarred === wasStarred and this branch doesn't run.
        if (isStarred !== !!wasStarred) {
          const actorId = await this.get<ActorId>("auth_actor_id");
          // Use the canonical Gmail thread URL as the source identifier
          const sourceUrl = `https://mail.google.com/mail/u/0/#inbox/${thread.id}`;
          if (actorId) {
            await this.tools.integrations.setThreadToDo(
              sourceUrl,
              actorId,
              isStarred
            );
            // Prevent the onThreadToDo callback from echoing back
            await this.set(`skip_todo_writeback:${thread.id}`, true);
          }
          await this.set(`starred:${thread.id}`, isStarred);
        }
      } catch (error) {
        console.error(`Failed to process Gmail thread ${thread.id}:`, error);
        // Continue processing other threads
      }
    }
  }

  async onNoteCreated(
    note: Note,
    thread: Thread
  ): Promise<NoteWriteBackResult | void> {
    const meta = thread.meta ?? {};
    const channelId = (meta.channelId ?? meta.syncableId) as string;
    if (!channelId) {
      console.error("No channelId in meta for Gmail reply");
      return;
    }

    const threadId = meta.threadId as string;
    if (!threadId) {
      console.error("No threadId in meta for Gmail reply");
      return;
    }

    // Idempotency: a callback may be re-dispatched after its send already
    // succeeded (e.g. the response was lost), which would send a duplicate
    // reply. `note.id` is stable across retries of the same note, so a guard
    // keyed on it suppresses the resend and returns the original message key.
    const sendGuardKey = `send_note:${note.id}`;
    const priorSend = await this.get<{ messageId: string }>(sendGuardKey);
    if (priorSend?.messageId) {
      console.log(
        `[gmail] onNoteCreated: note ${note.id} already sent as ${priorSend.messageId}, skipping resend`
      );
      return { key: priorSend.messageId };
    }

    const api = await this.getApi(channelId);

    // Fetch the full Gmail thread to get message headers
    const gmailThread = await api.getThread(threadId);
    if (!gmailThread.messages || gmailThread.messages.length === 0) {
      console.error("Gmail thread has no messages");
      return;
    }

    // Determine target message: specific replied-to note or last message in thread
    let targetMessage = gmailThread.messages[gmailThread.messages.length - 1];
    if (meta.reNoteKey) {
      const found = gmailThread.messages.find(
        (m) => m.id === meta.reNoteKey
      );
      if (found) {
        targetMessage = found;
      }
    }

    // Extract headers from target message
    const messageId = getHeader(targetMessage, "Message-ID");
    const references = getHeader(targetMessage, "References");
    const subject = getHeader(targetMessage, "Subject") ?? "Email";
    const fromHeader = getHeader(targetMessage, "From");
    const toHeader = getHeader(targetMessage, "To");
    const ccHeader = getHeader(targetMessage, "Cc");

    if (!messageId) {
      console.error("Target message has no Message-ID header");
      return;
    }

    // Get sender's email to exclude from reply-all recipients
    const profile = await api.getProfile();
    const senderEmail = profile.emailAddress.toLowerCase();

    // Build per-note access constraint: when note.accessContacts is set, resolve
    // contact IDs to lowercase email addresses using thread.accessContacts so we
    // can filter the outbound recipient list. null means no constraint (send to all).
    //
    // This implements the design rule: a note with accessContacts = [self] is a
    // Private note and must not be sent via Gmail at all.
    let accessContactEmails: Set<string> | null = null;
    if (note.accessContacts !== null) {
      const allowedIds = new Set<ActorId>(note.accessContacts);
      accessContactEmails = new Set<string>();
      for (const contact of thread.accessContacts ?? []) {
        if (allowedIds.has(contact.id) && contact.email) {
          accessContactEmails.add(contact.email.toLowerCase());
        }
      }
    }

    // Build reply-all candidates: all From + To + Cc, deduplicated
    const allCandidates = new Set<string>();
    for (const email of parseEmailAddresses(fromHeader)) {
      allCandidates.add(email.toLowerCase());
    }
    for (const email of parseEmailAddresses(toHeader)) {
      allCandidates.add(email.toLowerCase());
    }

    const ccCandidates = new Set<string>();
    for (const email of parseEmailAddresses(ccHeader)) {
      ccCandidates.add(email.toLowerCase());
    }

    // To = all direct recipients (From + To), Cc = remaining Cc.
    // Apply the per-note access constraint (and always exclude sender).
    const toCandidates = Array.from(allCandidates).filter(
      (email) => !ccCandidates.has(email)
    );
    const to = recipientsFor({
      accessContactEmails,
      candidates: toCandidates,
      self: senderEmail,
    });
    const cc = recipientsFor({
      accessContactEmails,
      candidates: Array.from(ccCandidates),
      self: senderEmail,
    });

    if (to.length === 0 && cc.length === 0) {
      if (note.accessContacts !== null) {
        // Private note or custom subset that excluded everyone — do not send.
        console.log(
          `[gmail] onNoteCreated: note ${note.id} has access_contacts constraint with no outbound recipients; skipping send`
        );
      } else {
        console.error("No recipients for Gmail reply");
      }
      return;
    }

    // Collect file attachments from note actions
    const attachments: AttachmentData[] = [];
    for (const action of note.actions ?? []) {
      if (action.type === ActionType.file) {
        try {
          const file = await this.tools.files.read(action.fileId);
          attachments.push({
            fileName: file.fileName,
            mimeType: file.mimeType,
            data: file.data,
          });
        } catch (err) {
          console.error(
            `[gmail] onNoteCreated: failed to read file ${action.fileId}:`,
            err
          );
          // Skip this attachment rather than failing the whole send
        }
      }
    }

    // Build and send the reply (with attachments if any)
    const raw = buildReplyMessage({
      to,
      cc,
      from: senderEmail,
      subject,
      body: note.content ?? "",
      messageId,
      references: references ?? "",
      attachments: attachments.length > 0 ? attachments : undefined,
    });

    const result = await api.sendMessage(raw, threadId);

    // Record the idempotency guard so a retried dispatch of this note does
    // not send a second copy (see the guard check above).
    await this.set(sendGuardKey, { messageId: result.id });

    // Store sent message ID for dedup when synced back
    await this.set(`sent:${result.id}`, true);

    // Return the Gmail message id as the note key so the runtime links this
    // Plot note to the sent message. We intentionally do NOT provide
    // `externalContent`: Gmail does not return the normalized message body
    // from `send`, and fetching + parsing the multipart payload just to
    // compute a baseline is expensive. The first incremental sync-in of the
    // sent message will establish the baseline naturally (runtime records
    // the stored content as the baseline on first external ingest).
    return { key: result.id };
  }

  async onThreadRead(
    thread: Thread,
    _actor: Actor,
    unread: boolean
  ): Promise<void> {
    const meta = thread.meta ?? {};
    const channelId = (meta.channelId ?? meta.syncableId) as string;
    if (!channelId) return;

    const threadId = meta.threadId as string;
    if (!threadId) return;

    const api = await this.getApi(channelId);

    if (unread) {
      await api.modifyThread(threadId, ["UNREAD"]);
    } else {
      await api.modifyThread(threadId, undefined, ["UNREAD"]);
    }
  }

  async onThreadToDo(
    thread: Thread,
    _actor: Actor,
    todo: boolean,
    _options: { date?: Date }
  ): Promise<void> {
    const meta = thread.meta ?? {};
    const threadId = meta.threadId as string;
    const channelId = (meta.channelId ?? meta.syncableId) as string;
    if (!threadId || !channelId) return;

    // Loop prevention: skip if this change originated from Gmail star sync
    if (await this.get(`skip_todo_writeback:${threadId}`)) {
      await this.clear(`skip_todo_writeback:${threadId}`);
      return;
    }

    // Update local state BEFORE calling Gmail, so the webhook fired by our
    // own write sees isStarred === wasStarred and doesn't re-propagate.
    await this.set(`starred:${threadId}`, todo);

    const api = await this.getApi(channelId);
    if (todo) {
      // Add STARRED, and re-add INBOX so an archived email returns to the
      // inbox when the user adds it to their agenda in Plot.
      await api.modifyThread(threadId, ["STARRED", "INBOX"]);
    } else {
      await api.modifyThread(threadId, undefined, ["STARRED"]);
    }
  }

  async onLinkUpdated(link: Link): Promise<void> {
    const threadId = link.meta?.threadId as string | undefined;
    const channelId = (link.meta?.channelId ?? link.meta?.syncableId) as
      | string
      | undefined;
    if (!threadId || !channelId) return;

    // Loop prevention: skip if this change originated from Gmail star sync
    if (await this.get(`skip_todo_writeback:${threadId}`)) {
      await this.clear(`skip_todo_writeback:${threadId}`);
      return;
    }

    const status = link.status;

    // Update local state BEFORE calling Gmail, so the webhook fired by our
    // own write sees isStarred === wasStarred and doesn't re-propagate.
    await this.set(`starred:${threadId}`, status === "starred");

    const api = await this.getApi(channelId);

    if (status === "starred") {
      await api.modifyThread(threadId, ["STARRED"]);
    } else if (status === "archived") {
      // Archive = remove from INBOX. Also unstar.
      await api.modifyThread(threadId, undefined, ["INBOX", "STARRED"]);
    } else if (status === "inbox") {
      // Back to inbox, unstar.
      await api.modifyThread(threadId, ["INBOX"], ["STARRED"]);
    }
  }

  /**
   * Creates a new outbound email from Plot.
   *
   * For the `email` link type's `compose.targets: "addresses"`, the runtime
   * fills `draft.recipients` from the connection-scoped
   * `contact_external_account` rows and falls back to `contact.email` for
   * any picked contact without a row. Free-form addresses the user typed in
   * arrive via `draft.inviteEmails`. The connector merges, dedupes, and
   * splits recipients into To/Cc/Bcc using each recipient's `role` (so BCC
   * recipients stay out of the visible To/Cc headers).
   *
   * The returned `NewLinkWithNotes`'s `meta` matches what `onNoteCreated`
   * reads so replies work with zero extra wiring.
   */
  override async onCreateLink(
    draft: CreateLinkDraft
  ): Promise<NewLinkWithNotes | null> {
    if (draft.type !== "email") return null;

    // Split recipients into To/Cc/Bcc by their thread role so CC/BCC
    // recipients are addressed correctly — and, critically, so BCC
    // recipients are never placed in the To: header where the other
    // recipients would see them (privacy leak). The `email` link type
    // declares `to`/`cc`/`bcc` roles (with `bcc` hidden); the runtime
    // resolves each contact's role from the thread's contact_meta into
    // `recipient.role`. A null role means the contact had no explicit
    // role entry, so it defaults to To. Free-form typed addresses
    // (`inviteEmails`) carry no contact role and likewise default to To.
    const seenEmails = new Set<string>();
    const toEmails: string[] = [];
    const ccEmails: string[] = [];
    const bccEmails: string[] = [];
    const addRecipient = (
      raw: string | null | undefined,
      role: string | null
    ) => {
      if (!raw) return;
      const trimmed = raw.trim();
      if (!trimmed) return;
      const key = trimmed.toLowerCase();
      if (seenEmails.has(key)) return;
      seenEmails.add(key);
      if (role === "cc") ccEmails.push(trimmed);
      else if (role === "bcc") bccEmails.push(trimmed);
      else toEmails.push(trimmed);
    };

    for (const r of draft.recipients ?? []) addRecipient(r.externalAccountId, r.role);
    for (const email of draft.inviteEmails ?? []) addRecipient(email, null);

    if (toEmails.length + ccEmails.length + bccEmails.length === 0) {
      console.error(
        "[gmail] onCreateLink: no email recipients could be derived from draft"
      );
      return null;
    }

    // Get sender's email address.
    const api = await this.getApiAny();
    if (!api) {
      console.error("[gmail] onCreateLink: no enabled channel to source auth from");
      return null;
    }

    const profile = await api.getProfile();
    const fromEmail = profile.emailAddress;

    const subject = draft.title || "";
    const body = draft.noteContent ?? "";

    // channelId: use the first enabled channel so onNoteCreated (reply path)
    // can resolve the OAuth token via getApi(channelId).
    const enabledChannels = await this.getEnabledChannels();
    const channelId = [...enabledChannels][0] ?? "";

    // Build the link the runtime wires to the originating thread. Shared
    // between the normal send and the dedup-hit path so a retried dispatch
    // returns an identical link.
    const linkFor = (gmailThreadId: string): NewLinkWithNotes => {
      const canonicalUrl = `https://mail.google.com/mail/u/0/#inbox/${gmailThreadId}`;
      return {
        source: canonicalUrl,
        type: "email",
        title: subject || undefined,
        status: draft.status,
        created: new Date(),
        sourceUrl: canonicalUrl,
        channelId,
        meta: {
          syncProvider: "google",
          syncableId: channelId,
          channelId,
          threadId: gmailThreadId,
          historyId: null,
        },
      };
    };

    // Idempotency: a compose draft carries no stable id, so dedupe on a hash
    // of its content. A second dispatch with identical content within
    // COMPOSE_DEDUP_WINDOW_MS is treated as a callback retry whose send
    // already succeeded — return the prior link instead of sending again.
    const dedupKey = `compose:${fnv1aHex(
      JSON.stringify([
        draft.type,
        draft.status,
        subject,
        body,
        [...toEmails].sort(),
        [...ccEmails].sort(),
        [...bccEmails].sort(),
      ])
    )}`;
    const prior = await this.get<{
      gmailThreadId: string;
      at: number;
    }>(dedupKey);
    if (prior?.gmailThreadId && Date.now() - prior.at < COMPOSE_DEDUP_WINDOW_MS) {
      console.log(
        `[gmail] onCreateLink: duplicate compose dispatch within ${COMPOSE_DEDUP_WINDOW_MS}ms, reusing thread ${prior.gmailThreadId}`
      );
      return linkFor(prior.gmailThreadId);
    }

    const raw = buildNewEmailMessage({
      to: toEmails,
      cc: ccEmails,
      bcc: bccEmails,
      from: fromEmail,
      subject,
      body,
    });

    const result = await api.sendNewMessage(raw);
    const gmailThreadId = result.threadId;
    const gmailMessageId = result.id;

    // Record the idempotency guard so a retried dispatch reuses this send
    // rather than emitting a duplicate email.
    await this.set(dedupKey, { gmailThreadId, at: Date.now() });

    // Suppress the echo when this sent message is synced back via Gmail's
    // incremental history. The message id is the note key the sync path
    // uses (same as onNoteCreated dedup).
    await this.set(`sent:${gmailMessageId}`, true);

    // Bind the opening note to this sent message — the bare message id, same
    // key onNoteCreated returns for a reply and sync-in uses. No
    // externalContent: Gmail's send doesn't return the stored body (same
    // tradeoff as onNoteCreated), and the sent message is echo-suppressed
    // above, so no baseline round-trip is needed.
    return { ...linkFor(gmailThreadId), originatingNote: { key: gmailMessageId } };
  }

  /**
   * Pub/Sub webhook handler. Single mailbox-wide watch → single handler.
   * Decodes Gmail's history-id notification and queues a mailbox-incremental
   * sync as a separate task so this handler returns quickly to Pub/Sub.
   *
   * The optional `_channelId` argument exists for backwards compatibility
   * with already-deployed per-channel webhook callbacks (which were
   * registered with `extraArgs: [channelId]`). The new mailbox-wide watch
   * registers without extraArgs, so newer deploys never pass a channelId.
   */
  async onGmailWebhook(
    request: WebhookRequest,
    _channelId?: string
  ): Promise<void> {
    // Record receipt before any early returns so `selfHealCheck` can
    // distinguish "watch is healthy, just no new mail" from "we haven't
    // heard from Gmail in hours". This is the only signal the connector has
    // that push delivery is working.
    await this.set("last_webhook_received_at", new Date().toISOString());

    // Self-heal bootstrap: ensures upgrades from versions without self-heal
    // start the cycle on the first push after deploy. Idempotent — skipped
    // if a task is already scheduled.
    const selfHealTask = await this.get<string>("mailbox_self_heal_task");
    if (!selfHealTask) {
      try {
        await this.scheduleSelfHealCheck();
      } catch (error) {
        console.error(
          `Gmail onGmailWebhook [${this.id}]: failed to bootstrap self-heal`,
          error
        );
      }
    }

    const body = request.body as { message?: { data: string } };
    const message = body?.message;
    if (!message) {
      console.warn(`Gmail onGmailWebhook [${this.id}]: no message in body`);
      return;
    }

    let data: { historyId?: string; emailAddress?: string };
    try {
      const decoded = atob(message.data);
      data = JSON.parse(decoded);
    } catch (error) {
      console.error(
        `Gmail onGmailWebhook [${this.id}]: failed to decode message`,
        error
      );
      return;
    }

    if (!data.historyId) return;

    // Renew the watch if its expiration has passed.
    const webhook = await this.get<MailboxWebhookState>("mailbox_webhook");
    if (webhook?.expiration && new Date(webhook.expiration) < new Date()) {
      await this.renewMailboxWatch();
    }

    // Make sure incremental_state exists (carries our last-acknowledged
    // historyId). If we somehow lost it, seed from the webhook's historyId
    // — we'll miss anything that happened between teardown and now, but
    // that's strictly bounded.
    const existing = await this.get<{ historyId?: string }>(
      "incremental_state"
    );
    if (!existing?.historyId) {
      await this.set("incremental_state", {
        historyId: data.historyId,
        lastSyncTime: new Date(),
      });
    }

    const callback = await this.callback(this.incrementalSyncBatch);
    await this.runTask(callback);
  }

  // Helpers ------------------------------------------------------------------

  /** Returns the set of channelIds the user currently has enabled. */
  private async getEnabledChannels(): Promise<Set<string>> {
    const list = (await this.get<string[]>("enabled_channels")) ?? [];
    return new Set(list);
  }

  /** Add a channelId to the enabled set (idempotent, preserves order). */
  private async addEnabledChannel(channelId: string): Promise<void> {
    const list = (await this.get<string[]>("enabled_channels")) ?? [];
    if (list.includes(channelId)) return;
    list.push(channelId);
    await this.set("enabled_channels", list);
  }

  /** Remove a channelId from the enabled set. */
  private async removeEnabledChannel(channelId: string): Promise<void> {
    const list = (await this.get<string[]>("enabled_channels")) ?? [];
    const filtered = list.filter((c) => c !== channelId);
    if (filtered.length === list.length) return;
    await this.set("enabled_channels", filtered);
  }

  /** Whether a channel is currently enabled. */
  private async isChannelEnabled(channelId: string): Promise<boolean> {
    const list = (await this.get<string[]>("enabled_channels")) ?? [];
    return list.includes(channelId);
  }

  /**
   * Returns a Gmail API client authed with any enabled channel's token.
   * Auth is per-Google-account (not per-label), so any enabled channelId
   * resolves to the same OAuth credential.
   */
  private async getApiAny(): Promise<GmailApi | null> {
    const enabled = await this.getEnabledChannels();
    for (const channelId of enabled) {
      const token = await this.tools.integrations.get(channelId);
      if (token?.token) return new GmailApi(token.token);
    }
    return null;
  }

  /**
   * Finds the channelId that owns a given Gmail message.
   *
   * Strategy:
   * 1. Check the store cache populated during inbound sync (fast path).
   * 2. On cache miss, probe each enabled channel by fetching the message with
   *    format=minimal; the first channel whose token can retrieve it wins.
   *    Cache the result for future calls.
   *
   * Returns null if no channel owns the message (e.g., the channel was
   * disabled, or the message predates the sync window).
   */
  private async findChannelForMessage(messageId: string): Promise<string | null> {
    // Fast path: check store cache
    const cached = await this.get<string>(`gmail:msg-channel:${messageId}`);
    if (cached) return cached;

    // Slow path: probe enabled channels
    const enabled = await this.getEnabledChannels();
    for (const channelId of enabled) {
      try {
        const token = await this.tools.integrations.get(channelId);
        if (!token?.token) continue;
        const api = new GmailApi(token.token);
        // Probe with minimal format (just confirms the message exists for this auth)
        await api.call(`/messages/${messageId}`, { params: { format: "minimal" } });
        // Found it — cache and return
        await this.set(`gmail:msg-channel:${messageId}`, channelId);
        return channelId;
      } catch {
        // This channel can't access the message — try next
      }
    }
    return null;
  }

  /**
   * Downloads an attachment from Gmail identified by the opaque `ref` string
   * emitted during inbound sync. The ref format is `${messageId}:${attachmentId}`.
   */
  override async downloadAttachment(ref: string): Promise<
    | { redirectUrl: string }
    | { body: Uint8Array; mimeType: string; fileName?: string }
  > {
    const colon = ref.indexOf(":");
    if (colon < 0) {
      throw new Error(`Invalid Gmail attachment ref: ${ref}`);
    }
    const messageId = ref.slice(0, colon);
    const attachmentId = ref.slice(colon + 1);

    const channelId = await this.findChannelForMessage(messageId);
    if (!channelId) {
      throw new Error(
        `No Gmail channel found for message ${messageId}. ` +
        `The channel may have been disabled or the message is outside the sync window. ` +
        `Try refreshing the Gmail connection.`
      );
    }

    const api = await this.getApi(channelId);
    const att = await api.getAttachment(messageId, attachmentId);

    // Gmail returns base64url-encoded data
    const b64 = (att.data ?? "").replace(/-/g, "+").replace(/_/g, "/");
    const padded = b64.padEnd(Math.ceil(b64.length / 4) * 4, "=");
    const binary = atob(padded);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }

    return {
      body: bytes,
      // Real MIME type comes from the fileRef action stored on the note.
      // We return a fallback here; the runtime uses the action's mimeType for
      // the Content-Type response header.
      mimeType: "application/octet-stream",
    };
  }
}

/**
 * Pick which enabled channel a thread should be filed under, based on the
 * labels carried by its messages. Selection precedence (most specific first):
 *
 *   1. Custom (user-defined) labels — alphabetically.
 *   2. STARRED → IMPORTANT → INBOX → SENT → DRAFT (system labels).
 *
 * Returns null if no enabled channel matches the thread (the thread came in
 * via mailbox-wide history but doesn't belong to any channel the user wants).
 *
 * Custom labels in Gmail use IDs like `Label_14`. We treat anything not in
 * the system-label list above as "custom", which matches getChannels()'s
 * own filter.
 */
function pickChannelForThread(
  thread: GmailThread,
  enabledChannels: Set<string>
): string | null {
  // Collect every label that appears on any message in the thread.
  const threadLabels = new Set<string>();
  for (const m of thread.messages ?? []) {
    for (const l of m.labelIds ?? []) threadLabels.add(l);
  }

  // Custom labels first, alphabetical for stability.
  const customMatches: string[] = [];
  for (const enabled of enabledChannels) {
    if (SYSTEM_LABEL_ORDER.includes(enabled)) continue;
    if (threadLabels.has(enabled)) customMatches.push(enabled);
  }
  if (customMatches.length > 0) {
    customMatches.sort();
    return customMatches[0];
  }

  // System labels in fixed precedence order.
  for (const label of SYSTEM_LABEL_ORDER) {
    if (enabledChannels.has(label) && threadLabels.has(label)) return label;
  }

  return null;
}

export default Gmail;
