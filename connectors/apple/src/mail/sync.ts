import type { ActorId } from "@plotday/twister";
import type { ImapMailboxStatus, ImapSession } from "@plotday/twister/tools/imap";

import {
  classifyICS,
  isCalendarAttachment,
  type CalendarBundle,
  type ClassifiedICS,
} from "./calendar-bundle";
import { connectIcloud, fetchUidRange, resolveSentMailbox } from "./imap-fetch";
import type { MailboxCursor, MailHost, MailSyncState } from "./mail-host";
import {
  mailSource,
  messageKey,
  rootMessageId,
  transformMessages,
  type MailMessage,
} from "./transform";

const DEFAULT_HISTORY_MS = 7 * 24 * 60 * 60 * 1000; // 7 days
const RECENT_WINDOW_MS = 30 * 24 * 60 * 60 * 1000; // 30 days

/** The connection-level cursor document (see `MailSyncState`). */
const STATE_KEY = "state";

/**
 * Soft ceilings for one merged pass, warned about (never enforced) so the
 * dev instance surfaces a runaway account before a user does. See the cost
 * model in `mailSync`'s docstring: memory, not the request budget, is the
 * tighter limit, because every fetched message is held with both bodies.
 */
const WARN_MESSAGE_COUNT = 1500;
const WARN_ROOT_COUNT = 400;

/** One enabled mail channel and the raw IMAP mailbox it maps to. */
export type MailChannel = {
  /** Namespaced channel id, e.g. `"mail:Archive"`. */
  channelId: string;
  /** Raw IMAP mailbox name, i.e. `parse(channelId).rawId`. */
  mailbox: string;
};

/**
 * Per-thread-root metadata, stored at `mail:thread:<rootId>`. One store read
 * per root per pass serves BOTH the home-channel resolution and the
 * calendar-bundle cache, which is why they share a document rather than
 * living under two keys.
 */
export type ThreadMeta = {
  /**
   * The namespaced mail channel this thread is homed to (resolved in
   * `mailSync`). Always a channel that was ENABLED at the time it was
   * written, and deliberately persisted rather than recomputed each pass:
   * the merged batch is window-dependent, so a derived value transitions as
   * old messages age out of the rescan window, rewriting `link.channel_id`
   * and changing what disable-time archiving matches.
   *
   * Optional so a home channel can be CLEARED (e.g. when its folder is
   * disabled) without discarding the root's `bundle` decision — the document's
   * presence is what marks the root "already known to Plot", and `mailSync`
   * re-resolves an absent channel from this pass's messages.
   */
  channelId?: string;
  /**
   * Persisted calendar-bundle classification. Absent = never evaluated;
   * `{ classified: null }` = evaluated, does not bundle. Wrapped in an object
   * — never a bare `ClassifiedICS | null` — so the two states stay
   * distinguishable (see `detectCalendarBundles`'s CACHING doc).
   */
  bundle?: { classified: ClassifiedICS | null };
};

function threadMetaKey(rootId: string): string {
  return `thread:${rootId}`;
}

/** Group messages by thread root, dropping messages with no id to thread on. */
function groupByRoot(messages: MailMessage[]): Map<string, MailMessage[]> {
  const byRoot = new Map<string, MailMessage[]>();
  for (const m of messages) {
    const root = rootMessageId(m);
    if (!root) continue;
    const list = byRoot.get(root) ?? [];
    list.push(m);
    byRoot.set(root, list);
  }
  return byRoot;
}

/**
 * Resolve the history floor. Uses `syncHistoryMin` when it parses to a valid
 * date; otherwise defaults to 7 days ago (a connection whose plan window was
 * never recorded still gets a bounded backfill rather than the whole mailbox).
 */
function resolveSinceFloor(syncHistoryMin: string | undefined): Date {
  if (syncHistoryMin) {
    const parsed = new Date(syncHistoryMin);
    if (!Number.isNaN(parsed.getTime())) return parsed;
  }
  return new Date(Date.now() - DEFAULT_HISTORY_MS);
}

/**
 * Widen the persisted history floor: the EARLIEST of the stored floor and an
 * incoming one. Never narrows — a plan downgrade must not erase history that
 * has already been synced. Invalid/absent values are ignored.
 */
function widestFloor(
  stored: string | undefined,
  incoming: string | undefined
): string | undefined {
  const valid = [stored, incoming].filter(
    (v): v is string => v !== undefined && !Number.isNaN(new Date(v).getTime())
  );
  if (valid.length === 0) return undefined;
  return valid.reduce((a, b) => (new Date(a) <= new Date(b) ? a : b));
}

/**
 * Deterministic "which folder does this thread live in" ordering: oldest
 * message first, then INBOX before any other folder, then mailbox name, then
 * uid. Mirrors `transform.ts`'s message ordering so the thread's home channel
 * and its originator message agree about which copy comes first.
 */
function compareForHome(a: MailMessage, b: MailMessage): number {
  const byDate = (a.date?.getTime() ?? 0) - (b.date?.getTime() ?? 0);
  if (byDate !== 0) return byDate;
  const rank = (m: MailMessage) => (m.mailbox.toUpperCase() === "INBOX" ? 0 : 1);
  const byRank = rank(a) - rank(b);
  if (byRank !== 0) return byRank;
  if (a.mailbox !== b.mailbox) return a.mailbox < b.mailbox ? -1 : 1;
  return a.uid - b.uid;
}

/**
 * Read-direction half of the to-do ↔ \Flagged loop (write direction is
 * `onThreadToDoFn` in write.ts). Groups `messages` by thread root
 * (`rootMessageId`), computes whether any message in the thread carries
 * `\Flagged`, and diffs that against the stored `flagged:<rootId>` marker:
 *
 *  - For a root in `initialRoots` (this pass is ingesting it from history for
 *    the first time), the marker is SEEDED from the current \Flagged state but
 *    `setThreadToDo` is never called — a message flagged years before the
 *    connection ever existed must not spam a fresh to-do on first connect
 *    (mirrors the initial-sync unread discipline in `transformMessages`).
 *  - Otherwise, a state change since the marker propagates once via
 *    `integrations.setThreadToDo` and updates the marker. An unchanged state —
 *    including the write path's own just-set marker (see `onThreadToDoFn` in
 *    write.ts) — is a no-op. That "no-op on no change" is what breaks the echo
 *    loop: our own Plot→\Flagged write is indistinguishable here from "nothing
 *    changed since we last looked".
 *
 * `initialRoots` is a SET, not a batch-wide flag: one merged pass can be
 * backfilling a newly-enabled folder's history while incrementally syncing
 * folders that already have a cursor, so seeding and propagating both happen
 * within a single call.
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
  initialRoots: Set<string>
): Promise<void> {
  const actorId = await host.get<ActorId>("auth_actor_id");
  if (!actorId) return;

  for (const [root, msgs] of groupByRoot(messages).entries()) {
    const isFlagged = msgs.some((m) => m.flags.includes("\\Flagged"));

    if (initialRoots.has(root)) {
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
 *
 * CACHING: once a root's calendar-bearing message(s) have been classified,
 * the decision (bundle info, or explicitly "no bundle" for a bare
 * invite/RSVP) is recorded on that root's `ThreadMeta.bundle` and reused on
 * every later pass instead of re-fetching. Two reasons this is required, not
 * just an optimization:
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
 *    `upsert_link`'s conflict target, since the old primary source is still
 *    on file. Persisting the decision once means the classification can never
 *    flip after the fact.
 *
 * The caller owns the store I/O: `meta` arrives pre-loaded (one read per root
 * for the pass, shared with home-channel resolution) and is MUTATED in place
 * with any new decision, with the root added to `changed` so the caller
 * persists it once. A root missing from `meta` is still classified and
 * returned, but its decision isn't recorded — `mailSync` guarantees an entry
 * for every root in `messages`.
 *
 * `eventKnown` (see `CalendarBundle`'s doc) is resolved via
 * `host.knownEventUids()` at most once per call — lazily, only once a
 * bundle is actually found — never per message/thread.
 */
export async function detectCalendarBundles(
  host: MailHost,
  session: ImapSession,
  messages: MailMessage[],
  meta: Map<string, ThreadMeta>,
  changed: Set<string>
): Promise<Map<string, CalendarBundle>> {
  const bundles = new Map<string, CalendarBundle>();
  let knownUids: Set<string> | null = null;
  const resolveEventKnown = async (uid: string): Promise<boolean> => {
    if (knownUids === null) knownUids = await host.knownEventUids();
    return knownUids.has(uid);
  };

  for (const [root, msgs] of groupByRoot(messages).entries()) {
    // Reuse an earlier pass's decision before doing anything else — see the
    // CACHING doc above for why this must not be gated behind "does THIS
    // pass have a calendar part" (the ICS-bearing message may have aged out
    // of the window while the thread itself is still active).
    const persisted = meta.get(root)?.bundle;
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
    // decision recorded (a thread with no calendar part yet is simply
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

    // Record the decision — including explicit "no bundle" — so this root is
    // never re-evaluated on a later pass (see the caching doc above).
    const entry = meta.get(root);
    if (entry) {
      entry.bundle = { classified };
      changed.add(root);
    }

    if (classified) {
      bundles.set(root, { ...classified, eventKnown: await resolveEventKnown(classified.uid) });
    }
  }
  return bundles;
}

/** How one mailbox is being read this pass. */
type BoxPlan = {
  /** Raw IMAP mailbox name. */
  mailbox: string;
  /** True for the account's Sent mailbox (read on every pass, never a channel). */
  isSent: boolean;
  /** SELECT status read during the gate phase. */
  status: ImapMailboxStatus;
  /** The stored cursor, if it exists AND its UIDVALIDITY still matches. */
  cursor: MailboxCursor | undefined;
  /** No usable cursor → read the whole history floor, contribute no new mail. */
  backfill: boolean;
  /** No cursor at all (as opposed to a UIDVALIDITY reset) → first-ever backfill. */
  firstBackfill: boolean;
};

/**
 * ONE merged sync pass for the whole connection: reads every enabled mailbox
 * plus Sent on a single IMAP session and rebuilds every touched thread from
 * its COMPLETE visible message set in exactly one `transformMessages()` call.
 *
 * That single call is the invariant this function exists to protect. A mail
 * thread's `link.source` comes from its root Message-ID, which is
 * mailbox-independent, so a conversation with messages in two enabled folders
 * is ONE Plot thread that both folders address. `transformMessages` derives
 * `title`, `unread` and the thread author from only the messages handed to one
 * call, so splitting the pass per mailbox makes each folder rewrite the shared
 * thread from a partial view and the passes overwrite each other forever.
 * Never call `transformMessages` (or `saveLinks`) per mailbox, per chunk, or
 * per root.
 *
 * There is no separate "initial" entry point: initial-ness is decided PER
 * MAILBOX (one without a cursor gets a backfill) and PER THREAD ROOT (one Plot
 * has never seen, arriving from history rather than as new mail, gets
 * `unread: false, archived: false`).
 *
 * `channels` is passed in rather than read from the host so this stays a pure
 * function of its inputs; the connector enumerates its enabled mail channels
 * and hands them over. An empty list means nothing is enabled — there is
 * correctly no pass.
 *
 * COST MODEL (budget: ~1000 requests and ~128 MB per execution). With `N`
 * enabled folders, `M` messages fetched, `R` distinct thread roots and `C`
 * newly calendar-classified roots, one pass costs roughly
 * `4N + ceil(M/50) + 2R (+ writes) + 2C + ~10` tool calls — the dominant term
 * is `R`, not `N`, so merging folders raises the message/root count rather
 * than the per-folder overhead. A fully-skipped pass (CONDSTORE gate hit)
 * costs only `N + 7`. Memory is the tighter limit: every fetched message is
 * held with both bodies, so the thresholds below warn well before the ceiling.
 * If the ceiling is ever hit for real, the correct escalation is a two-phase
 * fetch (headers-only across all mailboxes to build the root partition, then
 * bodies per root-slice, each root completed within its slice) — which keeps
 * the merge invariant, unlike splitting the pass by mailbox.
 */
export async function mailSync(
  host: MailHost,
  channels: MailChannel[],
  syncHistoryMin: string | undefined
): Promise<void> {
  if (channels.length === 0) return;

  // Deterministic order so the fallback home channel (and every
  // select/search/fetch sequence) is stable across passes.
  const ordered = [...channels].sort((a, b) =>
    a.channelId < b.channelId ? -1 : a.channelId > b.channelId ? 1 : 0
  );
  const enabledMailboxes = new Set(ordered.map((c) => c.mailbox));
  const enabledChannelIds = new Set(ordered.map((c) => c.channelId));
  const channelForMailbox = new Map(ordered.map((c) => [c.mailbox, c.channelId]));

  const session = await connectIcloud(host);
  try {
    const stored = await host.get<MailSyncState>(STATE_KEY);
    const historyMin = widestFloor(stored?.syncHistoryMin, syncHistoryMin);
    const floor = resolveSinceFloor(historyMin);
    const recentSince = new Date(Math.max(floor.getTime(), Date.now() - RECENT_WINDOW_MS));
    const pendingFullRescan = stored?.pendingFullRescan === true;
    const storedBoxes: Record<string, MailboxCursor> = stored?.boxes ?? {};

    // Sent is read on EVERY merged pass, not just when INBOX happens to be
    // enabled, so the owner's own replies keep landing on their threads no
    // matter which folders the user syncs. It is deliberately not an
    // enable-able channel (`channels.ts`), but guard anyway: treating an
    // enabled folder as Sent would double-read it and give it no home channel.
    const resolvedSent = await resolveSentMailbox(host, session);
    const sentBox = resolvedSent && !enabledMailboxes.has(resolvedSent) ? resolvedSent : null;

    // ---- Gate phase: one SELECT per mailbox, purely to read HIGHESTMODSEQ.
    const plans: BoxPlan[] = [];
    for (const mailbox of [...ordered.map((c) => c.mailbox), ...(sentBox ? [sentBox] : [])]) {
      const status = await host.imap.selectMailbox(session, mailbox);
      const storedCursor = storedBoxes[mailbox];
      const usable =
        storedCursor !== undefined && storedCursor.uidValidity === status.uidValidity;
      plans.push({
        mailbox,
        isSent: mailbox === sentBox,
        status,
        cursor: usable ? storedCursor : undefined,
        backfill: !usable,
        firstBackfill: storedCursor === undefined,
      });
    }

    // ---- The search window is a property of the PASS, never of one mailbox.
    //
    // Mixing windows across mailboxes reintroduces the very defect the merged
    // pass exists to fix, by a different route: the gate stops a per-mailbox
    // SKIP, but a per-mailbox WINDOW hands `transformMessages` an equally
    // partial message set. Concretely, with a 365-day plan floor and a 30-day
    // recent window, enabling Archive on a connection whose INBOX is already
    // synced would search Archive over 365 days and INBOX over 30 — so a
    // thread whose root landed in INBOX 60 days ago (below INBOX's `lastUid`)
    // and whose later reply was filed into Archive 45 days ago is rebuilt from
    // the Archive half alone: re-titled "Re: …" from the wrong originator, and
    // marked read if that copy is \Seen while the missing root is not. Neither
    // message falls in any later pass's 30-day window, so both are permanent.
    // The same asymmetry drops the owner's Sent replies older than the recent
    // window off every thread a newly-enabled folder backfills.
    //
    // So: if ANY mailbox in this pass is backfilling, or a full rescan is
    // pending, or the granted history floor has widened since these mailboxes
    // were last read (a plan upgrade — `MailboxCursor.syncHistoryMin`), then
    // EVERY mailbox — Sent included — searches from `floor`. Otherwise every
    // mailbox searches from `recentSince`. The cost is one wide pass per
    // folder-enable / plan upgrade, which is exactly what `pendingFullRescan`
    // already accepts.
    const floorMs = floor.getTime();
    const floorWidened = plans.some((p) => {
      const readFrom = p.cursor?.syncHistoryMin;
      if (readFrom === undefined) return false;
      const readFromMs = new Date(readFrom).getTime();
      return !Number.isNaN(readFromMs) && readFromMs > floorMs;
    });
    const wideWindow =
      pendingFullRescan || floorWidened || plans.some((p) => p.backfill);
    const since = wideWindow ? floor : recentSince;

    // The CONDSTORE gate (RFC 7162), generalized over every mailbox in the
    // pass. It is a single all-or-nothing decision: either every mailbox is
    // re-searched and re-fetched, or none is. A PER-MAILBOX gate would be
    // exactly the defect this pass exists to fix — skip INBOX because it
    // didn't move, fetch Archive because it did, and a thread with messages in
    // both gets rebuilt from Archive alone. A mailbox with no cursor, a
    // changed UIDVALIDITY, or a server that doesn't advertise CONDSTORE is
    // never "unchanged", so enabling a folder always forces the pass.
    const unchanged = (p: BoxPlan): boolean =>
      p.cursor !== undefined &&
      p.status.highestModSeq !== undefined &&
      p.cursor.lastModSeq !== undefined &&
      p.status.highestModSeq === p.cursor.lastModSeq;
    // `wideWindow` also forces the fetch phase: a widened history floor (or a
    // pending full rescan) must not be swallowed by an all-unchanged gate, or
    // the history the user was just granted never arrives. A backfilling
    // mailbox is never "unchanged" anyway, so that disjunct is belt-and-braces.
    const skipFetch = !wideWindow && plans.every(unchanged);

    // ---- Fetch phase.
    const merged: MailMessage[] = [];
    /** Messages that are NEW this pass, mailbox-qualified (see `messageKey`). */
    const newMessages = new Set<string>();
    const nextBoxes: Record<string, MailboxCursor> = { ...storedBoxes };

    if (!skipFetch) {
      for (const p of plans) {
        // Re-SELECT: the gate loop above moved the session's selection, and
        // IMAP SEARCH always targets whatever is currently selected.
        await host.imap.selectMailbox(session, p.mailbox);

        let windowUids: number[];
        let newUids: number[] = [];
        if (p.isSent) {
          // Sent is always window-shaped and NEVER contributes new-message
          // signal: mail the owner sent must not mark their own thread unread.
          // Its cursor exists only to carry uidValidity + lastModSeq for the
          // gate. It uses the PASS's window like every other mailbox, so a
          // wide pass (any folder backfilling, a widened floor, a pending full
          // rescan) puts the owner's historical replies on the threads that
          // pass rebuilds.
          windowUids = await host.imap.search(session, { since });
        } else if (p.backfill) {
          // No usable cursor: read the whole history floor (a backfilling
          // mailbox is one of the things that MAKES the pass wide, so `since`
          // is `floor` here). Contributes no `newMessages`, so already-known
          // roots keep their read state and never-seen roots fall into
          // `initialRoots` below.
          windowUids = await host.imap.search(session, { since });
        } else {
          // Incremental. New mail is everything above the cursor, bounded by
          // the floor so a dormant account can't fetch the entire mailbox.
          const fromFloor = await host.imap.search(session, { since: floor });
          newUids = fromFloor.filter((u) => u > p.cursor!.lastUid);
          if (wideWindow) {
            // Wide pass: fetch the whole floor rather than the recent window,
            // so this mailbox's half of any thread another mailbox is
            // backfilling (or re-homing, or newly granted history for) is
            // present in the single `transformMessages` call.
            windowUids = fromFloor;
          } else {
            // Recent-window rescan to catch \Seen / \Flagged changes on
            // already-synced mail, also capped at the floor.
            const recentUids = await host.imap.search(session, { since });
            windowUids = Array.from(new Set([...newUids, ...recentUids]));
          }
        }

        // `alreadySelected`: this mailbox was SELECTed just above for its
        // SEARCHes and nothing has moved the selection since.
        const fetched = await fetchUidRange(host, session, p.mailbox, windowUids, true);
        // Tag each message with its originating mailbox — UIDs are unique only
        // within one mailbox, so the tag is what keeps messages identifiable
        // once every folder is merged into one call (attachment refs,
        // `messageKey`, the Sent-only rule).
        const tagged = fetched.map((m) => ({ ...m, mailbox: p.mailbox }));
        merged.push(...tagged);
        if (newUids.length > 0) {
          const isNew = new Set(newUids);
          for (const m of tagged) if (isNew.has(m.uid)) newMessages.add(messageKey(m));
        }

        const maxUid = windowUids.reduce((acc, u) => (u > acc ? u : acc), 0);
        nextBoxes[p.mailbox] = {
          uidValidity: p.status.uidValidity,
          // Sent's lastUid is never consulted (it contributes no new mail).
          lastUid: p.isSent ? 0 : Math.max(maxUid, p.cursor?.lastUid ?? 0),
          // How far back this mailbox has actually been READ. A wide pass
          // searched it from `floor`, so the coverage advances to the (never
          // narrowing) floor; a recent-window pass leaves it where it was.
          // This is what makes a later floor widening detectable.
          syncHistoryMin: wideWindow
            ? (widestFloor(p.cursor?.syncHistoryMin, floor.toISOString()) ??
              floor.toISOString())
            : (p.cursor?.syncHistoryMin ?? floor.toISOString()),
          // Seed/update every pass: undefined (no CONDSTORE) correctly forces
          // a full rescan next pass too.
          lastModSeq: p.status.highestModSeq,
        };
      }
    }

    const byRoot = groupByRoot(merged);
    if (merged.length > WARN_MESSAGE_COUNT || byRoot.size > WARN_ROOT_COUNT) {
      console.warn(
        `[Apple Mail] Large merged pass: ${merged.length} messages, ${byRoot.size} threads ` +
          `across ${ordered.length} folders. Approaching the per-execution memory/request ` +
          `budget — see mailSync's cost model.`
      );
    }

    // ---- Per-root metadata: one read per root, serving BOTH the home-channel
    // resolution and the calendar-bundle cache.
    const storedMeta = new Map<string, ThreadMeta | undefined>();
    for (const root of byRoot.keys()) {
      storedMeta.set(root, await host.get<ThreadMeta>(threadMetaKey(root)));
    }

    // A thread with no message in any enabled folder this pass (a Sent-only
    // conversation, or one whose home channel was just disabled) still needs a
    // real, enabled channel: `null` would persist `channel_id = NULL`, which
    // disable-time archiving can never match and which never seeds the
    // thread's topic. INBOX when enabled, else the lowest-sorted channel.
    const fallbackChannel =
      ordered.find((c) => c.mailbox.toUpperCase() === "INBOX")?.channelId ??
      ordered[0].channelId;

    const channelByRoot = new Map<string, string>();
    const nextMeta = new Map<string, ThreadMeta>();
    const changedMeta = new Set<string>();
    for (const [root, msgs] of byRoot.entries()) {
      const prev = storedMeta.get(root);
      let channelId: string;
      if (prev?.channelId !== undefined && enabledChannelIds.has(prev.channelId)) {
        // Stable: a thread never changes folders because its oldest message
        // aged out of this pass's window.
        channelId = prev.channelId;
      } else {
        const candidates = msgs
          .filter((m) => enabledMailboxes.has(m.mailbox))
          .sort(compareForHome);
        channelId =
          candidates.length > 0
            ? channelForMailbox.get(candidates[0].mailbox)!
            : fallbackChannel;
      }
      channelByRoot.set(root, channelId);
      nextMeta.set(root, {
        channelId,
        ...(prev?.bundle ? { bundle: prev.bundle } : {}),
      });
      if (!prev || prev.channelId !== channelId) changedMeta.add(root);
    }

    // Per-root initial-ness: a root Plot has never seen (no stored metadata)
    // AND that contributed no new mail this pass is being ingested from
    // history, so it gets `unread: false, archived: false`. A root that is new
    // to Plot but arrived as live mail is NOT initial — it must still notify.
    const initialRoots = new Set<string>();
    for (const [root, msgs] of byRoot.entries()) {
      if (storedMeta.get(root) !== undefined) continue;
      if (msgs.some((m) => newMessages.has(messageKey(m)))) continue;
      initialRoots.add(root);
    }

    const calendarBundles = await detectCalendarBundles(
      host,
      session,
      merged,
      nextMeta,
      changedMeta
    );

    // THE single transformMessages call. See this function's docstring.
    const links = transformMessages(merged, {
      appleId: host.appleId,
      channelByRoot,
      initialRoots,
      newMessages,
      sentMailbox: sentBox,
      calendarBundles,
    });
    if (links.length > 0) await host.integrations.saveLinks(links);

    await reconcileTodoFlags(host, merged, initialRoots);

    // Persisted AFTER the save: if `saveLinks` throws, the next pass still
    // treats these roots as never-seen and re-runs the initial-sync
    // discipline, rather than inserting them with no `unread` key and
    // notifying for mail the user was never shown.
    //
    // ONE `setMany`, never a `set` per root: a merged pass can touch hundreds
    // of roots, and beyond the request budget a per-root loop can fail
    // half-written — the un-written roots then look never-seen on the next
    // pass and are re-emitted with `archived: false` (un-archiving threads the
    // user archived) and `unread: false` (silencing genuinely unread ones).
    if (changedMeta.size > 0) {
      await host.setMany(
        [...changedMeta].map((root): [string, ThreadMeta] => [
          threadMetaKey(root),
          nextMeta.get(root)!,
        ])
      );
    }

    const nextState: MailSyncState = {
      version: 2,
      boxes: nextBoxes,
      ...(historyMin ? { syncHistoryMin: historyMin } : {}),
      // `pendingFullRescan` is consumed by this pass and cleared by omission.
    };
    // CONSTRAINT: this is a read-modify-write of ONE connection-level document
    // (read at the top of the pass, replaced wholesale here), so it is only
    // safe while the connection can have at most one pass in flight — i.e. the
    // sync lock must be held at CONNECTION level, not per channel. Under a
    // per-channel lock two overlapping passes each write the whole document
    // from their own snapshot: the later writer restores the other mailbox's
    // pre-pass `lastUid`/`lastModSeq` (re-classifying already-ingested mail as
    // new and re-marking threads unread), or writes a snapshot that predates a
    // sibling's first cursor and drops it entirely, forcing a redundant
    // full-history backfill and a second `channelSyncCompleted`.
    await host.set(STATE_KEY, nextState);

    // Clear the "syncing…" spinner for each channel whose mailbox completed
    // its FIRST backfill in this pass. A UIDVALIDITY re-baseline is not a
    // first backfill — that channel already reported completion.
    if (!skipFetch) {
      for (const p of plans) {
        if (p.isSent || !p.firstBackfill) continue;
        const channelId = channelForMailbox.get(p.mailbox);
        if (channelId) await host.channelSyncCompleted(channelId);
      }
    }
  } finally {
    await host.imap.disconnect(session);
  }
}
