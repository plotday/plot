import type { Files } from "@plotday/twister/tools/files";
import type { Imap } from "@plotday/twister/tools/imap";
import type { Integrations } from "@plotday/twister/tools/integrations";
import type { Smtp } from "@plotday/twister/tools/smtp";

/**
 * Per-mailbox cursor inside the connection-level `MailSyncState`. The
 * PRESENCE of a cursor is what marks a mailbox as "already backfilled": a
 * mailbox with no entry is read from the history floor on the next pass and
 * contributes no new-message signal (see `mailSync` in `sync.ts`).
 */
export type MailboxCursor = {
  /** UIDVALIDITY the rest of this cursor is valid for. */
  uidValidity: number;
  /**
   * Highest UID processed so far in this mailbox. Unused for the Sent entry
   * (Sent is rescanned by date window only and never contributes new-message
   * signal — an owner's own reply must not mark their thread unread), stored
   * as 0 there.
   */
  lastUid: number;
  /** ISO floor this mailbox was first backfilled from. */
  syncHistoryMin?: string;
  /**
   * This mailbox's HIGHESTMODSEQ (RFC 7162 CONDSTORE) as of the last
   * successful pass. Absent when the server doesn't advertise CONDSTORE —
   * either way, its absence means "assume changed", forcing a rescan on the
   * next pass rather than a false "unchanged".
   */
  lastModSeq?: number;
};

/**
 * Connection-level mail sync state — ONE store key (`mail:state`) for the
 * whole connection, not one per channel.
 *
 * A mail thread's link `source` is derived from its root Message-ID, which is
 * mailbox-independent, so two enabled folders holding messages of the same
 * conversation address the SAME Plot thread. Per-channel cursors made each
 * folder run its own pass and rebuild that thread from only its own messages,
 * so title/unread/channel flip-flopped on every poll. One cursor document per
 * connection is what lets a single merged pass read every enabled mailbox
 * plus Sent and rebuild each thread from its complete visible message set.
 */
export type MailSyncState = {
  /** Schema version. 2 = merged connection-level pass. */
  version: 2;
  /** Cursors keyed by RAW IMAP mailbox name (every enabled folder AND Sent). */
  boxes: Record<string, MailboxCursor>;
  /** Widest history floor granted so far (ISO). Never narrows. */
  syncHistoryMin?: string;
  /**
   * Set when a channel was disabled while others remained enabled. Makes the
   * NEXT pass search every already-backfilled mailbox from `syncHistoryMin`
   * instead of the 30-day recent window, so threads that were archived by the
   * disable but still live in another enabled folder are re-homed and
   * re-upserted. Cleared by that pass.
   */
  pendingFullRescan?: boolean;
};

/**
 * Everything the pure mail-sync functions need from the connector. The
 * connector constructs this, namespacing all storage keys with "mail:" and
 * exposing the built-in tools it declared.
 */
export interface MailHost {
  imap: Imap;
  smtp: Smtp;
  integrations: Integrations;
  files: Files;
  appleId: string;
  appPassword: string;
  set<T>(key: string, value: T): Promise<void>;
  get<T>(key: string): Promise<T | undefined>;
  clear(key: string): Promise<void>;
  channelSyncCompleted(channelId: string): Promise<void>;
  /**
   * Enqueue `id` (`${"read"|"todo"}:${rootId}`) on the durable write-back
   * retry drain. Called when an IMAP flag write-back fails transiently —
   * the connector re-applies it from `mailWritebackDrain` once the drain
   * fires. See `setThreadFlag` in `write.ts`.
   */
  queueWritebackDrain(id: string): Promise<void>;
  /**
   * The set of iCalUIDs the calendar product has actually saved a TITLED
   * link for, across every currently-enabled calendar (backed by
   * `titled_uids_<calendarHref>` in `apple.ts` — deliberately NOT the
   * broader `event_uids_<calendarHref>`, which also includes hrefs CalDAV
   * returned but the calendar side skipped, e.g. a cancelled-during-
   * initial-sync event with no link ever created — see the doc on
   * `processCalDAVEvents` in apple.ts). The mail host's storage keys are
   * namespaced with "mail:" (see `buildMailHost` in apple.ts), so mail-side
   * code has no direct way to read the calendar side's unprefixed keys —
   * this is the wired-through lookup. Used by `detectCalendarBundles`
   * (`sync.ts`) to decide whether a bundled mail link should set `title`
   * from the email subject (no titled event yet) or omit it (the synced
   * calendar event owns it) — see `CalendarBundle`'s `eventKnown` doc in
   * `calendar-bundle.ts`.
   *
   * Does real work (a store list plus one read per enabled calendar) —
   * callers must resolve it at most once per sync pass, never per message.
   */
  knownEventUids(): Promise<Set<string>>;
}
