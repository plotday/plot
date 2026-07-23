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
  /** Same as `lastModSeq`, but for the Sent mailbox (independent cursor). */
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
}
