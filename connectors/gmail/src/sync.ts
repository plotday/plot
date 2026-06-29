/**
 * Reusable Gmail sync functions extracted from the Gmail connector.
 *
 * These functions implement the mailbox-wide watch + Pub/Sub incremental sync
 * pipeline, the per-channel initial backfill, the outbound send paths
 * (reply / compose / RSVP-free email), and the two-way read/star sync —
 * without any connector-level scheduling. They accept a {@link GmailSyncHost}
 * instead of `this` so they can be invoked from both the standalone Gmail
 * connector and the combined Google connector (which wraps `this` in a
 * key-namespaced host).
 *
 * Scheduler operations (this.callback / this.runTask / this.scheduleRecurring /
 * this.cancelScheduledTask / this.cancelTask) are intentionally NOT performed
 * inline. Where a function genuinely needs to schedule work or create a
 * callback, it does so through `host.scheduler.*` — a thin set of bound
 * references back to the concrete connector's spied instance methods — or it
 * returns a descriptor and lets the caller own the scheduling.
 */

import {
  type CreateLinkDraft,
  type NoteWriteBackResult,
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

import { enrichLinkContactsFromGoogle } from "@plotday/connector-google-contacts";

import {
  GmailApi,
  type GmailThread,
  type AttachmentData,
  type SyncState,
  buildNewEmailMessage,
  buildReplyMessage,
  getHeader,
  isGmailRateLimitError,
  parseEmailAddresses,
  syncGmailChannel,
  syncGmailMailboxIncremental,
  transformGmailThread,
} from "./gmail-api";
import { gmailFacets } from "./gmail-facets";
import { classifySendError, type ClassifiedSendError } from "./gmail-send-errors";

// ---------------------------------------------------------------------------
// Persisted state shapes (shared with the connector)
// ---------------------------------------------------------------------------

/**
 * Persisted mailbox-wide watch state. Gmail allows one watch per (mailbox,
 * OAuth client); each call to `users.watch()` from the same OAuth client
 * replaces that client's previous registration. Different OAuth clients
 * (e.g. dev vs prod) maintain independent watches.
 */
export type MailboxWebhookState = {
  topicName: string;
  historyId: string;
  expiration: Date;
  created: string;
};

/**
 * A thread whose full-fetch failed during an incremental sync and must be
 * re-attempted on a later sync. `attempts` bounds retries so a permanently
 * unfetchable thread (e.g. deleted) is eventually abandoned with a log line
 * rather than re-fetched forever.
 */
export type PendingThread = { id: string; attempts: number };

/**
 * Persisted mailbox-wide incremental cursor. `pendingThreadIds` carries
 * thread fetches that failed on a prior sync so the next sync retries them —
 * without this, advancing `historyId` past a failed fetch silently loses that
 * mail.
 */
export type IncrementalState = {
  historyId?: string;
  lastSyncTime?: Date;
  pendingThreadIds?: PendingThread[];
};

/** Persisted per-channel initial-backfill cursor. */
export type InitialSyncState = {
  pageToken?: string;
  lastSyncTime?: Date;
};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/**
 * How often `selfHealCheck` runs while at least one channel is enabled. A
 * faster cadence improves recovery latency when push delivery breaks; a
 * slower one reduces Gmail API load. 1h is a comfortable middle.
 */
export const SELF_HEAL_INTERVAL_MS = 60 * 60 * 1000;

/**
 * If a watch is within this window of expiry, `selfHealCheck` re-establishes
 * it preemptively rather than relying solely on the scheduled renewal task
 * (which can fail to fire if the Durable Object alarm is dropped on
 * deploy/eviction). 36h gives the renewal task its scheduled run plus a
 * safety margin.
 */
export const WATCH_PREEMPTIVE_RENEW_MS = 36 * 60 * 60 * 1000;

/** Max times we re-attempt a failing thread fetch before giving up. */
export const MAX_THREAD_FETCH_ATTEMPTS = 5;

/**
 * Max full threads to fetch+process in a single incremental-sync pass. A large
 * history window (e.g. the cursor reseed after the Google composite re-home, or
 * a high-volume burst) used to load every changed thread into one isolate at
 * once and exceed the Cloudflare Worker memory limit; the isolate kill then
 * tore down the in-flight DB connection mid-save ("driver has already been
 * destroyed") and dropped mail. Bounding each pass keeps memory flat and the
 * overflow is carried in `pendingThreadIds` and drained on a scheduled
 * continuation. Sized to match the initial-backfill page (`getThreads`
 * maxResults = 20), the proven-safe per-isolate batch.
 */
export const MAX_INCREMENTAL_THREADS_PER_BATCH = 20;

/**
 * Max deferred write-backs drained per retry pass. A burst of to-do/read
 * changes that hit Gmail's per-user-per-minute quota is queued and drained in
 * bounded passes, mirroring the incremental-sync batch cap so one drain
 * execution stays well inside the worker memory + request budget.
 */
export const MAX_WRITEBACK_RETRY_PER_BATCH = 20;

/**
 * Max times a single deferred write-back is re-attempted before it is abandoned
 * with a log line. Bounds the retry so a permanently-failing write-back (e.g. a
 * thread deleted in Gmail) can't loop forever. The state still lives in Plot;
 * only the Gmail label mirror is given up.
 */
export const MAX_WRITEBACK_ATTEMPTS = 5;

/**
 * Cap on the persisted deferred-write-back queue. A sustained quota outage must
 * not grow connector storage without bound; past this, the oldest pending
 * write-backs are dropped (the freshest user intent is the most worth keeping).
 */
export const MAX_PENDING_WRITEBACKS = 500;

/**
 * Delay before a deferred write-back drain runs. Sized to clear Gmail's
 * per-user-per-minute quota window so the retry lands after the limit resets
 * rather than immediately re-hitting it. The drain is scheduled with a stable
 * key (`scheduleTask`) so repeated enqueues collapse to one and it never
 * hot-loops.
 */
export const WRITEBACK_RETRY_DELAY_MS = 60 * 1000;

/**
 * A to-do/read write-back to Gmail that was deferred because the per-user
 * Gmail quota was exhausted. Persisted in `writeback_pending` and re-applied by
 * {@link processWriteBackRetryFn} once the quota window clears, so a quota burst
 * never silently drops a star/read sync.
 */
export type PendingWriteBack = {
  /** `todo` mirrors the STARRED label; `read` mirrors the UNREAD label. */
  kind: "todo" | "read";
  threadId: string;
  channelId: string;
  /** todo: target starred state; read: target unread state. */
  value: boolean;
  /** Re-attempt counter; bounded by {@link MAX_WRITEBACK_ATTEMPTS}. */
  attempts: number;
};

/**
 * Idempotency window for `onCreateLink`. A compose draft carries no stable
 * id, so we dedupe by a content hash; two dispatches with identical content
 * within this window are treated as a callback retry (suppress the resend),
 * while a genuine re-compose later than this still sends.
 */
export const COMPOSE_DEDUP_WINDOW_MS = 10 * 60 * 1000;

/**
 * Per-channel system labels we route through, in priority order (most
 * specific first). Threads with custom user labels are handled separately
 * (custom labels always win over system labels).
 */
export const SYSTEM_LABEL_ORDER = [
  "STARRED",
  "IMPORTANT",
  "INBOX",
  "SENT",
  "DRAFT",
];

// ---------------------------------------------------------------------------
// Host interface
// ---------------------------------------------------------------------------

/**
 * Minimal interface that a Gmail sync host must satisfy. Both Gmail (using
 * `this` directly via public wrappers) and the combined Google connector
 * (using a key-namespaced host) implement this.
 *
 * `scheduler` carries the operations that CANNOT be extracted — creating
 * callbacks and scheduling/cancelling tasks live on the concrete connector
 * (they reference its own callback methods and durable-task keys). Extracted
 * functions invoke them through these bound references so the connector stays
 * the single owner of scheduling.
 */
export interface GmailSyncHost {
  /** The twist-instance id, used purely for log context. */
  readonly id: string;

  /** Persist a value under a connector-scoped key. */
  set(key: string, value: unknown): Promise<void>;
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
      /** Set a thread's to-do (starred) state from the connector's own write. */
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
      /** Create the mailbox-wide Gmail Pub/Sub topic webhook. */
      createWebhook(
        options: { pubsub: "gmail" },
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        callback: any
      ): Promise<string>;
      /** Delete a previously-created webhook/topic. */
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
    /** The connector callback handed to `network.createWebhook` for Pub/Sub. */
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    onGmailWebhook: any;
    /** Idempotently (re)establish the mailbox watch + Pub/Sub topic. */
    setupMailboxWebhook(): Promise<void>;
    /** Renew the mailbox watch before expiry. */
    renewMailboxWatch(): Promise<void>;
    /** (Re)schedule the durable mailbox-watch-renewal recurring task. */
    scheduleMailboxRenewal(expiration: Date): Promise<void>;
    /** (Re)schedule the durable mailbox-self-heal recurring task. */
    scheduleSelfHealCheck(): Promise<void>;
    /** Cancel a durable recurring task by key. */
    cancelScheduledTask(key: string): Promise<void>;
    /** Queue the mailbox-wide incremental sync as a task. */
    queueIncrementalSync(): Promise<void>;
    /**
     * Schedule the deferred write-back drain as a keyed, delayed one-shot task
     * (so repeated enqueues collapse and it never hot-loops). Drains
     * `writeback_pending` via {@link processWriteBackRetryFn}.
     */
    queueWriteBackRetry(): Promise<void>;
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
export function pickChannelForThread(
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

/**
 * Merges thread fetches that must be retried into the prior pending set.
 *
 * Two distinct inputs:
 * - `failedIds` — threads we *attempted* to fetch and that failed. Each bumps a
 *   per-thread attempt counter and is dropped once it exhausts
 *   {@link MAX_THREAD_FETCH_ATTEMPTS} retries (logged, since that change is then
 *   effectively lost).
 * - `deferredIds` — threads we *did not attempt* this pass because the per-pass
 *   fetch budget was reached (see {@link syncGmailMailboxIncremental}). These
 *   carry forward at their existing attempt count WITHOUT a bump — they were
 *   only postponed, not tried — so a large backlog drains across continuations
 *   instead of being abandoned after a few passes.
 *
 * Threads that succeeded this round appear in neither list and therefore fall
 * out of the pending set.
 */
export function mergePendingThreads(
  prior: PendingThread[],
  failedIds: string[],
  deferredIds: string[] = []
): PendingThread[] {
  const attemptsById = new Map(prior.map((p) => [p.id, p.attempts]));
  const merged: PendingThread[] = [];
  const seen = new Set<string>();
  for (const id of failedIds) {
    if (seen.has(id)) continue;
    seen.add(id);
    const attempts = (attemptsById.get(id) ?? 0) + 1;
    if (attempts > MAX_THREAD_FETCH_ATTEMPTS) {
      console.error(
        `[gmail] giving up on thread ${id} after ${attempts - 1} failed fetch attempts; its change may be lost`
      );
      continue;
    }
    merged.push({ id, attempts });
  }
  for (const id of deferredIds) {
    if (seen.has(id)) continue;
    seen.add(id);
    merged.push({ id, attempts: attemptsById.get(id) ?? 0 });
  }
  return merged;
}

// ---------------------------------------------------------------------------
// Auth helpers
// ---------------------------------------------------------------------------

/**
 * Build a GmailApi instance authenticated for the given channel.
 * Throws if the token is absent.
 */
export async function getApiFn(
  host: GmailSyncHost,
  channelId: string
): Promise<GmailApi> {
  const token = await host.tools.integrations.get(channelId);
  if (!token) {
    throw new Error("No Google authentication token available");
  }
  return new GmailApi(token.token);
}

/**
 * Like {@link getApiFn}, but returns `null` instead of throwing when the
 * channel resolves no auth token (lapsed / revoked Google OAuth).
 *
 * Use this in best-effort write-backs (to-do star, read-state) where a
 * re-auth-needed connection should degrade to a silent no-op: the user's
 * change already lives in Plot, and the connection's re-auth need is already
 * surfaced in the connections UI. Throwing there only pages error tracking on
 * every toggle. Sync paths that must surface a missing token still use the
 * throwing {@link getApiFn}.
 */
export async function tryGetApiFn(
  host: GmailSyncHost,
  channelId: string
): Promise<GmailApi | null> {
  const token = await host.tools.integrations.get(channelId);
  if (!token) return null;
  return new GmailApi(token.token);
}

/**
 * Returns a Gmail API client authed with any enabled channel's token.
 * Auth is per-Google-account (not per-label), so any enabled channelId
 * resolves to the same OAuth credential.
 */
export async function getApiAnyFn(
  host: GmailSyncHost
): Promise<GmailApi | null> {
  const enabled = await getEnabledChannelsFn(host);
  for (const channelId of enabled) {
    const token = await host.tools.integrations.get(channelId);
    if (token?.token) return new GmailApi(token.token);
  }
  return null;
}

// ---------------------------------------------------------------------------
// Enabled-channel set helpers
// ---------------------------------------------------------------------------

/** Returns the set of channelIds the user currently has enabled. */
export async function getEnabledChannelsFn(
  host: GmailSyncHost
): Promise<Set<string>> {
  const list = (await host.get<string[]>("enabled_channels")) ?? [];
  return new Set(list);
}

/** Add a channelId to the enabled set (idempotent, preserves order). */
export async function addEnabledChannelFn(
  host: GmailSyncHost,
  channelId: string
): Promise<void> {
  const list = (await host.get<string[]>("enabled_channels")) ?? [];
  if (list.includes(channelId)) return;
  list.push(channelId);
  await host.set("enabled_channels", list);
}

/** Remove a channelId from the enabled set. */
export async function removeEnabledChannelFn(
  host: GmailSyncHost,
  channelId: string
): Promise<void> {
  const list = (await host.get<string[]>("enabled_channels")) ?? [];
  const filtered = list.filter((c) => c !== channelId);
  if (filtered.length === list.length) return;
  await host.set("enabled_channels", filtered);
}

/** Whether a channel is currently enabled. */
export async function isChannelEnabledFn(
  host: GmailSyncHost,
  channelId: string
): Promise<boolean> {
  const list = (await host.get<string[]>("enabled_channels")) ?? [];
  return list.includes(channelId);
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
export async function findChannelForMessageFn(
  host: GmailSyncHost,
  messageId: string
): Promise<string | null> {
  // Fast path: check store cache
  const cached = await host.get<string>(`gmail:msg-channel:${messageId}`);
  if (cached) return cached;

  // Slow path: probe enabled channels
  const enabled = await getEnabledChannelsFn(host);
  for (const channelId of enabled) {
    try {
      const token = await host.tools.integrations.get(channelId);
      if (!token?.token) continue;
      const api = new GmailApi(token.token);
      // Probe with minimal format (just confirms the message exists for this auth)
      await api.call(`/messages/${messageId}`, { params: { format: "minimal" } });
      // Found it — cache and return
      await host.set(`gmail:msg-channel:${messageId}`, channelId);
      return channelId;
    } catch {
      // This channel can't access the message — try next
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Outbound send (bounded retry)
// ---------------------------------------------------------------------------

/**
 * Send with bounded in-process retry for transient failures. Neither send
 * path (onNoteCreated reply / onCreateLink compose) rides a retrying queue,
 * so transient blips (429 / 5xx / network) must be retried here. Up to 3
 * attempts with short backoff (well under the worker budget); permanent and
 * auth failures short-circuit immediately. Returns a discriminated result so
 * the caller can surface a `deliveryError` to the user instead of throwing.
 *
 * Truly unexpected errors (classified `unknown`) are rethrown so they still
 * reach error tracking.
 */
export async function sendWithRetry(
  send: () => Promise<{ id: string; threadId: string }>,
  label: "reply" | "compose"
): Promise<
  | { ok: true; result: { id: string; threadId: string } }
  | { ok: false; error: ClassifiedSendError }
> {
  const maxAttempts = 3;
  const backoffMs = [400, 1200];
  let lastTransient: ClassifiedSendError | null = null;

  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    try {
      const result = await send();
      return { ok: true, result };
    } catch (error) {
      const classified = classifySendError(error);
      if (classified.class === "unknown") {
        // Genuinely unexpected — let it propagate to error tracking.
        throw error;
      }
      if (classified.class !== "transient") {
        // Permanent or auth: retrying won't help.
        console.warn(
          `[gmail] sendWithRetry(${label}): ${classified.class} failure`,
          { code: classified.code }
        );
        return { ok: false, error: classified };
      }
      lastTransient = classified;
      const delay = backoffMs[attempt];
      if (delay !== undefined) {
        await new Promise((resolve) => setTimeout(resolve, delay));
      }
    }
  }

  console.warn(
    `[gmail] sendWithRetry(${label}): transient failure persisted after ${maxAttempts} attempts`,
    { code: lastTransient?.code }
  );
  return {
    ok: false,
    error: lastTransient ?? {
      class: "transient",
      code: "unknown",
      message: "Couldn't send after several attempts",
    },
  };
}

// ---------------------------------------------------------------------------
// Mailbox watch / Pub/Sub topic lifecycle
// ---------------------------------------------------------------------------

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
export async function ensureMailboxWebhookFn(
  host: GmailSyncHost
): Promise<void> {
  const existing = await host.get<MailboxWebhookState>("mailbox_webhook");
  if (!existing) {
    await host.scheduler.setupMailboxWebhook();
    return;
  }
  // Watch already established — re-assert the self-heal recurring task.
  // scheduleRecurring is idempotent (keyed replace), so this is safe to
  // call even if the task is already scheduled.
  await host.scheduler.scheduleSelfHealCheck();
}

/**
 * (Re)establish the mailbox-wide Gmail watch + Pub/Sub topic.
 *
 * Tears down any prior watch and topic first (Gmail enforces one watch per
 * (mailbox, OAuth client) and returns 400 "Only one user push notification
 * client allowed per developer (call /stop then try again)" when
 * users.watch() is called with a NEW topic while a watch is already active —
 * setupMailboxWebhook always mints a fresh topic), then creates a new topic,
 * registers the watch, persists state, seeds the incremental cursor, and
 * schedules renewal + self-heal.
 *
 * Scheduling (renewal + self-heal) goes through `host.scheduler`; everything
 * else is data-plane.
 */
export async function setupMailboxWebhookFn(
  host: GmailSyncHost
): Promise<void> {
  // Tear down any prior watch and topic before creating new ones. Gmail
  // enforces one watch per (mailbox, OAuth client) and returns 400
  // "Only one user push notification client allowed per developer (call
  // /stop then try again)" when users.watch() is called with a NEW topic
  // while a watch is already active. setupMailboxWebhook always creates
  // a fresh topic (createWebhook mints a new callback token → new topic
  // name), so the existing watch must be stopped first; the orphaned
  // Pub/Sub topic is also deleted to avoid leaking resources every
  // self-heal renewal.
  const existing = await host.get<MailboxWebhookState>("mailbox_webhook");
  await host.clear("mailbox_webhook");
  const cleanupApi = await getApiAnyFn(host);
  if (cleanupApi) {
    try {
      await cleanupApi.stopWatch();
    } catch (error) {
      // Best-effort — old watch may have already expired or never existed.
      console.warn(
        `Gmail setupMailboxWebhook [${host.id}]: stopWatch (cleanup) failed`,
        error
      );
    }
  }
  if (existing?.topicName) {
    try {
      await host.tools.network.deleteWebhook(existing.topicName);
    } catch (error) {
      console.warn(
        `Gmail setupMailboxWebhook [${host.id}]: deleteWebhook (cleanup) failed`,
        error
      );
    }
  }

  // `pubsub: "gmail"` returns a Gmail-specific Pub/Sub topic name (instead
  // of a webhook URL) to hand to users.watch. This opt-in must be explicit
  // so a sibling Google connector's provider-less webhook (Calendar, Drive)
  // is never misrouted to a Gmail topic. The webhook delivers no extra
  // args — onGmailWebhook operates on the single mailbox-wide watch.
  const topicName = await host.tools.network.createWebhook(
    { pubsub: "gmail" },
    host.scheduler.onGmailWebhook
  );

  const api = await getApiAnyFn(host);
  if (!api) {
    console.warn(
      `Gmail setupMailboxWebhook [${host.id}]: no enabled channel to source auth from`
    );
    return;
  }

  // No labelId → mailbox-wide notifications. Failures here are surfaced
  // via throw so the runtime captures the exception in PostHog. The
  // caller (selfHealCheck or onChannelEnabled task) is responsible for
  // logging context and deciding whether to retry.
  const watchResult = await api.setupWatch(topicName);
  const expiration = new Date(parseInt(watchResult.expiration));

  await host.set("mailbox_webhook", {
    topicName,
    historyId: watchResult.historyId,
    expiration,
    created: new Date().toISOString(),
  } satisfies MailboxWebhookState);

  // Seed the incremental cursor so the first webhook has somewhere to
  // start. Gmail's watch returns the current historyId; any change after
  // this point will appear in history.list from this seed.
  const existingIncremental =
    await host.get<{ historyId?: string }>("incremental_state");
  if (!existingIncremental?.historyId) {
    await host.set("incremental_state", {
      historyId: watchResult.historyId,
      lastSyncTime: new Date(),
    });
  }

  await host.scheduler.scheduleMailboxRenewal(expiration);
  await host.scheduler.scheduleSelfHealCheck();
  console.log(`Gmail setupMailboxWebhook [${host.id}]: watch established`, {
    topicName,
    historyId: watchResult.historyId,
    expiration: expiration.toISOString(),
  });
}

/**
 * Cancel renewal, stop the Gmail watch, delete the Pub/Sub topic, and
 * clear all mailbox-watch state. Called when the last channel is disabled
 * (and from preUpgrade for stale per-channel state).
 */
export async function teardownMailboxWebhookFn(
  host: GmailSyncHost
): Promise<void> {
  await host.scheduler.cancelScheduledTask("mailbox-watch-renewal");
  await host.scheduler.cancelScheduledTask("mailbox-self-heal");

  const api = await getApiAnyFn(host);
  if (api) {
    try {
      await api.stopWatch();
    } catch (error) {
      console.error(
        `Gmail teardownMailboxWebhook [${host.id}]: stopWatch failed`,
        error
      );
    }
  }

  const webhook = await host.get<MailboxWebhookState>("mailbox_webhook");
  if (webhook?.topicName) {
    try {
      await host.tools.network.deleteWebhook(webhook.topicName);
    } catch (error) {
      console.error(
        `Gmail teardownMailboxWebhook [${host.id}]: deleteWebhook failed`,
        error
      );
    }
  }
  await host.clear("mailbox_webhook");
  await host.clear("incremental_state");
  await host.clear("last_webhook_received_at");
}

/**
 * Computes the renewal schedule for the mailbox watch given an expiration.
 *
 * Returns the durable recurring-task parameters the caller passes to
 * `scheduleRecurring("mailbox-watch-renewal", ...)`. The ceiling (3.5 days,
 * half the 7-day Gmail watch) ensures the watch is renewed even if a precise
 * renewal beat is missed; firstRunAt tightens the next run to 1 day before the
 * current expiration. The platform clamps a past firstRunAt to now, so no
 * immediate-renew branch is needed.
 */
export function getMailboxRenewalSchedule(expiration: Date): {
  intervalMs: number;
  firstRunAt: Date;
} {
  const renewalTime = new Date(expiration.getTime() - 24 * 60 * 60 * 1000);
  return {
    intervalMs: 3.5 * 24 * 60 * 60 * 1000,
    firstRunAt: renewalTime,
  };
}

/**
 * Renews the Gmail mailbox watch before it expires. On primary-path
 * failure, falls back to a full mailbox-webhook re-setup. If both paths
 * fail the error is rethrown so the runtime captures it in PostHog —
 * `selfHealCheck` is the safety net that retries on the next interval.
 */
export async function renewMailboxWatchFn(host: GmailSyncHost): Promise<void> {
  let primaryError: unknown;
  try {
    const api = await getApiAnyFn(host);
    if (!api) {
      console.warn(
        `Gmail renewMailboxWatch [${host.id}]: no enabled channel to source auth from`
      );
      return;
    }

    const webhook = await host.get<MailboxWebhookState>("mailbox_webhook");
    if (!webhook?.topicName) {
      await host.scheduler.setupMailboxWebhook();
      return;
    }

    const watchResult = await api.setupWatch(webhook.topicName);
    const expiration = new Date(parseInt(watchResult.expiration));

    await host.set("mailbox_webhook", {
      ...webhook,
      historyId: watchResult.historyId,
      expiration,
    } satisfies MailboxWebhookState);

    await host.scheduler.scheduleMailboxRenewal(expiration);
    await host.scheduler.scheduleSelfHealCheck();
    console.log(`Gmail renewMailboxWatch [${host.id}]: watch renewed`, {
      historyId: watchResult.historyId,
      expiration: expiration.toISOString(),
    });
    return;
  } catch (error) {
    primaryError = error;
    console.error(
      `Gmail renewMailboxWatch [${host.id}]: renewal failed, attempting full recreate`,
      error
    );
  }

  // Fallback path: tear down and recreate. If this also fails, throw so
  // the runtime surfaces the error to PostHog.
  try {
    await host.scheduler.setupMailboxWebhook();
  } catch (retryError) {
    console.error(
      `Gmail renewMailboxWatch [${host.id}]: fallback setup also failed`,
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
 * scheduled renewal task won't catch:
 *
 * - the renewal Durable-Object alarm gets dropped on a deploy or DO eviction,
 * - `users.watch()` succeeded but the Pub/Sub push subscription got
 *   tombstoned or tore itself down on consecutive delivery failures,
 * - notifications stopped arriving for an unrelated GCP-side reason.
 *
 * Each run does three things. The platform re-arms the recurring task after
 * every `intervalMs`, so a single failed run never permanently breaks the
 * cycle — the callback does NOT reschedule itself:
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
 * the runtime captures the exception in PostHog. The platform re-arms the
 * next run regardless of whether the callback throws.
 */
export async function selfHealCheckFn(host: GmailSyncHost): Promise<void> {
  const now = new Date();

  const enabled = await getEnabledChannelsFn(host);
  if (enabled.size === 0) {
    // No channels enabled — cancel the recurring task so it stops firing.
    // onChannelEnabled will re-assert it next time a channel is enabled.
    await host.scheduler.cancelScheduledTask("mailbox-self-heal");
    console.log(
      `Gmail selfHealCheck [${host.id}]: no enabled channels, ending cycle`
    );
    return;
  }

  let unrecoverableError: unknown;
  let action: "healthy" | "renewed" | "recreated" | "missed_history" =
    "healthy";
  let missedThreads = 0;

  const webhook = await host.get<MailboxWebhookState>("mailbox_webhook");
  const incremental = await host.get<IncrementalState>("incremental_state");
  const lastWebhookAt = await host.get<string>("last_webhook_received_at");

  // 1. Catch any history we missed. Works even when the watch is broken
  //    because we're calling history.list directly, not waiting for a push.
  if (incremental?.historyId) {
    try {
      const api = await getApiAnyFn(host);
      if (api) {
        const pending = incremental.pendingThreadIds ?? [];
        const result = await syncGmailMailboxIncremental(
          api,
          incremental.historyId,
          pending.map((p) => p.id),
          MAX_INCREMENTAL_THREADS_PER_BATCH
        );
        if (result.expired) {
          // History window expired; reseed cursor (same fallback as
          // incrementalSyncBatch).
          if (webhook?.historyId) {
            await host.set("incremental_state", {
              historyId: webhook.historyId,
              lastSyncTime: now,
            });
          } else {
            await host.clear("incremental_state");
          }
          console.warn(
            `Gmail selfHealCheck [${host.id}]: history window expired, reseeded cursor`
          );
        } else {
          if (result.threads.length > 0) {
            missedThreads = result.threads.length;
            await processEmailThreadsFn(host, result.threads, false);
            // Missed history while a watch existed = push delivery is
            // broken. Force a fresh watch setup below.
            action = "missed_history";
          }
          // Always advance the cursor and carry forward failed AND deferred
          // fetches so we neither re-walk the whole window nor lose unfetched
          // mail. A large window discovered here is bounded the same way the
          // webhook path is (MAX_INCREMENTAL_THREADS_PER_BATCH); the overflow
          // drains on a queued continuation below.
          await host.set("incremental_state", {
            historyId: result.historyId,
            lastSyncTime: now,
            pendingThreadIds: mergePendingThreads(
              pending,
              result.failedThreadIds,
              result.deferredThreadIds
            ),
          });
          if (result.deferredThreadIds.length > 0) {
            await host.scheduler.queueIncrementalSync();
          }
        }
      }
    } catch (error) {
      // History check is best-effort; don't let it abort the rest of
      // self-heal — we still want to verify watch state.
      console.error(
        `Gmail selfHealCheck [${host.id}]: history check failed`,
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
        `Gmail selfHealCheck [${host.id}]: watch expired ${-msToExpiry}ms ago`
      );
    } else if (msToExpiry < WATCH_PREEMPTIVE_RENEW_MS) {
      // <36h to expiry — preemptively renew (covers renewal alarm misses).
      needsReup = true;
      if (action === "healthy") action = "renewed";
    }
  }

  if (needsReup) {
    try {
      await host.scheduler.setupMailboxWebhook();
    } catch (error) {
      // Setup failed permanently. Capture for PostHog by rethrowing AFTER
      // we've rescheduled the next self-heal run.
      unrecoverableError = error;
      console.error(
        `Gmail selfHealCheck [${host.id}]: setupMailboxWebhook failed`,
        error
      );
    }
  }

  // Heartbeat with resolved outcome so a single log line tells the full
  // story (action, thread count, watch state, push silence duration).
  console.log(`Gmail selfHealCheck [${host.id}]: ${action}`, {
    missedThreads,
    enabledChannels: Array.from(enabled),
    historyId: incremental?.historyId ?? null,
    watchTopic: webhook?.topicName ?? null,
    watchExpiration: webhook?.expiration
      ? new Date(webhook.expiration).toISOString()
      : null,
    lastWebhookAt: lastWebhookAt ?? null,
    minutesSinceLastWebhook: lastWebhookAt
      ? Math.round((now.getTime() - new Date(lastWebhookAt).getTime()) / 60000)
      : null,
    now: now.toISOString(),
  });

  // The platform re-arms this recurring task automatically — no manual
  // reschedule needed. setupMailboxWebhook may call scheduleSelfHealCheck()
  // above; that's a keyed replace and is harmless.

  if (unrecoverableError) {
    throw unrecoverableError instanceof Error
      ? unrecoverableError
      : new Error(String(unrecoverableError));
  }
}

// ---------------------------------------------------------------------------
// Sync state machine
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
 * Per-channel initial backfill. Walks `users.threads.list?labelIds=<id>`
 * paginated and processes results. Used the FIRST time a channel is
 * enabled; ongoing changes flow through `incrementalSyncBatch` instead.
 *
 * Returns `{ next }` when more pages remain (caller schedules the next batch)
 * and `{ done: true }` when the backfill is complete or skipped. The
 * data-plane signal `channelSyncCompleted` is fired here (not a scheduling
 * operation).
 */
export async function initialSyncBatchFn(
  host: GmailSyncHost,
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
      await processEmailThreadsFn(host, result.threads, true, channelId);
    }

    if (result.hasMore) {
      await host.set(`initial_state_${channelId}`, {
        pageToken: result.state.pageToken,
        lastSyncTime: result.state.lastSyncTime,
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
 * Mailbox-wide incremental sync. Triggered from a Pub/Sub webhook. Calls
 * Gmail's history.list with NO label filter so we see every change, then
 * routes each affected thread to whichever enabled channel(s) it actually
 * matches (based on its messages' labels). On 404 (history-window
 * expired), reseeds the cursor from the watch's current historyId — we
 * don't re-walk every label here, since label-scoped re-walks happen
 * via a fresh onChannelEnabled if needed.
 */
export async function incrementalSyncBatchFn(
  host: GmailSyncHost
): Promise<void> {
  try {
    const enabled = await getEnabledChannelsFn(host);
    if (enabled.size === 0) return;

    const state = await host.get<IncrementalState>("incremental_state");
    if (!state?.historyId) {
      // Nothing to do — webhook will re-seed on next watch setup.
      return;
    }

    const api = await getApiAnyFn(host);
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
      pending.map((p) => p.id),
      MAX_INCREMENTAL_THREADS_PER_BATCH
    );
    if (result.expired) {
      // Recover by reseeding from the watch's most recent historyId.
      const webhook = await host.get<MailboxWebhookState>("mailbox_webhook");
      if (webhook?.historyId) {
        await host.set("incremental_state", {
          historyId: webhook.historyId,
          lastSyncTime: new Date(),
        });
      } else {
        await host.clear("incremental_state");
      }
      console.warn(
        "Gmail mailbox history expired; reseeded incremental cursor"
      );
      return;
    }

    if (result.threads.length > 0) {
      await processEmailThreadsFn(host, result.threads, false);
    }

    // Advance the cursor, but carry forward any thread fetches that failed
    // (so the next sync retries them) and any that were deferred to stay under
    // the per-pass memory budget — otherwise moving past either loses mail.
    await host.set("incremental_state", {
      historyId: result.historyId,
      lastSyncTime: new Date(),
      pendingThreadIds: mergePendingThreads(
        pending,
        result.failedThreadIds,
        result.deferredThreadIds
      ),
    });

    // Drain the rest on a scheduled continuation when threads were deferred for
    // the per-pass cap. Self-chain exit condition: each pass processes up to
    // MAX_INCREMENTAL_THREADS_PER_BATCH threads (deferred ones first), so the
    // backlog strictly shrinks and the chain terminates once nothing is
    // deferred. Failed-only pending does NOT re-queue here — those retry on the
    // next webhook/self-heal — so a permanently-unfetchable thread can't spin a
    // hot loop.
    if (result.deferredThreadIds.length > 0) {
      await host.scheduler.queueIncrementalSync();
    }
  } catch (error) {
    console.error("Error in Gmail incremental sync batch:", error);
    throw error;
  }
}

// ---------------------------------------------------------------------------
// Thread processing
// ---------------------------------------------------------------------------

export async function processEmailThreadsFn(
  host: GmailSyncHost,
  threads: GmailThread[],
  initialSync: boolean,
  forceChannelId?: string
): Promise<void> {
  // When forceChannelId is set we already know which channel owns these
  // threads (per-channel initial backfill). For mailbox-wide incremental
  // sync we pick a channel per thread by inspecting its message labels.
  const enabledChannels = forceChannelId
    ? new Set([forceChannelId])
    : await getEnabledChannelsFn(host);
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
      const noteContacts = (
        note as { accessContacts?: Array<{ email?: string }> }
      ).accessContacts;
      for (const c of noteContacts ?? []) {
        if (c?.email) allEmails.add(c.email);
      }
    }
  }

  if (allEmails.size > 0) {
    // Auth scope is per-account, not per-channel; any enabled channel ID
    // sources the same token.
    const authChannelId = forceChannelId ?? transformed[0]?.channelId ?? null;
    if (authChannelId) {
      try {
        const token = await host.tools.integrations.get(authChannelId);
        if (token) {
          await enrichLinkContactsFromGoogle(
            transformed.map((t) => t.plot),
            token.token,
            token.scopes
          );
        }
      } catch (err) {
        // Enrichment is best-effort — Gravatar fallback in the client still
        // covers anyone the People API doesn't return.
        console.warn("Failed to enrich Gmail contacts (non-blocking):", err);
      }
    }
  }

  for (const { thread, plot: plotThread, channelId } of transformed) {
    try {
      if (!plotThread.notes || plotThread.notes.length === 0) continue;

      // Cache message → channel mapping so downloadAttachment can look up
      // which channel owns a given Gmail message ID.
      for (const message of thread.messages ?? []) {
        await host.set(`gmail:msg-channel:${message.id}`, channelId);
      }

      // Filter out notes for messages we sent (dedup)
      const filtered = [];
      for (const note of plotThread.notes) {
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

      const isUnread =
        thread.messages?.some((m) => m.labelIds?.includes("UNREAD")) ?? false;

      if (initialSync) {
        plotThread.unread = false;
        plotThread.archived = false;
        await host.set(`unread:${thread.id}`, isUnread);
      } else {
        const wasUnread = await host.get<boolean>(`unread:${thread.id}`);
        if (wasUnread == null) {
          // First time seeing this thread incrementally.
          // If it is already read in Gmail, align Plot's state.
          if (!isUnread) {
            plotThread.unread = false;
          }
        } else if (isUnread !== wasUnread) {
          // The unread state changed in Gmail, so write it to Plot.
          plotThread.unread = isUnread;
        }
        await host.set(`unread:${thread.id}`, isUnread);
      }

      // Inject channel ID for priority routing and sync metadata
      plotThread.channelId = channelId;
      plotThread.meta = {
        ...plotThread.meta,
        syncProvider: "google",
        syncableId: channelId,
      };

      // Compute classifier facets from the parent message's headers + body.
      const facetParent = thread.messages.find(
        (m) => !m.labelIds?.includes("DRAFT")
      );
      if (facetParent) {
        // Use the parent message's full note body (not the short preview snippet)
        // so the classifier's reading-vs-notification length split can fire.
        const facetNote = plotThread.notes?.find(
          (n) => "key" in n && (n as { key: string }).key === facetParent.id
        );
        const facetBody = facetNote?.content ?? plotThread.preview ?? "";
        const { facets, cta } = gmailFacets(facetParent, facetBody);
        plotThread.facets = cta ? { ...facets, format: cta.kind } : facets;
        if (cta && facetNote) {
          (facetNote as { cta?: Cta | null }).cta = cta;
        }
      }

      // Star ↔ todo sync: detect star changes and sync to Plot todo status.
      // Statuses have been removed; every thread (including archived) is saved
      // with no status and treated like any other thread.
      const isStarred = GmailApi.isStarred(thread);
      // Save link directly via integrations
      const savedThreadId = await host.tools.integrations.saveLink(plotThread);
      if (!savedThreadId) continue; // Link was filtered (e.g., older than sync history) — skip star sync

      const wasStarred = await host.get<boolean>(`starred:${thread.id}`);

      // Echo suppression relies entirely on the `starred` state: when
      // Plot→Gmail writes STARRED, onThreadToDo updates this
      // state *before* the API call. The resulting Gmail webhook sees
      // isStarred === wasStarred and this branch doesn't run.
      if (isStarred !== !!wasStarred) {
        const actorId = await host.get<ActorId>("auth_actor_id");
        // Use the canonical Gmail thread URL as the source identifier
        const sourceUrl = `https://mail.google.com/mail/u/0/#inbox/${thread.id}`;
        if (actorId) {
          await host.tools.integrations.setThreadToDo(
            sourceUrl,
            actorId,
            isStarred
          );
          // Prevent the onThreadToDo callback from echoing back
          await host.set(`skip_todo_writeback:${thread.id}`, true);
        }
        await host.set(`starred:${thread.id}`, isStarred);
      }
    } catch (error) {
      console.error(`Failed to process Gmail thread ${thread.id}:`, error);
      // Continue processing other threads
    }
  }
}

// ---------------------------------------------------------------------------
// Outbound: reply / read / star / compose
// ---------------------------------------------------------------------------

export async function onNoteCreatedFn(
  host: GmailSyncHost,
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
  const priorSend = await host.get<{ messageId: string }>(sendGuardKey);
  if (priorSend?.messageId) {
    console.log(
      `[gmail] onNoteCreated: note ${note.id} already sent as ${priorSend.messageId}, skipping resend`
    );
    return { key: priorSend.messageId };
  }

  const api = await getApiFn(host, channelId);

  // Fetch the full Gmail thread to get message headers
  const gmailThread = await api.getThread(threadId);
  if (!gmailThread.messages || gmailThread.messages.length === 0) {
    console.error("Gmail thread has no messages");
    return;
  }

  // Determine target message: specific replied-to note or last message in thread
  let targetMessage = gmailThread.messages[gmailThread.messages.length - 1];
  if (meta.reNoteKey) {
    const found = gmailThread.messages.find((m) => m.id === meta.reNoteKey);
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
        const file = await host.tools.files.read(action.fileId);
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

  const sent = await sendWithRetry(() => api.sendMessage(raw, threadId), "reply");
  if (!sent.ok) {
    // Surface the failure to the user (thread goes unread + "Failed to send"
    // affordance). Do NOT set the idempotency guard, so an explicit retry
    // re-attempts the send. Clearing `deliveryError` happens automatically
    // on the next successful write-back.
    return {
      deliveryError: { code: sent.error.code, message: sent.error.message },
    };
  }
  const result = sent.result;

  // Record the idempotency guard so a retried dispatch of this note does
  // not send a second copy (see the guard check above).
  await host.set(sendGuardKey, { messageId: result.id });

  // Store sent message ID for dedup when synced back
  await host.set(`sent:${result.id}`, true);

  // Return the Gmail message id as the note key so the runtime links this
  // Plot note to the sent message. We intentionally do NOT provide
  // `externalContent`: Gmail does not return the normalized message body
  // from `send`, and fetching + parsing the multipart payload just to
  // compute a baseline is expensive. The first incremental sync-in of the
  // sent message will establish the baseline naturally (runtime records
  // the stored content as the baseline on first external ingest).
  // `deliveryError: null` clears any prior "Failed to send" marker from a
  // previous attempt that has now succeeded on retry.
  return { key: result.id, deliveryError: null };
}

export async function onThreadReadFn(
  host: GmailSyncHost,
  thread: Thread,
  _actor: Actor,
  unread: boolean
): Promise<void> {
  const meta = thread.meta ?? {};
  const channelId = (meta.channelId ?? meta.syncableId) as string;
  if (!channelId) return;

  const threadId = meta.threadId as string;
  if (!threadId) return;

  // Best-effort: if the connection lost its Google auth, skip the label
  // write-back instead of throwing (read-state already lives in Plot).
  const api = await tryGetApiFn(host, channelId);
  if (!api) return;

  // Cache the new unread state before modifying Gmail to prevent echo loops
  await host.set(`unread:${threadId}`, unread);

  try {
    if (unread) {
      await api.modifyThread(threadId, ["UNREAD"]);
    } else {
      await api.modifyThread(threadId, undefined, ["UNREAD"]);
    }
  } catch (error) {
    if (isGmailRateLimitError(error)) {
      // Gmail's per-user quota is exhausted even after GmailApi.call's in-process
      // backoff. Defer the write-back rather than drop it — the read state
      // already lives in Plot; the drain re-applies the UNREAD label once the
      // quota window clears.
      console.warn(
        `[gmail] onThreadRead: Gmail quota hit, deferring read write-back for thread ${threadId}`
      );
      await deferWriteBackFn(host, {
        kind: "read",
        threadId,
        channelId,
        value: unread,
      });
      return;
    }
    throw error;
  }
}

export async function onThreadToDoFn(
  host: GmailSyncHost,
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
  if (await host.get(`skip_todo_writeback:${threadId}`)) {
    await host.clear(`skip_todo_writeback:${threadId}`);
    return;
  }

  // Best-effort: if the connection lost its Google auth, skip the star
  // write-back instead of throwing (the to-do change already lives in Plot).
  // Resolved before the local-state mutation below so a no-token call is a
  // complete no-op and leaves no divergent `starred:` marker.
  const api = await tryGetApiFn(host, channelId);
  if (!api) return;

  // Update local state BEFORE calling Gmail, so the webhook fired by our
  // own write sees isStarred === wasStarred and doesn't re-propagate.
  await host.set(`starred:${threadId}`, todo);

  try {
    if (todo) {
      // Add STARRED, and re-add INBOX so an archived email returns to the
      // inbox when the user adds it to their agenda in Plot.
      await api.modifyThread(threadId, ["STARRED", "INBOX"]);
    } else {
      await api.modifyThread(threadId, undefined, ["STARRED"]);
    }
  } catch (error) {
    if (isGmailRateLimitError(error)) {
      // Gmail's per-user quota is exhausted even after GmailApi.call's in-process
      // backoff. Defer the write-back rather than drop it — the to-do state
      // already lives in Plot; the drain re-applies the STARRED label once the
      // quota window clears.
      console.warn(
        `[gmail] onThreadToDo: Gmail quota hit, deferring star write-back for thread ${threadId}`
      );
      await deferWriteBackFn(host, {
        kind: "todo",
        threadId,
        channelId,
        value: todo,
      });
      return;
    }
    throw error;
  }
}

// ---------------------------------------------------------------------------
// Deferred write-back retry (quota-exhaustion drain)
// ---------------------------------------------------------------------------

/**
 * Merge a freshly-deferred write-back into the persisted queue. Dedupes by
 * (kind, threadId) — a newer change to the same thread supersedes an older
 * pending one (last-write-wins) and resets its attempt counter (it is a fresh
 * intent, not a continued retry). Bounds the queue to
 * {@link MAX_PENDING_WRITEBACKS}, dropping the oldest entries first.
 */
export function mergePendingWriteBack(
  pending: PendingWriteBack[],
  next: Omit<PendingWriteBack, "attempts">
): PendingWriteBack[] {
  const deduped = pending.filter(
    (p) => !(p.kind === next.kind && p.threadId === next.threadId)
  );
  deduped.push({ ...next, attempts: 0 });
  return deduped.length > MAX_PENDING_WRITEBACKS
    ? deduped.slice(deduped.length - MAX_PENDING_WRITEBACKS)
    : deduped;
}

/**
 * Persist a deferred write-back and schedule the drain. Called from the
 * write-back callbacks when Gmail's quota is exhausted, so a star/read change is
 * retried later instead of silently lost.
 */
async function deferWriteBackFn(
  host: GmailSyncHost,
  next: Omit<PendingWriteBack, "attempts">
): Promise<void> {
  const pending =
    (await host.get<PendingWriteBack[]>("writeback_pending")) ?? [];
  await host.set("writeback_pending", mergePendingWriteBack(pending, next));
  await host.scheduler.queueWriteBackRetry();
}

/** Apply one pending write-back to Gmail (STARRED / UNREAD label mirror). */
function applyWriteBack(api: GmailApi, item: PendingWriteBack): Promise<void> {
  if (item.kind === "todo") {
    return item.value
      ? api.modifyThread(item.threadId, ["STARRED", "INBOX"])
      : api.modifyThread(item.threadId, undefined, ["STARRED"]);
  }
  return item.value
    ? api.modifyThread(item.threadId, ["UNREAD"])
    : api.modifyThread(item.threadId, undefined, ["UNREAD"]);
}

/**
 * Drain the deferred write-back queue in one bounded pass. Applies up to
 * {@link MAX_WRITEBACK_RETRY_PER_BATCH} pending write-backs:
 *  - success → removed from the queue;
 *  - still rate-limited → kept with a bumped attempt, until
 *    {@link MAX_WRITEBACK_ATTEMPTS} is reached, then abandoned with a log;
 *  - lost auth (no token) → dropped (the state already lives in Plot, and the
 *    re-auth need is surfaced in the connections UI);
 *  - any other error → dropped with a log, so one bad thread can't wedge the
 *    queue (the state remains correct in Plot).
 *
 * Self-terminating: re-queues only while work remains. The connector schedules
 * the continuation with a stable key + delay (see `WRITEBACK_RETRY_DELAY_MS`),
 * so a persistent quota outage retries on a slow cadence rather than hot-looping.
 */
export async function processWriteBackRetryFn(
  host: GmailSyncHost
): Promise<void> {
  const pending =
    (await host.get<PendingWriteBack[]>("writeback_pending")) ?? [];
  if (pending.length === 0) return;

  const batch = pending.slice(0, MAX_WRITEBACK_RETRY_PER_BATCH);
  const overflow = pending.slice(MAX_WRITEBACK_RETRY_PER_BATCH);
  const keep: PendingWriteBack[] = [];

  for (const item of batch) {
    const api = await tryGetApiFn(host, item.channelId);
    if (!api) {
      console.warn(
        `[gmail] writeback drain: channel ${item.channelId} has no token, dropping ${item.kind} write-back for thread ${item.threadId}`
      );
      continue;
    }
    try {
      await applyWriteBack(api, item);
    } catch (error) {
      if (isGmailRateLimitError(error)) {
        const attempts = item.attempts + 1;
        if (attempts >= MAX_WRITEBACK_ATTEMPTS) {
          console.error(
            `[gmail] writeback drain: giving up on ${item.kind} write-back for thread ${item.threadId} after ${attempts} attempts`
          );
          continue;
        }
        keep.push({ ...item, attempts });
        continue;
      }
      console.error(
        `[gmail] writeback drain: dropping ${item.kind} write-back for thread ${item.threadId}:`,
        error
      );
    }
  }

  const remaining = [...keep, ...overflow];
  if (remaining.length > 0) {
    await host.set("writeback_pending", remaining);
    // More to do (rate-limited retries and/or overflow) — schedule the next
    // delayed pass. Keyed scheduling in the connector collapses duplicates.
    await host.scheduler.queueWriteBackRetry();
  } else {
    await host.clear("writeback_pending");
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
export async function onCreateLinkFn(
  host: GmailSyncHost,
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
  const api = await getApiAnyFn(host);
  if (!api) {
    console.error(
      "[gmail] onCreateLink: no enabled channel to source auth from"
    );
    return null;
  }

  const profile = await api.getProfile();
  const fromEmail = profile.emailAddress;

  const subject = draft.title || "";
  const body = draft.noteContent ?? "";

  // channelId: use the first enabled channel so onNoteCreated (reply path)
  // can resolve the OAuth token via getApi(channelId).
  const enabledChannels = await getEnabledChannelsFn(host);
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
      status: null,
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
      subject,
      body,
      [...toEmails].sort(),
      [...ccEmails].sort(),
      [...bccEmails].sort(),
    ])
  )}`;
  const prior = await host.get<{
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

  const sent = await sendWithRetry(() => api.sendNewMessage(raw), "compose");
  if (!sent.ok) {
    // Compose send failed: don't create a link (there's no Gmail thread to
    // bind). Return a delivery-error marker so the runtime marks the thread's
    // opening note "Failed to send" and the thread goes unread. The user's
    // composed content is preserved in Plot; an explicit retry re-composes.
    return {
      originatingNote: {
        deliveryError: { code: sent.error.code, message: sent.error.message },
      },
    };
  }
  const result = sent.result;
  const gmailThreadId = result.threadId;
  const gmailMessageId = result.id;

  // Record the idempotency guard so a retried dispatch reuses this send
  // rather than emitting a duplicate email.
  await host.set(dedupKey, { gmailThreadId, at: Date.now() });

  // Suppress the echo when this sent message is synced back via Gmail's
  // incremental history. The message id is the note key the sync path
  // uses (same as onNoteCreated dedup).
  await host.set(`sent:${gmailMessageId}`, true);

  // Bind the opening note to this sent message — the bare message id, same
  // key onNoteCreated returns for a reply and sync-in uses. No
  // externalContent: Gmail's send doesn't return the stored body (same
  // tradeoff as onNoteCreated), and the sent message is echo-suppressed
  // above, so no baseline round-trip is needed. `deliveryError: null` clears
  // any prior "Failed to send" marker now that the compose has succeeded.
  return {
    ...linkFor(gmailThreadId),
    originatingNote: { key: gmailMessageId, deliveryError: null },
  };
}

// ---------------------------------------------------------------------------
// Pub/Sub webhook handler
// ---------------------------------------------------------------------------

/**
 * Return type for {@link onGmailWebhookFn}.
 *
 * - `queueIncrementalSync: true`: the caller should queue an incremental
 *   sync (via `this.runTask(await this.callback(this.incrementalSyncBatch))`).
 * - `done: true`: nothing to queue (invalid/empty notification).
 */
export type GmailWebhookResult =
  | { queueIncrementalSync: true }
  | { done: true };

/**
 * Pub/Sub webhook handler. Single mailbox-wide watch → single handler.
 * Decodes Gmail's history-id notification and returns a descriptor telling
 * the caller whether to queue a mailbox-incremental sync.
 *
 * Self-heal re-assertion + reactive watch renewal are routed through
 * `host.scheduler` so this function performs no scheduling itself.
 */
export async function onGmailWebhookFn(
  host: GmailSyncHost,
  request: WebhookRequest
): Promise<GmailWebhookResult> {
  // Record receipt before any early returns so `selfHealCheck` can
  // distinguish "watch is healthy, just no new mail" from "we haven't
  // heard from Gmail in hours". This is the only signal the connector has
  // that push delivery is working.
  await host.set("last_webhook_received_at", new Date().toISOString());

  // Self-heal bootstrap: re-asserts the durable recurring task on every
  // webhook delivery. scheduleRecurring is idempotent (keyed replace), so
  // this is safe to call even when the task is already scheduled.
  try {
    await host.scheduler.scheduleSelfHealCheck();
  } catch (error) {
    console.error(
      `Gmail onGmailWebhook [${host.id}]: failed to bootstrap self-heal`,
      error
    );
  }

  const body = request.body as { message?: { data: string } };
  const message = body?.message;
  if (!message) {
    console.warn(`Gmail onGmailWebhook [${host.id}]: no message in body`);
    return { done: true };
  }

  let data: { historyId?: string; emailAddress?: string };
  try {
    const decoded = atob(message.data);
    data = JSON.parse(decoded);
  } catch (error) {
    console.error(
      `Gmail onGmailWebhook [${host.id}]: failed to decode message`,
      error
    );
    return { done: true };
  }

  if (!data.historyId) return { done: true };

  // Renew the watch if its expiration has passed.
  const webhook = await host.get<MailboxWebhookState>("mailbox_webhook");
  if (webhook?.expiration && new Date(webhook.expiration) < new Date()) {
    await host.scheduler.renewMailboxWatch();
  }

  // Make sure incremental_state exists (carries our last-acknowledged
  // historyId). If we somehow lost it, seed from the webhook's historyId
  // — we'll miss anything that happened between teardown and now, but
  // that's strictly bounded.
  const existing = await host.get<{ historyId?: string }>("incremental_state");
  if (!existing?.historyId) {
    await host.set("incremental_state", {
      historyId: data.historyId,
      lastSyncTime: new Date(),
    });
  }

  return { queueIncrementalSync: true };
}

// ---------------------------------------------------------------------------
// Attachment download
// ---------------------------------------------------------------------------

/**
 * Downloads an attachment from Gmail identified by the opaque `ref` string
 * emitted during inbound sync. The ref format is `${messageId}:${attachmentId}`.
 */
export async function downloadAttachmentFn(
  host: GmailSyncHost,
  ref: string
): Promise<
  | { redirectUrl: string }
  | { body: Uint8Array; mimeType: string; fileName?: string }
> {
  const colon = ref.indexOf(":");
  if (colon < 0) {
    throw new Error(`Invalid Gmail attachment ref: ${ref}`);
  }
  const messageId = ref.slice(0, colon);
  const attachmentId = ref.slice(colon + 1);

  const channelId = await findChannelForMessageFn(host, messageId);
  if (!channelId) {
    throw new Error(
      `No Gmail channel found for message ${messageId}. ` +
        `The channel may have been disabled or the message is outside the sync window. ` +
        `Try refreshing the Gmail connection.`
    );
  }

  const api = await getApiFn(host, channelId);
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
