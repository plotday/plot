import type { ImapMessage, ImapSession } from "@plotday/twister/tools/imap";

import { connectIcloud, fetchUidRange, resolveSentMailbox } from "./imap-fetch";
import type { MailHost, MailSyncState } from "./mail-host";
import { transformMessages } from "./transform";

const DEFAULT_HISTORY_MS = 7 * 24 * 60 * 60 * 1000; // 7 days
const RECENT_WINDOW_MS = 30 * 24 * 60 * 60 * 1000; // 30 days

/**
 * Resolve the initial-sync history floor. Uses `syncHistoryMin` when it
 * parses to a valid date; otherwise defaults to 7 days ago. Guards against
 * `mailIncrementalSync`'s re-baseline path, where the stored
 * `state.syncHistoryMin` may be absent (older/first-poll state).
 */
function resolveSinceFloor(syncHistoryMin: string | undefined): Date {
  if (syncHistoryMin) {
    const parsed = new Date(syncHistoryMin);
    if (!Number.isNaN(parsed.getTime())) return parsed;
  }
  return new Date(Date.now() - DEFAULT_HISTORY_MS);
}

/**
 * Full backfill of INBOX plus the Sent mailbox (for the owner's own
 * in-thread replies) since a history floor, using an already-open IMAP
 * `session`. Persists a `MailSyncState` cursor for subsequent incremental
 * syncs and signals `channelSyncCompleted` once the backfill is saved.
 *
 * Shared by `mailInitialSync` (which opens its own session) and
 * `mailIncrementalSync`'s re-baseline paths (which reuse their already-open
 * session) so at most one IMAP session to the account is ever open at once —
 * iCloud enforces a per-account connection cap.
 */
async function runInitialBackfill(
  host: MailHost,
  session: ImapSession,
  channelId: string,
  syncHistoryMin: string | undefined | null
): Promise<void> {
  const since = resolveSinceFloor(syncHistoryMin ?? undefined);

  const status = await host.imap.selectMailbox(session, "INBOX");
  const inboxUids = await host.imap.search(session, { since });
  const inbox = await fetchUidRange(host, session, "INBOX", inboxUids);

  let sent: ImapMessage[] = [];
  const sentBox = await resolveSentMailbox(host, session);
  if (sentBox) {
    await host.imap.selectMailbox(session, sentBox);
    const sentUids = await host.imap.search(session, { since });
    sent = await fetchUidRange(host, session, sentBox, sentUids);
  }

  const links = transformMessages([...inbox, ...sent], {
    channelId,
    appleId: host.appleId,
    initialSync: true,
  });
  if (links.length > 0) await host.integrations.saveLinks(links);

  const lastUid = inboxUids.reduce((m, u) => (u > m ? u : m), 0);
  const state: MailSyncState = {
    uidValidity: status.uidValidity,
    lastUid,
    syncHistoryMin: since.toISOString(),
  };
  await host.set(`state_${channelId}`, state);

  await host.channelSyncCompleted(channelId);
}

/**
 * Full backfill of `rawMailbox` (INBOX) plus the Sent mailbox (for the
 * owner's own in-thread replies) since a history floor. Persists a
 * `MailSyncState` cursor for subsequent incremental syncs and signals
 * `channelSyncCompleted` once the backfill is saved.
 */
export async function mailInitialSync(
  host: MailHost,
  rawMailbox: string,
  channelId: string,
  syncHistoryMin: string | undefined
): Promise<void> {
  const session = await connectIcloud(host);
  try {
    await runInitialBackfill(host, session, channelId, syncHistoryMin);
  } finally {
    await host.imap.disconnect(session);
  }
}

/**
 * Incremental sync: new INBOX mail since the stored cursor, a recent-window
 * rescan to pick up `\Seen` flag changes, and a recent-window rescan of Sent
 * for new owner replies (Sent has no separate cursor — the recent rescan
 * plus idempotent upsert by `source`/note key is intentional). Re-baselines
 * (via the shared `runInitialBackfill`, reusing this sync's already-open
 * IMAP session) when UIDVALIDITY has changed or no cursor exists yet.
 */
export async function mailIncrementalSync(host: MailHost, channelId: string): Promise<void> {
  const session = await connectIcloud(host);
  try {
    const status = await host.imap.selectMailbox(session, "INBOX");
    const state = await host.get<MailSyncState>(`state_${channelId}`);

    if (!state) {
      // No cursor yet (first poll before an initial sync ever completed) —
      // run a full initial sync instead of guessing a delta. Reuse this
      // already-open session (not `mailInitialSync`, which would open a
      // second concurrent IMAP session to the same account).
      await runInitialBackfill(host, session, channelId, undefined);
      return;
    }

    if (status.uidValidity !== state.uidValidity) {
      // UIDVALIDITY changed (mailbox recreated/reindexed server-side) — old
      // UIDs are no longer meaningful. Re-baseline from the previously
      // stored history floor, reusing this already-open session.
      await runInitialBackfill(host, session, channelId, state.syncHistoryMin);
      return;
    }

    // New mail since the stored cursor, bounded by the plan floor so a
    // dormant account (stored lastUid: 0) can't fetch the entire mailbox.
    const floor = resolveSinceFloor(state.syncHistoryMin);
    const windowUids = await host.imap.search(session, { since: floor });
    const newUids = windowUids.filter((u) => u > state.lastUid);

    // Recent-window rescan to catch \Seen flag changes on already-synced
    // mail, also capped at the plan floor.
    const recentSince = new Date(Math.max(floor.getTime(), Date.now() - RECENT_WINDOW_MS));
    const recentUids = await host.imap.search(session, { since: recentSince });

    const inboxUids = Array.from(new Set([...newUids, ...recentUids]));
    const inbox = await fetchUidRange(host, session, "INBOX", inboxUids);

    let sent: ImapMessage[] = [];
    const sentBox = await resolveSentMailbox(host, session);
    if (sentBox) {
      await host.imap.selectMailbox(session, sentBox);
      const sentUids = await host.imap.search(session, { since: recentSince });
      sent = await fetchUidRange(host, session, sentBox, sentUids);
    }

    const links = transformMessages([...inbox, ...sent], {
      channelId,
      appleId: host.appleId,
      initialSync: false,
    });
    if (links.length > 0) await host.integrations.saveLinks(links);

    const newMaxUid = inboxUids.reduce((m, u) => (u > m ? u : m), 0);
    const nextState: MailSyncState = {
      uidValidity: status.uidValidity,
      lastUid: Math.max(newMaxUid, state.lastUid),
      syncHistoryMin: state.syncHistoryMin,
    };
    await host.set(`state_${channelId}`, nextState);
  } finally {
    await host.imap.disconnect(session);
  }
}
