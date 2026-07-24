import {
  type Action,
  ActionType,
  type Actor,
  type ActorId,
  ConferencingProvider,
  Connector,
  type CreateLinkDraft,
  type Link,
  type NewContact,
  type NewLinkWithNotes,
  type NoteWriteBackResult,
  type ProductInfo,
  type Serializable,
  type Thread,
  type ToolBuilder,
} from "@plotday/twister";
import type { CreateLinkResult, Note } from "@plotday/twister/plot";
import { Options } from "@plotday/twister/options";
import type {
  NewSchedule,
  NewScheduleContact,
  NewScheduleOccurrence,
  ScheduleContactStatus,
} from "@plotday/twister/schedule";
import type { Callback } from "@plotday/twister/tools/callbacks";
import {
  type AuthToken,
  type Authorization,
  type Channel,
  Integrations,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Files } from "@plotday/twister/tools/files";
import { Imap } from "@plotday/twister/tools/imap";
import { Network } from "@plotday/twister/tools/network";
import { Smtp } from "@plotday/twister/tools/smtp";
import { Tasks } from "@plotday/twister/tools/tasks";

import {
  AuthenticationError,
  CalDAVClient,
  type CalDAVEvent,
  InvalidSyncTokenError,
  PreconditionFailedError,
  toCalDAVTimeString,
} from "./calendar/caldav";
import { getCalendarChannels } from "./calendar/channels";
import {
  type ICSEvent,
  parseICSDateTime,
  parseICSEvents,
  parseRRuleCount,
  parseRRuleEnd,
  updateAttendeePartstat,
} from "./calendar/ics-parser";
import { composeChannels } from "./compose";
import { downloadAttachmentFn } from "./mail/attachments";
import { getMailChannels } from "./mail/channels";
import { getReminderChannels } from "./reminders/channels";
import {
  fullSyncFn as remindersFullSyncFn,
  onChannelDisabledFn as onRemindersChannelDisabledFn,
  onChannelEnabledFn as onRemindersChannelEnabledFn,
  pollFn as remindersPollFn,
  processSyncChunkFn as remindersProcessSyncChunkFn,
  REMINDERS_POLL_INTERVAL_MS,
  type RemindersHost,
  type SyncBatchResult as RemindersSyncBatchResult,
} from "./reminders/sync";
import {
  onCreateLinkFn as onRemindersCreateLinkFn,
  onLinkUpdatedFn as onRemindersLinkUpdatedFn,
} from "./reminders/write";
import { connectIcloud, ICLOUD_IMAP, resolveThreadMessages } from "./mail/imap-fetch";
import type { MailHost, MailSyncState } from "./mail/mail-host";
import {
  DEFAULT_HISTORY_MS,
  mailSync,
  widestFloor,
  type MailChannel,
  type ThreadMeta,
} from "./mail/sync";
import {
  onCreateLinkFn,
  onNoteCreatedFn,
  onThreadReadFn,
  onThreadToDoFn,
} from "./mail/write";
import { parse } from "./product-channel";
import { appleProducts } from "./products";

/**
 * Return shape `scheduleDrain`'s handler expects (`{ retry?: string[] } |
 * void` — retryable ids from the just-processed batch, or nothing when
 * everything succeeded). Mirrored locally rather than imported: it isn't part
 * of `@plotday/twister`'s public export surface.
 */
type DrainResult = { retry?: string[] } | void;

/**
 * Prefix of the per-channel "this mail folder is enabled" markers, written by
 * `onMailChannelEnabled` and enumerated by `enabledMailChannels()` to build
 * the connection's channel list for a merged pass. The markers stay per
 * channel; everything that SCHEDULES a pass is connection-level (below).
 */
const MAIL_ENABLED_PREFIX = "mail:enabled_";

/**
 * Connection-level scheduling keys for the merged mail pass.
 *
 * `mailSync` reads every enabled folder plus Sent in one go and rebuilds each
 * touched thread from its complete message set, keeping one `mail:state`
 * cursor document for the whole connection. That document is read at the start
 * of a pass and replaced wholesale at the end, so two passes running against
 * the same connection would clobber each other's cursors — the later writer
 * restoring a sibling mailbox's pre-pass `lastUid`/`lastModSeq` (re-ingesting
 * mail and re-marking read threads unread) or dropping a cursor the sibling
 * had just created (forcing a redundant full backfill). One lock, one poll and
 * one push drain for the whole connection is what makes that impossible.
 *
 * IDLE watches are deliberately NOT in this list: `imap.watch` is keyed per
 * mailbox, so those stay per channel and all feed the single push drain.
 */
const MAIL_SYNC_LOCK = "mail_sync";
const MAIL_POLL_TASK = "mailpoll";
const MAIL_PUSH_DRAIN = "mail-push";
const MAIL_SYNC_DRAIN = "mail-sync";

/**
 * Connection-level record of the WIDEST history floor any plan has ever
 * granted this connection. Deliberately its own key, separate from
 * `mail:state`: `mail:state` is read-at-start / replaced-wholesale by
 * `mailSync` under the `mail_sync` lock (see MAIL_SYNC_LOCK's doc), so a
 * lock-free write here would be silently discarded by an in-flight pass.
 * This key is never touched by `mailSync` — only read as a fallback (see
 * `resolveMailHistoryMin`) and written by `persistGrantedHistoryMin` — so
 * writing it from `onMailChannelEnabled` outside the lock is race-free.
 *
 * This is what makes the granted floor durable even when BOTH carriers that
 * would otherwise carry it can drop it: `mailSyncTask`'s callback/task
 * argument (lost on queue exhaustion after repeated failures) and
 * `scheduleDrain`'s coalesced `handlerArgs` (frozen at the first call of a
 * burst, so a later wider floor scheduled inside the coalescing window is
 * discarded). Not cleared on channel disable — like `mail:auth_actor_id`,
 * it's a connection-level fact that must survive a disable/re-enable cycle.
 */
const MAIL_GRANTED_HISTORY_MIN_KEY = "mail:granted_history_min";

/**
 * Build canonical identifiers for an Apple calendar (ICS) event. First
 * element is the connector-native source; second is the cross-vendor
 * `icaluid:<UID>` alias so other connectors can bundle into this thread.
 * Apple's ICS UID is already the iCalUID by spec.
 */
function buildEventSources(uid: string | null | undefined): string[] {
  if (!uid) return [];
  return [`apple-calendar:${uid}`, `icaluid:${uid}`];
}

/**
 * A cancellation is "fully in the past" when the cancelled event has already
 * ended. Surfacing it adds a "cancelled" note (or bumps the master thread for a
 * cancelled occurrence) and flips the thread unread for a meeting that already
 * happened — noise, especially when the cancellation syncs in long after the
 * fact. Events that have started but not yet finished (ongoing) and future
 * events are kept, so the user still learns an upcoming/in-progress meeting
 * won't happen.
 *
 * `start`/`end` are the parsed ICS values (a Date for timed events, a
 * "YYYY-MM-DD" string for all-day events). An all-day DTEND is the exclusive
 * end (already the end boundary); with no end, a timed start is treated as the
 * end (duration unknown) and an all-day start runs to the end of its day.
 */
export function cancellationIsForPastEventFn(
  start: Date | string,
  end: Date | string | null,
  now: Date = new Date()
): boolean {
  const toDate = (v: Date | string): Date =>
    v instanceof Date ? v : new Date(`${v}T00:00:00Z`);
  if (end) return toDate(end) < now;
  if (start instanceof Date) return start < now;
  const dayEnd = toDate(start);
  dayEnd.setUTCDate(dayEnd.getUTCDate() + 1); // all-day end = next-day midnight
  return dayEnd < now;
}

type SyncState = {
  calendarHref: string;
  initialSync: boolean;
  batchNumber: number;
  /** Event hrefs remaining to process (for batched multiget) */
  pendingHrefs?: string[];
  /**
   * Initial sync is two-pass:
   *  - `quick` walks `start = now → end = now + 1y` so upcoming meetings
   *    surface immediately.
   *  - `full` walks `start = 2y ago → end = now + 1y` for the historical
   *    backfill. The two passes share one sync lock; phase carries the
   *    transition without releasing.
   * Absent on incremental sync.
   */
  phase?: "quick" | "full";
  /** Range used by the current pass (only set during initial sync). */
  timeRangeStart?: string;
  timeRangeEnd?: string;
};

/**
 * Tail bookkeeping to apply once every chunk of an incremental sync's
 * changed-href multiget has been processed (see `processChangedHrefsChunked`
 * / `completeIncrementalSync`). Carries whichever the fast path (RFC 6578
 * `sync-collection`) or the fallback (ctag/etag-diff) needs to persist a new
 * cursor — kept as a discriminated union rather than two optional fields so
 * a caller can't accidentally construct a tail that mixes both.
 */
type IncrementalSyncTail =
  | {
      mode: "fast";
      /**
       * The exact token `getCollectionChanges` returned for this pass.
       * Persisted verbatim in `completeIncrementalSync` — NOT re-fetched via
       * `getSyncToken()` — because it's the server's authoritative marker
       * for "everything up to and including what this pass just processed".
       * An extra PROPFIND after the fact could race ahead (something
       * changes between the REPORT and the PROPFIND), silently skipping
       * that gap on the next poll.
       */
      syncToken: string;
      /**
       * Hrefs `getCollectionChanges` reported as deleted this pass —
       * already archived (via `archiveDeletedHrefs`) by the time this tail
       * is constructed, but their `event_uids_<calendarHref>`/
       * `etags_<calendarHref>` entries are pruned only here, in
       * `completeIncrementalSync`, after every chunk of `changed` hrefs has
       * ALSO succeeded (see the crash-safety ordering note on
       * `completeIncrementalSync`). Unlike the fallback tail's
       * `newEtagMap` (a full authoritative snapshot the fast path never
       * computes — it only ever sees a delta), this is a small, precise
       * list of keys to remove. Without this, the fast path never prunes
       * either map, and a long-lived connection's `event_uids_`/`etags_`
       * grow by one stale entry per deleted event forever.
       */
      deletedHrefs: string[];
    }
  | {
      mode: "fallback";
      /**
       * The authoritative etag snapshot for every href currently on the
       * calendar, captured up front by the ctag/etag-diff walk (before any
       * chunk was processed). Applied in `completeIncrementalSync` as a
       * wholesale overwrite of `etags_<calendarHref>` — this is what prunes
       * hrefs that no longer exist (a partial per-chunk merge, like
       * `processCalDAVEvents` does for the hrefs it's actually given, can
       * only ADD/UPDATE entries, never remove ones for hrefs that vanished).
       */
      newEtagMap: Record<string, string>;
    };

/** Continuation state for a chunked incremental-sync changed-href multiget
 *  (see `processChangedHrefsChunked`). Mirrors `SyncState.pendingHrefs`'s
 *  role for initial sync, but kept separate from `SyncState`/`sync_state_`
 *  so incremental continuations don't have to thread fast-path/fallback
 *  distinctions through the initial-sync-only phase/orphan-flush machinery
 *  those are built around. */
type IncrementalSyncState = {
  pendingHrefs: string[];
  tail: IncrementalSyncTail;
};

/**
 * Short stable hash of a string for use in note keys. Same content
 * produces the same key (idempotent upsert on re-sync); edited content
 * produces a different key (new note, prior versions preserved as
 * history on the thread).
 */
async function hashContent(content: string): Promise<string> {
  const data = new TextEncoder().encode(content);
  const buf = await crypto.subtle.digest("SHA-256", data);
  const bytes = new Uint8Array(buf);
  let hex = "";
  for (let i = 0; i < 8; i++) {
    hex += bytes[i].toString(16).padStart(2, "0");
  }
  return hex;
}

/**
 * Apple Calendar connector — syncs events from iCloud via CalDAV.
 *
 * Uses app-specific password authentication (no OAuth).
 * Polls for changes using ctag/etag change detection since CalDAV
 * does not support push notifications.
 */
export class Apple extends Connector<Apple> {
  readonly dynamicLinkTypes = true;
  readonly channelNoun = { singular: "calendar", plural: "calendars" };
  readonly autoEnableNewChannelsByDefault = true;
  readonly access = [
    "Reads your iCloud mail and calendar to add them to Plot",
    "Sends replies and writes your event RSVPs",
  ];

  // Bidirectional: user replies to mail threads are dispatched to onNoteCreated.
  static readonly handleReplies = true;

  // Per-product metadata for the combined-connection setup/status UX. Declaring
  // `products` makes the app render top-level Email / Calendar sections, each
  // expanding to its own channels (mail folders / calendars), instead of one
  // flat channel list. This connector has no OAuth scopes, so `scopeGroupId`
  // matches no optional scope group — the API then treats each product as
  // having no required scopes, i.e. always granted once credentials are set.
  readonly products: ProductInfo[] = [
    {
      key: "mail",
      label: "Email",
      description: "Turns your iCloud email into organized threads.",
      icon: "https://api.iconify.design/fluent-emoji-flat/envelope.svg",
      scopeGroupId: "mail",
      channelNoun: { singular: "folder", plural: "folders" },
    },
    {
      key: "calendar",
      label: "Calendar",
      description: "Adds your iCloud events to your agenda and writes your RSVPs.",
      icon: "https://api.iconify.design/fluent-emoji-flat/calendar.svg",
      scopeGroupId: "calendar",
      channelNoun: { singular: "calendar", plural: "calendars" },
    },
    {
      key: "reminders",
      label: "Reminders",
      description: "Turns your iCloud reminders into to-dos.",
      icon: "https://api.iconify.design/fluent-emoji-flat/spiral-notepad.svg",
      scopeGroupId: "reminders",
      channelNoun: { singular: "list", plural: "lists" },
    },
  ];

  // Lock TTL covering the worst-case full backfill. The framework releases
  // the lock automatically after this window even if a worker crashes, so
  // no stuck-sync recovery is needed.
  private static readonly SYNC_LOCK_TTL_MS = 2 * 60 * 60 * 1000;

  // Mail sync lock TTL. iCloud enforces a per-account IMAP connection cap, so
  // `mailSyncTask`/`mailSyncDrain`/`mailPoll`/`mailPushDrain` share one
  // CONNECTION-level lock (`mail_sync`) to bound concurrent IMAP sessions to
  // one, keep the single `mail:state` cursor document race-free (see
  // MAIL_SYNC_LOCK's doc), and coalesce overlapping passes (e.g.
  // `onMailChannelEnabled` re-dispatch from auto-enable/recovery racing an
  // in-flight poll). 30 minutes is comfortably longer than any
  // single-execution merged backfill/rescan (the work this guards is far
  // smaller than a full CalDAV history walk) while being shorter than
  // calendar's 2-hour TTL so a crashed run self-heals faster — the next
  // 15-minute poll or push drain can reacquire well before a user would
  // notice. `acquireLock` is non-blocking (returns immediately), so gating
  // these entry points behind it can never deadlock.
  private static readonly MAIL_SYNC_LOCK_TTL_MS = 30 * 60 * 1000;

  // Multiget chunk size for calendar-multiget REPORTs, matching
  // syncBatch/syncBatchContinue's established initial-sync chunk size (see
  // those methods' `slice(0, 50)`/`slice(50)`). Used by both incremental
  // sync paths (processChangedHrefsChunked) so a large delta (post-outage
  // catch-up, mass edit) can't blow one execution's ~1000-request / CPU /
  // memory budget — batches beyond the first are handed to a queued task
  // (`incrementalSyncContinue`), which gets a fresh budget of its own.
  private static readonly CALDAV_MULTIGET_CHUNK_SIZE = 50;

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      options: build(Options, {
        appleId: {
          type: "text" as const,
          label: "Apple ID",
          default: "",
          placeholder: "you@icloud.com",
        },
        appPassword: {
          type: "text" as const,
          secure: true,
          label: "App-Specific Password",
          default: "",
          placeholder: "xxxx-xxxx-xxxx-xxxx",
          description:
            "Generate at appleid.apple.com > Sign-In and Security > App-Specific Passwords",
        },
      }),
      imap: build(Imap, { hosts: ["imap.mail.me.com"] }),
      smtp: build(Smtp, { hosts: ["smtp.mail.me.com"] }),
      network: build(Network, {
        urls: ["https://caldav.icloud.com/*", "https://*.icloud.com/*"],
      }),
      tasks: build(Tasks),
      files: build(Files),
    };
  }

  // ---- Helpers ----

  private getCalDAV(): CalDAVClient {
    const appleId = this.tools.options.appleId as string;
    const appPassword = this.tools.options.appPassword as string;
    if (!appleId || !appPassword) {
      throw new Error(
        "Apple ID and app-specific password are required. Configure them in the connector options."
      );
    }
    return new CalDAVClient({ appleId, appPassword });
  }

  /** Raw CalDAV href for a namespaced calendar channel id. */
  private calDavHref(channelId: string): string {
    return parse(channelId).rawId;
  }

  /**
   * Discover principal and calendar home, caching the results.
   */
  private async discoverCalendarHome(): Promise<string> {
    const cached = await this.get<string>("calendar_home");
    if (cached) return cached;

    const client = this.getCalDAV();
    const principal = await client.discoverPrincipal();
    await this.set("principal_url", principal);

    const calendarHome = await client.discoverCalendarHome(principal);
    await this.set("calendar_home", calendarHome);

    return calendarHome;
  }

  override async getAccountName(
    _auth: Authorization | null,
    _token: AuthToken | null
  ): Promise<string | null> {
    const appleId = this.tools.options.appleId as string | undefined;
    return appleId && appleId.length > 0 ? appleId : null;
  }

  /**
   * The Apple ID IS an email address, so — unlike getAccountName above,
   * which is display-only — it doubles as a matchable identity: the
   * platform links it to the signed-in Plot user's contact so the
   * connector's own mail/calendar activity is recognized as "you" (see
   * getAccountIdentity's JSDoc in @plotday/twister/connector).
   */
  override async getAccountIdentity(): Promise<{ email: string } | null> {
    const appleId = this.tools.options.appleId as string | undefined;
    return appleId && appleId.length > 0 ? { email: appleId } : null;
  }

  /**
   * Records the connecting user's actor id so mail sync's to-do↔\Flagged
   * reconciliation (`reconcileTodoFlags` in `mail/sync.ts`) knows who to
   * attribute a flag change made directly in Apple Mail to. Mirrors Gmail's
   * identical override (`google/src/google.ts`), which the same
   * reconciliation pattern is based on. Apple has no OAuth (Options-based
   * credentials instead), but `activate()` still fires on connect with
   * `context.actor` populated from the owner contact.
   */
  override async activate(context: {
    auth: Authorization;
    actor: Actor;
  }): Promise<void> {
    await this.buildMailHost().set("auth_actor_id", context.actor.id);
    await this.buildRemindersHost().set("auth_actor_id", context.actor.id);
  }

  /**
   * Adapter the mail/* pure sync functions depend on. Storage keys are
   * namespaced with a "mail:" prefix here so mail's cursors can never collide
   * with calendar's `sync_state_<id>` etc. keys — callers in `src/mail/*` pass
   * bare keys (e.g. `state`, `thread:<rootId>`) and rely on this prefixing,
   * never adding "mail:" themselves.
   */
  private buildMailHost(): MailHost {
    const mailKey = (key: string) => `mail:${key}`;
    return {
      imap: this.tools.imap,
      smtp: this.tools.smtp,
      integrations: this.tools.integrations,
      files: this.tools.files,
      appleId: this.tools.options.appleId as string,
      appPassword: this.tools.options.appPassword as string,
      set: async <T>(key: string, value: T) => {
        await this.set(mailKey(key), value as unknown as Serializable);
      },
      setMany: async <T>(entries: [key: string, value: T][]) => {
        await this.setMany(
          entries.map(([key, value]): [string, Serializable] => [
            mailKey(key),
            value as unknown as Serializable,
          ])
        );
      },
      get: async <T>(key: string): Promise<T | undefined> => {
        const value = await this.get<Serializable>(mailKey(key));
        return (value as T | null) ?? undefined;
      },
      clear: async (key: string) => {
        await this.clear(mailKey(key));
      },
      channelSyncCompleted: async (channelId: string) => {
        await this.tools.integrations.channelSyncCompleted(channelId);
      },
      queueWritebackDrain: (id: string) =>
        this.scheduleDrain("mail-writeback", this.mailWritebackDrain, { ids: [id] }),
      knownEventUids: () => this.knownEventUids(),
    };
  }

  /**
   * Adapter the reminders/* pure sync functions depend on. Storage keys are
   * namespaced with a "reminders:" prefix — same convention as
   * `buildMailHost` — so reminders' per-list cursors can never collide with
   * calendar's `sync_state_<id>` etc. keys. Callers in `src/reminders/*` pass
   * bare keys and rely on this prefixing.
   */
  private buildRemindersHost(): RemindersHost {
    const remKey = (key: string) => `reminders:${key}`;
    return {
      id: this.id,
      caldav: this.getCalDAV(),
      set: async <T>(key: string, value: T) => {
        await this.set(remKey(key), value as unknown as Serializable);
      },
      get: async <T>(key: string): Promise<T | undefined> => {
        const value = await this.get<Serializable>(remKey(key));
        return (value as T | null) ?? undefined;
      },
      clear: async (key: string) => {
        await this.clear(remKey(key));
      },
      setMany: async <T>(entries: [key: string, value: T][]) => {
        await this.setMany(
          entries.map(([key, value]): [string, Serializable] => [
            remKey(key),
            value as unknown as Serializable,
          ])
        );
      },
      tools: {
        integrations: {
          saveLink: (link) => this.tools.integrations.saveLink(link),
          channelSyncCompleted: (channelId) =>
            this.tools.integrations.channelSyncCompleted(channelId),
          archiveLinks: (filter) => this.tools.integrations.archiveLinks(filter),
        },
      },
      scheduler: {
        schedulePoll: async (listId: string) => {
          const cb = await this.callback(this.remindersPoll, listId);
          await this.scheduleRecurring(`reminders-poll:${listId}`, cb, {
            intervalMs: REMINDERS_POLL_INTERVAL_MS,
          });
        },
        cancelPoll: (listId: string) =>
          this.cancelScheduledTask(`reminders-poll:${listId}`),
        queueFullSync: async (listId: string, initialSync: boolean) => {
          const cb = await this.callback(this.remindersInit, listId, initialSync);
          await this.runTask(cb);
        },
      },
    };
  }

  /**
   * Union of every iCalUID the calendar product has actually saved a titled
   * link for, across every currently-enabled calendar. Enumerates enabled
   * calendars via the same `sync_enabled_<channelId>` convention
   * `onCalendarChannelEnabled`/`onCalendarChannelDisabled` already
   * maintain (set on enable, cleared on disable — see those methods), then
   * unions each one's `titled_uids_<channelId>` map's keys (see
   * `processCalDAVEvents`'s doc for why this reads `titled_uids_` — a
   * precise "link actually created" signal — rather than the broader
   * `event_uids_`, which also includes hrefs CalDAV returned but
   * `prepareEvent` skipped, e.g. a cancelled-during-initial-sync event).
   * Backs `MailHost.knownEventUids` — see that doc for why the mail host
   * can't read these unprefixed calendar keys directly.
   */
  private async knownEventUids(): Promise<Set<string>> {
    const uids = new Set<string>();
    const enabledKeys = await this.tools.store.list("sync_enabled_");
    for (const key of enabledKeys) {
      const calendarChannelId = key.slice("sync_enabled_".length);
      const map = await this.get<Record<string, true>>(
        `titled_uids_${calendarChannelId}`
      );
      if (!map) continue;
      for (const uid of Object.keys(map)) uids.add(uid);
    }
    return uids;
  }

  // ---- Channel Lifecycle ----

  /**
   * Returns available channels across every Apple product (calendar, mail).
   * Auth params are null since we use Options for credentials.
   */
  async getChannels(
    _auth: Authorization | null,
    _token: AuthToken | null
  ): Promise<Channel[]> {
    // No creds → no products available yet (user hasn't filled Options).
    const appleId = this.tools.options.appleId as string | undefined;
    const appPassword = this.tools.options.appPassword as string | undefined;
    if (!appleId || !appPassword) return [];

    const products = appleProducts({
      getCalendarChannels: async () => {
        const calendarHome = await this.discoverCalendarHome();
        return getCalendarChannels(this.getCalDAV(), calendarHome);
      },
      getMailChannels: () => getMailChannels(this.buildMailHost()),
      getRemindersChannels: async () => {
        // Reuses the calendar product's cached calendar_home/principal_url
        // (both CalDAV-backed) rather than re-discovering them.
        const calendarHome = await this.discoverCalendarHome();
        const principalUrl =
          (await this.get<string>("principal_url")) ??
          (await this.getCalDAV().discoverPrincipal());
        return getReminderChannels(this.getCalDAV(), calendarHome, principalUrl);
      },
    });
    return composeChannels(products);
  }

  /**
   * Routes channel-enable dispatch to the product identified by the
   * namespaced channel id's prefix.
   */
  async onChannelEnabled(channel: Channel, context?: SyncContext): Promise<void> {
    const { product } = parse(channel.id);
    if (product === "calendar") return this.onCalendarChannelEnabled(channel, context);
    if (product === "mail") return this.onMailChannelEnabled(channel, context);
    if (product === "reminders") return this.onRemindersChannelEnabled(channel, context);
  }

  /**
   * Called when a mail folder is enabled. Marks the channel enabled and queues
   * a merged connection-level sync pass off the HTTP path, carrying whatever
   * history floor the plan granted.
   *
   * The floor is NOT written into `mail:state` here — that document is owned
   * by `mailSync` under the `mail_sync` lock, and a read-modify-write from
   * this (lock-free) path would be silently discarded by an in-flight pass
   * replacing the document from its own earlier snapshot. But "don't write
   * into `mail:state`" doesn't mean "don't persist at all": a granted floor
   * that exists ONLY as this task's callback argument is lost for good if the
   * task exhausts its retries (e.g. every attempt hits an IMAP timeout) or if
   * a coalesced `scheduleDrain` burst freezes on an earlier, narrower call's
   * args. So the floor is ALSO persisted here, widening-only, to its own
   * connection-level key (`persistGrantedHistoryMin` — see that key's doc for
   * why this write is race-free) — that's what lets `mailSyncTask` (and
   * `mailPoll`/`mailPushDrain`, via `resolveMailHistoryMin`) recover the
   * granted window even after the task that carried it is gone.
   *
   * Always queues the pass, even on re-dispatch (auto-enable / recovery):
   * `mailSync` upserts by `source`, so re-running it is a safe, idempotent
   * catch-up rather than something that needs to be skipped, and a mailbox
   * that already has a cursor simply runs incremental. A widened floor is
   * picked up by the same pass — `mailSync` compares the granted floor against
   * how far back each mailbox has actually been read and widens the whole pass
   * when it moved earlier.
   */
  private async onMailChannelEnabled(channel: Channel, context?: SyncContext): Promise<void> {
    await this.set(`${MAIL_ENABLED_PREFIX}${channel.id}`, true);

    const grantedFloor = context?.syncHistoryMin
      ? await this.persistGrantedHistoryMin(context.syncHistoryMin.toISOString())
      : ((await this.get<string>(MAIL_GRANTED_HISTORY_MIN_KEY)) ?? null);

    // Run the merged pass off the HTTP path. `null` (not `undefined`) for an
    // absent floor — callback arguments must be serializable.
    const cb = await this.callback(this.mailSyncTask, channel.id, grantedFloor);
    await this.runTask(cb);
  }

  /**
   * Persist the granted history floor to `MAIL_GRANTED_HISTORY_MIN_KEY`,
   * widening-only (the earliest of the stored value and `incoming` — same
   * "never narrows" rule `mailSync` applies to `mail:state.syncHistoryMin`,
   * reused via `widestFloor` from `mail/sync.ts` rather than a second copy of
   * the merge logic). Race-free because this key is never part of the
   * document `mailSync` replaces wholesale under the `mail_sync` lock — see
   * MAIL_GRANTED_HISTORY_MIN_KEY's doc.
   */
  private async persistGrantedHistoryMin(incoming: string): Promise<string> {
    const stored = await this.get<string>(MAIL_GRANTED_HISTORY_MIN_KEY);
    const widened = widestFloor(stored ?? undefined, incoming) ?? incoming;
    await this.set(MAIL_GRANTED_HISTORY_MIN_KEY, widened);
    return widened;
  }

  /**
   * The floor to use for a mail pass that carries no explicit history-min of
   * its own: the persisted granted floor if one was ever recorded, else the
   * default fallback. Consulted by every entry point that can otherwise end
   * up calling `mailSync` with no floor at all (`mailPoll`, `mailPushDrain`,
   * and `mailSyncTask`'s own fallback for a lost/absent argument) — without
   * this, a task lost to queue exhaustion or a coalesced drain would recover
   * to a rolling `DEFAULT_HISTORY_MS` window on the very next poll instead of
   * the floor the plan actually granted (see MAIL_GRANTED_HISTORY_MIN_KEY's
   * doc for the two ways the argument-only carrier can be lost).
   */
  private async resolveMailHistoryMin(): Promise<string> {
    const granted = await this.get<string>(MAIL_GRANTED_HISTORY_MIN_KEY);
    return granted ?? new Date(Date.now() - DEFAULT_HISTORY_MS).toISOString();
  }

  /**
   * Called when a calendar channel is enabled for syncing.
   *
   * Three cases (see SyncContext docs):
   *  - Initial enable: full backfill from scratch.
   *  - Already-enabled history-min refresh: skips when stored window is
   *    already at least as wide.
   *  - Recovery (`context.recovering = true`): the user re-entered their
   *    Apple ID / app-specific password after a credentials change. Drop
   *    the persisted ctag, etag/uid maps, sync state, and any scheduled
   *    poll so the next pass re-walks every event and picks up changes
   *    that landed during the auth gap.
   *
   * Keep this method thin: it must return quickly so the HTTP response
   * boundary doesn't hold the sync lock. All real init work (lock,
   * starting ctag, first batch) is deferred to initChannel which runs
   * inside a queued task.
   */
  private async onCalendarChannelEnabled(channel: Channel, context?: SyncContext): Promise<void> {
    if (context?.recovering) {
      // Wipe persisted cursors and per-event state so the next pass
      // re-walks history. Each clear is idempotent. Release any TTL-stuck
      // lock from the pre-recovery outage so initChannel can acquire fresh.
      await this.clear(`ctag_${channel.id}`);
      await this.clear(`etags_${channel.id}`);
      await this.clear(`event_uids_${channel.id}`);
      await this.clear(`titled_uids_${channel.id}`);
      await this.clear(`sync_state_${channel.id}`);
      await this.clear(`synctoken_${channel.id}`);
      await this.clear(`incremental_state_${channel.id}`);
      await this.tools.store.releaseLock(`sync_${channel.id}`);

      // Cancel any scheduled poll so the post-recovery sync starts cleanly
      // (a stale poll firing concurrently would race against initChannel).
      await this.cancelScheduledTask(`poll:${channel.id}`);

      // Clear any `pending_occ:` / `seen_master:` markers left behind
      // by the crashed pre-recovery sync. Stale markers from a half-done
      // run can otherwise cause the next full-pass orphan flush to
      // materialise empty Untitled threads (leftover `pending_occ`
      // matching leftover `seen_master` whose link no longer exists).
      await this.clearBuffers(channel.id);
    } else if (context?.syncHistoryMin) {
      // Store sync_history_min if provided and not already stored with an
      // equal/earlier value. Skipped on recovery so the recovery pass
      // re-walks even when the window hasn't widened.
      const key = `sync_history_min_${channel.id}`;
      const stored = await this.get<string>(key);
      if (stored && new Date(stored) <= context.syncHistoryMin) {
        return; // Already synced with equal or earlier history min
      }
      await this.set(key, context.syncHistoryMin.toISOString());
    }

    await this.set(`sync_enabled_${channel.id}`, true);

    // Queue all initialization work as a task so the HTTP response returns
    // quickly. initChannel acquires the sync lock, fetches the starting
    // ctag, and queues the first batch.
    const initCallback = await this.callback(this.initChannel, channel.id);
    await this.runTask(initCallback);
  }

  /**
   * Initializes a calendar channel: acquires the sync lock, fetches the
   * starting ctag, initializes sync state, and queues the first sync batch.
   * Runs as a queued task so the lock acquisition doesn't straddle the
   * HTTP-response boundary (where a dropped task could leave the lock held
   * until the TTL expires) and so the first batch's CalDAV multiget runs
   * in its own task.
   */
  async initChannel(channelId: string): Promise<void> {
    // Acquire sync lock. Self-expires after SYNC_LOCK_TTL_MS so a crashed
    // worker can't wedge sync forever. Bails if another sync is in flight
    // (e.g. an in-flight poll or a previous initChannel that hasn't drained).
    const acquired = await this.tools.store.acquireLock(
      `sync_${channelId}`,
      Apple.SYNC_LOCK_TTL_MS
    );
    if (!acquired) {
      // Another sync holds the lock (e.g. an in-flight init from a previous
      // enable attempt that hasn't drained, or a stuck TTL'd run). Schedule
      // a poll so the next interval can retry init — otherwise this channel
      // would be stuck with no scheduled work until the user re-enables.
      await this.schedulePoll(channelId);
      return;
    }

    try {
      // Store initial ctag for incremental sync
      const client = this.getCalDAV();
      const ctag = await client.getCalendarCtag(this.calDavHref(channelId));
      if (ctag) await this.set(`ctag_${channelId}`, ctag);

      // Two-pass initial sync:
      //  - Quick pass: `start = now → end = now + 1y`. Front-loads upcoming
      //    meetings so they appear in the activity feed immediately. Skips
      //    long-running recurring masters whose first instance is in the past
      //    (those land in the full pass).
      //  - Full pass: `start = 2y ago → end = now + 1y`. Walks the historical
      //    backfill. Saves are idempotent by `source`, so the overlap with
      //    the quick window is harmless.
      // The transition queues a fresh syncBatch with phase "full" without
      // releasing the lock; the full pass's terminal batch fires the
      // pending_occ orphan flush, channelSyncCompleted, and lock release.
      const now = new Date();
      const quickStart = toCalDAVTimeString(now);
      const quickEnd = toCalDAVTimeString(
        new Date(now.getFullYear() + 1, 11, 31)
      );

      await this.set(`sync_state_${channelId}`, {
        calendarHref: channelId,
        initialSync: true,
        batchNumber: 1,
        phase: "quick",
        timeRangeStart: quickStart,
        timeRangeEnd: quickEnd,
      } as SyncState);

      // Queue the first batch as a separate task instead of awaiting inline.
      // This mirrors google-calendar's initCalendar pattern: the init task
      // returns immediately after setup, freeing the runtime to schedule
      // syncBatch (which does the heavy CalDAV multiget) on its own.
      const syncCallback = await this.callback(
        this.syncBatch,
        channelId,
        true, // initialSync
        1, // batchNumber
        quickStart,
        quickEnd
      );
      await this.runTask(syncCallback);
    } catch (error) {
      // CalDAV throws here (bad credentials, network outage) would otherwise
      // leave the just-acquired lock held for the full 2-hour TTL. Release
      // it and schedule a poll so the next interval can retry init.
      try {
        await this.tools.store.releaseLock(`sync_${channelId}`);
        await this.clear(`sync_state_${channelId}`);
      } catch (cleanupError) {
        console.error(
          "Cleanup after initChannel failure also failed:",
          cleanupError
        );
      }
      await this.schedulePoll(channelId);
      throw error;
    }
  }

  /**
   * Routes channel-disable dispatch to the product identified by the
   * namespaced channel id's prefix.
   */
  async onChannelDisabled(channel: Channel): Promise<void> {
    const { product } = parse(channel.id);
    if (product === "calendar") return this.onCalendarChannelDisabled(channel);
    if (product === "mail") return this.onMailChannelDisabled(channel);
    if (product === "reminders") return this.onRemindersChannelDisabled(channel);
  }

  /**
   * Called when a mail channel is disabled. Splits into "always, for this
   * channel" and "only when this was the LAST enabled mail folder", because
   * the sync machinery is now connection-level (one `mailpoll` task, one
   * `mail-push`/`mail-sync`/`mail-writeback` drain, one `mail_sync` lock, one
   * `mail:state` cursor document) rather than per channel.
   *
   * Disabling one of several folders must NOT tear that shared machinery down:
   * cancelling the poll, releasing the `mail_sync` lock, or sweeping the
   * connection-scoped marker keys (`mail:compose:`, `mail:writeback:`,
   * `mail:flagged:`, `mail:cancel-email:`, `mail:thread:`) while other folders
   * are still enabled would break a legitimately in-flight pass and — worse —
   * drop live state. Concretely: wiping `mail:flagged:<root>` for a thread that
   * lives in a still-enabled folder makes the next pass read `wasFlagged =
   * undefined`, see the IMAP `\Flagged` still set, and re-mark a to-do the user
   * just cleared. So those actions run ONLY on the last-folder branch.
   *
   * Scoped to `syncProvider: "apple-mail"` (distinct from calendar's
   * `"apple"`) so disabling mail never touches calendar links.
   */
  private async onMailChannelDisabled(channel: Channel): Promise<void> {
    const rawMailbox = parse(channel.id).rawId;

    // --- Always, for this channel ---
    // The IMAP IDLE watch is genuinely per mailbox.
    await this.tools.imap.unwatch(channel.id);
    const pushCb = await this.get<Callback>(`mail:push_cb_${channel.id}`);
    if (pushCb) {
      await this.deleteCallback(pushCb);
      await this.clear(`mail:push_cb_${channel.id}`);
    }
    // Clear THIS channel's enabled marker FIRST — the emptiness check below
    // must count only the folders that REMAIN. Ordering is load-bearing:
    // scanning before clearing would always find at least this channel and the
    // count could never reach zero.
    await this.clear(`mail:enabled_${channel.id}`);
    // Legacy per-channel history-floor key; harmless no-op if absent (the live
    // floor is `mail:state.syncHistoryMin` / `mail:granted_history_min`).
    await this.clear(`mail:sync_history_min_${channel.id}`);

    const remaining = await this.enabledMailChannels();

    if (remaining.length === 0) {
      // This was the last enabled folder: tear down everything the connection
      // owned.
      await this.teardownMailConnection();
    } else {
      // One of several folders disabled: keep every connection-level primitive
      // alive for the folders that remain; adjust only this channel's
      // footprint in the shared documents.
      //
      // Default to an empty document (rather than skipping) when no pass has
      // ever run yet — the `pendingFullRescan` write below must still land
      // even though there are no cursors to prune. Harmless either way (an
      // empty `boxes` has nothing to widen), but skipping it would silently
      // drop the "force a wide next pass" intent for a connection that
      // hasn't synced yet.
      const state = (await this.get<MailSyncState>("mail:state")) ?? {
        version: 2,
        boxes: {},
      };
      // Prune only this mailbox's cursor; leave the others (and Sent's) in
      // the single document.
      if (state.boxes) delete state.boxes[rawMailbox];
      // Force the next pass to search every remaining mailbox from the
      // history floor (not the 30-day recent window), so a thread that was
      // archived just now but still lives in another enabled folder is
      // re-homed (§3.2) and re-upserted with normal incremental semantics.
      state.pendingFullRescan = true;
      await this.set("mail:state", state);
      // Re-home every thread this folder owned: clear ONLY the `channelId`
      // field, keeping the root's `bundle` decision and — crucially — its
      // PRESENCE. The next pass re-resolves the home from live messages
      // without re-fetching/re-classifying ICS attachments, and without
      // treating the root as brand-new (which would clobber the user's
      // read/archive state via the initial-root rule).
      const threadKeys = await this.tools.store.list("mail:thread:");
      for (const key of threadKeys) {
        const meta = await this.get<ThreadMeta>(key);
        if (meta?.channelId === channel.id) {
          const { channelId: _drop, ...rest } = meta;
          await this.set(key, rest);
        }
      }
    }

    // Archive this folder's synced links. Already precisely channel-scoped, and
    // with per-thread home channels (§3.2) it now matches exactly the threads
    // homed to this folder. Runs on BOTH branches.
    await this.tools.integrations.archiveLinks({
      channelId: channel.id,
      meta: { syncProvider: "apple-mail", syncableId: channel.id },
    });
  }

  /**
   * Called when a reminders list is enabled. `channel.id` is the NAMESPACED
   * id ("reminders:<href>") — passed straight through to the sync.ts
   * functions, which de-namespace internally only where a raw CalDAV href is
   * actually needed (see `rawHref()`'s doc in reminders/sync.ts).
   */
  private async onRemindersChannelEnabled(
    channel: Channel,
    context?: SyncContext
  ): Promise<void> {
    await onRemindersChannelEnabledFn(this.buildRemindersHost(), channel.id, {
      recovering: context?.recovering,
    });
    const cb = await this.callback(this.remindersInit, channel.id, true);
    await this.runTask(cb);
  }

  private async onRemindersChannelDisabled(channel: Channel): Promise<void> {
    await onRemindersChannelDisabledFn(this.buildRemindersHost(), channel.id);
  }

  /**
   * Kicks off a full VTODO backfill for a reminders list — the newly-enabled
   * path (`initialSync: true`) and every rescan trigger `pollFn` queues via
   * `host.scheduler.queueFullSync` (initial-flagged for a lost cursor,
   * non-initial for a routine ctag-detected change) share this one entry
   * point, so a large list's rescan chunks across executions exactly like
   * the original backfill does.
   */
  async remindersInit(listId: string, initialSync: boolean): Promise<void> {
    const result = await remindersFullSyncFn(this.buildRemindersHost(), listId, initialSync);
    await this.continueRemindersSync(listId, result, initialSync);
  }

  /** Continuation for a chunked backfill/rescan — see reminders/sync.ts's SyncBatchResult. */
  async remindersSyncBatch(
    listId: string,
    offset: number,
    initialSync: boolean
  ): Promise<void> {
    const result = await remindersProcessSyncChunkFn(
      this.buildRemindersHost(),
      listId,
      offset,
      initialSync
    );
    await this.continueRemindersSync(listId, result, initialSync);
  }

  private async continueRemindersSync(
    listId: string,
    result: RemindersSyncBatchResult,
    initialSync: boolean
  ): Promise<void> {
    if ("next" in result) {
      const cb = await this.callback(
        this.remindersSyncBatch,
        listId,
        result.next.offset,
        initialSync
      );
      await this.runTask(cb);
      return;
    }
    await this.buildRemindersHost().scheduler.schedulePoll(listId);
  }

  /** Recurring incremental poll for one reminders list — see reminders/sync.ts's pollFn. */
  async remindersPoll(listId: string): Promise<void> {
    await remindersPollFn(this.buildRemindersHost(), listId);
  }

  /**
   * Last-folder teardown: cancel the connection-level poll, drains and lock,
   * delete the whole `mail:state` cursor document, and sweep the
   * connection-scoped marker keys. Every sweep target below is written per
   * connection (never per channel), so with no folders left they are all
   * unambiguously reclaimable.
   *
   * Deliberately NOT swept: `mail:auth_actor_id` (re-set by `activate()` on
   * connect) and `mail:granted_history_min` (the widest floor any plan ever
   * granted). Both are connection-level facts that must survive a
   * disable/re-enable cycle — see those keys' docs.
   */
  private async teardownMailConnection(): Promise<void> {
    await this.cancelScheduledTask(MAIL_POLL_TASK);
    await this.cancelDrain(MAIL_PUSH_DRAIN);
    await this.cancelDrain(MAIL_SYNC_DRAIN);
    await this.cancelDrain("mail-writeback");
    await this.tools.store.releaseLock(MAIL_SYNC_LOCK);
    // The whole cursor document, including Sent's channel-less cursor — this is
    // the only place Sent's entry can be reclaimed.
    await this.clear("mail:state");

    // Sweep the connection-scoped marker keys. None expire on their own, and
    // each must be gone before a re-enable so a fresh backfill re-derives
    // everything (bundle classification, thread homes, echo-break markers)
    // rather than inheriting a decision cached before the gap.
    //
    //  - `mail:compose:` / `mail:forward:`   — Plot-initiated compose/forward dedup guards.
    //  - `mail:writeback:`                   — flag write-back retry payloads.
    //  - `mail:flagged:`                     — to-do↔\Flagged echo-break markers.
    //  - `mail:cancel-email:`                — calendar-cancellation hints (backstop
    //                                          for markers the calendar side never consumed).
    //  - `mail:thread:`                      — per-root home channel + bundle cache
    //                                          (supersedes the legacy `mail:bundle:`).
    for (const prefix of [
      "mail:compose:",
      "mail:forward:",
      "mail:writeback:",
      "mail:flagged:",
      "mail:cancel-email:",
      "mail:thread:",
    ]) {
      const keys = await this.tools.store.list(prefix);
      for (const key of keys) await this.clear(key);
    }
  }

  /**
   * Runs once per active instance when a new connector version deploys.
   * Migrates connections off the legacy per-channel mail-sync state onto the
   * connection-level shape (`mail:state` + per-root `mail:thread:`), and off
   * the legacy per-channel scheduling onto the single connection-level poll.
   * Every step is idempotent and runs outside the `mail_sync` lock.
   */
  override async upgrade(): Promise<void> {
    // Legacy per-channel cursors (`mail:state_<channelId>`) — superseded by the
    // single `mail:state` document. Drop them.
    for (const key of await this.tools.store.list("mail:state_")) {
      await this.clear(key);
    }
    // Legacy per-channel history floors (`mail:sync_history_min_<channelId>`) —
    // fold the WIDEST (earliest) into the connection-level `mail:state`, then
    // drop them, so the newly-granted history isn't silently narrowed.
    let widest: string | undefined;
    for (const key of await this.tools.store.list("mail:sync_history_min_")) {
      const floor = await this.get<string>(key);
      widest = widestFloor(widest, floor ?? undefined);
      await this.clear(key);
    }
    // Legacy calendar-bundle cache (`mail:bundle:<rootId>`) — superseded by
    // `mail:thread:<rootId>.bundle`. Drop it.
    for (const key of await this.tools.store.list("mail:bundle:")) {
      await this.clear(key);
    }

    // Seed a `mail:thread:<rootId>` document (channel-less, bundle-less) for
    // every previously-synced root that doesn't already have one.
    // `mail:flagged:<rootId>` is written for EVERY root the prior backfill
    // ingested (see `reconcileTodoFlags`), so it enumerates them. Seeding
    // marks each root "already known to Plot" so the first merged pass does
    // NOT treat it as an initial ingest and mass mark-read / un-archive the
    // whole mailbox (`mail:thread:` would otherwise be empty, making every
    // root look brand-new). The next pass re-homes each from live messages
    // and re-classifies bundles as needed.
    //
    // `upgrade()` reruns on EVERY later deploy, not only this v1→v2
    // transition — skipping roots that already have a `mail:thread:` document
    // is what makes this one-shot in effect: on a routine v3+ deploy every
    // root has long since been re-homed by a real merged pass, so the
    // pre-existing-key filter below leaves them untouched. Without it, a
    // blanket `setMany` here would overwrite every root's live `{channelId,
    // bundle}` back to `{}` on every deploy, forcing the next pass to
    // re-resolve each thread's home (risking a channel flip when the root
    // aged out of the window but a reply lives in a different enabled
    // folder) and re-fetch/re-classify every in-window ICS attachment.
    const flaggedKeys = await this.tools.store.list("mail:flagged:");
    const existingThreadKeys = new Set(
      await this.tools.store.list("mail:thread:")
    );
    const seed: [string, ThreadMeta][] = flaggedKeys
      .map((key): string => `mail:thread:${key.slice("mail:flagged:".length)}`)
      .filter((threadKey) => !existingThreadKeys.has(threadKey))
      .map((threadKey): [string, ThreadMeta] => [threadKey, {}]);
    if (seed.length > 0) await this.setMany(seed);

    // Persist the migrated connection-level state document.
    const existing = await this.get<MailSyncState>("mail:state");
    const floor = widestFloor(existing?.syncHistoryMin, widest);
    const migrated: MailSyncState = {
      version: 2,
      boxes: existing?.boxes ?? {},
      ...(floor !== undefined ? { syncHistoryMin: floor } : {}),
      ...(existing?.pendingFullRescan ? { pendingFullRescan: true } : {}),
    };
    await this.set("mail:state", migrated);

    // Cancel legacy per-channel scheduling for every currently-enabled mail
    // channel (`mailpoll:<channelId>`, `mail-push:<channelId>`,
    // `mail_sync_<channelId>`), then arm the connection-level poll once.
    for (const { channelId } of await this.enabledMailChannels()) {
      await this.cancelScheduledTask(`mailpoll:${channelId}`);
      await this.cancelDrain(`mail-push:${channelId}`);
      await this.tools.store.releaseLock(`mail_sync_${channelId}`);
    }
    await this.scheduleMailPoll();
  }

  /**
   * Every currently-enabled mail channel, paired with its raw IMAP mailbox,
   * in a deterministic (channel-id ascending) order.
   *
   * This is what makes the pass connection-level: `mailSync` rebuilds each
   * thread from its complete message set across every folder listed here, so
   * a thread whose messages are spread over Inbox and Archive gets ONE title,
   * ONE read state and ONE home channel instead of two folders racing to
   * recompute them from their own half.
   *
   * The `product === "mail"` filter is belt-and-braces (only mail channels
   * ever write this prefix) and, importantly, uses `parse()` — which splits on
   * the FIRST `:` — so a folder whose name itself contains `:` or `/`
   * round-trips unchanged.
   */
  private async enabledMailChannels(): Promise<MailChannel[]> {
    const keys = await this.tools.store.list(MAIL_ENABLED_PREFIX);
    return keys
      .map((key) => key.slice(MAIL_ENABLED_PREFIX.length))
      .filter((channelId) => parse(channelId).product === "mail")
      .map((channelId) => ({ channelId, mailbox: parse(channelId).rawId }))
      .sort((a, b) =>
        a.channelId < b.channelId ? -1 : a.channelId > b.channelId ? 1 : 0
      );
  }

  /**
   * Runs one merged connection-level mail pass as a queued task (dispatched
   * callback), then arms the recurring poll and every enabled channel's IDLE
   * watch.
   *
   * `_channelId` names the channel whose enable triggered this task. It is
   * accepted and ignored: the pass always covers the WHOLE connection, and
   * keeping the parameter means callbacks scheduled by earlier, per-channel
   * versions still resolve after a deploy.
   *
   * Guarded by the connection-level `mail_sync` lock. On losing it this
   * RESCHEDULES rather than skipping: an in-flight pass enumerated its channel
   * list before this channel's enabled marker existed, so it demonstrably does
   * not cover the new folder — skipping would leave that folder unsynced and
   * its `channelSyncCompleted` unfired, sticking the "syncing…" indicator
   * until the next 15-minute poll at best. The non-blocking acquire plus a 5 s
   * delay can neither deadlock nor busy-loop; the holder releases within one
   * pass, and the lock's TTL bounds the worst case.
   *
   * `armMailWatches` runs either way (idempotent and lock-free) so an attempt
   * that lost the race never leaves the connection without push watches.
   * `scheduleMailPoll` only runs on the ACQUIRED branch — see this method's
   * `else` branch for why re-arming it on every lost-lock retry would starve
   * the recurring poll instead of protecting it.
   */
  async mailSyncTask(_channelId?: string, syncHistoryMin?: string | null): Promise<void> {
    const channels = await this.enabledMailChannels();
    if (channels.length === 0) return; // last channel disabled before we ran

    const min = syncHistoryMin ?? (await this.resolveMailHistoryMin());
    const acquired = await this.tools.store.acquireLock(
      MAIL_SYNC_LOCK,
      Apple.MAIL_SYNC_LOCK_TTL_MS
    );
    if (acquired) {
      try {
        await mailSync(this.buildMailHost(), channels, min);
      } finally {
        await this.tools.store.releaseLock(MAIL_SYNC_LOCK);
      }
      await this.scheduleMailPoll();
    } else {
      // Carry the granted floor with the retry: `mail:state` may be rewritten
      // by the in-flight pass from a snapshot that predates this enable, so
      // re-reading it later could silently narrow the window.
      //
      // Deliberately does NOT call `scheduleMailPoll` here. A crashed lock
      // holder is retried every 5s for up to the 30-minute TTL (~360
      // attempts); `scheduleRecurring` is a singleton delete+insert that
      // re-arms `callAt` to `now + 15min` on every call, so calling it from
      // this branch would push the recurring poll's next fire 15 minutes
      // into the future on EVERY retry — starving the poll's safety-net role
      // for the whole crashed-holder window, exactly when it's most needed.
      // Leaving whatever poll schedule already exists untouched here is
      // correct; the acquired branch re-arms it once the pass actually runs.
      await this.scheduleDrain(MAIL_SYNC_DRAIN, this.mailSyncDrain, {
        delayMs: 5000,
        handlerArgs: [min],
      });
    }
    await this.armMailWatches(channels);
  }

  /**
   * Retry pass for `mailSyncTask` when it lost the `mail_sync` lock. Re-enters
   * the same lock-guarded body (and reschedules again if it loses again).
   * Signal-only: the merged pass derives its own work from mailbox state, so
   * the drain's id set is always empty.
   */
  async mailSyncDrain(_ids: string[], syncHistoryMin?: string | null): Promise<void> {
    await this.mailSyncTask(undefined, syncHistoryMin);
  }

  /**
   * Recurring mail poll (dispatched callback). Bails if every mail channel was
   * disabled since this poll was scheduled; otherwise re-arms each enabled
   * channel's push watch (self-healing: restarts a dropped watch and refreshes
   * rotated credentials — a cheap keyed upsert when nothing changed) and runs
   * the merged sync. With push active, this poll is the safety net for
   * anything IDLE missed.
   *
   * The watch re-arm happens BEFORE the `mail_sync` lock check so a dropped
   * IDLE watch always self-heals, even while another pass holds the lock. The
   * sync itself is guarded: if the lock is held, another pass already covers
   * current mailbox state, so this poll skips its own sync and relies on the
   * next 15-minute interval to retry.
   *
   * Passes `resolveMailHistoryMin()` rather than `undefined`: if a prior
   * `mailSyncTask` never completed (task exhaustion), `mail:state` never
   * picked up the granted floor, so falling back to `undefined` here would
   * let `mailSync` recompute its own hardcoded default every 15 minutes
   * forever. Reading the persisted `MAIL_GRANTED_HISTORY_MIN_KEY` here is
   * what lets this recurring poll self-heal that loss — see
   * MAIL_GRANTED_HISTORY_MIN_KEY's doc.
   *
   * `_channelId` is accepted and ignored so tasks scheduled by earlier,
   * per-channel versions still resolve; the poll is connection-level.
   */
  async mailPoll(_channelId?: string): Promise<void> {
    const channels = await this.enabledMailChannels();
    if (channels.length === 0) return;
    await this.armMailWatches(channels);

    const acquired = await this.tools.store.acquireLock(
      MAIL_SYNC_LOCK,
      Apple.MAIL_SYNC_LOCK_TTL_MS
    );
    if (!acquired) return;
    try {
      await mailSync(this.buildMailHost(), channels, await this.resolveMailHistoryMin());
    } finally {
      await this.tools.store.releaseLock(MAIL_SYNC_LOCK);
    }
  }

  /**
   * Push notification from the platform's IMAP IDLE watch (dispatched
   * callback). Watches are per mailbox, so this fires with the pushing
   * channel's id — but every one of them feeds the SINGLE connection-level
   * drain, so a burst spanning several folders folds into one merged pass
   * instead of one pass per folder.
   *
   * Never syncs inline: pushes arrive in bursts (one per new message / flag
   * change), so route through a short-delay drain that coalesces them.
   */
  async mailPushed(_channelId?: string): Promise<void> {
    const channels = await this.enabledMailChannels();
    if (channels.length === 0) return;
    await this.scheduleDrain(MAIL_PUSH_DRAIN, this.mailPushDrain, {
      // Signal-only drain: the merged pass derives its own work from mailbox
      // state. 2s keeps push feeling instant while still folding a burst into
      // one pass.
      delayMs: 2000,
      handlerArgs: [],
    });
  }

  /**
   * Coalesced drain pass behind `mailPushed` — one merged sync, guarded by the
   * same connection-level `mail_sync` lock as `mailPoll`/`mailSyncTask`.
   * Unlike `mailPoll` (which just skips and waits for the next interval), a
   * lost race here RESCHEDULES the drain instead of dropping it: the change
   * that triggered this push may have landed AFTER the in-flight pass's
   * mailbox SEARCH already ran, so it isn't guaranteed to be covered. The
   * non-blocking acquire + reschedule can't deadlock or busy-loop — the
   * current holder releases within one pass's duration, well inside the 2s
   * delay before this retries.
   *
   * `_channelId` is accepted and ignored so drains scheduled by earlier,
   * per-channel versions still resolve.
   *
   * Passes `resolveMailHistoryMin()` rather than `undefined` — same reason as
   * `mailPoll`: falling back to `undefined` here would let a lost granted
   * floor collapse to `mailSync`'s hardcoded default on every push instead of
   * self-healing from the persisted `MAIL_GRANTED_HISTORY_MIN_KEY`.
   */
  async mailPushDrain(_ids: string[], _channelId?: string): Promise<void> {
    const channels = await this.enabledMailChannels();
    if (channels.length === 0) return;

    const acquired = await this.tools.store.acquireLock(
      MAIL_SYNC_LOCK,
      Apple.MAIL_SYNC_LOCK_TTL_MS
    );
    if (!acquired) {
      await this.scheduleDrain(MAIL_PUSH_DRAIN, this.mailPushDrain, {
        delayMs: 2000,
        handlerArgs: [],
      });
      return;
    }
    try {
      await mailSync(this.buildMailHost(), channels, await this.resolveMailHistoryMin());
    } finally {
      await this.tools.store.releaseLock(MAIL_SYNC_LOCK);
    }
  }

  /**
   * Coalesced drain pass for deferred read/to-do flag write-backs queued by
   * `setThreadFlag` (`mail/write.ts`) when a direct IMAP write fails
   * transiently. Each id is `${"read"|"todo"}:${rootId}`; `scheduleDrain`'s
   * durable set only tracks id presence + attempt count, so the desired flag
   * state is looked up from its own `writeback:${kind}:${rootId}` key
   * (written by `setThreadFlag`) and re-applied here. A missing payload means
   * a fresher direct call already resolved it — skip without retrying. Ids
   * that fail again are returned in `retry`; `scheduleDrain` bumps their
   * attempt count and drops them once `maxAttempts` (default 5) is exceeded.
   */
  async mailWritebackDrain(ids: string[]): Promise<DrainResult> {
    const host = this.buildMailHost();
    const retry: string[] = [];
    for (const id of ids) {
      const sep = id.indexOf(":");
      const kind = id.slice(0, sep);
      const rootId = id.slice(sep + 1);
      const pending = await host.get<{
        title?: string;
        mailbox?: string;
        flag: string;
        operation: "add" | "remove";
      }>(`writeback:${kind}:${rootId}`);
      if (!pending) continue; // already resolved by a fresher direct call
      try {
        const session = await connectIcloud(host);
        try {
          // `mailbox` may be absent on a payload persisted before write-back
          // became mailbox-aware — fall back to INBOX, the historical target.
          const { uids } = await resolveThreadMessages(
            host,
            session,
            pending.mailbox ?? "INBOX",
            rootId,
            pending.title
          );
          if (uids.length > 0) {
            await host.imap.setFlags(session, uids, [pending.flag], pending.operation);
          }
          await host.clear(`writeback:${kind}:${rootId}`);
        } finally {
          await host.imap.disconnect(session);
        }
      } catch {
        retry.push(id); // scheduleDrain bumps attempts + auto-drops after maxAttempts
      }
    }
    return { retry };
  }

  /**
   * Start (or refresh) the platform-held IMAP IDLE watch on EVERY enabled
   * channel's mailbox. Watches stay per mailbox — `imap.watch` is keyed that
   * way — even though everything they trigger (the drain, the pass, the lock)
   * is connection-level.
   *
   * Each channel's callback token is created once and reused across re-arms;
   * `imap.watch` is a keyed upsert, so re-arming every poll costs one cheap
   * call per channel and never stacks watches or callbacks. Failures are
   * per channel and degrade to polling rather than failing the caller's sync
   * or skipping the remaining channels.
   *
   * Sent is deliberately not watched: it is not an enable-able channel. New
   * Sent mail is picked up by the 15-minute poll or by any folder's push.
   */
  private async armMailWatches(channels: MailChannel[]): Promise<void> {
    for (const { channelId, mailbox } of channels) {
      try {
        let cb = await this.get<Callback>(`mail:push_cb_${channelId}`);
        if (!cb) {
          cb = (await this.callback(this.mailPushed, channelId)) as Callback;
          await this.set(`mail:push_cb_${channelId}`, cb);
        }
        await this.tools.imap.watch(
          channelId,
          {
            ...ICLOUD_IMAP,
            username: this.tools.options.appleId as string,
            password: this.tools.options.appPassword as string,
            mailbox,
          },
          cb
        );
      } catch (error) {
        // Push is an enhancement over the 15-minute poll — a watch-arm
        // failure must not fail the sync that triggered it, nor stop the
        // other channels' watches from being armed. The next poll retries.
        console.warn(`[Apple] Failed to arm IMAP watch for ${channelId}:`, error);
      }
    }
  }

  /**
   * Schedule the recurring mail poll — ONE for the whole connection, so N
   * enabled folders don't produce N overlapping passes fighting over the
   * `mail_sync` lock and the single `mail:state` cursor document. Keyed
   * distinctly from calendar's `poll:<id>` so the two products' polling chains
   * never collide. `scheduleRecurring` re-arms automatically — `mailPoll` must
   * not reschedule itself.
   */
  private async scheduleMailPoll(): Promise<void> {
    const cb = await this.callback(this.mailPoll);
    await this.scheduleRecurring(MAIL_POLL_TASK, cb, {
      intervalMs: 15 * 60 * 1000,
      firstRunAt: new Date(Date.now() + 15 * 60 * 1000),
    });
  }

  /**
   * Called when a calendar channel is disabled.
   */
  private async onCalendarChannelDisabled(channel: Channel): Promise<void> {
    // Cancel scheduled poll (singleton keyed task).
    await this.cancelScheduledTask(`poll:${channel.id}`);

    // Clear all state for this channel
    await this.clear(`sync_enabled_${channel.id}`);
    await this.clear(`sync_state_${channel.id}`);
    await this.clear(`ctag_${channel.id}`);
    await this.clear(`etags_${channel.id}`);
    await this.clear(`event_uids_${channel.id}`);
    await this.clear(`titled_uids_${channel.id}`);
    await this.clear(`synctoken_${channel.id}`);
    await this.clear(`incremental_state_${channel.id}`);

    // Release the framework-managed sync lock so a re-enable can acquire
    // cleanly without waiting for the TTL.
    await this.tools.store.releaseLock(`sync_${channel.id}`);

    // Clear pending occurrences AND seen-master markers for this
    // calendar only. Keys are scoped per calendar (calendar href as
    // prefix) so disabling one calendar doesn't wipe buffers for
    // siblings on the same account that are still enabled.
    await this.clearBuffers(channel.id);
  }

  /**
   * Clear all `pending_occ:` and `seen_master:` markers for one calendar.
   * Used on recovery, disable, and sync-error paths so stale buffers from
   * a crashed run can't combine with leftover seen-master markers to
   * materialise empty Untitled threads on the next initial sync.
   */
  private async clearBuffers(channelHref: string): Promise<void> {
    const pendingKeys = await this.tools.store.list(
      `pending_occ:${channelHref}:`
    );
    for (const key of pendingKeys) {
      await this.clear(key);
    }
    const seenMasterKeys = await this.tools.store.list(
      `seen_master:${channelHref}:`
    );
    for (const key of seenMasterKeys) {
      await this.clear(key);
    }
  }

  // ---- Mail Write-Back ----
  //
  // None of the write-back/user-action handlers below (onNoteCreated,
  // onCreateLink, onThreadRead, onThreadToDo, downloadAttachment) or
  // mailWritebackDrain/getMailChannels take the connection-level `mail_sync`
  // lock used by mailSyncTask/mailPoll/mailPushDrain. They're
  // user-latency-sensitive (a reply, a read/to-do toggle, an attachment
  // download the user is waiting on) and/or open their own short-lived IMAP
  // session — gating them behind a possibly-long backfill would add
  // user-visible latency for no correctness benefit. Because `acquireLock` is
  // non-blocking, leaving them unlocked can't deadlock against the sync
  // lock; the residual concurrency (one read-sync session alongside a short
  // write-back/reply session and the always-on IDLE watch) is small and
  // acceptable.

  /**
   * A reply on a mail thread → send it over SMTP. No-ops for calendar threads
   * (the mail fn gates on meta.syncProvider === "apple-mail").
   */
  override async onNoteCreated(
    note: Note,
    thread: Thread
  ): Promise<NoteWriteBackResult | void> {
    return onNoteCreatedFn(this.buildMailHost(), note, thread);
  }

  /**
   * A Plot-composed thread → either a new sent email (SMTP) or a new iCloud
   * reminder (CalDAV), by draft type. No-ops (returns null) for any other
   * link type.
   */
  override async onCreateLink(draft: CreateLinkDraft): Promise<CreateLinkResult | null> {
    const mailResult = await onCreateLinkFn(this.buildMailHost(), draft);
    if (mailResult) return mailResult;
    return onRemindersCreateLinkFn(this.buildRemindersHost(), draft);
  }

  /** Read/unread on a mail thread → \Seen write-back over IMAP. */
  override async onThreadRead(thread: Thread, actor: Actor, unread: boolean): Promise<void> {
    await onThreadReadFn(this.buildMailHost(), thread, actor, unread);
  }

  /** To-do toggle on a mail thread → \Flagged write-back over IMAP. */
  override async onThreadToDo(
    thread: Thread,
    actor: Actor,
    todo: boolean,
    options: { date?: Date }
  ): Promise<void> {
    await onThreadToDoFn(this.buildMailHost(), thread, actor, todo, options);
  }

  /** Status toggle (done <-> reopen) on a reminder link → VTODO STATUS write-back over CalDAV. */
  override async onLinkUpdated(link: Link): Promise<void> {
    await onRemindersLinkUpdatedFn(this.buildRemindersHost(), link);
  }

  /**
   * Resolve an inbound mail attachment's bytes for download. `ref` is the
   * opaque `<mailbox>:<uid>:<partNumber>` value transform.ts emitted on the
   * note's `fileRef` action — see mail/attachments.ts.
   */
  override async downloadAttachment(
    ref: string
  ): Promise<{ body: Uint8Array; mimeType: string }> {
    return downloadAttachmentFn(this.buildMailHost(), ref);
  }

  // ---- Sync Logic ----

  /**
   * Sync a batch of calendar events.
   */
  async syncBatch(
    calendarHref: string,
    initialSync: boolean,
    batchNumber: number,
    timeRangeStart?: string,
    timeRangeEnd?: string
  ): Promise<void> {
    try {
      const client = this.getCalDAV();

      if (batchNumber === 1 && timeRangeStart && timeRangeEnd) {
        // First batch: fetch all events in the time range. Preserve `phase`
        // from any pre-seeded state (initChannel writes phase=quick before
        // queuing this callback; the quick→full transition writes phase=full
        // before queuing again).
        const seeded = await this.get<SyncState>(`sync_state_${calendarHref}`);
        const phase = seeded?.phase;
        const events = await client.fetchEvents(this.calDavHref(calendarHref), {
          start: timeRangeStart,
          end: timeRangeEnd,
        });

        // Process events in batches. processCalDAVEvents persists the
        // href→uid AND href→etag maps together at end-of-batch so the two
        // stay consistent across worker crashes — see the comment on
        // processCalDAVEvents for why we deliberately don't pre-write
        // etags before processing.
        await this.processCalDAVEvents(
          events.slice(0, 50),
          calendarHref,
          initialSync
        );

        if (events.length > 50) {
          // Store remaining hrefs for next batches
          const remainingHrefs = events.slice(50).map((e) => e.href);
          await this.set(`sync_state_${calendarHref}`, {
            calendarHref,
            initialSync,
            batchNumber: batchNumber + 1,
            pendingHrefs: remainingHrefs,
            phase,
            timeRangeStart,
            timeRangeEnd,
          } as SyncState);

          const nextBatch = await this.callback(
            this.syncBatchContinue,
            calendarHref,
            initialSync,
            batchNumber + 1
          );
          await this.runTask(nextBatch);
        } else {
          await this.finishSync(calendarHref, initialSync, phase);
        }
      }
    } catch (error) {
      console.error(
        `Apple Calendar sync failed for ${calendarHref} in batch ${batchNumber}:`,
        error
      );

      // Release lock and clear state so future syncs aren't permanently
      // blocked. Wrap in its own try/catch so a release/clear failure
      // doesn't mask the original error — the lock's TTL is the safety net.
      try {
        await this.tools.store.releaseLock(`sync_${calendarHref}`);
        await this.clear(`sync_state_${calendarHref}`);
      } catch (cleanupError) {
        console.error(
          `Apple Calendar sync cleanup after failure also failed for ${calendarHref}:`,
          cleanupError
        );
      }

      // Clear any `pending_occ:` / `seen_master:` markers buffered by
      // this initial-sync run. Otherwise the next initial sync would
      // inherit them and the full-pass orphan flush could materialise
      // empty Untitled threads from leftover-but-now-stale buffers.
      // Incremental sync doesn't buffer, but the clear is idempotent.
      try {
        await this.clearBuffers(calendarHref);
      } catch (cleanupError) {
        console.error(
          `Failed to clear pending buffers after sync error for ${calendarHref}:`,
          cleanupError
        );
      }

      // The runtime auto-clears the "Syncing…" indicator when
      // onChannelEnabled itself throws, but NOT when a queued task
      // throws. Without an explicit signal here, the indicator stays on
      // indefinitely after a mid-sync crash until the user disables and
      // re-enables. Inner try/catch so a signal failure doesn't mask
      // the original error.
      if (initialSync) {
        try {
          await this.tools.integrations.channelSyncCompleted(calendarHref);
        } catch (signalError) {
          console.error(
            "Failed to signal sync completion on error path:",
            signalError
          );
        }
      }

      // Schedule a poll so polling resumes — otherwise a failure here
      // strands the channel (startIncrementalSync's lock-fail bail
      // intentionally relies on the active holder, which is us, to
      // reschedule).
      await this.schedulePoll(calendarHref);

      // Re-throw to let the runtime handle it (PostHog capture, etc.).
      throw error;
    }
  }

  /**
   * Continue processing remaining events using multiget.
   */
  async syncBatchContinue(
    calendarHref: string,
    initialSync: boolean,
    batchNumber: number
  ): Promise<void> {
    try {
      const state = await this.get<SyncState>(`sync_state_${calendarHref}`);
      if (!state?.pendingHrefs?.length) {
        await this.finishSync(calendarHref, initialSync, state?.phase);
        return;
      }

      const client = this.getCalDAV();
      const batch = state.pendingHrefs.slice(0, 50);
      const remaining = state.pendingHrefs.slice(50);

      const events = await client.fetchEventsByHref(this.calDavHref(calendarHref), batch);
      await this.processCalDAVEvents(events, calendarHref, initialSync);

      if (remaining.length > 0) {
        await this.set(`sync_state_${calendarHref}`, {
          calendarHref,
          initialSync,
          batchNumber: batchNumber + 1,
          pendingHrefs: remaining,
          phase: state.phase,
          timeRangeStart: state.timeRangeStart,
          timeRangeEnd: state.timeRangeEnd,
        } as SyncState);

        const nextBatch = await this.callback(
          this.syncBatchContinue,
          calendarHref,
          initialSync,
          batchNumber + 1
        );
        await this.runTask(nextBatch);
      } else {
        await this.finishSync(calendarHref, initialSync, state.phase);
      }
    } catch (error) {
      console.error(
        `Apple Calendar sync continue failed for ${calendarHref} in batch ${batchNumber}:`,
        error
      );

      // Release lock and clear state so future syncs aren't permanently
      // blocked. Wrap cleanup so a release/clear failure doesn't mask the
      // original error — the lock's TTL is the safety net.
      try {
        await this.tools.store.releaseLock(`sync_${calendarHref}`);
        await this.clear(`sync_state_${calendarHref}`);
      } catch (cleanupError) {
        console.error(
          `Apple Calendar sync cleanup after failure also failed for ${calendarHref}:`,
          cleanupError
        );
      }

      // Clear any `pending_occ:` / `seen_master:` markers buffered by
      // this initial-sync run — see syncBatch's catch for why.
      try {
        await this.clearBuffers(calendarHref);
      } catch (cleanupError) {
        console.error(
          `Failed to clear pending buffers after sync error for ${calendarHref}:`,
          cleanupError
        );
      }

      // The runtime auto-clears the "Syncing…" indicator when
      // onChannelEnabled itself throws, but NOT when a queued task
      // throws — see syncBatch's catch for the full rationale.
      if (initialSync) {
        try {
          await this.tools.integrations.channelSyncCompleted(calendarHref);
        } catch (signalError) {
          console.error(
            "Failed to signal sync completion on error path:",
            signalError
          );
        }
      }

      // Schedule a poll so polling resumes — startIncrementalSync's
      // lock-fail bail relies on the active holder (us) to reschedule.
      await this.schedulePoll(calendarHref);

      throw error;
    }
  }

  /**
   * Clean up after sync completes and schedule polling.
   *
   * On initial sync, this is invoked twice — once for the quick pass and
   * once for the full pass. The quick→full transition queues a fresh
   * syncBatch with `phase = "full"` and returns WITHOUT releasing the
   * lock or signalling completion. The full-pass terminal call performs
   * the orphan flush, ctag bump, channelSyncCompleted, and lock release.
   */
  private async finishSync(
    calendarHref: string,
    initialSync: boolean,
    phase?: "quick" | "full"
  ): Promise<void> {
    // Quick pass done: transition to full pass without releasing the lock
    // or clearing pending_occ buffers. The full pass walks the historical
    // range and any exception instances the quick pass buffered are
    // carried across; orphans (master never appeared in either pass) are
    // cleared by the orphan-flush block on the full-pass terminal below.
    if (initialSync && phase === "quick") {
      const now = new Date();
      const fullStart = toCalDAVTimeString(
        new Date(now.getFullYear() - 2, 0, 1)
      );
      const fullEnd = toCalDAVTimeString(
        new Date(now.getFullYear() + 1, 11, 31)
      );

      await this.set(`sync_state_${calendarHref}`, {
        calendarHref,
        initialSync: true,
        batchNumber: 1,
        phase: "full",
        timeRangeStart: fullStart,
        timeRangeEnd: fullEnd,
      } as SyncState);

      const fullCallback = await this.callback(
        this.syncBatch,
        calendarHref,
        true,
        1,
        fullStart,
        fullEnd
      );
      await this.runTask(fullCallback);
      return;
    }

    // Full-pass terminal (or `phase` absent, e.g. older deployed callbacks):
    // flush leftover pending_occ buffers as standalone occurrence-only
    // links — but ONLY when their master was actually processed during
    // this initial sync (and is therefore in the DB by now).
    // `seen_master:<canonical>` markers, written per batch in
    // processCalDAVEvents, distinguish legitimate cross-batch leftovers
    // (master-in-batch-A, instance-in-batch-B → flushed; saveLinks
    // upserts onto the existing master link) from orphans whose master
    // never came through (master deleted upstream → flushing would
    // create a useless empty Untitled thread, so drop silently).
    if (initialSync) {
      // Scope lookups to this calendar so concurrent syncs of other
      // calendars in the same account aren't affected.
      const seenMasterPrefix = `seen_master:${calendarHref}:`;
      const pendingPrefix = `pending_occ:${calendarHref}:`;
      const seenMasterKeys = await this.tools.store.list(seenMasterPrefix);
      const seenMasters = new Set(
        seenMasterKeys.map((k) => k.slice(seenMasterPrefix.length))
      );
      const pendingKeys = await this.tools.store.list(pendingPrefix);
      const flushLinks: NewLinkWithNotes[] = [];
      let droppedOrphans = 0;
      for (const key of pendingKeys) {
        const pending = await this.get<NewScheduleOccurrence>(key);
        if (!pending) {
          await this.clear(key);
          continue;
        }
        const occurrenceDate =
          pending.occurrence instanceof Date
            ? pending.occurrence
            : new Date(pending.occurrence as unknown as string);
        const suffix = `:${occurrenceDate.toISOString()}`;
        if (!key.startsWith(pendingPrefix) || !key.endsWith(suffix)) {
          // Malformed key — drop it.
          await this.clear(key);
          continue;
        }
        const canonical = key.slice(
          pendingPrefix.length,
          key.length - suffix.length
        );
        if (!seenMasters.has(canonical)) {
          droppedOrphans += 1;
          await this.clear(key);
          continue;
        }
        flushLinks.push({
          type: "event",
          title: undefined,
          source: canonical,
          sources: canonical.startsWith("apple-calendar:")
            ? buildEventSources(canonical.slice("apple-calendar:".length))
            : undefined,
          channelId: calendarHref,
          meta: {
            uid: canonical.startsWith("apple-calendar:")
              ? canonical.slice("apple-calendar:".length)
              : null,
            syncProvider: "apple",
            syncableId: calendarHref,
          },
          scheduleOccurrences: [pending],
          notes: [],
        });
        await this.clear(key);
      }
      if (flushLinks.length > 0 || droppedOrphans > 0) {
        console.log(
          `[AppleCalendar] full-pass flush: calendar=${calendarHref} ` +
            `flushedLinks=${flushLinks.length} ` +
            `droppedOrphans=${droppedOrphans}`
        );
      }
      if (flushLinks.length > 0) {
        await this.tools.integrations.saveLinks(flushLinks);
      }

      // Clear master markers for the next initial sync.
      for (const key of seenMasterKeys) {
        await this.clear(key);
      }
    }

    // Update ctag
    const client = this.getCalDAV();
    const ctag = await client.getCalendarCtag(this.calDavHref(calendarHref));
    if (ctag) await this.set(`ctag_${calendarHref}`, ctag);

    // Seed the RFC 6578 sync token so the first incremental poll after this
    // initial sync can take the fast `sync-collection` path instead of
    // falling back to the ctag/etag-diff walk (see startIncrementalSync). A
    // depth-0 PROPFIND — cheap regardless of calendar size, unlike
    // `getCollectionChanges(href, null)`, which would return every object
    // in the collection to compute a token.
    const syncToken = await client.getSyncToken(this.calDavHref(calendarHref));
    if (syncToken) await this.set(`synctoken_${calendarHref}`, syncToken);

    await this.clear(`sync_state_${calendarHref}`);

    // Initial sync is fully complete — clear the "syncing…" indicator on
    // the connection. Gated on initialSync so incremental polls don't
    // re-fire the signal.
    if (initialSync) {
      await this.tools.integrations.channelSyncCompleted(calendarHref);
    }

    // Release the framework-managed sync lock so the next poll (or a
    // manual re-trigger) can acquire it.
    await this.tools.store.releaseLock(`sync_${calendarHref}`);

    // Schedule next poll in 15 minutes
    await this.schedulePoll(calendarHref);
  }

  /**
   * Schedule a poll for changes in 15 minutes.
   */
  private async schedulePoll(calendarHref: string): Promise<void> {
    const enabled = await this.get<boolean>(`sync_enabled_${calendarHref}`);
    if (!enabled) return;

    // Singleton scheduled task: re-scheduling under this key atomically
    // replaces any pending poll, so the self-rescheduling loop can never
    // stack — even if onChannelEnabled is re-dispatched (auto-enable /
    // recovery) or multiple sync paths each (re)schedule a poll.
    const pollCallback = await this.callback(this.pollForChanges, calendarHref);
    await this.scheduleRecurring(`poll:${calendarHref}`, pollCallback, {
      intervalMs: 15 * 60 * 1000,
      firstRunAt: new Date(Date.now() + 15 * 60 * 1000),
    });
  }

  /**
   * Poll for changes.
   *
   * Once a sync token is stored, this goes STRAIGHT to `startIncrementalSync`
   * — its fast path (an RFC 6578 `sync-collection` REPORT) already IS the
   * cheap "did anything change?" check: one request, cost independent of
   * delta size, and it always returns a fresh token to persist. Gating it
   * behind a separate ctag PROPFIND first would just be a second O(1)
   * request for no benefit — and worse, the fast path's tail never used to
   * refresh `ctag_` (see FIX 2's history: the fallback tail wrote
   * `ctag_`/`etags_`, but the fast tail wrote only `synctoken_`), so once
   * ANY real change happened, `ctag_` froze at its initial-sync value
   * forever — making this gate permanently "changed" and forcing a REPORT
   * on every single poll regardless of whether anything actually changed
   * since the last one. Removing the ctag pre-check for the steady state
   * (a token exists on every poll after the first) sidesteps that
   * staleness entirely rather than adding another PROPFIND to keep it
   * fresh.
   *
   * The ctag comparison is kept ONLY for when no token is stored yet (first
   * poll after enable/recovery, or the pass right after an invalid-token
   * reset) — there, it's still a cheap way to avoid firing the expensive
   * etag-diff fallback walk `startIncrementalSync` would otherwise run
   * unconditionally on every idle 15-minute tick.
   */
  async pollForChanges(calendarHref: string): Promise<void> {
    const enabled = await this.get<boolean>(`sync_enabled_${calendarHref}`);
    if (!enabled) return;

    try {
      const storedToken = await this.get<string>(`synctoken_${calendarHref}`);
      if (storedToken) {
        await this.startIncrementalSync(calendarHref);
        return;
      }

      const client = this.getCalDAV();
      const currentCtag = await client.getCalendarCtag(this.calDavHref(calendarHref));
      const storedCtag = await this.get<string>(`ctag_${calendarHref}`);

      if (currentCtag && currentCtag !== storedCtag) {
        // Calendar has changed — run incremental sync
        await this.startIncrementalSync(calendarHref);
      } else {
        // No changes — just schedule next poll
        await this.schedulePoll(calendarHref);
      }
    } catch (error) {
      if (error instanceof AuthenticationError) {
        // Expected, user-visible failure (revoked/incorrect app-specific
        // password) — per the repo's error-capture rule, expected auth
        // failures the user will see must not be reported. Left
        // unclassified, this would re-throw on EVERY 15-minute poll of
        // EVERY calendar for the life of a dead connection
        // (~96/day/calendar, plus queue retries) and page error tracking
        // every time. Log locally for visibility, reschedule so the
        // connection keeps retrying (the user may fix the password), and
        // swallow rather than re-throw.
        console.warn(`Apple Calendar poll auth failure for ${calendarHref}:`, error);
        await this.schedulePoll(calendarHref);
        return;
      }
      console.error(`Poll failed for calendar ${calendarHref}:`, error);
      // Schedule next poll even on failure — a transient blip (network
      // hiccup, momentary iCloud outage) shouldn't kill the polling chain.
      await this.schedulePoll(calendarHref);
      // Re-throw so the runtime reports it (PostHog capture, etc.) — same
      // reasoning as every other calendar catch in this file (see the
      // comment on syncBatch's catch). A failing ctag check or incremental
      // sync is genuinely unexpected (network blip, iCloud outage, a bug)
      // and was previously invisible: this caught it, logged it, and
      // swallowed it with no way to notice a persistent failure.
      throw error;
    }
  }

  /**
   * Incremental sync entry point. Tries the RFC 6578 WebDAV-Sync fast path
   * first — a `sync-collection` REPORT that returns only what changed since
   * the stored token, skipping the O(all events) PROPFIND `getEventEtags`
   * does on every poll — and falls back to the proven ctag/etag-diff walk
   * whenever the fast path isn't available or is rejected. This is a GATE in
   * front of the fallback, not a replacement for it:
   *
   *  - No stored token (first incremental pass after enable/recovery): runs
   *    the fallback unchanged, and seeds a token at the end for next time.
   *  - Stored token, server accepts it: fast path only — the win.
   *  - Stored token, server rejects it (`InvalidSyncTokenError`, RFC 6578
   *    §3.7): the token is discarded and the fallback runs for THIS pass,
   *    reseeding a fresh token at the end. Never surfaces as a failure.
   */
  private async startIncrementalSync(calendarHref: string): Promise<void> {
    // Acquire sync lock to prevent the 15-min poll from racing an
    // in-progress initial sync, or two polls overlapping if a previous
    // run is still draining batches.
    const acquired = await this.tools.store.acquireLock(
      `sync_${calendarHref}`,
      Apple.SYNC_LOCK_TTL_MS
    );
    if (!acquired) {
      // Another sync is in flight. Don't reschedule a poll either — the
      // running sync's completion (finishSync / completeIncrementalSync)
      // will schedule the next one.
      return;
    }

    try {
      const client = this.getCalDAV();
      const storedToken = await this.get<string>(`synctoken_${calendarHref}`);

      if (storedToken) {
        try {
          await this.runFastIncrementalSync(client, calendarHref, storedToken);
          return; // completeIncrementalSync (inline, or via a queued
          // continuation for a large delta) already released the lock and
          // scheduled the next poll.
        } catch (error) {
          if (!(error instanceof InvalidSyncTokenError)) throw error;
          // RFC 6578 §3.7 precondition failure — the token is stale
          // (expired, or the collection was reset server-side). Discard it
          // and fall through to the fallback below for THIS pass; a fresh
          // token is reseeded once it completes.
          await this.clear(`synctoken_${calendarHref}`);
        }
      }

      await this.runFallbackIncrementalSync(client, calendarHref);
    } catch (error) {
      console.error(
        `Apple Calendar incremental sync failed for ${calendarHref}:`,
        error
      );

      // Release lock so future syncs aren't permanently blocked. Wrap in
      // its own try/catch so a release failure doesn't mask the real
      // error — the lock's TTL is the safety net.
      try {
        await this.tools.store.releaseLock(`sync_${calendarHref}`);
        await this.clear(`incremental_state_${calendarHref}`);
      } catch (cleanupError) {
        console.error(
          `Apple Calendar incremental sync cleanup after failure also failed for ${calendarHref}:`,
          cleanupError
        );
      }

      // Incremental sync doesn't buffer to `pending_occ:`, but the next
      // initial sync (after a fresh enable) might inherit any markers
      // sitting in storage. The clear is idempotent so it's safe to run
      // here even on the incremental error path.
      try {
        await this.clearBuffers(calendarHref);
      } catch (cleanupError) {
        console.error(
          `Failed to clear pending buffers after incremental sync error for ${calendarHref}:`,
          cleanupError
        );
      }

      // Reschedule a poll so we recover on the next interval.
      await this.schedulePoll(calendarHref);

      throw error;
    }
  }

  /**
   * RFC 6578 WebDAV-Sync fast path: ask the server for only what changed
   * since `storedToken` instead of PROPFINDing every event's etag. Never
   * catches `InvalidSyncTokenError` — that propagates to the caller
   * (`startIncrementalSync`), which clears the stored token and retries via
   * the fallback for this pass.
   */
  private async runFastIncrementalSync(
    client: CalDAVClient,
    calendarHref: string,
    storedToken: string
  ): Promise<void> {
    const { token, changed, deletedHrefs } = await client.getCollectionChanges(
      this.calDavHref(calendarHref),
      storedToken
    );

    const storedUids =
      (await this.get<Record<string, string>>(
        `event_uids_${calendarHref}`
      )) || {};

    if (deletedHrefs.length > 0) {
      const { archivedCount, missingUidCount } = await this.archiveDeletedHrefs(
        calendarHref,
        deletedHrefs,
        storedUids
      );
      console.log(
        `[AppleCalendar] fast incremental sync: calendar=${calendarHref} ` +
          `deleted=${deletedHrefs.length} archived=${archivedCount} ` +
          `missingUid=${missingUidCount}`
      );
    }

    // Fetch and process changed events, chunked (see
    // processChangedHrefsChunked). Completes the pass — including
    // persisting the new sync token and pruning event_uids_/etags_ for
    // deletedHrefs (FIX 3) — once every chunk has succeeded.
    await this.processChangedHrefsChunked(
      client,
      calendarHref,
      changed.map((c) => c.href),
      { mode: "fast", syncToken: token, deletedHrefs }
    );
  }

  /**
   * The ctag/etag-diff incremental sync: PROPFIND every event's etag and
   * diff against the stored map to find changed/new/deleted events. Runs
   * when no sync token is stored yet (first incremental pass after
   * enabling/recovery) or when the server rejected the stored token (see
   * startIncrementalSync's catch). Unchanged in substance from before RFC
   * 6578 support was added, other than routing changed-href processing
   * through the shared chunking helper.
   */
  private async runFallbackIncrementalSync(
    client: CalDAVClient,
    calendarHref: string
  ): Promise<void> {
    // Get current etags
    const currentEtags = await client.getEventEtags(this.calDavHref(calendarHref));
    const storedEtags =
      (await this.get<Record<string, string>>(`etags_${calendarHref}`)) || {};
    const storedUids =
      (await this.get<Record<string, string>>(
        `event_uids_${calendarHref}`
      )) || {};

    // Find new/changed events
    const changedHrefs: string[] = [];
    const newEtagMap: Record<string, string> = {};

    for (const [href, etag] of currentEtags) {
      newEtagMap[href] = etag;
      if (!storedEtags[href] || storedEtags[href] !== etag) {
        changedHrefs.push(href);
      }
    }

    // Find deleted events (present in stored, absent from current)
    const deletedHrefs: string[] = [];
    for (const href of Object.keys(storedEtags)) {
      if (!currentEtags.has(href)) {
        deletedHrefs.push(href);
      }
    }

    // Archive deleted events selectively, per-uid — see archiveDeletedHrefs
    // for why a channel-level filter is unsafe and why this can't be
    // batched into fewer archiveLinks calls.
    if (deletedHrefs.length > 0) {
      const { archivedCount, missingUidCount } = await this.archiveDeletedHrefs(
        calendarHref,
        deletedHrefs,
        storedUids
      );
      console.log(
        `[AppleCalendar] incremental sync: calendar=${calendarHref} ` +
          `deleted=${deletedHrefs.length} archived=${archivedCount} ` +
          `missingUid=${missingUidCount}`
      );
    }

    // Fetch and process changed events, chunked (see
    // processChangedHrefsChunked). Completes the pass — pruning the uid
    // map, persisting the authoritative etag snapshot, refreshing the
    // ctag, and seeding a fresh sync token — once every chunk has
    // succeeded.
    await this.processChangedHrefsChunked(client, calendarHref, changedHrefs, {
      mode: "fallback",
      newEtagMap,
    });
  }

  /**
   * Archive deleted calendar hrefs by resolving each to its persisted uid
   * via `event_uids_<calendarHref>`, then `archiveLinks` per uid. Previously
   * this code called `archiveLinks` with only the channel-level meta — a
   * containment filter that matches every Apple event on the channel. One
   * deleted event would wipe the whole calendar. The href→uid map built in
   * `processCalDAVEvents` lets us resolve each deleted href back to its uid
   * and archive precisely.
   *
   * Hrefs missing from the uid map are skipped (logged): they were synced
   * before this map existed, and will be rebuilt on the next batch that
   * touches them, but on this one run we can't safely archive by channel
   * without the data-loss risk above.
   *
   * NOT BATCHABLE: `integrations.archiveLinks` (see
   * `@plotday/twister/tools/integrations`) takes a SINGLE `ArchiveLinkFilter`
   * matched via jsonb containment (`link.meta @> filter.meta` — see
   * `archive_links` in the schema), not a `uid: string[]` / IN-list form. N
   * distinct uids genuinely require N calls; there's no way to widen the
   * filter to match several uids at once without also matching every OTHER
   * event on the channel (the exact data-loss bug this per-uid approach was
   * written to avoid). Left serial, per the existing TODO below.
   *
   * Per-uid archive is serial — fine for typical incremental drift (≤
   * handful of deletes per poll), but a bulk delete (user clearing a
   * multi-year backfill) could approach the ~1000-request runtime limit.
   *
   * TODO: extend `integrations.archiveLinks` to accept a `uids[]` filter (or
   * chunk this loop into batched callbacks via runTask) before this becomes
   * a real-world cap. Deferred for now — typical deletion volume is well
   * below the budget.
   */
  private async archiveDeletedHrefs(
    calendarHref: string,
    deletedHrefs: string[],
    storedUids: Record<string, string>
  ): Promise<{ archivedCount: number; missingUidCount: number }> {
    let archivedCount = 0;
    let missingUidCount = 0;
    for (const href of deletedHrefs) {
      const uid = storedUids[href];
      if (!uid) {
        missingUidCount += 1;
        continue;
      }
      await this.tools.integrations.archiveLinks({
        channelId: calendarHref,
        meta: { syncProvider: "apple", syncableId: calendarHref, uid },
      });
      archivedCount += 1;
    }
    return { archivedCount, missingUidCount };
  }

  /**
   * Process `changedHrefs` in calendar-multiget REPORTs of
   * `CALDAV_MULTIGET_CHUNK_SIZE` (50), mirroring `syncBatch`/
   * `syncBatchContinue`'s established initial-sync chunk size. When
   * everything fits in one chunk (the common case — a normal 15-minute
   * poll's delta is typically tiny), this completes the pass inline via
   * `completeIncrementalSync`. When more remain, the remainder plus enough
   * state to finish correctly is persisted to
   * `incremental_state_<calendarHref>` and handed to a queued
   * `incrementalSyncContinue` task instead of being processed inline — so a
   * large delta (post-outage catch-up, mass edit) can't blow one
   * execution's ~1000-request / CPU / memory budget. The sync lock stays
   * held across continuations; only `completeIncrementalSync` releases it.
   * Shared by both the fast path and the fallback path — `tail` carries
   * whichever bookkeeping each path's `completeIncrementalSync` call needs
   * once every chunk has succeeded.
   */
  private async processChangedHrefsChunked(
    client: CalDAVClient,
    calendarHref: string,
    changedHrefs: string[],
    tail: IncrementalSyncTail
  ): Promise<void> {
    const chunk = changedHrefs.slice(0, Apple.CALDAV_MULTIGET_CHUNK_SIZE);
    const remaining = changedHrefs.slice(Apple.CALDAV_MULTIGET_CHUNK_SIZE);

    if (chunk.length > 0) {
      const events = await client.fetchEventsByHref(
        this.calDavHref(calendarHref),
        chunk
      );
      await this.processCalDAVEvents(events, calendarHref, false);
    }

    if (remaining.length === 0) {
      await this.completeIncrementalSync(calendarHref, tail);
      return;
    }

    await this.set(`incremental_state_${calendarHref}`, {
      pendingHrefs: remaining,
      tail,
    } as IncrementalSyncState);
    const nextBatch = await this.callback(
      this.incrementalSyncContinue,
      calendarHref
    );
    await this.runTask(nextBatch);
  }

  /**
   * Continuation task for a chunked incremental-sync changed-href multiget
   * (see `processChangedHrefsChunked`). Runs as its OWN execution (queued
   * via `runTask`), so it gets a fresh request/CPU/memory budget — the
   * entire reason for chunking in the first place. Processes the next
   * chunk and either re-queues itself (more remain) or completes the pass.
   */
  async incrementalSyncContinue(calendarHref: string): Promise<void> {
    try {
      const state = await this.get<IncrementalSyncState>(
        `incremental_state_${calendarHref}`
      );
      if (!state?.pendingHrefs?.length) {
        // Shouldn't normally happen — processChangedHrefsChunked only
        // queues this continuation when `remaining` is non-empty — but
        // degrade gracefully rather than leaving the lock stuck until its
        // TTL: finish with whatever tail we have, or if even that's gone
        // (e.g. a disable cleared `incremental_state_` between this
        // continuation being queued and it firing), just release the lock
        // and reschedule.
        if (state?.tail) {
          await this.completeIncrementalSync(calendarHref, state.tail);
        } else {
          await this.tools.store.releaseLock(`sync_${calendarHref}`);
          await this.schedulePoll(calendarHref);
        }
        return;
      }

      const client = this.getCalDAV();
      await this.processChangedHrefsChunked(
        client,
        calendarHref,
        state.pendingHrefs,
        state.tail
      );
    } catch (error) {
      console.error(
        `Apple Calendar incremental sync continuation failed for ${calendarHref}:`,
        error
      );

      // Release lock and clear continuation state so future syncs aren't
      // permanently blocked. Wrap in its own try/catch so a release/clear
      // failure doesn't mask the original error — the lock's TTL is the
      // safety net. Mirrors syncBatchContinue's catch.
      try {
        await this.tools.store.releaseLock(`sync_${calendarHref}`);
        await this.clear(`incremental_state_${calendarHref}`);
      } catch (cleanupError) {
        console.error(
          `Apple Calendar incremental sync continuation cleanup after failure also failed for ${calendarHref}:`,
          cleanupError
        );
      }

      // Reschedule a poll so we recover on the next interval —
      // startIncrementalSync's lock-fail bail relies on the active holder
      // (us) to reschedule.
      await this.schedulePoll(calendarHref);

      throw error;
    }
  }

  /**
   * Apply the tail bookkeeping for a completed incremental sync pass — see
   * `IncrementalSyncTail` — then release the sync lock and schedule the
   * next poll. Called either inline from `processChangedHrefsChunked`
   * (common case: the whole delta fit in one chunk) or from
   * `incrementalSyncContinue`'s terminal chunk (a large delta that needed
   * multiple chunks/executions).
   *
   * ⚠️ CRASH-SAFETY ORDERING: this is the ONLY place a new sync cursor
   * (`synctoken_<calendarHref>`, or the fallback's `etags_`/`ctag_`
   * snapshot) is persisted for an incremental pass, and it runs LAST — only
   * after every chunk's deletions/changed-events have already been
   * archived/saved. If a worker crashes between chunks (before this runs),
   * the OLD cursor is still stored, so the next poll simply re-derives and
   * re-applies the same delta — archiveLinks/saveLinks are both
   * idempotent upserts, so that replay is a safe no-op for whatever was
   * already applied. Persisting the cursor BEFORE processing finished would
   * instead let a crash permanently skip whatever wasn't yet processed,
   * with no way to re-derive it — the same class of bug as writing
   * `etags_`/`ctag_` early (see the note on `processCalDAVEvents`).
   */
  private async completeIncrementalSync(
    calendarHref: string,
    tail: IncrementalSyncTail
  ): Promise<void> {
    if (tail.mode === "fast") {
      // Prune event_uids_/etags_ for hrefs reported deleted this pass
      // (FIX 3) — the fallback tail below rebuilds its uid map wholesale
      // from an authoritative snapshot, but the fast path only ever sees a
      // delta, so precise per-href removal is the only option here. Only
      // touch the maps (an extra get+set each) when there's actually
      // something to prune — the common idle-poll case has none.
      if (tail.deletedHrefs.length > 0) {
        const uidMap =
          (await this.get<Record<string, string>>(
            `event_uids_${calendarHref}`
          )) || {};
        const etagMap =
          (await this.get<Record<string, string>>(`etags_${calendarHref}`)) ||
          {};
        let uidMapDirty = false;
        let etagMapDirty = false;
        for (const href of tail.deletedHrefs) {
          if (href in uidMap) {
            delete uidMap[href];
            uidMapDirty = true;
          }
          if (href in etagMap) {
            delete etagMap[href];
            etagMapDirty = true;
          }
        }
        if (uidMapDirty) await this.set(`event_uids_${calendarHref}`, uidMap);
        if (etagMapDirty) await this.set(`etags_${calendarHref}`, etagMap);
      }
      await this.set(`synctoken_${calendarHref}`, tail.syncToken);
    } else {
      // Prune the uid map: drop entries whose href is no longer present in
      // the current (authoritative) etag set. Keeps the map bounded as
      // events are deleted.
      const storedUids =
        (await this.get<Record<string, string>>(
          `event_uids_${calendarHref}`
        )) || {};
      const newUidMap: Record<string, string> = {};
      for (const href of Object.keys(tail.newEtagMap)) {
        const uid = storedUids[href];
        if (uid) newUidMap[href] = uid;
      }
      await this.set(`event_uids_${calendarHref}`, newUidMap);

      // Update stored etags and ctag
      await this.set(`etags_${calendarHref}`, tail.newEtagMap);
      const client = this.getCalDAV();
      const ctag = await client.getCalendarCtag(this.calDavHref(calendarHref));
      if (ctag) await this.set(`ctag_${calendarHref}`, ctag);

      // Seed a fresh sync token for the next poll's fast path. The
      // ctag/etag-diff walk never gets one from a REPORT response the way
      // the fast path does, so a dedicated (cheap, depth-0) PROPFIND is the
      // only way to obtain one here.
      const syncToken = await client.getSyncToken(this.calDavHref(calendarHref));
      if (syncToken) await this.set(`synctoken_${calendarHref}`, syncToken);
    }

    await this.clear(`incremental_state_${calendarHref}`);

    // Release lock before scheduling the next poll so the poll can
    // re-acquire cleanly.
    await this.tools.store.releaseLock(`sync_${calendarHref}`);

    // Schedule next poll
    await this.schedulePoll(calendarHref);
  }

  // ---- Event Processing ----

  /**
   * Process CalDAV events (parse ICS and save as links).
   *
   * Also maintains the `event_uids_<calendarHref>` and `etags_<calendarHref>`
   * maps keyed by event href so future incremental syncs can archive deleted
   * events selectively by uid (see startIncrementalSync). Both maps are
   * updated together at end-of-batch as one logical commit per batch — if a
   * worker crashes mid-batch and never reaches this point, neither map is
   * advanced, keeping stored etags and stored uids consistent. Writing etags
   * before this method ran would have stranded hrefs in the etag set with no
   * uid mapping, so a future deletion would silently drop (logged as
   * missingUid).
   *
   * Recurrence-only entries (RECURRENCE-ID overrides) share the same uid
   * as their master, so the master entry already covers them — we record
   * uid once per href.
   *
   * Also maintains `titled_uids_<calendarHref>` — a Record<uid, true> of
   * uids that actually got a titled link saved this batch (mirrors
   * `event_uids_` in shape, but is written ONLY when `addLink` is actually
   * called for that uid, i.e. `prepareEvent`/`prepareEventInstance`
   * returned non-null). This is deliberately a SEPARATE signal from
   * `event_uids_`: that map records every href/uid CalDAV returned,
   * regardless of whether a link was produced (`uidMap[href] = uid` above
   * is unconditional) — most notably, a master event that's
   * `STATUS:CANCELLED` during INITIAL sync is skipped entirely
   * (`prepareEvent` returns null) yet still gets recorded in `event_uids_`.
   * `knownEventUids()` (backing `MailHost.knownEventUids`, consumed by
   * `mail/sync.ts`'s FIX 1 title-omission decision) needs the precise
   * "does a titled calendar thread actually exist for this uid" answer —
   * using `event_uids_` there would report that skipped-cancelled uid as
   * "known" and wrongly omit `title` on a bundled mail link, silently
   * reintroducing the "Untitled" bug FIX 1 exists to fix.
   */
  private async processCalDAVEvents(
    events: CalDAVEvent[],
    calendarHref: string,
    initialSync: boolean
  ): Promise<void> {
    // Load persisted href→uid and href→etag maps once, merge new entries
    // from this batch in memory, and write back together at the end. Avoids
    // one read+write per event and ensures both maps advance atomically per
    // batch.
    const uidMap =
      (await this.get<Record<string, string>>(
        `event_uids_${calendarHref}`
      )) || {};
    const etagMap =
      (await this.get<Record<string, string>>(`etags_${calendarHref}`)) || {};
    const titledUids =
      (await this.get<Record<string, true>>(
        `titled_uids_${calendarHref}`
      )) || {};
    let uidMapDirty = false;
    let etagMapDirty = false;
    let titledUidsDirty = false;

    // Coalesce everything keyed by canonical source so a master + any number
    // of its exception instances (and multiple exceptions of the same series
    // landing in the same batch) collapse into a single NewLinkWithNotes. The
    // final saveLinks call makes one RPC for the entire batch. Heavy
    // recurring meetings (master + many exception VEVENTs in one ICS file)
    // used to fire N+1 saveLink calls; now they fire one.
    const linksBySource = new Map<string, NewLinkWithNotes>();
    type LinkWithSource = NewLinkWithNotes & { source: string };
    const addLink = (link: LinkWithSource) => {
      const existing = linksBySource.get(link.source) as
        | LinkWithSource
        | undefined;
      if (!existing) {
        linksBySource.set(link.source, link);
        return;
      }
      // Merge occurrences and notes. Prefer the fuller entry (master)
      // when only one side carries the series-level fields (schedules,
      // title, ...).
      existing.scheduleOccurrences = [
        ...(existing.scheduleOccurrences || []),
        ...(link.scheduleOccurrences || []),
      ];
      if (link.notes?.length) {
        existing.notes = [...(existing.notes || []), ...link.notes];
      }
      if (link.schedules && !existing.schedules) {
        existing.schedules = link.schedules;
        existing.title = link.title ?? existing.title;
        existing.type = link.type ?? existing.type;
        existing.status = link.status ?? existing.status;
        existing.actions = link.actions ?? existing.actions;
        existing.sourceUrl = link.sourceUrl ?? existing.sourceUrl;
        existing.preview = link.preview ?? existing.preview;
        existing.access = link.access ?? existing.access;
        existing.accessContacts =
          link.accessContacts ?? existing.accessContacts;
        existing.author = link.author ?? existing.author;
        existing.created = link.created ?? existing.created;
        existing.meta = { ...(existing.meta || {}), ...(link.meta || {}) };
        if (link.unread !== undefined) existing.unread = link.unread;
        if (link.archived !== undefined) existing.archived = link.archived;
      }
    };

    for (const caldavEvent of events) {
      try {
        const icsEvents = parseICSEvents(caldavEvent.icsData);

        for (const icsEvent of icsEvents) {
          // Record href→uid mapping. Apple ICS UID is stable per event
          // (RECURRENCE-ID overrides share the master's uid) so writing
          // it once per href is sufficient.
          if (icsEvent.uid && uidMap[caldavEvent.href] !== icsEvent.uid) {
            uidMap[caldavEvent.href] = icsEvent.uid;
            uidMapDirty = true;
          }

          if (icsEvent.recurrenceId) {
            const instanceLink = await this.prepareEventInstance(
              icsEvent,
              calendarHref,
              initialSync
            );
            if (instanceLink) {
              addLink(instanceLink as LinkWithSource);
              if (icsEvent.uid && !titledUids[icsEvent.uid]) {
                titledUids[icsEvent.uid] = true;
                titledUidsDirty = true;
              }
            }
          } else {
            const masterLink = await this.prepareEvent(
              icsEvent,
              calendarHref,
              initialSync,
              caldavEvent.href
            );
            if (masterLink) {
              addLink(masterLink as LinkWithSource);
              if (icsEvent.uid && !titledUids[icsEvent.uid]) {
                titledUids[icsEvent.uid] = true;
                titledUidsDirty = true;
              }
            }
          }
        }

        // Record etag only after the per-event work succeeds so a parse
        // failure can't leave an etag without a uid (which would later
        // surface as a `missingUid` skip on deletion).
        if (etagMap[caldavEvent.href] !== caldavEvent.etag) {
          etagMap[caldavEvent.href] = caldavEvent.etag;
          etagMapDirty = true;
        }
      } catch (error) {
        console.error(
          `Error processing CalDAV event ${caldavEvent.href}:`,
          error
        );
      }
    }

    // Drain pending_occ buffers for any masters present in this batch.
    // Done here (after the events loop) instead of inline at master-
    // processing time so the merge is order-independent within a batch:
    // instances arriving before the master are caught (the original
    // case), and instances arriving after the master are caught too
    // (the case inline draining would miss, silently losing
    // cancellations whose master happened to come first in the
    // CalDAV response).
    let drainedTotal = 0;
    for (const [source, link] of linksBySource.entries()) {
      // Keys are scoped per calendar so concurrent syncs of other
      // calendars in the same account aren't affected.
      const pendingPrefix = `pending_occ:${calendarHref}:${source}:`;
      const pendingKeys = await this.tools.store.list(pendingPrefix);
      if (pendingKeys.length === 0) continue;
      const merged: NewScheduleOccurrence[] = [
        ...(link.scheduleOccurrences || []),
      ];
      for (const key of pendingKeys) {
        const pending = await this.get<NewScheduleOccurrence>(key);
        if (pending) {
          merged.push(pending);
          drainedTotal += 1;
        }
        await this.clear(key);
      }
      link.scheduleOccurrences = merged;
    }
    if (initialSync && drainedTotal > 0) {
      console.log(
        `[AppleCalendar] drain: calendar=${calendarHref} ` +
          `masters=${linksBySource.size} drained=${drainedTotal}`
      );
    }

    // Record every master/regular event saved this batch so the full-pass
    // terminal cleanup in finishSync can distinguish legitimate cross-
    // batch leftovers (master-in-batch-A, instance-in-batch-B → flush is
    // correct, upserts onto the existing master link) from orphans whose
    // master never came through (master deleted upstream → flushing
    // would create a useless empty Untitled thread, so drop silently).
    //
    // Scoped with the calendar href so multi-calendar accounts don't
    // share the seen-master set — without scoping, Calendar A's orphan
    // flush would treat B's buffered occurrences as flushable.
    if (initialSync) {
      for (const source of linksBySource.keys()) {
        await this.set(`seen_master:${calendarHref}:${source}`, true);
      }
    }

    // Single batched save for the whole batch. Collapses what used to be
    // one saveLink RPC per event (and one per exception instance on heavy
    // recurring meetings) into a single cross-runtime call.
    const batch = Array.from(linksBySource.values());
    if (batch.length > 0) {
      await this.tools.integrations.saveLinks(batch);
    }

    if (uidMapDirty) {
      await this.set(`event_uids_${calendarHref}`, uidMap);
    }
    if (etagMapDirty) {
      await this.set(`etags_${calendarHref}`, etagMap);
    }
    if (titledUidsDirty) {
      await this.set(`titled_uids_${calendarHref}`, titledUids);
    }
  }

  /**
   * Transform a master/standalone ICS event into a {@link NewLinkWithNotes}
   * for the caller's batched saveLinks. Returns null when the event should
   * be skipped (e.g. already-cancelled events during initial sync). Never
   * saves directly.
   */
  private async prepareEvent(
    icsEvent: ICSEvent,
    calendarHref: string,
    initialSync: boolean,
    eventHref?: string
  ): Promise<NewLinkWithNotes | null> {
    const source = `apple-calendar:${icsEvent.uid}`;
    const isCancelled = icsEvent.status === "CANCELLED";

    // Consume any `cancel-email:<uid>` marker the mail sync recorded when it
    // bundled a real METHOD:CANCEL invite email onto this event's thread via
    // the shared `icaluid:<uid>` alias (see `detectCalendarBundles` in
    // `src/mail/sync.ts`). Read (and clear) it here — before the
    // initial-sync skip just below — so the one-shot marker is spent
    // whenever we observe the cancellation at all, including the
    // initial-sync case where no cancellation link/note is even produced.
    // Namespaced with `mail:` because `buildMailHost()` prefixes every
    // mail-side key with that prefix when writing through `host.set()` — a
    // bare `cancel-email:` key here would never match what mail wrote. A
    // leftover, never-consumed marker (e.g. the event was removed from
    // CalDAV outright rather than left CANCELLED, so this method never runs
    // for it) is swept by `onMailChannelDisabled`'s `mail:cancel-email:`
    // sweep as a backstop.
    const cancelEmailMarkerKey = `mail:cancel-email:${icsEvent.uid}`;
    const cancelEmailMarker = isCancelled
      ? await this.get<{ at: string }>(cancelEmailMarkerKey)
      : null;
    if (cancelEmailMarker) {
      await this.clear(cancelEmailMarkerKey);
    }

    // On initial sync, skip cancelled events
    if (initialSync && isCancelled) return null;

    // Parse start/end
    const start = parseICSDateTime(icsEvent.dtstart);
    const end = icsEvent.dtend ? parseICSDateTime(icsEvent.dtend) : null;

    // Author from organizer
    const authorContact: NewContact | undefined = icsEvent.organizer
      ? {
          email: icsEvent.organizer.email,
          name: icsEvent.organizer.name ?? undefined,
        }
      : undefined;

    // Handle cancelled events
    if (isCancelled) {
      // Drop the cancellation when the event has already ended — a past event's
      // cancellation is just noise (and would flip the thread unread for a
      // meeting that already happened). Incremental only: initial-sync
      // cancellations already returned above.
      if (cancellationIsForPastEventFn(start, end)) {
        return null;
      }

      // Prefer the cancellation email's own wording (the organizer's actual
      // message, already on this thread via mail/calendar bundling) over our
      // generic note when `cancelEmailMarker` says the mail sync already put
      // it there — avoids a redundant, lower-fidelity note on the same
      // thread. The structural cancellation below (status/schedule/unread)
      // always applies regardless of this signal.
      const cancelNote = {
        key: "cancellation" as const,
        content: icsEvent.organizer?.name
          ? `${icsEvent.organizer.name} cancelled this event.`
          : "This event was cancelled.",
        contentType: "text" as const,
        // Apple ICS LAST-MODIFIED on a CANCELLED VEVENT is when the event
        // was cancelled (per RFC 5545); it doesn't drift on later edits
        // because cancelled events aren't edited further. Safe to use as
        // the note `created`.
        created: icsEvent.lastModified
          ? parseICSDateTimeToDate(icsEvent.lastModified)
          : new Date(),
      };

      return {
        source,
        sources: buildEventSources(icsEvent.uid),
        type: "event",
        title: icsEvent.summary ?? undefined,
        status: "Cancelled",
        preview: "Cancelled",
        channelId: calendarHref,
        meta: {
          uid: icsEvent.uid,
          eventHref: eventHref || null,
          syncProvider: "apple",
          syncableId: calendarHref,
        },
        notes: cancelEmailMarker ? [] : [cancelNote],
        schedules: [
          {
            start: start instanceof Date ? start : new Date(),
            archived: true,
          },
        ],
        ...(initialSync ? { unread: false } : {}),
        ...(initialSync ? { archived: false } : {}),
      };
    }

    // Build schedule
    const schedule: Omit<NewSchedule, "threadId"> = {
      start,
      end: end ?? null,
    };

    // Handle recurrence for master events
    if (icsEvent.rrule) {
      schedule.recurrenceRule = icsEvent.rrule;

      const recurrenceCount = parseRRuleCount(icsEvent.rrule);
      if (recurrenceCount) {
        schedule.recurrenceCount = recurrenceCount;
      } else {
        const recurrenceUntil = parseRRuleEnd(icsEvent.rrule);
        if (recurrenceUntil) {
          schedule.recurrenceUntil = recurrenceUntil;
        }
      }

      if (icsEvent.exdates.length > 0) {
        schedule.recurrenceExdates = icsEvent.exdates;
      }
    }

    // Build schedule occurrences from RDATEs
    let scheduleOccurrences: NewScheduleOccurrence[] | undefined;
    if (icsEvent.rdates.length > 0) {
      scheduleOccurrences = icsEvent.rdates.map((rdate) => ({
        occurrence: rdate,
        start: rdate,
      }));
    }

    // Build attendee contacts on the base schedule so client-generated
    // recurring occurrences inherit attendee data (needed for RSVP buttons).
    // Per-occurrence overrides with their own contacts take precedence.
    const validAttendees = icsEvent.attendees.filter((a) => a.email);
    let scheduleContacts: NewScheduleContact[] | undefined;
    if (validAttendees.length > 0) {
      scheduleContacts = validAttendees.map((att) => ({
        contact: { email: att.email, name: att.name ?? undefined },
        status:
          att.partstat === "ACCEPTED"
            ? ("attend" as const)
            : att.partstat === "DECLINED"
            ? ("skip" as const)
            : null,
        role:
          att.role === "CHAIR"
            ? ("organizer" as const)
            : att.role === "OPT-PARTICIPANT"
            ? ("optional" as const)
            : ("required" as const),
      }));
      schedule.contacts = scheduleContacts;
    }

    // Build actions (conferencing links from description/location)
    const actions: Action[] = [];
    const seenUrls = new Set<string>();

    if (icsEvent.location) {
      extractConferencingUrls(icsEvent.location, actions, seenUrls);
    }
    if (icsEvent.description) {
      extractConferencingUrls(icsEvent.description, actions, seenUrls);
    }
    if (icsEvent.url) {
      actions.push({
        type: ActionType.external,
        title: "Open Link",
        url: icsEvent.url,
      });
    }

    // Build description note. The key embeds a hash of the description
    // content so each distinct version produces a separate note:
    // re-syncing the same description is an idempotent no-op upsert
    // (same key + same content), while an edited description gets a new
    // key and a fresh note — preserving prior versions as history on
    // the thread. Apple ICS CREATED is per-spec stable across edits
    // (set once when the event is first created), so we can use it
    // directly as the note `created` without a firstSeenAt anchor
    // (unlike Outlook's lastModifiedDateTime, which drifts on any edit).
    const hasDescription =
      icsEvent.description && icsEvent.description.trim().length > 0;

    const attendeeMentions: NewContact[] = [];
    if (authorContact) attendeeMentions.push(authorContact);
    for (const att of validAttendees) {
      attendeeMentions.push({ email: att.email, name: att.name ?? undefined });
    }

    const descHash =
      hasDescription && icsEvent.description
        ? await hashContent(icsEvent.description)
        : null;
    const descriptionNote =
      hasDescription && descHash
        ? {
            key: `description-${descHash}`,
            content: icsEvent.description!,
            contentType: "text" as const,
            created: icsEvent.created
              ? parseICSDateTimeToDate(icsEvent.created)
              : undefined,
            ...(authorContact ? { author: authorContact } : {}),
          }
        : null;

    const notes = descriptionNote ? [descriptionNote] : [];

    return {
      source,
      sources: buildEventSources(icsEvent.uid),
      type: "event",
      title: icsEvent.summary || "",
      status:
        icsEvent.status === "CONFIRMED"
          ? "Confirmed"
          : icsEvent.status === "TENTATIVE"
          ? "Tentative"
          : "Confirmed",
      access: "private",
      accessContacts: attendeeMentions,
      created: icsEvent.created
        ? parseICSDateTimeToDate(icsEvent.created)
        : undefined,
      author: authorContact,
      channelId: calendarHref,
      meta: {
        uid: icsEvent.uid,
        eventHref: eventHref || null,
        syncProvider: "apple",
        syncableId: calendarHref,
        location: icsEvent.location || null,
      },
      sourceUrl: icsEvent.url ?? null,
      actions: actions.length > 0 ? actions : undefined,
      notes,
      preview: hasDescription ? icsEvent.description!.slice(0, 200) : null,
      schedules: [schedule],
      scheduleOccurrences,
      ...(initialSync ? { unread: false } : {}),
      ...(initialSync ? { archived: false } : {}),
    };
  }

  /**
   * Transform a recurring event instance (RECURRENCE-ID) into either an
   * occurrence-only {@link NewLinkWithNotes} (for the caller's batched
   * saveLinks), or `null` when the occurrence is instead buffered to
   * `pending_occ:` storage for cross-batch merging during initial sync.
   * Never saves directly.
   */
  private async prepareEventInstance(
    icsEvent: ICSEvent,
    calendarHref: string,
    initialSync: boolean
  ): Promise<NewLinkWithNotes | null> {
    if (!icsEvent.recurrenceId) return null;

    const originalStart = parseICSDateTime(icsEvent.recurrenceId);
    const masterSource = `apple-calendar:${icsEvent.uid}`;

    // Handle cancelled instances
    if (icsEvent.status === "CANCELLED") {
      const start = parseICSDateTime(icsEvent.dtstart);
      const end = icsEvent.dtend ? parseICSDateTime(icsEvent.dtend) : null;

      const cancelledOccurrence: NewScheduleOccurrence = {
        occurrence:
          originalStart instanceof Date
            ? originalStart
            : new Date(originalStart),
        start: start instanceof Date ? start : new Date(start),
        end: end,
        cancelled: true,
        // Same initial-sync rule the non-cancelled branch below follows: a
        // historical backfill must land already-read so importing a calendar
        // can't spray notifications for occurrences that were cancelled long
        // ago. Omitted on incremental so a genuine cancellation still surfaces.
        ...(initialSync ? { unread: false } : {}),
      };

      // During initial sync, buffer the occurrence under a unique key for
      // later merging with its master. Per-occurrence keys keep each write
      // O(1); appending to a single shared list was O(N²) across batches
      // and blew the CF worker CPU limit on calendars with many recurring
      // exceptions.
      //
      // The key is scoped with the calendar href so multi-calendar accounts
      // (e.g. iCloud Home + Work + Family) don't share `pending_occ:`
      // namespace. UIDs are globally unique per iCal spec, but they are
      // shared across one user's calendars whenever a meeting was filed
      // on more than one, so an un-scoped key would cause Calendar A's
      // orphan flush to misclassify B's buffered occurrences and silently
      // drop them.
      if (initialSync) {
        const occurrenceTs =
          originalStart instanceof Date
            ? originalStart.toISOString()
            : new Date(originalStart).toISOString();
        const pendingKey = `pending_occ:${calendarHref}:${masterSource}:${occurrenceTs}`;
        await this.set(pendingKey, cancelledOccurrence);
        return null;
      }

      // Drop the cancellation when the occurrence has already ended — bumping
      // the master thread for a past occurrence's cancellation is just noise.
      if (cancellationIsForPastEventFn(start, end)) {
        return null;
      }

      return {
        type: "event",
        title: undefined,
        source: masterSource,
        sources: buildEventSources(icsEvent.uid),
        channelId: calendarHref,
        meta: { syncProvider: "apple", syncableId: calendarHref },
        scheduleOccurrences: [cancelledOccurrence],
        notes: [],
      };
    }

    // Build contacts from attendees for this occurrence
    const validAttendees = icsEvent.attendees.filter((a) => a.email);
    const contacts: NewScheduleContact[] | undefined =
      validAttendees.length > 0
        ? validAttendees.map((att) => ({
            contact: { email: att.email, name: att.name ?? undefined },
            status:
              att.partstat === "ACCEPTED"
                ? ("attend" as const)
                : att.partstat === "DECLINED"
                ? ("skip" as const)
                : null,
            role:
              att.role === "CHAIR"
                ? ("organizer" as const)
                : att.role === "OPT-PARTICIPANT"
                ? ("optional" as const)
                : ("required" as const),
          }))
        : undefined;

    const instanceStart = parseICSDateTime(icsEvent.dtstart);
    const instanceEnd = icsEvent.dtend
      ? parseICSDateTime(icsEvent.dtend)
      : null;

    const occurrence: NewScheduleOccurrence = {
      occurrence:
        originalStart instanceof Date ? originalStart : new Date(originalStart),
      start: instanceStart,
      contacts,
      ...(initialSync ? { unread: false } : {}),
    };

    if (instanceEnd !== undefined && instanceEnd !== null) {
      occurrence.end = instanceEnd;
    }

    // During initial sync, buffer under a unique key for merging with
    // master. See the cancelled branch above for why per-occurrence keys
    // replaced the single-list-append pattern, and why the key is
    // prefixed with the calendar href.
    if (initialSync) {
      const occurrenceTs =
        originalStart instanceof Date
          ? originalStart.toISOString()
          : new Date(originalStart).toISOString();
      const pendingKey = `pending_occ:${calendarHref}:${masterSource}:${occurrenceTs}`;
      await this.set(pendingKey, occurrence);
      return null;
    }

    // Incremental sync: return an occurrence-only link. The caller merges
    // it with the master (if the master is in the same batch) or saves it
    // standalone (master already exists in the DB from a prior sync).
    return {
      type: "event",
      title: undefined,
      source: masterSource,
      sources: buildEventSources(icsEvent.uid),
      channelId: calendarHref,
      meta: { syncProvider: "apple", syncableId: calendarHref },
      scheduleOccurrences: [occurrence],
      notes: [],
    };
  }

  // ---- RSVP Write-Back ----

  /**
   * Called when a user changes their RSVP status in Plot.
   * Updates the ATTENDEE PARTSTAT in the CalDAV event via PUT.
   */
  async onScheduleContactUpdated(
    thread: Thread,
    _scheduleId: string,
    _contactId: ActorId,
    status: ScheduleContactStatus | null,
    _actor: Actor
  ): Promise<void> {
    const meta = thread.meta as Record<string, unknown> | null;
    const linkSource = meta?.linkSource as string | null;
    const calendarHref = meta?.syncableId as string | null;
    const eventHref = meta?.eventHref as string | null;

    if (!linkSource || !calendarHref || !eventHref) return;

    // The connector user's email is the Apple ID
    const appleId = this.tools.options.appleId as string;
    if (!appleId) return;

    // Map Plot status to CalDAV PARTSTAT
    const partstat =
      status === "attend"
        ? "ACCEPTED"
        : status === "skip"
        ? "DECLINED"
        : "NEEDS-ACTION";

    try {
      await this.updateRSVP(calendarHref, eventHref, appleId, partstat);
    } catch (error) {
      console.error("[RSVP Sync] Failed to sync RSVP to Apple Calendar", {
        eventHref,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  /**
   * Update RSVP status for the connector user on a CalDAV event.
   * Fetches the event ICS, modifies the ATTENDEE PARTSTAT, and PUTs it back
   * with `If-Match` set to the etag it just read, so a change that landed on
   * the server between the GET and the PUT (another RSVP write, a sync
   * pass, an organizer edit) is detected instead of silently clobbered.
   *
   * On a `412` (the race was lost), re-reads the now-current ICS + etag,
   * re-applies the PARTSTAT patch to that fresh copy, and retries the PUT
   * exactly once — an expected, self-resolving condition, not a bug. If the
   * retry also loses the race, this throws and lets the caller
   * (`onScheduleContactUpdated`) log it via its existing catch, same as any
   * other write failure.
   */
  private async updateRSVP(
    _calendarHref: string,
    eventHref: string,
    email: string,
    partstat: string
  ): Promise<void> {
    const client = this.getCalDAV();

    const fetched = await client.fetchEventICS(eventHref);
    if (!fetched) {
      throw new Error(`Event not found: ${eventHref}`);
    }

    const updatedICS = updateAttendeePartstat(fetched.icsData, email, partstat);
    if (!updatedICS) {
      console.warn(
        `[RSVP Sync] User ${email} is not an attendee of event ${eventHref}`
      );
      return;
    }

    try {
      const success = await client.updateEventICS(
        eventHref,
        updatedICS,
        fetched.etag ?? undefined
      );
      if (!success) {
        throw new Error(`Failed to update event: ${eventHref}`);
      }
    } catch (error) {
      if (!(error instanceof PreconditionFailedError)) throw error;

      console.warn(
        `[RSVP Sync] Lost a concurrent-write race on ${eventHref} (412); ` +
          `re-reading and retrying once`
      );

      const retryFetched = await client.fetchEventICS(eventHref);
      if (!retryFetched) {
        throw new Error(`Event not found on retry: ${eventHref}`);
      }
      const retryICS = updateAttendeePartstat(
        retryFetched.icsData,
        email,
        partstat
      );
      if (!retryICS) {
        console.warn(
          `[RSVP Sync] User ${email} is not an attendee of event ` +
            `${eventHref} (retry)`
        );
        return;
      }
      const retrySuccess = await client.updateEventICS(
        eventHref,
        retryICS,
        retryFetched.etag ?? undefined
      );
      if (!retrySuccess) {
        throw new Error(`Failed to update event after retry: ${eventHref}`);
      }
    }
  }
}

// ---- Helpers ----

/**
 * Parse a raw ICS datetime string to a Date (for created/lastModified fields).
 */
function parseICSDateTimeToDate(value: string): Date {
  const d = value.trim();
  if (/^\d{8}T\d{6}Z?$/.test(d)) {
    const year = d.slice(0, 4);
    const month = d.slice(4, 6);
    const day = d.slice(6, 8);
    const hour = d.slice(9, 11);
    const minute = d.slice(11, 13);
    const second = d.slice(13, 15);
    return new Date(`${year}-${month}-${day}T${hour}:${minute}:${second}Z`);
  }
  return new Date(d);
}

/**
 * Detect conferencing provider from a URL.
 */
function detectConferencingProvider(url: string): ConferencingProvider | null {
  const lowerUrl = url.toLowerCase();

  if (lowerUrl.includes("zoom.us")) return ConferencingProvider.zoom;
  if (
    lowerUrl.includes("teams.microsoft.com") ||
    lowerUrl.includes("teams.live.com")
  )
    return ConferencingProvider.microsoftTeams;
  if (lowerUrl.includes("webex.com")) return ConferencingProvider.webex;
  if (lowerUrl.includes("meet.google.com"))
    return ConferencingProvider.googleMeet;

  return null;
}

/**
 * Extract conferencing URLs from text and add to actions array.
 */
function extractConferencingUrls(
  text: string,
  actions: Action[],
  seenUrls: Set<string>
): void {
  const urlRegex = /https?:\/\/[^\s<>"{}|\\^`\[\]]+/gi;
  const matches = text.match(urlRegex);
  if (!matches) return;

  for (const url of matches) {
    const provider = detectConferencingProvider(url);
    if (provider && !seenUrls.has(url)) {
      seenUrls.add(url);
      actions.push({
        type: ActionType.conferencing,
        url,
        provider,
      });
    }
  }
}

export default Apple;
