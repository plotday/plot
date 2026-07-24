import type { Files } from "@plotday/twister/tools/files";
import type { Imap } from "@plotday/twister/tools/imap";
import type { Integrations } from "@plotday/twister/tools/integrations";
import type { Smtp } from "@plotday/twister/tools/smtp";

/** Persisted per-channel cursor for incremental IMAP sync. */
export type MailSyncState = {
  /** UIDVALIDITY of the mailbox the cursor is valid for. */
  uidValidity: number;
  /** Highest UID processed so far. */
  lastUid: number;
  /** ISO date floor for the initial backfill (plan-based). */
  syncHistoryMin?: string;
  /**
   * INBOX's HIGHESTMODSEQ (RFC 7162 CONDSTORE) as of the last successful
   * poll. Absent when the server doesn't advertise CONDSTORE, or for state
   * written before this cursor existed — either way, its absence forces a
   * full rescan on the next incremental pass rather than a false "unchanged".
   */
  lastModSeq?: number;
  /**
   * Same as `lastModSeq`, but for the Sent mailbox. The two cursors are
   * stored per-mailbox, but `mailIncrementalSync` combines them into a single
   * rescan decision — a change in EITHER mailbox rescans BOTH — so a thread is
   * never rebuilt from a partial message set (e.g. a Sent-only reply must not
   * re-title an INBOX-rooted thread). Do not gate the two independently.
   */
  sentLastModSeq?: number;
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
