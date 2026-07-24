/**
 * Reusable Outlook Mail sync functions extracted from the Outlook Mail
 * connector.
 *
 * These functions implement the mailbox-wide Graph change-notification
 * subscription lifecycle, the per-folder initial backfill, the delta-query
 * self-heal sweep, the mailbox-wide incremental sync, the outbound send paths
 * (reply / compose), and the two-way read/flag sync — without any
 * connector-level scheduling. They accept an {@link OutlookMailSyncHost}
 * instead of `this` so they can be invoked from both the standalone Outlook
 * Mail connector and a future combined Outlook connector (which wraps `this`
 * in a key-namespaced host).
 *
 * Scheduler operations (this.callback / this.runTask / this.scheduleRecurring /
 * this.cancelScheduledTask) are intentionally NOT performed inline. Where a
 * function genuinely needs to schedule work or create a callback, it does so
 * through `host.scheduler.*` — a thin set of bound references back to the
 * concrete connector's spied instance methods — or it returns a descriptor and
 * lets the caller own the scheduling (mirrors the Google connector's src/mail).
 */

import {
  type Addressee,
  baseEmail,
  canonicalizeEmail,
  type CreateLinkDraft,
  type NoteWriteBackResult,
  resolveOutboundReplyRecipients,
} from "@plotday/twister";
import { ActionType } from "@plotday/twister/plot";
import type {
  Actor,
  ActorId,
  NewLinkWithNotes,
  Note,
  Thread,
} from "@plotday/twister/plot";
import type { WebhookRequest } from "@plotday/twister/tools/network";
import type { Cta } from "@plotday/twister/facets";
import { markdownToHtml } from "@plotday/twister/utils/markdown-html";

import { enrichLinkContactsFromOutlook } from "./enrich";
import {
  EXCLUDED_WELL_KNOWN,
  GraphMailApi,
  GraphMailApiError,
  classifyOutlookCalendar,
  conversationSource,
  isConversationFlagged,
  isConversationUnread,
  recipientEmails,
  sortConversation,
  transformOutlookConversation,
  type GraphAttachmentMeta,
  type GraphHeader,
  type GraphMessage,
  type WellKnownFolders,
} from "./graph-mail-api";
import { outlookFacets } from "./outlook-facets";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/**
 * How often `selfHealCheck` runs while at least one channel is enabled.
 * Mirrors the Gmail connector's cadence: fast enough that a broken
 * subscription or missed notification is recovered within an hour, slow
 * enough to keep Graph API load negligible.
 */
export const SELF_HEAL_INTERVAL_MS = 60 * 60 * 1000;

/**
 * If the subscription is within this window of expiry, `selfHealCheck`
 * re-establishes it preemptively rather than relying on the durable
 * renewal task alone (which can be delayed by deploy/eviction). 36h gives
 * the renewal task its scheduled run plus a safety margin.
 */
export const SUB_PREEMPTIVE_RENEW_MS = 36 * 60 * 60 * 1000;

/** Renew the Graph subscription this far before expiry. */
export const RENEWAL_LEAD_MS = 24 * 60 * 60 * 1000;

/**
 * Graph caps Outlook-resource subscriptions at a few days; 3 days is the
 * value outlook-calendar has run in production, safely under every
 * documented cap.
 */
export const SUBSCRIPTION_DURATION_DAYS = 3;

/** Max times we re-attempt a failing message fetch before giving up. */
export const MAX_MESSAGE_FETCH_ATTEMPTS = 5;

/**
 * Max notified messages probed (and their conversations fetched) per
 * incremental drain pass. Graph sends one change notification per message;
 * an unbounded pass loaded every notified conversation into one worker at
 * once. Overflow stays in the per-message pending keys (see
 * {@link PENDING_MSG_PREFIX}) and drains on a scheduled continuation.
 */
export const MAX_INCREMENTAL_MESSAGES_PER_BATCH = 20;

/**
 * Delay before a webhook-triggered incremental drain runs. The drain is
 * scheduled as a keyed coalescing task, so a burst of Graph notifications
 * collapses into one pass that fires at most this long after the first.
 */
export const INCREMENTAL_SYNC_COALESCE_MS = 10_000;

/** Task key for the coalesced incremental drain. */
export const INCREMENTAL_SYNC_TASK_KEY = "mailbox-incremental-sync";

/**
 * Store-key prefix for notified-but-not-yet-ingested message ids. Each id
 * lives under its own key (value: failed-fetch attempt count), so concurrent
 * webhook deliveries and an in-flight drain can never lose ids to a
 * read-modify-write race on shared state; keys are deleted only after the
 * message's conversation is ingested.
 */
export const PENDING_MSG_PREFIX = "pending_msg:";

/**
 * Page cap per folder per self-heal delta sweep. A walk that exceeds the
 * cap stores its nextLink and resumes on the next cycle, bounding the work
 * any single self-heal run can do.
 */
export const MAX_DELTA_PAGES_PER_HEAL = 20;

/**
 * Idempotency window for `onCreateLink`. A compose draft carries no stable
 * id, so we dedupe by a content hash; two dispatches with identical content
 * within this window are treated as a callback retry (suppress the resend),
 * while a genuine re-compose later than this still sends.
 */
export const COMPOSE_DEDUP_WINDOW_MS = 10 * 60 * 1000;

/** Direct fileAttachment POST limit; larger files go via upload session. */
export const DIRECT_ATTACH_MAX_BYTES = 3 * 1024 * 1024;

// ---------------------------------------------------------------------------
// Persisted state shapes (shared with the connector)
// ---------------------------------------------------------------------------

/**
 * A message whose probe/fetch failed during an incremental sync and must be
 * re-attempted on a later sync. `attempts` bounds retries so a permanently
 * unfetchable message is eventually abandoned with a log line rather than
 * re-fetched forever.
 */
export type PendingMessage = { id: string; attempts: number };

/** Persisted mailbox-wide Graph subscription state. */
export type SubscriptionState = {
  subscriptionId: string;
  /** Random secret echoed back in every notification — Graph's only
   * notification-authenticity signal. Verified in the webhook handler. */
  clientState: string;
  /** Webhook callback URL (deleted on teardown to free the token). */
  webhookUrl: string;
  expiration: Date;
  created: string;
};

/** Persisted incremental retry state (notified ids whose fetch failed). */
export type IncrementalState = { pendingMessageIds?: PendingMessage[] };

/** Persisted per-channel initial-backfill cursor. */
export type InitialSyncState = { nextLink?: string | null; lastSyncTime?: Date };

/** Per-folder delta cursor: nextLink mid-walk or deltaLink at rest. */
export type DeltaState = { url: string };

type ConversationItem = {
  messages: GraphMessage[];
  attachmentsByMessageId: Map<string, GraphAttachmentMeta[]>;
  parentHeaders: GraphHeader[] | null;
};

// ---------------------------------------------------------------------------
// Host interface
// ---------------------------------------------------------------------------

/**
 * Minimal interface that an Outlook Mail sync host must satisfy. Both
 * OutlookMail (using `this` directly via public wrappers) and a future
 * combined Outlook connector (using a key-namespaced host) implement this.
 *
 * `scheduler` carries the operations that CANNOT be extracted — creating
 * callbacks and scheduling/cancelling tasks live on the concrete connector
 * (they reference its own callback methods and durable-task keys). Extracted
 * functions invoke them through these bound references so the connector stays
 * the single owner of scheduling.
 */
export interface OutlookMailSyncHost {
  /** The twist-instance id, used purely for log context. */
  readonly id: string;

  /** Persist a value under a connector-scoped key. */
  set(key: string, value: unknown): Promise<void>;
  /** Persist many key/value pairs in one round-trip (bulk upsert). */
  setMany(entries: [key: string, value: unknown][]): Promise<void>;
  /** Retrieve a previously persisted value. Returns null if absent. */
  get<T>(key: string): Promise<T | null>;
  /** Delete a persisted value. */
  clear(key: string): Promise<void>;

  tools: {
    integrations: {
      /** Read the OAuth token for a channel. */
      get(
        channelId: string
      ): Promise<{ token: string; scopes: string[] } | null>;
      /** Persist a link (upsert by source). Returns the saved thread id (or null if filtered). */
      saveLink(link: NewLinkWithNotes): Promise<string | null>;
      /** Signal that the initial backfill for a channel has finished. */
      channelSyncCompleted(channelId: string): Promise<void>;
      /** Set a thread's to-do (flagged) state from the connector's own write. */
      setThreadToDo(
        source: string,
        actorId: ActorId,
        todo: boolean
      ): Promise<void>;
    };
    files: {
      /** Read a file referenced by a note action (for outbound attachments). */
      read(fileId: string): Promise<{
        data: Uint8Array;
        fileName: string;
        mimeType: string;
        fileSize: number;
      }>;
    };
    network: {
      /** Create the mailbox-wide Graph change-notification webhook. */
      createWebhook(
        options: { async: boolean },
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        callback: any
      ): Promise<string>;
      /** Delete a previously-created webhook/token. */
      deleteWebhook(url: string): Promise<void>;
    };
    store: {
      /** Try to acquire a named lock. Returns true if acquired. */
      acquireLock(key: string, ttlMs: number): Promise<boolean>;
      /** Release a named lock. */
      releaseLock(key: string): Promise<void>;
      /** List all persisted keys that start with the given prefix. */
      list(prefix: string): Promise<string[]>;
    };
  };

  /**
   * Scheduler boundary — operations that must stay on the concrete connector.
   * These route to the connector's own (spied-in-tests) instance methods, so
   * extracting the logic that calls them does not move scheduling off the
   * connector.
   */
  scheduler: {
    /** The connector callback handed to `network.createWebhook`. */
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    onOutlookMailWebhook: any;
    /** Idempotently (re)establish the mailbox subscription + webhook. */
    setupMailboxSubscription(): Promise<void>;
    /** Renew the Graph subscription before expiry. */
    renewMailboxSubscription(): Promise<void>;
    /** (Re)schedule the durable subscription-renewal recurring task. */
    scheduleMailboxRenewal(expiration: Date): Promise<void>;
    /** (Re)schedule the durable mailbox-self-heal recurring task. */
    scheduleSelfHealCheck(): Promise<void>;
    /** Cancel a durable recurring task by key. */
    cancelScheduledTask(key: string): Promise<void>;
    /**
     * Record notified message ids and schedule the coalesced incremental
     * drain via the platform's `scheduleDrain` primitive (the connector owns
     * the call so the handler is one of its own methods). A burst of calls
     * collapses into one pending pass; ids persist durably until drained.
     */
    scheduleDrain(messageIds: string[]): Promise<void>;
    /** Queue a subscription renewal (lifecycle-notification response). */
    queueRenewSubscription(): Promise<void>;
    /**
     * Re-queue a fresh full backfill of one folder, dropping stale cursors.
     * Routes to the connector's own (spied-in-tests) method, which performs
     * the cursor reset AND schedules the first initial batch.
     */
    requeueInitialSync(channelId: string): Promise<void>;
  };
}

// ---------------------------------------------------------------------------
// Pure helpers (no host state)
// ---------------------------------------------------------------------------

/**
 * FNV-1a 32-bit hash → 8-char hex. Deterministic and dependency-free; used
 * only to derive a compact idempotency key from compose-draft content, not
 * for anything security-sensitive.
 */
export function fnv1aHex(input: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < input.length; i++) {
    h ^= input.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return (h >>> 0).toString(16).padStart(8, "0");
}

/**
 * Pick which enabled channel (folder) a conversation files under. Custom
 * folders are most specific so they win (alphabetical for stability); then
 * inbox; then sentitems; then archive. Returns null when no enabled folder
 * holds any of the conversation's messages (a mailbox-wide change that's
 * irrelevant to the enabled channels — skipped, same as gmail's
 * pickChannelForThread).
 */
export function pickChannelForConversation(
  messages: GraphMessage[],
  enabledChannels: Set<string>,
  wellKnown: WellKnownFolders
): string | null {
  const folders = new Set<string>();
  for (const m of messages) {
    if (m.parentFolderId) folders.add(m.parentFolderId);
  }
  const system = new Set(
    [wellKnown.inbox, wellKnown.sentitems, wellKnown.archive].filter(
      Boolean
    ) as string[]
  );
  const customMatches = [...enabledChannels]
    .filter((id) => !system.has(id) && folders.has(id))
    .sort();
  if (customMatches.length > 0) return customMatches[0];
  for (const id of [wellKnown.inbox, wellKnown.sentitems, wellKnown.archive]) {
    if (id && enabledChannels.has(id) && folders.has(id)) return id;
  }
  return null;
}

/** Standard-base64 encode (chunked to avoid call-stack limits on big files). */
function uint8ToBase64(bytes: Uint8Array): string {
  const CHUNK = 32768;
  let binary = "";
  for (let i = 0; i < bytes.length; i += CHUNK) {
    const slice = bytes.subarray(i, i + CHUNK);
    for (let j = 0; j < slice.length; j++) {
      binary += String.fromCharCode(slice[j]);
    }
  }
  return btoa(binary);
}

/**
 * Merges newly-failed message fetches into the prior pending set, bumping a
 * per-message attempt counter and dropping messages that have exhausted
 * {@link MAX_MESSAGE_FETCH_ATTEMPTS} retries (logged, since that change is
 * effectively lost). Messages that succeeded this round are simply absent
 * from `failedIds` and therefore fall out of the pending set.
 */
export function mergePendingMessages(
  prior: PendingMessage[],
  failedIds: string[]
): PendingMessage[] {
  const attemptsById = new Map(prior.map((p) => [p.id, p.attempts]));
  const merged: PendingMessage[] = [];
  for (const id of failedIds) {
    const attempts = (attemptsById.get(id) ?? 0) + 1;
    if (attempts > MAX_MESSAGE_FETCH_ATTEMPTS) {
      console.error(
        `[outlook-mail] giving up on message ${id} after ${attempts - 1} failed fetch attempts; its change may be lost`
      );
      continue;
    }
    merged.push({ id, attempts });
  }
  return merged;
}

// ---------------------------------------------------------------------------
// Auth helpers
// ---------------------------------------------------------------------------

/**
 * Build a GraphMailApi instance authenticated for the given channel.
 * Throws if the token is absent.
 */
export async function getApiFn(
  host: OutlookMailSyncHost,
  channelId: string
): Promise<GraphMailApi> {
  const token = await host.tools.integrations.get(channelId);
  if (!token) {
    throw new Error("No Microsoft authentication token available");
  }
  return new GraphMailApi(token.token);
}

/**
 * Returns a Graph client authed with any enabled channel's token. Auth is
 * per-Microsoft-account (not per-folder), so any enabled channelId resolves
 * to the same OAuth credential.
 */
export async function getApiAnyFn(
  host: OutlookMailSyncHost
): Promise<GraphMailApi | null> {
  const enabled = await getEnabledChannelsFn(host);
  for (const channelId of enabled) {
    const token = await host.tools.integrations.get(channelId);
    if (token?.token) return new GraphMailApi(token.token);
  }
  return null;
}

// ---------------------------------------------------------------------------
// Enabled-channel set helpers
// ---------------------------------------------------------------------------

/** Returns the set of channelIds the user currently has enabled. */
export async function getEnabledChannelsFn(
  host: OutlookMailSyncHost
): Promise<Set<string>> {
  const list = (await host.get<string[]>("enabled_channels")) ?? [];
  return new Set(list);
}

/** Add a channelId to the enabled set (idempotent, preserves order). */
export async function addEnabledChannelFn(
  host: OutlookMailSyncHost,
  channelId: string
): Promise<void> {
  const list = (await host.get<string[]>("enabled_channels")) ?? [];
  if (list.includes(channelId)) return;
  list.push(channelId);
  await host.set("enabled_channels", list);
}

/** Remove a channelId from the enabled set. */
export async function removeEnabledChannelFn(
  host: OutlookMailSyncHost,
  channelId: string
): Promise<void> {
  const list = (await host.get<string[]>("enabled_channels")) ?? [];
  const filtered = list.filter((c) => c !== channelId);
  if (filtered.length === list.length) return;
  await host.set("enabled_channels", filtered);
}

/** Whether a channel is currently enabled. */
export async function isChannelEnabledFn(
  host: OutlookMailSyncHost,
  channelId: string
): Promise<boolean> {
  const list = (await host.get<string[]>("enabled_channels")) ?? [];
  return list.includes(channelId);
}

/** The connected mailbox's address, fetched once and cached. */
export async function ensureUserEmailFn(
  host: OutlookMailSyncHost,
  api?: GraphMailApi
): Promise<string> {
  const stored = await host.get<string>("user_email");
  if (stored) return stored;
  const client = api ?? (await getApiAnyFn(host));
  if (!client) return "";
  const profile = await client.getProfile();
  if (profile.email) await host.set("user_email", profile.email);
  return profile.email;
}

/** Well-known folder map, cached by getChannels and refreshed on demand. */
export async function getWellKnownFn(
  host: OutlookMailSyncHost,
  api?: GraphMailApi
): Promise<WellKnownFolders> {
  const stored = await host.get<WellKnownFolders>("wellknown_folders");
  if (stored && Object.keys(stored).length > 0) return stored;
  const client = api ?? (await getApiAnyFn(host));
  if (!client) return {};
  const fresh = await client.getWellKnownFolderIds();
  await host.set("wellknown_folders", fresh);
  return fresh;
}

// ---------------------------------------------------------------------------
// Recovery (run from upgrade)
// ---------------------------------------------------------------------------

/**
 * Re-queue a fresh full backfill of one folder, dropping any stale cursors
 * (initial + delta) so the walk restarts and the delta baseline reseeds.
 * Used by recovery to re-import mail that arrived while push delivery was
 * dead.
 *
 * Returns a descriptor telling the caller to schedule the first initial
 * batch — scheduling stays on the connector.
 */
export async function requeueInitialSyncFn(
  host: OutlookMailSyncHost,
  channelId: string
): Promise<{ scheduleInitialBatch: { channelId: string } }> {
  await host.set(`initial_state_${channelId}`, {} satisfies InitialSyncState);
  await host.clear(`delta_${channelId}`);
  return { scheduleInitialBatch: { channelId } };
}

/**
 * Ensure live push delivery + recurring maintenance for any instance with
 * enabled channels. Runs from upgrade() on every deploy.
 *
 * Two stranded states were previously unrecoverable — neither the old
 * `if (mailbox_subscription) re-assert` upgrade path nor the cron
 * maintenance sweep could heal them, so the connection stayed silently dead
 * until the user manually re-enabled a channel:
 *
 *   1. `mailbox_subscription` never persisted — a prior
 *      `setupMailboxSubscription()` threw before its `set()`. With no
 *      sentinel there was nothing to re-assert, and because
 *      `scheduleRecurring` never ran the maintenance sweep's `ever` marker
 *      was never set either; and
 *   2. the subscription expired while the self-heal/renewal chain was dead.
 *
 * A healthy subscription (present and unexpired) only re-asserts the
 * recurring tasks. A missing or expired one is re-established AND every
 * enabled folder is re-walked, so mail that accumulated while delivery was
 * dead is backfilled. The backfill upserts by `source` (no duplicates) and
 * uses initial-sync semantics (read/unarchived), so it never spams
 * notifications.
 *
 * Scheduling (renewal + self-heal + per-folder requeue) goes through
 * `host.scheduler`; everything else is data-plane.
 */
export async function recoverMailboxDeliveryFn(
  host: OutlookMailSyncHost
): Promise<void> {
  const enabled = await getEnabledChannelsFn(host);
  if (enabled.size === 0) return;

  const subscription = await host.get<SubscriptionState>(
    "mailbox_subscription"
  );
  if (
    subscription?.subscriptionId &&
    new Date(subscription.expiration).getTime() > Date.now()
  ) {
    // Healthy subscription — re-assert durable maintenance (idempotent).
    try {
      await host.scheduler.scheduleSelfHealCheck();
      await host.scheduler.scheduleMailboxRenewal(
        new Date(subscription.expiration)
      );
    } catch (error) {
      console.error(
        `OutlookMail upgrade [${host.id}]: failed to re-assert recurring tasks`,
        error
      );
    }
    return;
  }

  // Stranded: subscription missing or expired with nothing live renewing it.
  try {
    for (const channelId of enabled) {
      await host.scheduler.requeueInitialSync(channelId);
    }
    await host.scheduler.setupMailboxSubscription();
  } catch (error) {
    console.error(
      `OutlookMail upgrade [${host.id}]: stranded-mailbox recovery failed`,
      error
    );
  }
}

/**
 * Durable recovery backstop, run on every deploy. Re-asserts recurring
 * maintenance for a healthy mailbox and re-establishes (plus backfills) a
 * stranded one. See {@link recoverMailboxDeliveryFn} for the stranded cases.
 */
export async function upgradeFn(host: OutlookMailSyncHost): Promise<void> {
  // One-time migration of pre-drain pending-message bookkeeping.
  await migrateLegacyPendingMessagesFn(host);
  await recoverMailboxDeliveryFn(host);
}

// ---------------------------------------------------------------------------
// Subscription lifecycle
// ---------------------------------------------------------------------------

/**
 * Idempotently set up the mailbox-wide Graph subscription. Called every time
 * a channel is enabled; first call creates it, subsequent calls only make
 * sure the self-heal cycle is running.
 */
export async function ensureMailboxSubscriptionFn(
  host: OutlookMailSyncHost
): Promise<void> {
  const existing = await host.get<SubscriptionState>("mailbox_subscription");
  if (!existing) {
    await host.scheduler.setupMailboxSubscription();
    return;
  }
  await host.scheduler.scheduleSelfHealCheck();
}

/**
 * (Re)establish the mailbox-wide Graph subscription + webhook.
 *
 * Replaces any prior subscription: deletes the server-side subscription and
 * webhook token, then creates fresh (mirrors gmail's setupMailboxWebhook
 * cleanup so renewals never leak resources). Scheduling (renewal +
 * self-heal) goes through `host.scheduler`; everything else is data-plane.
 */
export async function setupMailboxSubscriptionFn(
  host: OutlookMailSyncHost
): Promise<void> {
  // Replace any prior subscription: delete the server-side subscription
  // and webhook token, then create fresh (mirrors gmail's
  // setupMailboxWebhook cleanup so renewals never leak resources).
  const existing = await host.get<SubscriptionState>("mailbox_subscription");
  await host.clear("mailbox_subscription");
  if (existing?.subscriptionId) {
    const cleanupApi = await getApiAnyFn(host);
    if (cleanupApi) {
      try {
        await cleanupApi.deleteSubscription(existing.subscriptionId);
      } catch (error) {
        console.warn(
          `OutlookMail setup [${host.id}]: stale subscription delete failed`,
          error
        );
      }
    }
  }
  if (existing?.webhookUrl) {
    try {
      await host.tools.network.deleteWebhook(existing.webhookUrl);
    } catch (error) {
      console.warn(
        `OutlookMail setup [${host.id}]: stale webhook delete failed`,
        error
      );
    }
  }

  // Synchronous webhook: Graph validates the endpoint inline by POSTing
  // ?validationToken=... and expecting a text/plain echo — the async queue
  // default would reply `200 { queued: true }` and creation would fail.
  const webhookUrl = await host.tools.network.createWebhook(
    { async: false },
    host.scheduler.onOutlookMailWebhook
  );
  if (webhookUrl.includes("localhost") || webhookUrl.includes("127.0.0.1")) {
    console.log(
      `OutlookMail setup [${host.id}]: localhost webhook — skipping subscription`
    );
    return;
  }

  const api = await getApiAnyFn(host);
  if (!api) {
    console.warn(
      `OutlookMail setup [${host.id}]: no enabled channel to source auth from`
    );
    return;
  }

  const clientState = crypto.randomUUID();
  const expirationDateTime = new Date(
    Date.now() + SUBSCRIPTION_DURATION_DAYS * 24 * 60 * 60 * 1000
  );
  const sub = await api.createSubscription({
    notificationUrl: webhookUrl,
    clientState,
    expirationDateTime,
  });

  const expiration = new Date(sub.expirationDateTime);
  await host.set("mailbox_subscription", {
    subscriptionId: sub.id,
    clientState,
    webhookUrl,
    expiration,
    created: new Date().toISOString(),
  } satisfies SubscriptionState);
  await host.scheduler.scheduleMailboxRenewal(expiration);
  await host.scheduler.scheduleSelfHealCheck();
  console.log(`OutlookMail setup [${host.id}]: subscription established`, {
    subscriptionId: sub.id,
    expiration: expiration.toISOString(),
  });
}

/**
 * Cancel renewal + self-heal tasks, delete the Graph subscription and the
 * webhook token, and clear all subscription state. Called when the last
 * channel is disabled.
 */
export async function teardownMailboxSubscriptionFn(
  host: OutlookMailSyncHost
): Promise<void> {
  await host.scheduler.cancelScheduledTask("mailbox-subscription-renewal");
  await host.scheduler.cancelScheduledTask("mailbox-self-heal");

  const subscription = await host.get<SubscriptionState>(
    "mailbox_subscription"
  );
  if (subscription?.subscriptionId) {
    const api = await getApiAnyFn(host);
    if (api) {
      try {
        await api.deleteSubscription(subscription.subscriptionId);
      } catch (error) {
        console.error(
          `OutlookMail teardown [${host.id}]: deleteSubscription failed`,
          error
        );
      }
    }
  }
  if (subscription?.webhookUrl) {
    try {
      await host.tools.network.deleteWebhook(subscription.webhookUrl);
    } catch (error) {
      console.error(
        `OutlookMail teardown [${host.id}]: deleteWebhook failed`,
        error
      );
    }
  }
  await host.clear("mailbox_subscription");
  await host.clear("incremental_state");
  await host.clear("last_webhook_received_at");
}

/**
 * Computes the renewal schedule for the Graph subscription given an
 * expiration. Returns the durable recurring-task parameters the caller
 * passes to `scheduleRecurring("mailbox-subscription-renewal", ...)`.
 * firstRunAt tightens the next run to RENEWAL_LEAD_MS before expiry; the
 * platform clamps a past firstRunAt to now.
 */
export function getMailboxRenewalSchedule(expiration: Date): {
  intervalMs: number;
  firstRunAt: Date;
} {
  const renewalTime = new Date(expiration.getTime() - RENEWAL_LEAD_MS);
  return {
    intervalMs: 1.5 * 24 * 60 * 60 * 1000,
    firstRunAt: renewalTime,
  };
}

/**
 * Renews the Graph subscription before it expires (PATCH keeps the
 * subscription id and clientState stable). On primary-path failure, falls
 * back to a full delete-and-recreate. If both paths fail the error is
 * rethrown so the runtime captures it in PostHog — `selfHealCheck` is the
 * safety net that retries on the next interval.
 */
export async function renewMailboxSubscriptionFn(
  host: OutlookMailSyncHost
): Promise<void> {
  let primaryError: unknown;
  try {
    const api = await getApiAnyFn(host);
    if (!api) {
      console.warn(
        `OutlookMail renew [${host.id}]: no enabled channel to source auth from`
      );
      return;
    }

    const subscription = await host.get<SubscriptionState>(
      "mailbox_subscription"
    );
    if (!subscription?.subscriptionId) {
      await host.scheduler.setupMailboxSubscription();
      return;
    }

    const newExpiry = new Date(
      Date.now() + SUBSCRIPTION_DURATION_DAYS * 24 * 60 * 60 * 1000
    );
    await api.renewSubscription(subscription.subscriptionId, newExpiry);
    await host.set("mailbox_subscription", {
      ...subscription,
      expiration: newExpiry,
    } satisfies SubscriptionState);
    await host.scheduler.scheduleMailboxRenewal(newExpiry);
    await host.scheduler.scheduleSelfHealCheck();
    console.log(`OutlookMail renew [${host.id}]: subscription renewed`, {
      expiration: newExpiry.toISOString(),
    });
    return;
  } catch (error) {
    primaryError = error;
    console.error(
      `OutlookMail renew [${host.id}]: renewal failed, attempting full recreate`,
      error
    );
  }

  try {
    await host.scheduler.setupMailboxSubscription();
  } catch (retryError) {
    console.error(`OutlookMail renew [${host.id}]: fallback setup also failed`, {
      primaryError,
      retryError,
    });
    throw retryError instanceof Error
      ? retryError
      : new Error(String(retryError));
  }
}

// ---------------------------------------------------------------------------
// Self-heal
// ---------------------------------------------------------------------------

/**
 * Periodic safety net. Each run (1) sweeps per-folder delta queries to
 * ingest anything push delivery missed, (2) verifies the subscription
 * isn't missing/expired/imminent, and (3) logs a heartbeat. The platform
 * re-arms the recurring task after every interval, so a single failed run
 * never breaks the cycle.
 *
 * Unlike gmail (whose history cursor advances on every webhook, making
 * any history found here proof that push broke), our delta cursors only
 * advance during this sweep — so delta results overlap with mail the
 * webhook path already processed. That re-processing is idempotent
 * (source/key upserts, cached unread/flag state), and it is NOT treated
 * as evidence the subscription is broken; re-subscription is driven only
 * by the subscription's own expiry state.
 *
 * Scheduling (cancel / renew / re-setup) goes through `host.scheduler`;
 * everything else is data-plane.
 */
export async function selfHealCheckFn(
  host: OutlookMailSyncHost
): Promise<void> {
  const now = new Date();

  const enabled = await getEnabledChannelsFn(host);
  if (enabled.size === 0) {
    await host.scheduler.cancelScheduledTask("mailbox-self-heal");
    console.log(
      `OutlookMail selfHealCheck [${host.id}]: no enabled channels, ending cycle`
    );
    return;
  }

  let unrecoverableError: unknown;
  let action: "healthy" | "renewed" | "recreated" = "healthy";
  let sweptMessages = 0;

  const subscription = await host.get<SubscriptionState>(
    "mailbox_subscription"
  );
  const lastWebhookAt = await host.get<string>("last_webhook_received_at");

  // 1. Delta sweep per enabled folder. Works even when the subscription
  //    is broken because we're polling delta directly.
  try {
    const api = await getApiAnyFn(host);
    if (api) {
      const changed = new Set<string>();
      for (const folderId of enabled) {
        try {
          for (const id of await folderDeltaCatchUpFn(host, api, folderId)) {
            changed.add(id);
          }
        } catch (error) {
          console.error(
            `OutlookMail selfHealCheck [${host.id}]: delta sweep failed for ${folderId}`,
            error
          );
        }
      }
      if (changed.size > 0) {
        sweptMessages = changed.size;
        await incrementalSyncBatchFn(host, [...changed]);
      }
    }
  } catch (error) {
    // Sweep is best-effort; don't let it abort subscription verification.
    console.error(
      `OutlookMail selfHealCheck [${host.id}]: delta sweep failed`,
      error
    );
  }

  // 2. Verify subscription state. Recreate/renew if missing/expired/imminent.
  let needsReup = false;
  if (!subscription) {
    needsReup = true;
    action = "recreated";
  } else {
    const expirationDate = new Date(subscription.expiration);
    const msToExpiry = expirationDate.getTime() - now.getTime();
    if (msToExpiry < 0) {
      needsReup = true;
      action = "recreated";
      console.warn(
        `OutlookMail selfHealCheck [${host.id}]: subscription expired ${-msToExpiry}ms ago`
      );
    } else if (msToExpiry < SUB_PREEMPTIVE_RENEW_MS) {
      needsReup = true;
      action = "renewed";
    }
  }

  if (needsReup) {
    try {
      if (action === "renewed") {
        await host.scheduler.renewMailboxSubscription();
      } else {
        await host.scheduler.setupMailboxSubscription();
      }
    } catch (error) {
      unrecoverableError = error;
      console.error(
        `OutlookMail selfHealCheck [${host.id}]: subscription re-up failed`,
        error
      );
    }
  }

  console.log(`OutlookMail selfHealCheck [${host.id}]: ${action}`, {
    sweptMessages,
    enabledChannels: Array.from(enabled),
    subscriptionId: subscription?.subscriptionId ?? null,
    subscriptionExpiration: subscription?.expiration
      ? new Date(subscription.expiration).toISOString()
      : null,
    lastWebhookAt: lastWebhookAt ?? null,
    minutesSinceLastWebhook: lastWebhookAt
      ? Math.round((now.getTime() - new Date(lastWebhookAt).getTime()) / 60000)
      : null,
    now: now.toISOString(),
  });

  if (unrecoverableError) {
    throw unrecoverableError instanceof Error
      ? unrecoverableError
      : new Error(String(unrecoverableError));
  }
}

/**
 * Delta catch-up for one enabled folder. First run seeds the delta
 * baseline filtered to `now` (cheap — establishes a cursor without
 * walking history; the initial backfill already imported history).
 * Subsequent runs walk changes since the stored link. Returns changed
 * message ids. On 410 the cursor is cleared and reseeds next cycle
 * (bounded gap; the webhook path still covers new mail).
 */
export async function folderDeltaCatchUpFn(
  host: OutlookMailSyncHost,
  api: GraphMailApi,
  folderId: string
): Promise<string[]> {
  const stored = await host.get<DeltaState>(`delta_${folderId}`);
  let url = stored?.url ?? api.buildInitialDeltaUrl(folderId, new Date());
  const seeding = !stored;
  const changed: string[] = [];
  for (let page = 0; page < MAX_DELTA_PAGES_PER_HEAL; page++) {
    let result;
    try {
      result = await api.deltaPage(url);
    } catch (error) {
      if (error instanceof GraphMailApiError && error.status === 410) {
        await host.clear(`delta_${folderId}`); // reseed next cycle
        return changed;
      }
      throw error;
    }
    if (!seeding) {
      for (const m of result.messages) {
        if (m.id && !(m as Record<string, unknown>)["@removed"]) {
          changed.push(m.id);
        }
      }
    }
    if (result.deltaLink) {
      await host.set(`delta_${folderId}`, {
        url: result.deltaLink,
      } satisfies DeltaState);
      return changed;
    }
    if (!result.nextLink) return changed;
    url = result.nextLink;
    // Persist mid-walk so a page-capped (or crashed) walk resumes here.
    await host.set(`delta_${folderId}`, { url } satisfies DeltaState);
  }
  return changed;
}

// ---------------------------------------------------------------------------
// Sync pipeline
// ---------------------------------------------------------------------------

/**
 * Return type for {@link initialSyncBatchFn}.
 *
 * - `next`: schedule another initial-backfill batch with `batchNumber`.
 * - `done`: backfill complete (or skipped); nothing more to schedule.
 */
export type InitialSyncBatchResult =
  | { next: { batchNumber: number } }
  | { done: true };

/**
 * Per-channel initial backfill. Walks the folder's messages newest-first
 * and processes whole conversations. Used the FIRST time a channel is
 * enabled; ongoing changes flow through `incrementalSyncBatch` instead.
 *
 * Returns `{ next }` when more pages remain (caller schedules the next batch)
 * and `{ done: true }` when the backfill is complete or skipped. The
 * data-plane signal `channelSyncCompleted` is fired here (not a scheduling
 * operation).
 */
export async function initialSyncBatchFn(
  host: OutlookMailSyncHost,
  channelId: string,
  batchNumber: number
): Promise<InitialSyncBatchResult> {
  try {
    // Channel may have been disabled between scheduling and execution.
    if (!(await isChannelEnabledFn(host, channelId))) {
      await host.clear(`initial_state_${channelId}`);
      return { done: true };
    }

    const cursor = await host.get<InitialSyncState>(
      `initial_state_${channelId}`
    );
    if (!cursor) {
      // Already completed.
      return { done: true };
    }

    const token = await host.tools.integrations.get(channelId);
    if (!token) {
      console.warn(
        `Auth token missing for channel ${channelId} at initial batch ${batchNumber}, skipping`
      );
      return { done: true };
    }
    const api = new GraphMailApi(token.token);
    if (batchNumber === 1) {
      await ensureUserEmailFn(host, api);
    }

    const storedMin = await host.get<string>(`sync_history_min_${channelId}`);
    const page = await api.getMessagesPage(
      cursor.nextLink
        ? { nextLink: cursor.nextLink }
        : {
            folderId: channelId,
            top: 20,
            since: storedMin ? new Date(storedMin) : undefined,
          }
    );

    // One conversation may surface on multiple pages (one message per
    // page); the re-save is an idempotent upsert on source/note.key.
    const conversationIds = [
      ...new Set(
        page.messages
          .filter((m) => !m.isDraft && m.conversationId)
          .map((m) => m.conversationId!)
      ),
    ];
    if (conversationIds.length > 0) {
      const items = await fetchConversationsFn(host, api, conversationIds);
      await processConversationsFn(host, items, true, channelId);
    }

    if (page.nextLink) {
      await host.set(`initial_state_${channelId}`, {
        nextLink: page.nextLink,
        lastSyncTime: cursor.lastSyncTime,
      } satisfies InitialSyncState);
      return { next: { batchNumber: batchNumber + 1 } };
    } else {
      // Backfill done. Drop the cursor and clear the "syncing…" UI.
      await host.clear(`initial_state_${channelId}`);
      await host.tools.integrations.channelSyncCompleted(channelId);
      return { done: true };
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
 * Fetch full conversations (messages + attachment metadata + the parent's
 * raw headers for facets). Per-conversation failures are logged and
 * skipped — incremental retries happen at the notified-message level.
 */
export async function fetchConversationsFn(
  _host: OutlookMailSyncHost,
  api: GraphMailApi,
  conversationIds: string[]
): Promise<ConversationItem[]> {
  const items: ConversationItem[] = [];
  for (const conversationId of conversationIds) {
    try {
      const messages = await api.getConversationMessages(conversationId);
      if (messages.length === 0) continue;
      const attachmentsByMessageId = new Map<string, GraphAttachmentMeta[]>();
      for (const m of messages) {
        if (!m.isDraft && m.hasAttachments) {
          try {
            attachmentsByMessageId.set(m.id, await api.listAttachments(m.id));
          } catch (error) {
            console.warn(
              `[outlook-mail] attachments fetch failed for ${m.id}:`,
              error
            );
          }
        }
      }
      const parent = messages.find((m) => !m.isDraft);
      let parentHeaders: GraphHeader[] | null = null;
      if (parent) {
        try {
          parentHeaders = await api.getInternetMessageHeaders(parent.id);
        } catch {
          // Facets degrade to header-less signals.
        }
      }
      items.push({ messages, attachmentsByMessageId, parentHeaders });
    } catch (error) {
      console.error(
        `[outlook-mail] failed to fetch conversation ${conversationId}:`,
        error
      );
    }
  }
  return items;
}

// ---------------------------------------------------------------------------
// Webhook handler
// ---------------------------------------------------------------------------

/**
 * Return type for {@link onOutlookMailWebhookFn}.
 *
 * - `validationToken`: echo this string back (text/plain) for Graph's
 *   endpoint-validation handshake.
 * - `queueRenewSubscription`/`queueIncrementalSync`: the caller should queue
 *   the named follow-up tasks (subscription renewal and/or an incremental
 *   sync over `messageIds`).
 * - `done: true`: nothing to queue (invalid/empty notification).
 */
export type OutlookMailWebhookResult =
  | { validationToken: string }
  | {
      queueRenewSubscription: boolean;
      queueIncrementalSync: boolean;
      messageIds: string[];
    }
  | { done: true };

/**
 * Graph change-notification handler (synchronous webhook). Echoes the
 * validation handshake, verifies clientState, and returns a descriptor
 * telling the caller which follow-up tasks to queue.
 *
 * Self-heal re-assertion is routed through `host.scheduler`; queuing the
 * renewal / incremental-sync tasks is left to the caller via the returned
 * descriptor (mirrors gmail's onGmailWebhookFn).
 */
export async function onOutlookMailWebhookFn(
  host: OutlookMailSyncHost,
  request: WebhookRequest
): Promise<OutlookMailWebhookResult> {
  // Graph endpoint validation handshake — echo as text/plain (sync route).
  if (request.params?.validationToken) {
    return { validationToken: request.params.validationToken as string };
  }

  // Record receipt before any early returns so `selfHealCheck` can
  // distinguish "subscription healthy, just no new mail" from "we haven't
  // heard from Graph in hours".
  await host.set("last_webhook_received_at", new Date().toISOString());

  // Self-heal bootstrap for instances whose cycle died. Idempotent.
  try {
    await host.scheduler.scheduleSelfHealCheck();
  } catch (error) {
    console.error(
      `OutlookMail webhook [${host.id}]: self-heal bootstrap failed`,
      error
    );
  }

  const body = request.body as {
    value?: Array<{
      clientState?: string;
      lifecycleEvent?: string;
      resourceData?: { id?: string };
    }>;
  } | null;
  const notifications = body?.value ?? [];
  if (notifications.length === 0) return { done: true };

  const stored = await host.get<SubscriptionState>("mailbox_subscription");
  const ids = new Set<string>();
  let lifecycleAction = false;
  for (const n of notifications) {
    // clientState is Graph's only notification-authenticity signal.
    if (!stored?.clientState || n.clientState !== stored.clientState) {
      console.warn(
        `OutlookMail webhook [${host.id}]: clientState mismatch, dropping notification`
      );
      continue;
    }
    if (
      n.lifecycleEvent === "subscriptionRemoved" ||
      n.lifecycleEvent === "reauthorizationRequired"
    ) {
      lifecycleAction = true;
      continue;
    }
    if (n.resourceData?.id) ids.add(n.resourceData.id);
  }

  if (!lifecycleAction && ids.size === 0) return { done: true };

  return {
    queueRenewSubscription: lifecycleAction,
    queueIncrementalSync: ids.size > 0,
    messageIds: [...ids],
  };
}

/**
 * Mailbox-wide incremental sync over a set of notified message ids.
 * Probes each message, skips drafts and excluded folders, then fetches
 * and processes whole conversations. Failed probes are carried in
 * `incremental_state.pendingMessageIds` for retry on a later sync.
 */
/**
 * Record notified message ids and schedule the coalesced incremental drain.
 * Thin forwarder onto the platform's `scheduleDrain` primitive (via the host
 * scheduler boundary), which owns the durable dirty set, coalescing, bounded
 * passes, and per-id retry caps.
 */
export async function queueIncrementalSyncFn(
  host: OutlookMailSyncHost,
  messageIds: string[]
): Promise<void> {
  await host.scheduler.scheduleDrain(messageIds);
}

/**
 * Legacy entry point kept for already-queued callbacks (and the pre-drain
 * webhook flow): re-records the ids with the platform drain and lets the
 * scheduled pass do the work.
 */
export async function incrementalSyncBatchFn(
  host: OutlookMailSyncHost,
  messageIds: string[]
): Promise<void> {
  await host.scheduler.scheduleDrain(messageIds);
}

/**
 * One-time migration of the hand-rolled pending-message bookkeeping that
 * predates the platform drain: `pending_msg:<id>` keys and
 * `incremental_state.pendingMessageIds` are re-recorded via
 * {@link OutlookMailSyncHost.scheduler.scheduleDrain} and the old state is
 * cleared. Runs from `upgradeFn` on deploy; a no-op once migrated.
 */
export async function migrateLegacyPendingMessagesFn(
  host: OutlookMailSyncHost
): Promise<void> {
  const legacyKeys = await host.tools.store.list(PENDING_MSG_PREFIX);
  const state = await host.get<IncrementalState>("incremental_state");
  const legacyState = state?.pendingMessageIds ?? [];
  const ids = new Set<string>([
    ...legacyKeys.map((k) => k.slice(PENDING_MSG_PREFIX.length)),
    ...legacyState.map((p) => p.id),
  ]);
  if (ids.size === 0) return;

  await host.scheduler.scheduleDrain([...ids]);
  for (const key of legacyKeys) {
    await host.clear(key);
  }
  if (legacyState.length > 0) {
    await host.set("incremental_state", {} satisfies IncrementalState);
  }
  console.log(
    `[outlook-mail] migrated ${ids.size} legacy pending message id(s) to the platform drain`
  );
}

/**
 * Drain handler: probe the notified message ids handed over by the platform
 * drain (already bounded to one pass's batch), route them to conversations,
 * and ingest those conversations. Returns `{ retry }` for probe failures so
 * the platform keeps just those ids pending (with attempt caps); skipped
 * probes (drafts, excluded folders, hard-deleted messages) are simply
 * released.
 */
export async function drainNotifiedMessagesFn(
  host: OutlookMailSyncHost,
  messageIds: string[]
): Promise<{ retry: string[] } | undefined> {
  if (messageIds.length === 0) return;
  const enabled = await getEnabledChannelsFn(host);
  if (enabled.size === 0) return;
  const api = await getApiAnyFn(host);
  if (!api) {
    console.warn(
      "[outlook-mail] drainNotifiedMessages: no enabled channel to source auth from"
    );
    return;
  }

  const wellKnown = await getWellKnownFn(host, api);
  const excludedFolderIds = new Set(
    EXCLUDED_WELL_KNOWN.map((n) => wellKnown[n]).filter(Boolean) as string[]
  );

  const conversationIds = new Set<string>();
  const retry: string[] = [];
  for (const id of messageIds) {
    try {
      const m = await api.getMessage(
        id,
        "id,conversationId,parentFolderId,isDraft"
      );
      if (!m) continue; // 404 — hard-deleted upstream; nothing to ingest
      if (m.isDraft) continue;
      if (m.parentFolderId && excludedFolderIds.has(m.parentFolderId)) {
        continue;
      }
      if (m.conversationId) conversationIds.add(m.conversationId);
    } catch (error) {
      console.error(`[outlook-mail] message probe failed for ${id}:`, error);
      retry.push(id);
    }
  }

  const items = await fetchConversationsFn(host, api, [...conversationIds]);
  if (items.length > 0) {
    await processConversationsFn(host, items, false);
  }

  return retry.length > 0 ? { retry } : undefined;
}

export async function processConversationsFn(
  host: OutlookMailSyncHost,
  items: ConversationItem[],
  initialSync: boolean,
  forceChannelId?: string
): Promise<void> {
  const enabledChannels = forceChannelId
    ? new Set([forceChannelId])
    : await getEnabledChannelsFn(host);
  if (enabledChannels.size === 0) return;

  const accountEmail = await ensureUserEmailFn(host);
  const wellKnown = await getWellKnownFn(host);

  // Pre-build all plot threads, then enrich contact names across the
  // batch in one People/Contacts pass.
  const transformed: {
    item: ConversationItem;
    plot: NewLinkWithNotes;
    channelId: string;
    conversationId: string;
  }[] = [];
  for (const item of items) {
    const plot = transformOutlookConversation({
      messages: item.messages,
      attachmentsByMessageId: item.attachmentsByMessageId,
      accountEmail,
    });
    if (!plot.notes || plot.notes.length === 0) continue;

    const chosen =
      forceChannelId ??
      pickChannelForConversation(item.messages, enabledChannels, wellKnown);
    if (!chosen) continue; // Conversation doesn't match any enabled channel.

    transformed.push({
      item,
      plot,
      channelId: chosen,
      conversationId: plot.meta!.conversationId as string,
    });
  }
  if (transformed.length === 0) return;

  // Auth scope is per-account, not per-channel; any enabled channel ID
  // sources the same token.
  const authChannelId = forceChannelId ?? transformed[0].channelId;
  try {
    const token = await host.tools.integrations.get(authChannelId);
    if (token) {
      await enrichLinkContactsFromOutlook(
        transformed.map((t) => t.plot),
        token.token,
        token.scopes
      );
    }
  } catch (err) {
    // Enrichment is best-effort — Gravatar fallback in the client still
    // covers anyone the People API doesn't return.
    console.warn("Failed to enrich Outlook contacts (non-blocking):", err);
  }

  for (const {
    item,
    plot: plotThread,
    channelId,
    conversationId,
  } of transformed) {
    try {
      // Cache message → channel mapping so downloadAttachment can find
      // auth for a given Graph message id.
      for (const message of item.messages) {
        if (!message.isDraft) {
          await host.set(`outlook:msg-channel:${message.id}`, channelId);
        }
      }

      // Filter out notes for messages we sent from Plot (echo dedup).
      const filtered = [];
      for (const note of plotThread.notes!) {
        const noteKey = "key" in note ? (note as { key: string }).key : null;
        if (noteKey) {
          const wasSent = await host.get<boolean>(`sent:${noteKey}`);
          if (wasSent) {
            await host.clear(`sent:${noteKey}`);
            continue;
          }
        }
        filtered.push(note);
      }
      plotThread.notes = filtered;
      if (plotThread.notes.length === 0) continue;

      const isUnread = isConversationUnread(item.messages);
      if (initialSync) {
        plotThread.unread = false;
        plotThread.archived = false;
        await host.set(`unread:${conversationId}`, isUnread);
      } else {
        const wasUnread = await host.get<boolean>(`unread:${conversationId}`);
        if (wasUnread == null) {
          // First time seeing this conversation incrementally. If it is
          // already read in Outlook, align Plot's state.
          if (!isUnread) {
            plotThread.unread = false;
          }
        } else if (isUnread !== wasUnread) {
          // The unread state changed in Outlook, so write it to Plot.
          plotThread.unread = isUnread;
        }
        await host.set(`unread:${conversationId}`, isUnread);
      }

      // Inject channel ID for priority routing and sync metadata.
      plotThread.channelId = channelId;
      plotThread.meta = {
        ...plotThread.meta,
        syncProvider: "microsoft",
        syncableId: channelId,
        channelId,
      };

      // Bundle onto the calendar event's thread when this conversation relates
      // to one (a Plot-sent reply chain, or a meeting update/cancellation).
      const calBundle = classifyOutlookCalendar(
        item.messages,
        item.parentHeaders
      );
      if (calBundle) {
        plotThread.sources = [
          ...(plotThread.sources ?? []),
          `icaluid:${calBundle.uid}`,
        ];
        if (calBundle.kind === "cancel") {
          await host.set(`cancel-email:${calBundle.uid}`, {
            at: new Date().toISOString(),
          });
        }
      }

      // Compute classifier facets from the parent message's headers + body.
      const facetParent = sortConversation(item.messages).find(
        (m) => !m.isDraft
      );
      if (facetParent) {
        const parentKey = facetParent.internetMessageId ?? facetParent.id;
        const facetNote = plotThread.notes?.find(
          (n) => "key" in n && (n as { key: string }).key === parentKey
        );
        const facetBody =
          (facetNote as { content?: string } | undefined)?.content ??
          plotThread.preview ??
          "";
        const { facets, cta } = outlookFacets(
          item.parentHeaders,
          facetParent,
          facetBody
        );
        plotThread.facets = cta ? { ...facets, format: cta.kind } : facets;
        if (cta && facetNote) {
          (facetNote as { cta?: Cta | null }).cta = cta;
        }
      }

      const isFlagged = isConversationFlagged(item.messages);
      const savedThreadId = await host.tools.integrations.saveLink(plotThread);
      if (!savedThreadId) continue; // Link was filtered (e.g., older than sync history)

      const wasFlagged = await host.get<boolean>(`flagged:${conversationId}`);

      // Echo suppression relies entirely on the `flagged` state: when
      // Plot→Outlook writes the flag, onThreadToDo updates this state
      // *before* the API call. The resulting Graph notification sees
      // isFlagged === wasFlagged and this branch doesn't run.
      if (isFlagged !== !!wasFlagged) {
        const actorId = await host.get<ActorId>("auth_actor_id");
        if (actorId) {
          await host.tools.integrations.setThreadToDo(
            plotThread.source as string,
            actorId,
            isFlagged
          );
        }
        await host.set(`flagged:${conversationId}`, isFlagged);
      }
    } catch (error) {
      console.error(
        `Failed to process Outlook conversation ${conversationId}:`,
        error
      );
      // Continue processing other conversations.
    }
  }
}

// ---------------------------------------------------------------------------
// Two-way status sync
// ---------------------------------------------------------------------------

export async function onThreadReadFn(
  host: OutlookMailSyncHost,
  thread: Thread,
  _actor: Actor,
  unread: boolean
): Promise<void> {
  const meta = thread.meta ?? {};
  const channelId = (meta.channelId ?? meta.syncableId) as string;
  const conversationId = meta.conversationId as string;
  if (!channelId || !conversationId) return;

  const api = await getApiFn(host, channelId);

  // Cache the new state before the Graph writes so the resulting change
  // notifications see state === cache and don't re-propagate.
  await host.set(`unread:${conversationId}`, unread);

  const messages = (await api.getConversationMessages(conversationId)).filter(
    (m) => !m.isDraft
  );
  if (messages.length === 0) return;

  if (unread) {
    // Mark the latest message unread — matches Outlook's own conversation
    // unread affordance without resurrecting every old message.
    await api.updateMessage(messages[messages.length - 1].id, {
      isRead: false,
    });
  } else {
    for (const m of messages) {
      if (m.isRead === false) {
        await api.updateMessage(m.id, { isRead: true });
      }
    }
  }
}

export async function onThreadToDoFn(
  host: OutlookMailSyncHost,
  thread: Thread,
  _actor: Actor,
  todo: boolean,
  _options: { date?: Date }
): Promise<void> {
  const meta = thread.meta ?? {};
  const conversationId = meta.conversationId as string;
  const channelId = (meta.channelId ?? meta.syncableId) as string;
  if (!conversationId || !channelId) return;

  // Update local state BEFORE calling Graph, so the notification fired by
  // our own write sees isFlagged === wasFlagged and doesn't re-propagate.
  await host.set(`flagged:${conversationId}`, todo);

  const api = await getApiFn(host, channelId);
  const messages = (await api.getConversationMessages(conversationId)).filter(
    (m) => !m.isDraft
  );
  if (messages.length === 0) return;

  if (todo) {
    await api.updateMessage(messages[messages.length - 1].id, {
      flag: { flagStatus: "flagged" },
    });
  } else {
    for (const m of messages) {
      if (m.flag?.flagStatus === "flagged") {
        await api.updateMessage(m.id, { flag: { flagStatus: "notFlagged" } });
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Reply + compose
// ---------------------------------------------------------------------------

export async function onNoteCreatedFn(
  host: OutlookMailSyncHost,
  note: Note,
  thread: Thread
): Promise<NoteWriteBackResult | void> {
  const meta = thread.meta ?? {};

  // Calendar event threads carry a calendarId + iCalUId but no Outlook
  // conversationId. Route them to a fresh-email fan-out to the event's
  // invitees.
  if (meta.calendarId && !meta.conversationId) {
    return sendCalendarEventReplyFn(host, note, thread);
  }

  const channelId = (meta.channelId ?? meta.syncableId) as string;
  if (!channelId) {
    console.error("No channelId in meta for Outlook reply");
    return;
  }
  const conversationId = meta.conversationId as string;
  if (!conversationId) {
    console.error("No conversationId in meta for Outlook reply");
    return;
  }

  // Idempotency for a re-dispatched onNoteCreated is now guaranteed by the Plot
  // runtime: it will not re-invoke onNoteCreated for a note it already wrote
  // back, so no per-connector send guard is needed here.

  const api = await getApiFn(host, channelId);

  const messages = (await api.getConversationMessages(conversationId)).filter(
    (m) => !m.isDraft
  );
  if (messages.length === 0) {
    console.error("Outlook conversation has no messages");
    return;
  }

  // Determine target message: specific replied-to note or last message.
  let targetMessage = messages[messages.length - 1];
  if (meta.reNoteKey) {
    const found = messages.find((m) => m.internetMessageId === meta.reNoteKey);
    if (found) {
      targetMessage = found;
    }
  }

  const senderEmail = (await ensureUserEmailFn(host, api)).toLowerCase();

  // The acting user's own addresses must never receive their own reply: the
  // connected mailbox plus the authoring identity (which may be a different
  // linked email). Used only for the header-derived cases — the runtime's
  // note.recipients are already self-excluded across every linked identity.
  const selfEmails = new Set<string>([senderEmail]);
  const authorEmail = (thread.accessContacts ?? []).find(
    (contact) => contact.id === note.author.id
  )?.email;
  if (authorEmail) selfEmails.add(authorEmail.toLowerCase());

  // Gmail ignores dots and anything after "+" in the local part, so a header
  // may address the user via a variant that never string-matches selfEmails
  // (e.g. "krisbraun@gmail.com" vs the connected "kris.braun@gmail.com").
  // Compare header candidates against the base form of every self address,
  // in addition to the exact-match `selfEmails` set the shared helper below
  // still uses for the access-contact/reply-all cases.
  const selfBases = new Set(Array.from(selfEmails, baseEmail));
  const isSelfAddress = (email: string) => selfBases.has(baseEmail(email));

  // Fallback access constraint (used only when the runtime didn't resolve
  // note.recipients): resolve the note's access list to lowercased emails.
  let accessContactEmails: Set<string> | null = null;
  if (note.accessContacts != null) {
    const allowedIds = new Set<ActorId>(note.accessContacts);
    accessContactEmails = new Set<string>();
    for (const contact of thread.accessContacts ?? []) {
      if (allowedIds.has(contact.id) && contact.email) {
        accessContactEmails.add(contact.email.toLowerCase());
      }
    }
  }

  // Original-message participants: From ∪ To → To, Cc → Cc. Self-address
  // variants (see isSelfAddress above) are dropped here so they never reach
  // the shared recipient resolver below.
  const fromToCandidates = new Set<string>();
  for (const email of recipientEmails(
    targetMessage.from ? [targetMessage.from] : []
  )) {
    fromToCandidates.add(email.toLowerCase());
  }
  for (const email of recipientEmails(targetMessage.toRecipients)) {
    fromToCandidates.add(email.toLowerCase());
  }
  const ccCandidates = new Set<string>();
  for (const email of recipientEmails(targetMessage.ccRecipients)) {
    ccCandidates.add(email.toLowerCase());
  }
  const toCandidates = Array.from(fromToCandidates).filter(
    (email) => !ccCandidates.has(email) && !isSelfAddress(email)
  );

  // Resolve the outbound recipients via the shared helper: prefer the runtime's
  // pre-resolved note.recipients (curated, self-excluded, role-aware), else
  // narrow/augment the original participants by the access constraint, else
  // reply-all. Identical logic to every other email-style connector.

  // Raw original sender(s) — drives the shared helper's self-reply fallback so
  // a reply in a self-email thread addresses the original sender instead of
  // resolving to nobody. Not self-filtered. Withheld only for a genuinely
  // private note (access list explicitly = the author only) so it never
  // becomes an outbound self-email; a default/uncurated reply (accessContacts
  // null) is a normal reply and still sends.
  const choseOthers = (note.accessContacts ?? []).some(
    (id) => id !== note.author.id
  );
  const isPrivateToSelfOnly =
    note.accessContacts != null &&
    note.accessContacts.every((id) => id === note.author.id);
  const headerFrom = isPrivateToSelfOnly
    ? []
    : recipientEmails(targetMessage.from ? [targetMessage.from] : []).map(
        (email) => email.toLowerCase()
      );

  const { to, cc, bcc } = resolveOutboundReplyRecipients({
    recipients: note.recipients ?? null,
    accessContactEmails,
    headerTo: toCandidates,
    headerCc: Array.from(ccCandidates).filter((email) => !isSelfAddress(email)),
    selfEmails,
    headerFrom,
  });

  if (to.length === 0 && cc.length === 0 && bcc.length === 0) {
    // If the user explicitly chose recipients (anyone other than themselves)
    // and none are deliverable, surface it instead of dropping silently. A
    // private note (access list = the author only) or an empty reply-all just
    // skips quietly.
    if (choseOthers) {
      return {
        deliveryError: {
          code: "no_recipients",
          message: "This reply had no deliverable recipients.",
        },
      };
    }
    console.log(
      `[outlook-mail] onNoteCreated: note ${note.id} resolved to no outbound recipients; skipping send`
    );
    return;
  }

  // Graph threads the reply for us (In-Reply-To / References / subject).
  const draft = await api.createReplyDraft(targetMessage.id);

  // PATCHing the body replaces Outlook's quoted-history block — Plot
  // threads carry the history as notes, and Gmail replies are likewise
  // unquoted.
  const addr = (a: Addressee) => ({
    emailAddress: { address: a.address, ...(a.name ? { name: a.name } : {}) },
  });
  await api.updateMessage(draft.id, {
    // Send rendered HTML rather than raw Markdown as plain text, so the
    // recipient sees clean formatting and Outlook doesn't hard-wrap prose.
    body: { contentType: "html", content: markdownToHtml(note.content ?? "") },
    toRecipients: to.map(addr),
    ccRecipients: cc.map(addr),
    ...(bcc.length > 0 ? { bccRecipients: bcc.map(addr) } : {}),
  });

  // Attach files from note actions (skip failures rather than failing
  // the whole send).
  for (const action of note.actions ?? []) {
    if (action.type === ActionType.file) {
      try {
        const file = await host.tools.files.read(action.fileId);
        if (file.data.length <= DIRECT_ATTACH_MAX_BYTES) {
          await api.addFileAttachment(draft.id, {
            name: file.fileName,
            contentType: file.mimeType,
            contentBytes: uint8ToBase64(file.data),
          });
        } else {
          await api.uploadLargeAttachment(draft.id, {
            name: file.fileName,
            contentType: file.mimeType,
            data: file.data,
          });
        }
      } catch (err) {
        console.error(
          `[outlook-mail] onNoteCreated: failed to attach file ${action.fileId}:`,
          err
        );
      }
    }
  }

  // Read the draft's internetMessageId before sending — it's the note key
  // sync-in will use for the sent message's echo.
  const refreshed = await api.getMessage(
    draft.id,
    "id,internetMessageId,conversationId"
  );
  const key =
    refreshed?.internetMessageId ?? draft.internetMessageId ?? draft.id;

  await api.send(draft.id);

  await host.set(`sent:${key}`, true);

  // No `externalContent`: Graph's send returns 202 with no stored body,
  // and the sent message is echo-suppressed above; the first sync-in
  // establishes the baseline naturally (same tradeoff as Gmail).
  return { key };
}

/**
 * Reply on a calendar event thread → email the event's invitees. Unlike a
 * mail reply there is no upstream Outlook conversation to reply into, so the
 * first reply starts a fresh conversation (state stored under
 * `cal-reply:<iCalUID>`) and later replies thread into it via
 * `createReplyDraft`. Only the seed message carries the `X-Plot-Event-UID`
 * header — Graph won't PATCH headers onto a reply draft, and one tagged
 * message per conversation is enough for the mail sync to bundle the
 * conversation back onto this event thread (Plan B).
 */
export async function sendCalendarEventReplyFn(
  host: OutlookMailSyncHost,
  note: Note,
  thread: Thread
): Promise<NoteWriteBackResult | void> {
  const meta = thread.meta ?? {};
  const channelId = (meta.channelId ?? meta.syncableId) as string;
  const iCalUID = (meta.iCalUId ?? meta.eventId) as string;
  if (!channelId || !iCalUID) {
    console.error("[outlook-mail] calendar reply: missing channelId/iCalUId in meta");
    return;
  }
  const api = await getApiFn(host, channelId);
  const senderEmail = (await ensureUserEmailFn(host, api)).toLowerCase();
  const selfEmails = new Set<string>([senderEmail]);
  const authorEmail = (thread.accessContacts ?? []).find((c) => c.id === note.author.id)?.email;
  if (authorEmail) selfEmails.add(authorEmail.toLowerCase());

  // Fallback access constraint when the runtime didn't resolve note.recipients.
  let accessContactEmails: Set<string> | null = null;
  if (note.accessContacts != null) {
    const allowed = new Set<ActorId>(note.accessContacts);
    accessContactEmails = new Set<string>();
    for (const c of thread.accessContacts ?? []) {
      if (allowed.has(c.id) && c.email) accessContactEmails.add(c.email.toLowerCase());
    }
  }

  const { to, cc, bcc } = resolveOutboundReplyRecipients({
    recipients: note.recipients ?? null,
    accessContactEmails,
    headerTo: [],
    headerCc: [],
    selfEmails,
  });
  if (to.length === 0 && cc.length === 0 && bcc.length === 0) {
    const choseOthers = (note.accessContacts ?? []).some((id) => id !== note.author.id);
    if (choseOthers) {
      return {
        deliveryError: {
          code: "no_recipients",
          message: "This reply had no deliverable recipients.",
        },
      };
    }
    return; // private note or empty roster
  }

  const addr = (a: Addressee) => ({
    emailAddress: { address: a.address, ...(a.name ? { name: a.name } : {}) },
  });
  const bodyHtml = { contentType: "html", content: markdownToHtml(note.content ?? "") };
  const stateKey = `cal-reply:${iCalUID}`;
  const prior = await host.get<{ conversationId: string; lastMessageId: string }>(stateKey);

  const sendFreshConversation = async (): Promise<NoteWriteBackResult | void> => {
    const created = await api.createDraft({
      subject: (thread.title as string) || "Event",
      body: bodyHtml,
      toRecipients: to.map(addr),
      ccRecipients: cc.map(addr),
      bccRecipients: bcc.map(addr),
      internetMessageHeaders: [{ name: "x-plot-event-uid", value: iCalUID }],
    });
    const draftId = created.id;
    let imid = created.internetMessageId;
    let conversationId = created.conversationId;
    if (!imid || !conversationId) {
      const r = await api.getMessage(draftId, "id,internetMessageId,conversationId");
      imid = imid ?? r?.internetMessageId;
      conversationId = conversationId ?? r?.conversationId;
    }
    await api.send(draftId);
    if (!conversationId) return;
    const key = imid ?? draftId;
    await host.set(stateKey, { conversationId, lastMessageId: key });
    await host.set(`sent:${key}`, true);
    return { key };
  };

  if (!prior) {
    return sendFreshConversation();
  }

  // Subsequent reply: thread into the stored conversation via a REAL Graph
  // item id (`createReplyDraft` → POST /me/messages/{id}/createReply
  // requires the item id, not an internetMessageId — the prior code passed
  // `prior.lastMessageId`, an RFC-822 Message-ID, which Graph rejects with a
  // 404 ErrorInvalidIdMalformed on every reply after the first).
  const conversationMessages = (
    await api.getConversationMessages(prior.conversationId)
  ).filter((m) => !m.isDraft);
  if (conversationMessages.length === 0) {
    // Defensive: the stored conversation has no live messages to thread
    // into (shouldn't normally happen — we sent a message there
    // previously). Fall back to starting a fresh conversation rather than
    // calling createReplyDraft with nothing to anchor to.
    console.warn(
      `[outlook-mail] calendar reply: conversation ${prior.conversationId} has no messages, starting a fresh one`
    );
    return sendFreshConversation();
  }
  const target = conversationMessages[conversationMessages.length - 1];

  const draft = await api.createReplyDraft(target.id);
  const draftId = draft.id;
  await api.updateMessage(draftId, {
    body: bodyHtml,
    toRecipients: to.map(addr),
    ccRecipients: cc.map(addr),
    ...(bcc.length > 0 ? { bccRecipients: bcc.map(addr) } : {}),
  });
  const refreshed = await api.getMessage(draftId, "id,internetMessageId,conversationId");
  const key = refreshed?.internetMessageId ?? draft.internetMessageId ?? draftId;
  await api.send(draftId);
  await host.set(stateKey, { conversationId: prior.conversationId, lastMessageId: key });
  await host.set(`sent:${key}`, true);
  return { key };
}

/**
 * Creates a new outbound email from Plot. The runtime fills
 * `draft.recipients` from connection-scoped rows (falling back to
 * `contact.email`); free-form typed addresses arrive via
 * `draft.inviteEmails`. Recipients split into To/Cc/Bcc by role so BCC
 * recipients never appear in visible headers.
 */
export async function onCreateLinkFn(
  host: OutlookMailSyncHost,
  draft: CreateLinkDraft
): Promise<NewLinkWithNotes | null> {
  if (draft.type !== "email") return null;

  const seenEmails = new Set<string>();
  const toEmails: Addressee[] = [];
  const ccEmails: Addressee[] = [];
  const bccEmails: Addressee[] = [];
  const addRecipient = (
    raw: string | null | undefined,
    role: string | null,
    name: string | null
  ) => {
    if (!raw) return;
    const trimmed = raw.trim();
    if (!trimmed) return;
    const key = canonicalizeEmail(trimmed);
    if (seenEmails.has(key)) return;
    seenEmails.add(key);
    const addressee: Addressee = { address: trimmed, name };
    if (role === "cc") ccEmails.push(addressee);
    else if (role === "bcc") bccEmails.push(addressee);
    else toEmails.push(addressee);
  };

  for (const r of draft.recipients ?? []) {
    addRecipient(r.externalAccountId, r.role, r.name);
  }
  for (const email of draft.inviteEmails ?? []) addRecipient(email, null, null);

  if (toEmails.length + ccEmails.length + bccEmails.length === 0) {
    console.error(
      "[outlook-mail] onCreateLink: no email recipients could be derived from draft"
    );
    return null;
  }

  const api = await getApiAnyFn(host);
  if (!api) {
    console.error(
      "[outlook-mail] onCreateLink: no enabled channel to source auth from"
    );
    return null;
  }

  const fromEmail = await ensureUserEmailFn(host, api);
  const subject = draft.title || "";
  const body = draft.noteContent ?? "";

  // channelId: use the first enabled channel so onNoteCreated (reply path)
  // can resolve the OAuth token via getApi(channelId).
  const enabledChannels = await getEnabledChannelsFn(host);
  const channelId = [...enabledChannels][0] ?? "";

  // Build the link the runtime wires to the originating thread. Shared
  // between the normal send and the dedup-hit path so a retried dispatch
  // returns an identical link.
  const linkFor = (conversationId: string): NewLinkWithNotes => ({
    source: conversationSource(fromEmail, conversationId),
    type: "email",
    title: subject || undefined,
    status: null,
    created: new Date(),
    sourceUrl: null,
    channelId,
    meta: {
      syncProvider: "microsoft",
      syncableId: channelId,
      channelId,
      conversationId,
    },
  });

  // Idempotency: dedupe on a content hash within the retry window. Keyed on
  // the raw addresses only (not display names) so the same recipient set
  // dedupes regardless of name resolution differences between retries.
  const dedupKey = `compose:${fnv1aHex(
    JSON.stringify([
      draft.type,
      subject,
      body,
      toEmails.map((a) => a.address).sort(),
      ccEmails.map((a) => a.address).sort(),
      bccEmails.map((a) => a.address).sort(),
    ])
  )}`;
  const prior = await host.get<{ conversationId: string; at: number }>(
    dedupKey
  );
  if (
    prior?.conversationId &&
    Date.now() - prior.at < COMPOSE_DEDUP_WINDOW_MS
  ) {
    console.log(
      `[outlook-mail] onCreateLink: duplicate compose dispatch within ${COMPOSE_DEDUP_WINDOW_MS}ms, reusing conversation ${prior.conversationId}`
    );
    return linkFor(prior.conversationId);
  }

  const addr = (a: Addressee) => ({
    emailAddress: { address: a.address, ...(a.name ? { name: a.name } : {}) },
  });
  const created = await api.createDraft({
    subject,
    // Send rendered HTML rather than raw Markdown as plain text, so the
    // recipient sees clean formatting and Outlook doesn't hard-wrap prose.
    body: { contentType: "html", content: markdownToHtml(body) },
    toRecipients: toEmails.map(addr),
    ccRecipients: ccEmails.map(addr),
    bccRecipients: bccEmails.map(addr),
  });

  // POST /me/messages returns the full draft; fall back to a re-fetch if
  // internetMessageId / conversationId are somehow absent.
  let imid = created.internetMessageId;
  let conversationId = created.conversationId;
  if (!imid || !conversationId) {
    const refreshed = await api.getMessage(
      created.id,
      "id,internetMessageId,conversationId"
    );
    imid = imid ?? refreshed?.internetMessageId;
    conversationId = conversationId ?? refreshed?.conversationId;
  }

  await api.send(created.id);

  if (!conversationId) {
    console.error(
      "[outlook-mail] onCreateLink: sent draft has no conversationId"
    );
    return null;
  }

  await host.set(dedupKey, { conversationId, at: Date.now() });

  // Suppress the echo when the sent message arrives via notification.
  const noteKey = imid ?? created.id;
  await host.set(`sent:${noteKey}`, true);

  return { ...linkFor(conversationId), originatingNote: { key: noteKey } };
}

// ---------------------------------------------------------------------------
// Attachment download
// ---------------------------------------------------------------------------

/**
 * Downloads an attachment identified by the opaque `ref` emitted during
 * inbound sync. Ref format is `${graphMessageId}:${attachmentId}` (Graph
 * ImmutableIds are URL-safe base64 and never contain a colon).
 */
export async function downloadAttachmentFn(
  host: OutlookMailSyncHost,
  ref: string
): Promise<
  | { redirectUrl: string }
  | { body: Uint8Array; mimeType: string; fileName?: string }
> {
  const colon = ref.indexOf(":");
  if (colon < 0) {
    throw new Error(`Invalid Outlook attachment ref: ${ref}`);
  }
  const messageId = ref.slice(0, colon);
  const attachmentId = ref.slice(colon + 1);

  // All channels share one mailbox, so any enabled channel's token works.
  const api = await getApiAnyFn(host);
  if (!api) {
    throw new Error(
      "No enabled Outlook Mail channel to source auth from. " +
        "Try refreshing the Outlook Mail connection."
    );
  }

  const att = await api.getAttachment(messageId, attachmentId);
  if (!att?.contentBytes) {
    throw new Error(
      `Outlook attachment ${attachmentId} on message ${messageId} has no downloadable content`
    );
  }

  const binary = atob(att.contentBytes);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }

  return {
    body: bytes,
    mimeType: att.contentType ?? "application/octet-stream",
    fileName: att.name,
  };
}
