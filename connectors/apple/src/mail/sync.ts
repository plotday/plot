import type { ActorId } from "@plotday/twister";
import type { ImapMailboxStatus, ImapMessage, ImapSession } from "@plotday/twister/tools/imap";

import {
  classifyICS,
  isCalendarAttachment,
  type CalendarBundle,
  type ClassifiedICS,
} from "./calendar-bundle";
import { connectIcloud, fetchUidRange, resolveSentMailbox } from "./imap-fetch";
import type { MailHost, MailSyncState } from "./mail-host";
import { mailSource, rootMessageId, transformMessages, type MailMessage } from "./transform";

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
 * Read-direction half of the to-do ↔ \Flagged loop (write direction is
 * `onThreadToDoFn` in write.ts). Groups `messages` by thread root
 * (`rootMessageId`), computes whether any message in the thread carries
 * `\Flagged`, and diffs that against the stored `flagged:<rootId>` marker:
 *
 *  - On `initialSync`, the marker is SEEDED from the current \Flagged state
 *    for every thread, but `setThreadToDo` is never called — a message
 *    flagged years before the connection ever existed must not spam a
 *    fresh to-do on first connect (mirrors the initial-sync unread
 *    discipline in `transformMessages`).
 *  - Otherwise (incremental), a state change since the marker propagates
 *    once via `integrations.setThreadToDo` and updates the marker. An
 *    unchanged state — including the write path's own just-set marker (see
 *    `onThreadToDoFn` in write.ts) — is a no-op. That "no-op on no change"
 *    is what breaks the echo loop: our own Plot→\Flagged write is
 *    indistinguishable here from "nothing changed since we last looked".
 *
 * Requires a stored `auth_actor_id` (set by `Apple.activate()` on connect)
 * to know who to attribute the to-do to. Older connections that predate
 * that override have no marker or actor id yet, so the whole reconciliation
 * is skipped cleanly — no crash, no marker writes — until a future
 * activate/reconnect (or re-baseline) seeds it.
 *
 * Ordering hazard (accepted, same class Gmail ships with): the write-back
 * queue's ~2s coalescing drain can complete its multi-round-trip IMAP
 * `setFlags` concurrently, in a different worker, with a read pass landing
 * here. A read pass that lands between the write path's marker-set and the
 * drain's flag write completing could read stale \Flagged and momentarily
 * propagate the OLD value back to Plot. Not locked against — bounded, and
 * self-corrects on the next poll.
 */
export async function reconcileTodoFlags(
  host: MailHost,
  messages: MailMessage[],
  initialSync: boolean
): Promise<void> {
  const actorId = await host.get<ActorId>("auth_actor_id");
  if (!actorId) return;

  const byRoot = new Map<string, MailMessage[]>();
  for (const m of messages) {
    const root = rootMessageId(m);
    if (!root) continue;
    const list = byRoot.get(root) ?? [];
    list.push(m);
    byRoot.set(root, list);
  }

  for (const [root, msgs] of byRoot.entries()) {
    const isFlagged = msgs.some((m) => m.flags.includes("\\Flagged"));

    if (initialSync) {
      await host.set(`flagged:${root}`, isFlagged);
      continue;
    }

    const wasFlagged = await host.get<boolean>(`flagged:${root}`);
    if (isFlagged !== !!wasFlagged) {
      await host.integrations.setThreadToDo(mailSource(root), actorId, isFlagged, {});
      await host.set(`flagged:${root}`, isFlagged);
    }
  }
}

/**
 * Persisted per-root calendar-bundle classification (see `detectCalendarBundles`'s
 * caching doc below). Wrapped in an object — never a bare `ClassifiedICS |
 * null` — because `MailHost.get`'s "mail:"-prefixed implementation
 * normalizes a stored `null` back to `undefined` (see `buildMailHost` in
 * apple.ts: `(value as T | null) ?? undefined`), which would make a
 * persisted "evaluated, doesn't bundle" decision indistinguishable from
 * "never evaluated" and defeat the whole point of caching it.
 */
type StoredBundleDecision = { classified: ClassifiedICS | null };

/**
 * Detects mail↔calendar thread bundling for a sync pass: groups `messages`
 * by thread root, and for each thread fetches + classifies (via
 * `classifyICS`) every `text/calendar`/`application/ics` attachment found —
 * across ALL of the thread's messages, not just the first, mirroring
 * Google's `classifyCalendarThread` (`google/src/mail/gmail-api.ts`), which
 * evaluates every ICS part in a Gmail thread and bundles on the first
 * CANCEL or REQUEST/SEQUENCE>0 hit. This is the I/O layer: `transform.ts`'s
 * `transformMessages` is pure and must not fetch, so this function does the
 * fetching (using the already-open `session`) and hands the pure
 * `classifyICS` decoded ICS text.
 *
 * Also records a `cancel-email:<uid>` marker (mirroring Google's
 * `mail/sync.ts`) for every CANCEL bundle, so a later calendar-side sync can
 * prefer the cancellation email's own note over its generic "This event was
 * cancelled." text.
 *
 * Most mail carries no calendar attachment at all, so this never issues
 * IMAP round-trips (a `selectMailbox` + `fetchAttachment` per calendar part
 * encountered) for a thread that doesn't have one — an empty `messages`
 * array, or messages with no calendar-mime attachments, does no IMAP I/O.
 * It DOES do one cheap store lookup (`host.get`) per thread root every
 * pass, unconditionally — see CACHING below for why that can't be skipped
 * for calendar-less threads either.
 *
 * CACHING: once a root's calendar-bearing message(s) have been classified,
 * the decision (bundle info, or explicitly "no bundle" for a bare
 * invite/RSVP) is persisted to `bundle:<rootId>` and reused on every later
 * pass instead of re-fetching. Two reasons this is required, not just an
 * optimization:
 *  - Cost: every poll otherwise re-fetches and re-classifies the same ICS
 *    attachment for every invite thread still inside the 30-day recent
 *    window — ~2 extra IMAP round-trips per thread, every 15 minutes,
 *    against a ~1000-request execution budget.
 *  - Correctness: the recent-window rescan only re-fetches messages dated
 *    within the last 30 days. Once the ICS-bearing message ages out of that
 *    window, a LATER pass's `messages` for this root may contain no
 *    calendar-bearing message at all (just an in-window reply) — the
 *    persisted decision must still apply, which is why the cache is
 *    consulted BEFORE checking whether this pass's message set has a
 *    calendar part, not gated behind it. Without this, re-classifying from
 *    scratch would find nothing and flip the thread back to "not bundled" —
 *    changing `sources`' sorted-minimum primary source (`"icaluid:…"` sorts
 *    before `"icloud-mail:thread:…"`) and creating a SECOND link row on
 *    `upsert_link`'s `(source, source_priority_root)` conflict target,
 *    since the old primary source is still on file. Persisting the decision
 *    once means the classification can never flip after the fact.
 *
 * `eventKnown` (see `CalendarBundle`'s doc) is resolved via
 * `host.knownEventUids()` at most once per call — lazily, only once a
 * bundle is actually found — never per message/thread.
 */
export async function detectCalendarBundles(
  host: MailHost,
  session: ImapSession,
  messages: MailMessage[]
): Promise<Map<string, CalendarBundle>> {
  const byRoot = new Map<string, MailMessage[]>();
  for (const m of messages) {
    const root = rootMessageId(m);
    if (!root) continue;
    const list = byRoot.get(root) ?? [];
    list.push(m);
    byRoot.set(root, list);
  }

  const bundles = new Map<string, CalendarBundle>();
  let knownUids: Set<string> | null = null;
  const resolveEventKnown = async (uid: string): Promise<boolean> => {
    if (knownUids === null) knownUids = await host.knownEventUids();
    return knownUids.has(uid);
  };

  for (const [root, msgs] of byRoot.entries()) {
    // Reuse an earlier pass's decision before doing anything else — see the
    // CACHING doc above for why this must not be gated behind "does THIS
    // pass have a calendar part" (the ICS-bearing message may have aged out
    // of the window while the thread itself is still active).
    const persisted = await host.get<StoredBundleDecision>(`bundle:${root}`);
    if (persisted) {
      if (persisted.classified) {
        bundles.set(root, {
          ...persisted.classified,
          eventKnown: await resolveEventKnown(persisted.classified.uid),
        });
      }
      continue;
    }

    // Not yet classified. Cheap in-memory check (no I/O) — only
    // calendar-bearing threads ever touch IMAP below, and only those get a
    // decision persisted (a thread with no calendar part yet is simply
    // re-checked next pass in case one arrives later).
    const calendarMsgs = msgs.filter((m) =>
      (m.attachments ?? []).some((a) => isCalendarAttachment(a.mimeType))
    );
    if (calendarMsgs.length === 0) continue;

    let classified: ClassifiedICS | null = null;
    for (const m of calendarMsgs) {
      const part = (m.attachments ?? []).find((a) => isCalendarAttachment(a.mimeType))!;

      await host.imap.selectMailbox(session, m.mailbox);
      const bytes = await host.imap.fetchAttachment(session, m.uid, part.partNumber);
      const ics = new TextDecoder("utf-8").decode(bytes);
      classified = classifyICS(ics);
      if (!classified) continue; // bare invite or RSVP — check the thread's other messages

      if (classified.kind === "cancel") {
        await host.set(`cancel-email:${classified.uid}`, { at: new Date().toISOString() });
      }
      break; // this thread is classified; stop scanning its remaining messages
    }

    // Persist the decision — including explicit "no bundle" — so this root
    // is never re-evaluated on a later pass (see the caching doc above).
    await host.set(`bundle:${root}`, { classified } satisfies StoredBundleDecision);

    if (classified) {
      bundles.set(root, { ...classified, eventKnown: await resolveEventKnown(classified.uid) });
    }
  }
  return bundles;
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
  let sentStatus: ImapMailboxStatus | undefined;
  const sentBox = await resolveSentMailbox(host, session);
  if (sentBox) {
    sentStatus = await host.imap.selectMailbox(session, sentBox);
    const sentUids = await host.imap.search(session, { since });
    sent = await fetchUidRange(host, session, sentBox, sentUids);
  }

  // Tag each message with its originating mailbox — UIDs are only unique
  // within a single mailbox, so this is required to build correct
  // attachment refs once INBOX and Sent are merged into one call. See
  // transform.ts's `MailMessage` doc.
  const merged: MailMessage[] = [
    ...inbox.map((m) => ({ ...m, mailbox: "INBOX" })),
    ...(sentBox ? sent.map((m) => ({ ...m, mailbox: sentBox })) : []),
  ];
  const calendarBundles = await detectCalendarBundles(host, session, merged);
  const links = transformMessages(merged, {
    channelId,
    appleId: host.appleId,
    initialSync: true,
    calendarBundles,
  });
  if (links.length > 0) await host.integrations.saveLinks(links);

  // Seed the \Flagged↔to-do marker from history without propagating: see
  // reconcileTodoFlags's doc.
  await reconcileTodoFlags(host, merged, true);

  const lastUid = inboxUids.reduce((m, u) => (u > m ? u : m), 0);
  const state: MailSyncState = {
    uidValidity: status.uidValidity,
    lastUid,
    syncHistoryMin: since.toISOString(),
    // Re-baselining (first sync, no-state, or UIDVALIDITY change) always
    // resets both modseq cursors from the fresh SELECT — correct, since a
    // new UIDVALIDITY invalidates old mod-sequences too.
    lastModSeq: status.highestModSeq,
    sentLastModSeq: sentStatus?.highestModSeq,
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

    // COMBINED CONDSTORE gate (RFC 7162). INBOX and Sent are always merged
    // into a single transformMessages() call per pass (see
    // runInitialBackfill's doc) so that a thread rooted in one mailbox is
    // never rebuilt from a partial message set — e.g. an INBOX-rooted
    // thread's title/author must never be recomputed from just a Sent
    // reply. That merge invariant means the two mailboxes' gates cannot be
    // decided independently: if EITHER mailbox's HIGHESTMODSEQ advanced
    // since the last successful poll, BOTH must be (re)fetched this pass so
    // any thread the change touches is rebuilt from its complete message
    // set. Only skip both when NEITHER advanced. Falls back to "assume
    // changed" for a given mailbox when the server doesn't advertise
    // CONDSTORE (`highestModSeq === undefined`) or no baseline cursor exists
    // yet for it (`lastModSeq`/`sentLastModSeq === undefined`, e.g. state
    // written before this cursor shipped).
    const inboxUnchanged =
      status.highestModSeq !== undefined &&
      state.lastModSeq !== undefined &&
      status.highestModSeq === state.lastModSeq;

    // Read Sent's HIGHESTMODSEQ up front (before deciding whether to
    // rescan) so the combined decision below can see both mailboxes' state.
    // This SELECTs Sent, moving the session's selected mailbox off INBOX.
    const sentBox = await resolveSentMailbox(host, session);
    let sentStatus: ImapMailboxStatus | undefined;
    if (sentBox) {
      sentStatus = await host.imap.selectMailbox(session, sentBox);
    }
    // No Sent mailbox at all means there's nothing to gate on that side, so
    // it can never block a rescan the INBOX side needs (and vice versa) —
    // treat as "unchanged" so the combined decision rests on whichever
    // mailbox actually exists.
    const sentUnchanged =
      !sentBox ||
      (sentStatus!.highestModSeq !== undefined &&
        state.sentLastModSeq !== undefined &&
        sentStatus!.highestModSeq === state.sentLastModSeq);

    // Pure date math, shared by both mailboxes' rescans below.
    const floor = resolveSinceFloor(state.syncHistoryMin);
    const recentSince = new Date(Math.max(floor.getTime(), Date.now() - RECENT_WINDOW_MS));

    let newUids: number[] = [];
    let inboxUids: number[] = [];
    let inbox: ImapMessage[] = [];
    let sent: ImapMessage[] = [];

    if (!(inboxUnchanged && sentUnchanged)) {
      // Either mailbox changed => rescan BOTH, exactly today's full-rescan
      // behavior, so any thread the change touches is rebuilt complete.

      // Re-select INBOX first: the Sent SELECT above (used to read its
      // HIGHESTMODSEQ) switched the session's currently-selected mailbox,
      // and IMAP SEARCH always targets whatever's currently selected.
      await host.imap.selectMailbox(session, "INBOX");

      // New mail since the stored cursor, bounded by the plan floor so a
      // dormant account (stored lastUid: 0) can't fetch the entire mailbox.
      const windowUids = await host.imap.search(session, { since: floor });
      newUids = windowUids.filter((u) => u > state.lastUid);

      // Recent-window rescan to catch \Seen flag changes on already-synced
      // mail, also capped at the plan floor.
      const recentUids = await host.imap.search(session, { since: recentSince });

      inboxUids = Array.from(new Set([...newUids, ...recentUids]));
      inbox = await fetchUidRange(host, session, "INBOX", inboxUids);

      if (sentBox) {
        await host.imap.selectMailbox(session, sentBox);
        const sentUids = await host.imap.search(session, { since: recentSince });
        sent = await fetchUidRange(host, session, sentBox, sentUids);
      }
    }

    // See runInitialBackfill: tag each message with its originating mailbox
    // for correct attachment refs once INBOX and Sent are merged.
    const merged: MailMessage[] = [
      ...inbox.map((m) => ({ ...m, mailbox: "INBOX" })),
      ...(sentBox ? sent.map((m) => ({ ...m, mailbox: sentBox })) : []),
    ];
    const calendarBundles = await detectCalendarBundles(host, session, merged);
    const links = transformMessages(merged, {
      channelId,
      appleId: host.appleId,
      initialSync: false,
      // Only these newly-arrived UIDs may (re)mark a thread unread; the
      // recent-window rescan messages are read-state propagation only.
      newUids,
      calendarBundles,
    });
    if (links.length > 0) await host.integrations.saveLinks(links);

    // Same recent-window messages double as the \Flagged rescan — any flag
    // change (like the \Seen rescan above) shows up within this window.
    await reconcileTodoFlags(host, merged, false);

    // When the INBOX gate skipped (inboxUids stays []), newMaxUid is 0 and
    // Math.max preserves the prior lastUid unchanged.
    const newMaxUid = inboxUids.reduce((m, u) => (u > m ? u : m), 0);
    const nextState: MailSyncState = {
      uidValidity: status.uidValidity,
      lastUid: Math.max(newMaxUid, state.lastUid),
      syncHistoryMin: state.syncHistoryMin,
      // Seed/update every pass: undefined (no CONDSTORE) correctly forces a
      // full rescan next poll too.
      lastModSeq: status.highestModSeq,
      sentLastModSeq: sentStatus?.highestModSeq,
    };
    await host.set(`state_${channelId}`, nextState);
  } finally {
    await host.imap.disconnect(session);
  }
}
