import type { NewLinkWithNotes } from "@plotday/twister";

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
    const since = resolveSinceFloor(syncHistoryMin);

    const status = await host.imap.selectMailbox(session, rawMailbox);
    const inboxUids = await host.imap.search(session, { since });
    const inbox = await fetchUidRange(host, session, rawMailbox, inboxUids);
    const inboxLinks = transformMessages(inbox, {
      channelId,
      appleId: host.appleId,
      fromSent: false,
      initialSync: true,
    });

    let sentLinks: NewLinkWithNotes[] = [];
    const sentBox = await resolveSentMailbox(host, session);
    if (sentBox) {
      await host.imap.selectMailbox(session, sentBox);
      const sentUids = await host.imap.search(session, { since });
      const sent = await fetchUidRange(host, session, sentBox, sentUids);
      sentLinks = transformMessages(sent, {
        channelId,
        appleId: host.appleId,
        fromSent: true,
        initialSync: true,
      });
    }

    const links = [...inboxLinks, ...sentLinks];
    if (links.length > 0) await host.integrations.saveLinks(links);

    const lastUid = inboxUids.length > 0 ? Math.max(...inboxUids) : 0;
    const state: MailSyncState = {
      uidValidity: status.uidValidity,
      lastUid,
      syncHistoryMin: since.toISOString(),
    };
    await host.set(`state_${channelId}`, state);

    await host.channelSyncCompleted(channelId);
  } finally {
    await host.imap.disconnect(session);
  }
}

/**
 * Incremental sync: new INBOX mail since the stored cursor, a recent-window
 * rescan to pick up `\Seen` flag changes, and a recent-window rescan of Sent
 * for new owner replies (Sent has no separate cursor — the recent rescan
 * plus idempotent upsert by `source`/note key is intentional). Re-baselines
 * via `mailInitialSync` when UIDVALIDITY has changed or no cursor exists yet.
 */
export async function mailIncrementalSync(host: MailHost, channelId: string): Promise<void> {
  const session = await connectIcloud(host);
  try {
    const status = await host.imap.selectMailbox(session, "INBOX");
    const state = await host.get<MailSyncState>(`state_${channelId}`);

    if (!state) {
      // No cursor yet (first poll before an initial sync ever completed) —
      // run a full initial sync instead of guessing a delta.
      await mailInitialSync(host, "INBOX", channelId, undefined);
      return;
    }

    if (status.uidValidity !== state.uidValidity) {
      // UIDVALIDITY changed (mailbox recreated/reindexed server-side) — old
      // UIDs are no longer meaningful. Re-baseline from the previously
      // stored history floor.
      await mailInitialSync(host, "INBOX", channelId, state.syncHistoryMin);
      return;
    }

    // New mail since the stored cursor.
    const upperUid = status.uidNext - 1;
    let newUids: number[] = [];
    if (upperUid >= state.lastUid + 1) {
      const range: number[] = [];
      for (let uid = state.lastUid + 1; uid <= upperUid; uid++) range.push(uid);
      newUids = await host.imap.search(session, { uid: range });
    }

    // Recent-window rescan to catch \Seen flag changes on already-synced mail.
    const recentSince = new Date(Date.now() - RECENT_WINDOW_MS);
    const recentUids = await host.imap.search(session, { since: recentSince });

    const inboxUids = Array.from(new Set([...newUids, ...recentUids]));
    const inbox = await fetchUidRange(host, session, "INBOX", inboxUids);
    const inboxLinks = transformMessages(inbox, {
      channelId,
      appleId: host.appleId,
      fromSent: false,
      initialSync: false,
    });

    let sentLinks: NewLinkWithNotes[] = [];
    const sentBox = await resolveSentMailbox(host, session);
    if (sentBox) {
      await host.imap.selectMailbox(session, sentBox);
      const sentUids = await host.imap.search(session, { since: recentSince });
      const sent = await fetchUidRange(host, session, sentBox, sentUids);
      sentLinks = transformMessages(sent, {
        channelId,
        appleId: host.appleId,
        fromSent: true,
        initialSync: false,
      });
    }

    const links = [...inboxLinks, ...sentLinks];
    if (links.length > 0) await host.integrations.saveLinks(links);

    const newMaxUid = inboxUids.length > 0 ? Math.max(...inboxUids) : 0;
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
