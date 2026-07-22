import type { Imap } from "@plotday/twister/tools/imap";
import type { Integrations } from "@plotday/twister/tools/integrations";

/** Persisted per-channel cursor for incremental IMAP sync. */
export type MailSyncState = {
  /** UIDVALIDITY of the mailbox the cursor is valid for. */
  uidValidity: number;
  /** Highest UID processed so far. */
  lastUid: number;
  /** ISO date floor for the initial backfill (plan-based). */
  syncHistoryMin?: string;
};

/**
 * Everything the pure mail-sync functions need from the connector. The
 * connector constructs this, namespacing all storage keys with "mail:" and
 * exposing the built-in tools it declared.
 */
export interface MailHost {
  imap: Imap;
  integrations: Integrations;
  appleId: string;
  appPassword: string;
  set<T>(key: string, value: T): Promise<void>;
  get<T>(key: string): Promise<T | undefined>;
  clear(key: string): Promise<void>;
  channelSyncCompleted(channelId: string): Promise<void>;
}
