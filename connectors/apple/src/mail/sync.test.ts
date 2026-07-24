import { describe, expect, it, vi } from "vitest";
import type {
  Imap,
  ImapFetchOptions,
  ImapMailbox,
  ImapMailboxStatus,
  ImapMessage,
  ImapSearchCriteria,
  ImapSession,
} from "@plotday/twister/tools/imap";
import type { Files } from "@plotday/twister/tools/files";
import type { Integrations } from "@plotday/twister/tools/integrations";
import type { Smtp } from "@plotday/twister/tools/smtp";
import type { NewLinkWithNotes } from "@plotday/twister";

import { buildAttachmentRef, parseAttachmentRef } from "./attachments";
import {
  detectCalendarBundles,
  mailSync,
  reconcileTodoFlags,
  type MailChannel,
  type ThreadMeta,
} from "./sync";
import type { MailboxCursor, MailHost, MailSyncState } from "./mail-host";
import type { MailMessage } from "./transform";

/** One mock mailbox: its selectMailbox() status, search() results, and messages by uid. */
type MailboxFixture = {
  name: string;
  /** IMAP SPECIAL-USE attribute reported by `listMailboxes` (e.g. `"\\Sent"`). */
  specialUse?: string;
  status: ImapMailboxStatus;
  searchUids: number[];
  messagesByUid: Map<number, ImapMessage>;
};

type SearchCall = { mailbox: string; criteria: ImapSearchCriteria };
type FetchCall = { mailbox: string; uids: number[] };
type FetchAttachmentCall = { mailbox: string; uid: number; partNumber: string };

/**
 * Minimal in-memory MailHost — no real IMAP. Captures search()/fetch()/
 * select() calls and saveLinks() output.
 *
 * `mailboxes` is a flat list because the merged pass reads EVERY enabled
 * mailbox plus Sent on one session; there is no "primary" mailbox any more.
 * `listMailboxes` returns every registered box, so `resolveSentMailbox` sees
 * exactly what a real account would. Selecting a mailbox that isn't registered
 * throws, so a pass that reaches for the wrong mailbox fails loudly rather
 * than silently returning nothing.
 */
function buildFakeHost(opts: {
  appleId: string;
  mailboxes: MailboxFixture[];
  /**
   * Fixture attachment bytes for `imap.fetchAttachment`, keyed by
   * `buildAttachmentRef(mailbox, uid, partNumber)` — the same
   * mailbox:uid:partNumber shape `detectCalendarBundles` fetches by. A
   * lookup miss throws, so an unexpected fetch fails the test loudly
   * instead of silently returning garbage bytes.
   */
  attachments?: Record<string, Uint8Array>;
  /**
   * UIDs the calendar product has actually saved a titled link for —
   * mirrors `MailHost.knownEventUids()`'s real backing
   * (`titled_uids_<calendarHref>` in apple.ts). Defaults to none (nothing
   * synced yet), which is the common case for these mail-only fixtures.
   */
  knownEventUids?: string[];
}) {
  const stored = new Map<string, unknown>();
  const savedLinks: NewLinkWithNotes[] = [];
  /** One entry per `saveLinks()` INVOCATION — the merged pass must make
   *  exactly one per sync, never one per mailbox. */
  const saveLinksCalls: NewLinkWithNotes[][] = [];
  const searchCalls: SearchCall[] = [];
  const fetchCalls: FetchCall[] = [];
  const fetchAttachmentCalls: FetchAttachmentCall[] = [];
  /** Every mailbox SELECTed, in order. */
  const selectCalls: string[] = [];
  /** One entry per `setMany()` INVOCATION: the keys it wrote. */
  const setManyCalls: string[][] = [];
  const syncCompleted: string[] = [];
  let selected = opts.mailboxes[0]?.name ?? "INBOX";

  const mailboxes = new Map<string, MailboxFixture>();
  for (const box of opts.mailboxes) mailboxes.set(box.name, box);

  const imap = {
    connect: async (): Promise<ImapSession> => "session-1",
    listMailboxes: async (): Promise<ImapMailbox[]> =>
      opts.mailboxes.map((b) => ({
        name: b.name,
        delimiter: "/",
        flags: [],
        ...(b.specialUse ? { specialUse: b.specialUse } : {}),
      })),
    selectMailbox: async (_session: ImapSession, mailbox: string): Promise<ImapMailboxStatus> => {
      selectCalls.push(mailbox);
      selected = mailbox;
      const fixture = mailboxes.get(mailbox);
      if (!fixture) throw new Error(`unexpected mailbox select: ${mailbox}`);
      return fixture.status;
    },
    search: async (
      _session: ImapSession,
      criteria: ImapSearchCriteria
    ): Promise<number[]> => {
      searchCalls.push({ mailbox: selected, criteria });
      const fixture = mailboxes.get(selected);
      if (!fixture) return [];
      // HONOUR `since`, like a real server: a search window that is too narrow
      // must actually MISS the messages outside it. Without this the fake
      // returned every uid regardless of window, so a pass that searched two
      // mailboxes over two different windows still saw every message and
      // window bugs were invisible unless a test asserted the raw `since`
      // argument. A fixture uid with no message (or no date) is always
      // returned — there is nothing to compare it against.
      const since =
        criteria.since === undefined ? undefined : new Date(criteria.since).getTime();
      if (since === undefined) return fixture.searchUids;
      return fixture.searchUids.filter((uid) => {
        const date = fixture.messagesByUid.get(uid)?.date;
        return date === undefined || date.getTime() >= since;
      });
    },
    fetchMessages: async (
      _session: ImapSession,
      uids: number[],
      _options?: ImapFetchOptions
    ): Promise<ImapMessage[]> => {
      fetchCalls.push({ mailbox: selected, uids });
      const fixture = mailboxes.get(selected);
      if (!fixture) return [];
      return uids
        .map((uid) => fixture.messagesByUid.get(uid))
        .filter((m): m is ImapMessage => m !== undefined);
    },
    setFlags: async (): Promise<void> => {},
    disconnect: async (): Promise<void> => {},
    fetchAttachment: async (
      _session: ImapSession,
      uid: number,
      partNumber: string
    ): Promise<Uint8Array> => {
      fetchAttachmentCalls.push({ mailbox: selected, uid, partNumber });
      const key = buildAttachmentRef(selected, uid, partNumber);
      const bytes = opts.attachments?.[key];
      if (!bytes) throw new Error(`no such attachment part: ${key}`);
      return bytes;
    },
  } as unknown as Imap;

  const setThreadToDo = vi.fn(async () => {});
  const integrations = {
    saveLinks: async (links: NewLinkWithNotes[]): Promise<(string | null)[]> => {
      saveLinksCalls.push(links);
      savedLinks.push(...links);
      return links.map(() => null);
    },
    setThreadToDo,
  } as unknown as Integrations;

  const smtp = {} as unknown as Smtp;
  const files = {} as unknown as Files;

  const host: MailHost = {
    imap,
    smtp,
    integrations,
    files,
    appleId: opts.appleId,
    appPassword: "app-specific-password",
    set: async <T>(key: string, value: T): Promise<void> => {
      stored.set(key, value);
    },
    setMany: async <T>(entries: [key: string, value: T][]): Promise<void> => {
      setManyCalls.push(entries.map(([key]) => key));
      for (const [key, value] of entries) stored.set(key, value);
    },
    get: async <T>(key: string): Promise<T | undefined> => stored.get(key) as T | undefined,
    clear: async (key: string): Promise<void> => {
      stored.delete(key);
    },
    channelSyncCompleted: async (channelId: string): Promise<void> => {
      syncCompleted.push(channelId);
    },
    queueWritebackDrain: async (): Promise<void> => {},
    knownEventUids: async (): Promise<Set<string>> => new Set(opts.knownEventUids ?? []),
  };

  return {
    host,
    stored,
    savedLinks,
    saveLinksCalls,
    searchCalls,
    fetchCalls,
    fetchAttachmentCalls,
    selectCalls,
    setManyCalls,
    syncCompleted,
    setThreadToDo,
  };
}

const DAY_MS = 24 * 60 * 60 * 1000;

/**
 * Fixture timestamps are anchored to NOW, never to fixed calendar dates. The
 * pass's recent window is `now - 30d`, and the fake `search()` now HONOURS
 * `since` (see `buildFakeHost`), so a fixed date would quietly drift out of
 * that window as time passes and rot the suite instead of testing it.
 */
function daysAgo(days: number): Date {
  return new Date(Date.now() - days * DAY_MS);
}

/** The plan history floor most fixtures run under — inside the 30-day window,
 *  so `floor` and `recentSince` coincide and these tests exercise the merge
 *  rather than the window. The window itself is exercised by the tests that
 *  pass `FAR_ISO` (a paid plan's 365-day floor), where the two differ. */
const RECENT_ISO = daysAgo(10).toISOString();

function msg(over: Partial<ImapMessage>): ImapMessage {
  return {
    uid: 1,
    flags: [],
    from: [{ address: "jane@example.com", name: "Jane" }],
    to: [{ address: "kris@icloud.com", name: "Kris" }],
    messageId: "<m1@example.com>",
    // Comfortably inside every window these fixtures use, including the
    // 7-day default floor a pass gets when no plan history is recorded.
    date: daysAgo(4),
    subject: "Lunch?",
    bodyText: "Can we meet?",
    ...over,
  };
}

/** A mailbox fixture holding the given messages, keyed by uid. */
function box(
  name: string,
  messages: ImapMessage[],
  over: { highestModSeq?: number; uidValidity?: number; specialUse?: string } = {}
): MailboxFixture {
  const uids = messages.map((m) => m.uid);
  return {
    name,
    ...(over.specialUse ? { specialUse: over.specialUse } : {}),
    status: {
      name,
      exists: messages.length,
      recent: 0,
      uidValidity: over.uidValidity ?? 1,
      uidNext: Math.max(0, ...uids) + 1,
      unseen: messages.filter((m) => !m.flags.includes("\\Seen")).length,
      ...(over.highestModSeq !== undefined ? { highestModSeq: over.highestModSeq } : {}),
    },
    searchUids: uids,
    messagesByUid: new Map(messages.map((m) => [m.uid, m])),
  };
}

/** A search call's `since` floor in epoch ms (`ImapSearchCriteria.since` is
 *  `string | Date`), or -1 when the search was unbounded. */
function sinceMs(call: SearchCall): number {
  const since = call.criteria.since;
  return since === undefined ? -1 : new Date(since).getTime();
}

/** A link's note keys, sorted. (`NewNote.key` sits in a union, hence the cast.) */
function noteKeys(link: NewLinkWithNotes): string[] {
  return (link.notes ?? [])
    .map((n) => (n as { key?: string }).key ?? "")
    .sort();
}

const INBOX_CHANNEL: MailChannel = { channelId: "mail:INBOX", mailbox: "INBOX" };
const ARCHIVE_CHANNEL: MailChannel = { channelId: "mail:Archive", mailbox: "Archive" };
const SENT_BOX = "Sent Messages";

/** A connection-level cursor document. */
function state(
  boxes: Record<string, MailboxCursor>,
  over: Partial<MailSyncState> = {}
): MailSyncState {
  return { version: 2, boxes, syncHistoryMin: RECENT_ISO, ...over };
}

/** One owner-sent message in the Sent mailbox. */
function sentMsg(over: Partial<ImapMessage>): ImapMessage {
  return msg({
    from: [{ address: "kris@icloud.com", name: "Kris" }],
    to: [{ address: "jane@example.com", name: "Jane" }],
    flags: ["\\Seen"],
    ...over,
  });
}

/** The single link this pass saved for `source`. */
function linkFor(links: NewLinkWithNotes[], source: string): NewLinkWithNotes {
  const found = links.filter((l) => l.source === source);
  expect(found).toHaveLength(1);
  return found[0];
}

/**
 * The defect this whole merged-pass design exists to fix.
 *
 * A mail thread's `source` is derived from its root Message-ID, which is
 * mailbox-independent — so a conversation whose root sits in Archive and
 * whose newest reply landed in INBOX is ONE Plot thread addressed by BOTH
 * folders. With a pass per channel, each folder rebuilt that thread from only
 * its own messages: Archive's pass re-titled it from the root and claimed
 * `channelId: mail:Archive`, INBOX's pass re-titled it from the reply and
 * claimed `mail:INBOX`, and they alternated on every poll.
 */
describe("mailSync — one merged pass per connection", () => {
  const rootMsg = msg({
    uid: 70,
    messageId: "<root@example.com>",
    subject: "Project kickoff",
    from: [{ address: "jane@example.com", name: "Jane" }],
    to: [{ address: "kris@icloud.com", name: "Kris" }],
    flags: ["\\Seen"],
    date: daysAgo(9),
  });
  const oldReply = msg({
    uid: 71,
    messageId: "<old-reply@example.com>",
    references: ["<root@example.com>"],
    subject: "Re: Project kickoff",
    flags: ["\\Seen"],
    date: daysAgo(8),
  });
  const newReply = msg({
    uid: 30,
    messageId: "<new-reply@example.com>",
    references: ["<root@example.com>"],
    subject: "Re: Project kickoff",
    flags: [], // unseen — genuinely new mail
    date: daysAgo(2),
  });

  /** No HIGHESTMODSEQ anywhere, so the CONDSTORE gate never skips and every
   *  pass genuinely re-reads both folders — the harshest churn test. */
  function fixture() {
    return buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [box("INBOX", [newReply]), box("Archive", [rootMsg, oldReply])],
    });
  }

  const SOURCE = "icloud-mail:thread:root@example.com";
  const channels = [INBOX_CHANNEL, ARCHIVE_CHANNEL];

  it("rebuilds a thread split across two folders in ONE saveLinks call, with one link", async () => {
    const { host, saveLinksCalls } = fixture();

    await mailSync(host, channels, RECENT_ISO);

    expect(saveLinksCalls).toHaveLength(1);
    const forRoot = saveLinksCalls[0].filter((l) => l.source === SOURCE);
    expect(forRoot).toHaveLength(1);
    // Every message of the thread, from BOTH folders, in one link.
    expect(noteKeys(forRoot[0])).toEqual([
      "new-reply@example.com",
      "old-reply@example.com",
      "root@example.com",
    ]);
  });

  it("titles the thread from its root message, not from whichever folder ran last", async () => {
    const { host, savedLinks } = fixture();

    await mailSync(host, channels, RECENT_ISO);

    const link = linkFor(savedLinks, SOURCE);
    expect(link.title).toBe("Project kickoff");
  });

  it("homes the thread to the folder holding its earliest message, and keeps channelId === meta.syncableId", async () => {
    const { host, savedLinks } = fixture();

    await mailSync(host, channels, RECENT_ISO);

    const link = linkFor(savedLinks, SOURCE);
    expect(link.channelId).toBe("mail:Archive");
    expect((link.meta as { syncableId?: string }).syncableId).toBe("mail:Archive");
  });

  it("does not churn: repeated passes emit byte-identical links", async () => {
    const { host, saveLinksCalls } = fixture();

    await mailSync(host, channels, RECENT_ISO);
    await mailSync(host, channels, RECENT_ISO);
    await mailSync(host, channels, RECENT_ISO);

    expect(saveLinksCalls).toHaveLength(3);
    const links = saveLinksCalls.map(
      (call) => call.find((l) => l.source === SOURCE)!
    );
    // Title and home channel are the values the old per-channel passes
    // alternated between — they must be identical on every pass.
    expect(links.map((l) => l.title)).toEqual([
      "Project kickoff",
      "Project kickoff",
      "Project kickoff",
    ]);
    expect(links.map((l) => l.channelId)).toEqual([
      "mail:Archive",
      "mail:Archive",
      "mail:Archive",
    ]);
    // Passes 2 and 3 are both steady-state incremental passes over the same
    // mailbox contents, so their output must be identical byte for byte.
    // (Pass 1 legitimately differs: it is the initial backfill, which also
    // carries `unread: false, archived: false`.)
    expect(JSON.stringify(links[2])).toEqual(JSON.stringify(links[1]));
  });

  it("writes one connection-level cursor document covering both folders", async () => {
    const { host, stored } = fixture();

    await mailSync(host, channels, RECENT_ISO);

    const state = stored.get("state") as MailSyncState;
    expect(state.version).toBe(2);
    expect(Object.keys(state.boxes).sort()).toEqual(["Archive", "INBOX"]);
    // …and no per-channel cursor keys survive.
    expect([...stored.keys()].some((k) => k.startsWith("state_"))).toBe(false);
  });
});

/**
 * The CONDSTORE gate (RFC 7162), generalized over every mailbox the merged
 * pass reads. It is a SINGLE all-or-nothing decision: either every mailbox is
 * re-searched and re-fetched, or none is. A per-mailbox gate would be the
 * defect itself — skip the folder that didn't move, fetch the one that did,
 * and a thread with messages in both is rebuilt from half its messages.
 */
describe("mailSync — generalized CONDSTORE gate", () => {
  const inbox = () =>
    box("INBOX", [msg({ uid: 30, messageId: "<inbox-30@x.com>", flags: [] })], {
      highestModSeq: 100,
    });
  const archive = () =>
    box("Archive", [msg({ uid: 70, messageId: "<archive-70@x.com>", flags: [] })], {
      highestModSeq: 200,
    });
  const other = () =>
    box("Receipts", [msg({ uid: 80, messageId: "<receipts-80@x.com>", flags: [] })], {
      highestModSeq: 300,
    });
  const sent = (modSeq: number) =>
    box(SENT_BOX, [sentMsg({ uid: 40, messageId: "<sent-40@icloud.com>" })], {
      highestModSeq: modSeq,
      specialUse: "\\Sent",
    });

  const RECEIPTS_CHANNEL: MailChannel = { channelId: "mail:Receipts", mailbox: "Receipts" };
  const three = [INBOX_CHANNEL, ARCHIVE_CHANNEL, RECEIPTS_CHANNEL];

  const cursors = (over: Record<string, Partial<MailboxCursor>> = {}) => ({
    INBOX: { uidValidity: 1, lastUid: 30, lastModSeq: 100, ...over.INBOX },
    Archive: { uidValidity: 1, lastUid: 70, lastModSeq: 200, ...over.Archive },
    Receipts: { uidValidity: 1, lastUid: 80, lastModSeq: 300, ...over.Receipts },
    [SENT_BOX]: { uidValidity: 1, lastUid: 0, lastModSeq: 50, ...over[SENT_BOX] },
  });

  it("gate hit: every mailbox unchanged — no SEARCH, no fetch, no saveLinks, cursors preserved", async () => {
    const { host, stored, searchCalls, fetchCalls, saveLinksCalls, selectCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [inbox(), archive(), other(), sent(50)],
    });
    await host.set("state", state(cursors()));

    await mailSync(host, three, RECENT_ISO);

    expect(searchCalls).toHaveLength(0);
    expect(fetchCalls).toHaveLength(0);
    expect(saveLinksCalls).toHaveLength(0);
    // One SELECT per mailbox is the irreducible cost of reading HIGHESTMODSEQ.
    expect(selectCalls.sort()).toEqual(["Archive", "INBOX", "Receipts", SENT_BOX].sort());
    const next = stored.get("state") as MailSyncState;
    expect(next.boxes).toEqual(cursors());
  });

  it("gate miss: ONE of three mailboxes advanced — EVERY mailbox is searched and fetched", async () => {
    const { host, searchCalls, fetchCalls, saveLinksCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [inbox(), archive(), other(), sent(50)],
    });
    // Only Archive moved (199 → 200).
    await host.set("state", state(cursors({ Archive: { lastModSeq: 199 } })));

    await mailSync(host, three, RECENT_ISO);

    for (const mailbox of ["INBOX", "Archive", "Receipts", SENT_BOX]) {
      expect(searchCalls.some((c) => c.mailbox === mailbox)).toBe(true);
      expect(fetchCalls.some((c) => c.mailbox === mailbox)).toBe(true);
    }
    // …and still exactly one merged save.
    expect(saveLinksCalls).toHaveLength(1);
  });

  it("gate miss: only Sent advanced — every enabled mailbox is fetched too", async () => {
    const { host, fetchCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [inbox(), archive(), sent(61)],
    });
    await host.set("state", state(cursors()));

    await mailSync(host, [INBOX_CHANNEL, ARCHIVE_CHANNEL], RECENT_ISO);

    expect(fetchCalls.some((c) => c.mailbox === "INBOX")).toBe(true);
    expect(fetchCalls.some((c) => c.mailbox === "Archive")).toBe(true);
    expect(fetchCalls.some((c) => c.mailbox === SENT_BOX)).toBe(true);
  });

  it("gate miss: an enabled mailbox advanced, Sent unchanged — Sent is fetched too", async () => {
    const { host, fetchCalls, stored } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [inbox(), sent(50)],
    });
    await host.set("state", state(cursors({ INBOX: { lastModSeq: 99 } })));

    await mailSync(host, [INBOX_CHANNEL], RECENT_ISO);

    expect(fetchCalls.some((c) => c.mailbox === "INBOX")).toBe(true);
    expect(fetchCalls.some((c) => c.mailbox === SENT_BOX)).toBe(true);
    const next = stored.get("state") as MailSyncState;
    expect(next.boxes.INBOX.lastModSeq).toBe(100);
    expect(next.boxes[SENT_BOX].lastModSeq).toBe(50);
  });

  it("no CONDSTORE on one mailbox: highestModSeq undefined — full rescan", async () => {
    const noCondstore = box("Archive", [msg({ uid: 70, messageId: "<archive-70@x.com>" })]);
    const { host, fetchCalls, stored } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [inbox(), noCondstore],
    });
    await host.set("state", state(cursors()));

    await mailSync(host, [INBOX_CHANNEL, ARCHIVE_CHANNEL], RECENT_ISO);

    expect(fetchCalls.some((c) => c.mailbox === "INBOX")).toBe(true);
    expect(fetchCalls.some((c) => c.mailbox === "Archive")).toBe(true);
    const next = stored.get("state") as MailSyncState;
    expect(next.boxes.Archive.lastModSeq).toBeUndefined();
  });

  it("no baseline yet: a cursor without lastModSeq forces a rescan and seeds one", async () => {
    const { host, fetchCalls, stored } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [inbox()],
    });
    await host.set("state", state({ INBOX: { uidValidity: 1, lastUid: 0 } }));

    await mailSync(host, [INBOX_CHANNEL], RECENT_ISO);

    expect(fetchCalls.length).toBeGreaterThan(0);
    const next = stored.get("state") as MailSyncState;
    expect(next.boxes.INBOX.lastModSeq).toBe(100);
  });

  it("an enabled folder unchanged + Sent changed must not corrupt that folder's threads", async () => {
    // The folder's own HIGHESTMODSEQ never moves when an owner reply lands in
    // Sent, so a per-mailbox gate would rebuild the thread from the Sent reply
    // alone — overwriting its real title and author with the reply's.
    const orig = msg({
      uid: 30,
      messageId: "<orig@x>",
      subject: "Original",
      from: [{ address: "alice@example.com", name: "Alice" }],
      to: [{ address: "kris@icloud.com", name: "Kris" }],
      flags: ["\\Seen"],
      date: daysAgo(9),
    });
    const reply = sentMsg({
      uid: 40,
      messageId: "<reply@x>",
      references: ["<orig@x>"],
      subject: "Re: Original",
      to: [{ address: "alice@example.com", name: "Alice" }],
      date: daysAgo(7),
    });
    const { host, savedLinks, fetchCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [
        box("INBOX", [orig], { highestModSeq: 100 }),
        box(SENT_BOX, [reply], { highestModSeq: 61, specialUse: "\\Sent" }),
      ],
    });
    await host.set(
      "state",
      state({
        INBOX: { uidValidity: 1, lastUid: 30, lastModSeq: 100 },
        [SENT_BOX]: { uidValidity: 1, lastUid: 0, lastModSeq: 60 },
      })
    );

    await mailSync(host, [INBOX_CHANNEL], RECENT_ISO);

    expect(fetchCalls.some((c) => c.mailbox === "INBOX")).toBe(true);
    const link = linkFor(savedLinks, "icloud-mail:thread:orig@x");
    expect(link.title).toBe("Original");
    expect((link.author as { email?: string } | undefined)?.email).toBe("alice@example.com");
  });

  it("a first pass persists a cursor for every mailbox read, including Sent", async () => {
    const { host, stored } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [box("INBOX", [msg({ uid: 30 })], { highestModSeq: 77 }), sent(33)],
    });

    await mailSync(host, [INBOX_CHANNEL], undefined);

    const next = stored.get("state") as MailSyncState;
    expect(next.boxes.INBOX.lastModSeq).toBe(77);
    expect(next.boxes.INBOX.lastUid).toBe(30);
    expect(next.boxes[SENT_BOX].lastModSeq).toBe(33);
    // Sent's lastUid is never consulted (it contributes no new mail).
    expect(next.boxes[SENT_BOX].lastUid).toBe(0);
  });

  it("an account with no Sent mailbox gates on the enabled folders alone", async () => {
    const { host, stored, fetchCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [inbox()],
    });
    await host.set("state", state({ INBOX: { uidValidity: 1, lastUid: 30, lastModSeq: 100 } }));

    await mailSync(host, [INBOX_CHANNEL], RECENT_ISO);

    // Unchanged and nothing else in the pass to force a rescan.
    expect(fetchCalls).toHaveLength(0);
    const next = stored.get("state") as MailSyncState;
    expect(Object.keys(next.boxes)).toEqual(["INBOX"]);
  });
});

describe("mailSync — per-mailbox phase and per-root initial-ness", () => {
  const FAR_ISO = "2025-01-01T00:00:00Z";
  const FLOOR_MS = new Date(FAR_ISO).getTime();

  it("mixes a newly-enabled folder's backfill with the other folders' incremental pass", async () => {
    const archiveRoot = msg({
      uid: 70,
      messageId: "<archive-root@x.com>",
      subject: "Old thread",
      flags: [], // unseen, but historical — must NOT be treated as new mail
      // Outside the 30-day recent window, inside the 365-day plan floor.
      date: daysAgo(52),
    });
    const inboxMsg = msg({
      uid: 30,
      messageId: "<inbox-30@x.com>",
      subject: "Recent",
      flags: ["\\Seen"],
    });
    const { host, savedLinks, saveLinksCalls, searchCalls, syncCompleted } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [box("INBOX", [inboxMsg]), box("Archive", [archiveRoot])],
    });
    // INBOX already has a cursor; Archive has none (just enabled).
    await host.set(
      "state",
      state({ INBOX: { uidValidity: 1, lastUid: 30 } }, { syncHistoryMin: FAR_ISO })
    );
    // The Archive thread is ALREADY KNOWN to Plot (it was synced through
    // another folder before), so it is not in `initialRoots` — which makes it
    // a clean probe for "does a backfilling mailbox contribute new mail?".
    await host.set("thread:archive-root@x.com", { channelId: "mail:Archive" } satisfies ThreadMeta);

    await mailSync(host, [INBOX_CHANNEL, ARCHIVE_CHANNEL], FAR_ISO);

    // ONE merged transform/save covering both folders.
    expect(saveLinksCalls).toHaveLength(1);

    // The window is a property of the PASS: because Archive is backfilling,
    // EVERY mailbox — INBOX and Sent included — searches from the history
    // floor, never the 30-day recent window. A per-mailbox window would hand
    // the single transformMessages call a partial view of any thread that
    // spans the backfilling folder and an incremental one (see the split-
    // thread test below).
    const archiveSearches = searchCalls.filter((c) => c.mailbox === "Archive");
    expect(archiveSearches.length).toBeGreaterThan(0);
    const inboxSearches = searchCalls.filter((c) => c.mailbox === "INBOX");
    expect(inboxSearches.length).toBeGreaterThan(0);
    expect(searchCalls.every((c) => sinceMs(c) === FLOOR_MS)).toBe(true);

    // A backfilling mailbox contributes NO new-message signal: this unseen
    // historical message must not re-mark its already-known thread unread.
    const link = linkFor(savedLinks, "icloud-mail:thread:archive-root@x.com");
    expect("unread" in link).toBe(false);

    // Only the folder that completed its FIRST backfill clears its spinner.
    expect(syncCompleted).toEqual(["mail:Archive"]);
  });

  it("a backfilling folder does not leave the incremental folder's half of a shared thread behind", async () => {
    // The paid-plan case the merged pass has to survive: a 365-day history
    // floor and a 30-day recent window are 335 days apart, so a window chosen
    // per mailbox splits a thread that spans a backfilling folder and an
    // already-synced one — permanently, since neither message ever re-enters
    // a 30-day window again.
    const inboxRoot = msg({
      uid: 50, // BELOW the INBOX cursor: not new mail, so incremental-only
      messageId: "<split@x.com>",
      subject: "Quarterly plan",
      flags: [], // genuinely unread
      date: daysAgo(60), // outside the 30-day recent window
    });
    const archivedReply = msg({
      uid: 70,
      messageId: "<split-reply@x.com>",
      references: ["<split@x.com>"],
      subject: "Re: Quarterly plan",
      flags: ["\\Seen"],
      date: daysAgo(45), // also outside the recent window
    });
    const { host, savedLinks, fetchCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [box("INBOX", [inboxRoot]), box("Archive", [archivedReply])],
    });
    // INBOX is synced up to uid 100; Archive was just enabled (no cursor).
    await host.set(
      "state",
      state(
        { INBOX: { uidValidity: 1, lastUid: 100, syncHistoryMin: FAR_ISO } },
        { syncHistoryMin: FAR_ISO }
      )
    );
    // Already known to Plot, so its read state is a real decision rather than
    // the initial-sync discipline.
    await host.set("thread:split@x.com", { channelId: "mail:INBOX" } satisfies ThreadMeta);

    await mailSync(host, [INBOX_CHANNEL, ARCHIVE_CHANNEL], FAR_ISO);

    // Both halves reach the single transformMessages call…
    const fetchedIn = (mailbox: string) =>
      fetchCalls.filter((c) => c.mailbox === mailbox).flatMap((c) => c.uids);
    expect(fetchedIn("INBOX")).toContain(50);
    expect(fetchedIn("Archive")).toContain(70);
    const link = linkFor(savedLinks, "icloud-mail:thread:split@x.com");
    expect(noteKeys(link)).toEqual(["split-reply@x.com", "split@x.com"]);
    // …so the thread keeps the ROOT's subject, not the Archive copy's "Re: …",
    // and is NOT marked read off the back of the Archive copy's \Seen flag
    // while the unseen root is missing from the batch.
    expect(link.title).toBe("Quarterly plan");
    expect("unread" in link).toBe(false);
  });

  it("searches Sent from the history floor on a first backfill, so old owner replies land on backfilled threads", async () => {
    const inbound = msg({
      uid: 30,
      messageId: "<inbound@x.com>",
      subject: "Contract",
      flags: ["\\Seen"],
      date: daysAgo(60), // outside the 30-day recent window
    });
    const ownerReply = sentMsg({
      uid: 40,
      messageId: "<owner-reply@icloud.com>",
      references: ["<inbound@x.com>"],
      date: daysAgo(59),
    });
    const { host, savedLinks, searchCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [
        box("INBOX", [inbound]),
        box(SENT_BOX, [ownerReply], { specialUse: "\\Sent" }),
      ],
    });

    await mailSync(host, [INBOX_CHANNEL], FAR_ISO);

    const sentSearches = searchCalls.filter((c) => c.mailbox === SENT_BOX);
    expect(sentSearches.length).toBeGreaterThan(0);
    expect(sentSearches.every((c) => sinceMs(c) === FLOOR_MS)).toBe(true);
    // The owner's months-old reply is on the thread, not lost to a 30-day
    // window that only the backfilling folder escaped.
    const link = linkFor(savedLinks, "icloud-mail:thread:inbound@x.com");
    expect(noteKeys(link)).toEqual(["inbound@x.com", "owner-reply@icloud.com"]);
  });

  it("widens an ALREADY-SYNCED Sent mailbox when another folder is backfilling", async () => {
    // Sent having its own cursor must not narrow it while the rest of the
    // pass is wide: the owner's older replies would silently drop off every
    // thread the newly-enabled folder backfills.
    const archived = msg({
      uid: 70,
      messageId: "<deal@x.com>",
      subject: "Deal terms",
      flags: ["\\Seen"],
      date: daysAgo(60),
    });
    const ownerReply = sentMsg({
      uid: 40,
      messageId: "<deal-reply@icloud.com>",
      references: ["<deal@x.com>"],
      date: daysAgo(59),
    });
    const { host, savedLinks, searchCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [
        box("Archive", [archived]),
        box(SENT_BOX, [ownerReply], { specialUse: "\\Sent" }),
      ],
    });
    // Sent is already synced; Archive was just enabled.
    await host.set(
      "state",
      state(
        { [SENT_BOX]: { uidValidity: 1, lastUid: 0, syncHistoryMin: FAR_ISO } },
        { syncHistoryMin: FAR_ISO }
      )
    );

    await mailSync(host, [ARCHIVE_CHANNEL], FAR_ISO);

    const sentSearches = searchCalls.filter((c) => c.mailbox === SENT_BOX);
    expect(sentSearches.length).toBeGreaterThan(0);
    expect(sentSearches.every((c) => sinceMs(c) === FLOOR_MS)).toBe(true);
    const link = linkFor(savedLinks, "icloud-mail:thread:deal@x.com");
    expect(noteKeys(link)).toEqual(["deal-reply@icloud.com", "deal@x.com"]);
  });

  it("re-reads every mailbox from the floor when the granted history window widens", async () => {
    // Plan upgrade: the connection was synced under a 7-day floor and is now
    // granted a year. Every mailbox has a cursor and an unchanged
    // HIGHESTMODSEQ, so without noticing the widening the pass would skip
    // outright and the newly-granted history would never arrive.
    const older = msg({
      uid: 20,
      messageId: "<older@x.com>",
      subject: "Older",
      flags: ["\\Seen"],
      date: daysAgo(90),
    });
    const recent = msg({ uid: 30, messageId: "<recent@x.com>", flags: ["\\Seen"] });
    const { host, savedLinks, searchCalls, stored } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [box("INBOX", [older, recent], { highestModSeq: 100 })],
    });
    const NARROW_ISO = daysAgo(7).toISOString();
    await host.set(
      "state",
      state(
        {
          INBOX: { uidValidity: 1, lastUid: 30, lastModSeq: 100, syncHistoryMin: NARROW_ISO },
        },
        { syncHistoryMin: NARROW_ISO }
      )
    );

    await mailSync(host, [INBOX_CHANNEL], FAR_ISO);

    expect(searchCalls.every((c) => sinceMs(c) === FLOOR_MS)).toBe(true);
    linkFor(savedLinks, "icloud-mail:thread:older@x.com");
    // The cursor records how far back the mailbox has now been read, so the
    // next pass narrows back to the recent window instead of re-reading a
    // year of history every time.
    const next = stored.get("state") as MailSyncState;
    expect(new Date(next.boxes.INBOX.syncHistoryMin!).getTime()).toBe(FLOOR_MS);
  });

  it("writes every changed thread marker in one batched store call", async () => {
    const { host, setManyCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [
        box("INBOX", [
          msg({ uid: 30, messageId: "<a@x.com>" }),
          msg({ uid: 31, messageId: "<b@x.com>" }),
          msg({ uid: 32, messageId: "<c@x.com>" }),
        ]),
      ],
    });

    await mailSync(host, [INBOX_CHANNEL], RECENT_ISO);

    // One round-trip for all three roots — not one `set` each: a merged pass
    // can touch hundreds of roots, and a partially-written loop makes the
    // un-written roots look never-seen next pass (un-archiving them).
    expect(setManyCalls).toHaveLength(1);
    expect(setManyCalls[0].sort()).toEqual([
      "thread:a@x.com",
      "thread:b@x.com",
      "thread:c@x.com",
    ]);
  });

  it("a UIDVALIDITY reset re-baselines only that mailbox, and leaves known threads' read state alone", async () => {
    const inboxMsg = msg({ uid: 30, messageId: "<known@x.com>", flags: [] });
    const archiveMsg = msg({ uid: 70, messageId: "<archive-70@x.com>", flags: ["\\Seen"] });
    const { host, savedLinks, stored, syncCompleted } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [box("INBOX", [inboxMsg]), box("Archive", [archiveMsg])],
    });
    await host.set(
      "state",
      state({
        INBOX: { uidValidity: 9, lastUid: 25 }, // stale — mailbox recreated server-side
        Archive: { uidValidity: 1, lastUid: 70 },
      })
    );
    await host.set("thread:known@x.com", { channelId: "mail:INBOX" } satisfies ThreadMeta);

    await mailSync(host, [INBOX_CHANNEL, ARCHIVE_CHANNEL], RECENT_ISO);

    const link = linkFor(savedLinks, "icloud-mail:thread:known@x.com");
    // The old per-channel code re-ran a full `initialSync: true` backfill here,
    // clearing `unread` on every already-synced thread in the window.
    expect("unread" in link).toBe(false);
    expect("archived" in link).toBe(false);
    const next = stored.get("state") as MailSyncState;
    expect(next.boxes.INBOX.uidValidity).toBe(1);
    expect(next.boxes.Archive.uidValidity).toBe(1);
    // A re-baseline is not a FIRST backfill — the spinner was cleared long ago.
    expect(syncCompleted).toEqual([]);
  });

  it("pendingFullRescan widens every mailbox to the history floor, then clears itself", async () => {
    const { host, searchCalls, stored, fetchCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [
        box("INBOX", [msg({ uid: 30, messageId: "<i@x>" })], { highestModSeq: 100 }),
        box(SENT_BOX, [sentMsg({ uid: 40, messageId: "<s@x>" })], {
          highestModSeq: 50,
          specialUse: "\\Sent",
        }),
      ],
    });
    await host.set(
      "state",
      state(
        {
          INBOX: { uidValidity: 1, lastUid: 30, lastModSeq: 100 },
          [SENT_BOX]: { uidValidity: 1, lastUid: 0, lastModSeq: 50 },
        },
        { syncHistoryMin: FAR_ISO, pendingFullRescan: true }
      )
    );

    await mailSync(host, [INBOX_CHANNEL], FAR_ISO);

    // Every mailbox is unchanged by HIGHESTMODSEQ, yet the pass still runs…
    expect(fetchCalls.length).toBeGreaterThan(0);
    // …from the floor, not the 30-day window, so a thread archived by a
    // sibling channel's disable is re-homed even if its mail is months old.
    expect(searchCalls.length).toBeGreaterThan(0);
    expect(searchCalls.every((c) => sinceMs(c) === FLOOR_MS)).toBe(true);
    const next = stored.get("state") as MailSyncState;
    expect(next.pendingFullRescan).toBeUndefined();
  });

  it("a never-seen root from a backfill is silent; a genuinely new message notifies", async () => {
    const historical = msg({
      uid: 70,
      messageId: "<historical@x.com>",
      flags: [], // unseen older mail, inside this pass's history floor
      date: daysAgo(9),
    });
    const brandNew = msg({
      uid: 31,
      messageId: "<brand-new@x.com>",
      flags: [], // unseen and above the cursor
    });
    const { host, savedLinks } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [box("INBOX", [brandNew]), box("Archive", [historical])],
    });
    await host.set("state", state({ INBOX: { uidValidity: 1, lastUid: 30 } }));

    await mailSync(host, [INBOX_CHANNEL, ARCHIVE_CHANNEL], RECENT_ISO);

    const backfilled = linkFor(savedLinks, "icloud-mail:thread:historical@x.com");
    expect(backfilled.unread).toBe(false);
    expect(backfilled.archived).toBe(false);
    const arrived = linkFor(savedLinks, "icloud-mail:thread:brand-new@x.com");
    expect(arrived.unread).toBe(true);
    expect("archived" in arrived).toBe(false);
  });

  it("bounds every search by the history floor instead of fetching the whole mailbox", async () => {
    const { host, searchCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [
        {
          name: "INBOX",
          status: { name: "INBOX", exists: 100000, recent: 0, uidValidity: 1, uidNext: 100000 },
          searchUids: [],
          messagesByUid: new Map(),
        },
      ],
    });
    // Dormant account: cursor never advanced past 0.
    await host.set("state", state({ INBOX: { uidValidity: 1, lastUid: 0 } }));

    await mailSync(host, [INBOX_CHANNEL], RECENT_ISO);

    expect(searchCalls.length).toBeGreaterThan(0);
    expect(searchCalls.every((c) => c.criteria.uid === undefined)).toBe(true);
    expect(searchCalls.every((c) => c.criteria.since !== undefined)).toBe(true);
  });

  it("warns once when a pass grows past the per-execution memory budget", async () => {
    const many = Array.from({ length: 1501 }, (_, i) =>
      msg({ uid: i + 1, messageId: `<bulk-${i}@x.com>` })
    );
    const { host } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [box("INBOX", many)],
    });
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});

    await mailSync(host, [INBOX_CHANNEL], RECENT_ISO);

    const budgetWarnings = warn.mock.calls.filter((c) =>
      String(c[0]).includes("Large merged pass")
    );
    expect(budgetWarnings).toHaveLength(1);
    warn.mockRestore();
  });
});

describe("mailSync — Sent handling", () => {
  it("merges an owner Sent reply and an inbound reply into one unread thread", async () => {
    const ownerSent = sentMsg({
      uid: 10,
      messageId: "<root@icloud.com>",
      date: daysAgo(8),
      subject: "Proposal",
      bodyText: "Here's the proposal",
    });
    const reply = msg({
      uid: 20,
      messageId: "<reply@example.com>",
      references: ["<root@icloud.com>"],
      flags: [], // unseen inbound reply
      date: daysAgo(7),
      bodyText: "Sounds good",
    });
    const { host, savedLinks } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [
        box("INBOX", [reply]),
        box(SENT_BOX, [ownerSent], { specialUse: "\\Sent" }),
      ],
    });
    await host.set("state", state({ INBOX: { uidValidity: 1, lastUid: 5 } }));

    await mailSync(host, [INBOX_CHANNEL], RECENT_ISO);

    const link = linkFor(savedLinks, "icloud-mail:thread:root@icloud.com");
    expect(link.unread).toBe(true);
    expect(noteKeys(link)).toEqual(["reply@example.com", "root@icloud.com"]);
  });

  it("reads Sent even when INBOX is not an enabled channel", async () => {
    // The old per-channel pass only read Sent during INBOX's own pass, so a
    // user who enabled Archive and disabled Inbox stopped seeing their own
    // replies entirely.
    const ownerSent = sentMsg({ uid: 40, messageId: "<sent-only@icloud.com>", subject: "FYI" });
    const { host, savedLinks, fetchCalls, selectCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [
        box("Archive", [msg({ uid: 70, messageId: "<archive-70@x.com>" })]),
        box(SENT_BOX, [ownerSent], { specialUse: "\\Sent" }),
      ],
    });

    await mailSync(host, [ARCHIVE_CHANNEL], RECENT_ISO);

    expect(selectCalls).toContain(SENT_BOX);
    expect(fetchCalls.some((c) => c.mailbox === SENT_BOX)).toBe(true);
    const link = linkFor(savedLinks, "icloud-mail:thread:sent-only@icloud.com");
    // Sent is not an enable-able channel, so a Sent-only thread falls back to
    // a real enabled channel — never a null channel, which disable-time
    // archiving could never match.
    expect(link.channelId).toBe("mail:Archive");
    // …and a Sent-only thread Plot has never seen is still an INSERT, so it
    // must carry a real title (an omitted key becomes the literal "Untitled",
    // permanently) and must not notify.
    expect(link.title).toBe("FYI");
    expect(link.unread).toBe(false);
  });

  it("leaves an already-known thread's title and unread alone when only its Sent copy is in the window", async () => {
    const ownerReply = sentMsg({
      uid: 41,
      messageId: "<owner-reply@icloud.com>",
      references: ["<known-root@x.com>"],
      subject: "Re: The real subject",
    });
    const { host, savedLinks } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [
        box("INBOX", []),
        box(SENT_BOX, [ownerReply], { specialUse: "\\Sent" }),
      ],
    });
    await host.set("state", state({ INBOX: { uidValidity: 1, lastUid: 30 } }));
    await host.set("thread:known-root@x.com", { channelId: "mail:INBOX" } satisfies ThreadMeta);

    await mailSync(host, [INBOX_CHANNEL], RECENT_ISO);

    const link = linkFor(savedLinks, "icloud-mail:thread:known-root@x.com");
    // The batch knows neither the thread's real subject nor its read state —
    // both keys must be ABSENT, since a present key of any value overwrites.
    expect("title" in link).toBe(false);
    expect("unread" in link).toBe(false);
  });
});

describe("mailSync — persisted home channel", () => {
  it("keeps a thread's channel once its original folder's message ages out of the window", async () => {
    const archiveRoot = msg({
      uid: 70,
      messageId: "<split-root@x.com>",
      subject: "Kickoff",
      flags: ["\\Seen"],
      date: daysAgo(9),
    });
    const inboxReply = msg({
      uid: 30,
      messageId: "<split-reply@x.com>",
      references: ["<split-root@x.com>"],
      flags: ["\\Seen"],
      date: daysAgo(2),
    });
    const archiveBox = box("Archive", [archiveRoot]);
    const { host, savedLinks, stored } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [box("INBOX", [inboxReply]), archiveBox],
    });

    await mailSync(host, [INBOX_CHANNEL, ARCHIVE_CHANNEL], RECENT_ISO);
    expect(linkFor(savedLinks, "icloud-mail:thread:split-root@x.com").channelId).toBe(
      "mail:Archive"
    );
    expect(stored.get("thread:split-root@x.com")).toEqual({ channelId: "mail:Archive" });

    // The Archive copy ages out of the rescan window: this pass sees the
    // thread only through INBOX. A channel DERIVED from the batch would flip
    // to mail:INBOX here, rewriting link.channel_id and changing what a
    // disable would archive.
    savedLinks.length = 0;
    archiveBox.searchUids = [];
    archiveBox.messagesByUid = new Map();

    await mailSync(host, [INBOX_CHANNEL, ARCHIVE_CHANNEL], RECENT_ISO);

    const link = linkFor(savedLinks, "icloud-mail:thread:split-root@x.com");
    expect(link.channelId).toBe("mail:Archive");
    expect((link.meta as { syncableId?: string }).syncableId).toBe("mail:Archive");
  });
});

describe("mailSync — folder names with a delimiter", () => {
  const NESTED = "Archive/2024";
  const NESTED_CHANNEL: MailChannel = { channelId: "mail:Archive/2024", mailbox: NESTED };

  it("selects, searches and fetches the nested mailbox and round-trips its attachment refs", async () => {
    const withAttachment = msg({
      uid: 70,
      messageId: "<nested@x.com>",
      attachments: [
        {
          partNumber: "2",
          fileName: "invoice.pdf",
          mimeType: "application/pdf",
          size: 10,
          encoding: "base64",
        },
      ],
    });
    const { host, savedLinks, selectCalls, searchCalls, fetchCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [box(NESTED, [withAttachment])],
    });

    await mailSync(host, [NESTED_CHANNEL], RECENT_ISO);

    expect(selectCalls.every((m) => m === NESTED)).toBe(true);
    expect(searchCalls.every((c) => c.mailbox === NESTED)).toBe(true);
    expect(fetchCalls.every((c) => c.mailbox === NESTED)).toBe(true);

    const link = linkFor(savedLinks, "icloud-mail:thread:nested@x.com");
    // `parse` splits on the FIRST ':' only, so the '/' survives the round trip.
    expect(link.channelId).toBe("mail:Archive/2024");
    expect((link.meta as { syncableId?: string }).syncableId).toBe("mail:Archive/2024");

    const refs = (link.notes ?? []).flatMap((n) =>
      (n.actions ?? []).map((a) => (a as { ref?: string }).ref)
    );
    expect(refs).toContain(buildAttachmentRef(NESTED, 70, "2"));
    expect(parseAttachmentRef(refs[0]!)).toEqual({
      mailbox: NESTED,
      uid: 70,
      partNumber: "2",
    });
  });
});

describe("mailSync — to-do ⟷ \\Flagged wiring", () => {
  function flagged(flag: boolean) {
    return box("INBOX", [msg({ uid: 1, messageId: "<root@x.com>", flags: flag ? ["\\Flagged"] : [] })]);
  }
  const known: ThreadMeta = { channelId: "mail:INBOX" };

  it("propagates a message newly flagged in Apple Mail to Plot's to-do state", async () => {
    const { host, stored, setThreadToDo } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [flagged(true)],
    });
    await host.set("auth_actor_id", "actor-1");
    await host.set("state", state({ INBOX: { uidValidity: 1, lastUid: 1 } }));
    await host.set("thread:root@x.com", known);

    await mailSync(host, [INBOX_CHANNEL], RECENT_ISO);

    expect(setThreadToDo).toHaveBeenCalledWith(
      "icloud-mail:thread:root@x.com",
      "actor-1",
      true,
      {}
    );
    expect(stored.get("flagged:root@x.com")).toBe(true);
  });

  it("does not re-propagate once the marker already matches (echo suppression)", async () => {
    const { host, setThreadToDo } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [flagged(true)],
    });
    await host.set("auth_actor_id", "actor-1");
    await host.set("flagged:root@x.com", true); // e.g. onThreadToDoFn's own prior write
    await host.set("state", state({ INBOX: { uidValidity: 1, lastUid: 1 } }));
    await host.set("thread:root@x.com", known);

    await mailSync(host, [INBOX_CHANNEL], RECENT_ISO);

    expect(setThreadToDo).not.toHaveBeenCalled();
  });

  it("seeds the marker for a root ingested from history without propagating a to-do", async () => {
    const { host, stored, setThreadToDo } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [flagged(true)],
    });
    await host.set("auth_actor_id", "actor-1");
    // No stored thread metadata → this root is being ingested for the first
    // time from history, so a years-old \Flagged must not spawn a to-do.

    await mailSync(host, [INBOX_CHANNEL], RECENT_ISO);

    expect(setThreadToDo).not.toHaveBeenCalled();
    expect(stored.get("flagged:root@x.com")).toBe(true);
  });

  it("skips reconciliation entirely with no stored auth_actor_id", async () => {
    const { host, stored, setThreadToDo } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [flagged(true)],
    });
    await host.set("state", state({ INBOX: { uidValidity: 1, lastUid: 1 } }));

    await mailSync(host, [INBOX_CHANNEL], RECENT_ISO);

    expect(setThreadToDo).not.toHaveBeenCalled();
    expect(stored.get("flagged:root@x.com")).toBeUndefined();
  });
});

describe("reconcileTodoFlags", () => {
  /** Minimal MailHost stub — it only ever touches `get`/`set` and
   *  `integrations.setThreadToDo`. */
  function buildHost(opts: { actorId?: string; stored?: Record<string, unknown> }) {
    const store = new Map<string, unknown>(Object.entries(opts.stored ?? {}));
    if (opts.actorId !== undefined) store.set("auth_actor_id", opts.actorId);
    const setThreadToDo = vi.fn(async () => {});
    const host = {
      imap: {} as unknown as Imap,
      smtp: {} as unknown as Smtp,
      integrations: { setThreadToDo } as unknown as Integrations,
      files: {} as unknown as Files,
      appleId: "me@icloud.com",
      appPassword: "pw",
      set: async (key: string, value: unknown) => {
        store.set(key, value);
      },
      get: async (key: string) => store.get(key),
      clear: async (key: string) => {
        store.delete(key);
      },
      channelSyncCompleted: async () => {},
      queueWritebackDrain: async () => {},
    } as unknown as MailHost;
    return { host, store, setThreadToDo };
  }

  function flaggedMsg(flag: boolean, over: Partial<MailMessage> = {}): MailMessage {
    return {
      uid: 1,
      flags: flag ? ["\\Flagged"] : [],
      mailbox: "INBOX",
      messageId: "<root@x.com>",
      date: new Date("2026-07-15T10:00:00Z"),
      subject: "Lunch?",
      ...over,
    };
  }

  const NONE = new Set<string>();

  it("a newly-flagged thread propagates once and updates the marker", async () => {
    const { host, store, setThreadToDo } = buildHost({ actorId: "actor-1" });

    await reconcileTodoFlags(host, [flaggedMsg(true)], NONE);

    expect(setThreadToDo).toHaveBeenCalledWith(
      "icloud-mail:thread:root@x.com",
      "actor-1",
      true,
      {}
    );
    expect(store.get("flagged:root@x.com")).toBe(true);
  });

  it("an unflagged-again thread propagates false", async () => {
    const { host, store, setThreadToDo } = buildHost({
      actorId: "actor-1",
      stored: { "flagged:root@x.com": true },
    });

    await reconcileTodoFlags(host, [flaggedMsg(false)], NONE);

    expect(setThreadToDo).toHaveBeenCalledWith(
      "icloud-mail:thread:root@x.com",
      "actor-1",
      false,
      {}
    );
    expect(store.get("flagged:root@x.com")).toBe(false);
  });

  it("does not call setThreadToDo when the flag state already matches the marker", async () => {
    const { host, setThreadToDo } = buildHost({
      actorId: "actor-1",
      stored: { "flagged:root@x.com": true },
    });

    await reconcileTodoFlags(host, [flaggedMsg(true)], NONE);

    expect(setThreadToDo).not.toHaveBeenCalled();
  });

  it("skips the whole reconciliation with no stored auth_actor_id", async () => {
    const { host, store, setThreadToDo } = buildHost({});

    await reconcileTodoFlags(host, [flaggedMsg(true)], NONE);

    expect(setThreadToDo).not.toHaveBeenCalled();
    expect(store.get("flagged:root@x.com")).toBeUndefined();
  });

  it("seeds the marker without propagating for a root in initialRoots", async () => {
    const { host, store, setThreadToDo } = buildHost({ actorId: "actor-1" });

    await reconcileTodoFlags(host, [flaggedMsg(true)], new Set(["root@x.com"]));

    expect(setThreadToDo).not.toHaveBeenCalled();
    expect(store.get("flagged:root@x.com")).toBe(true);
  });

  it("seeds one root while propagating another in the same merged pass", async () => {
    // Per-root, not per pass: one merged pass can backfill a newly-enabled
    // folder while incrementally syncing the folders that already have cursors.
    const { host, store, setThreadToDo } = buildHost({ actorId: "actor-1" });

    await reconcileTodoFlags(
      host,
      [
        flaggedMsg(true),
        flaggedMsg(true, { uid: 2, messageId: "<fresh@x.com>", mailbox: "Archive" }),
      ],
      new Set(["fresh@x.com"])
    );

    expect(setThreadToDo).toHaveBeenCalledTimes(1);
    expect(setThreadToDo).toHaveBeenCalledWith(
      "icloud-mail:thread:root@x.com",
      "actor-1",
      true,
      {}
    );
    expect(store.get("flagged:fresh@x.com")).toBe(true);
  });

  it("ignores a message with no resolvable thread root", async () => {
    const { host, setThreadToDo } = buildHost({ actorId: "actor-1" });

    await reconcileTodoFlags(host, [flaggedMsg(true, { messageId: undefined })], NONE);

    expect(setThreadToDo).not.toHaveBeenCalled();
  });
});

/** Build a minimal VCALENDAR/VEVENT ICS blob. */
function ics(opts: { method?: string; uid?: string; sequence?: number }): string {
  const lines = ["BEGIN:VCALENDAR", "VERSION:2.0"];
  if (opts.method) lines.push(`METHOD:${opts.method}`);
  lines.push("BEGIN:VEVENT");
  if (opts.uid !== undefined) lines.push(`UID:${opts.uid}`);
  if (opts.sequence !== undefined) lines.push(`SEQUENCE:${opts.sequence}`);
  lines.push("SUMMARY:Team sync");
  lines.push("DTSTART:20260801T140000Z");
  lines.push("END:VEVENT");
  lines.push("END:VCALENDAR");
  return lines.join("\r\n");
}

/** UTF-8 encode an ICS string as the raw bytes `imap.fetchAttachment` returns. */
function icsBytes(icsText: string): Uint8Array {
  return new TextEncoder().encode(icsText);
}

/** The pre-loaded per-root metadata `mailSync` hands `detectCalendarBundles`. */
function metaFor(roots: string[], channelId = "mail:INBOX"): Map<string, ThreadMeta> {
  return new Map(roots.map((r) => [r, { channelId }]));
}

const CALENDAR_PART = {
  partNumber: "2",
  fileName: "invite.ics",
  mimeType: "text/calendar",
  size: 100,
  encoding: "8bit",
};

/** A one-mailbox host with no messages — `detectCalendarBundles` is driven
 *  directly with a message array, so only `fetchAttachment` matters. */
function bundleHost(opts: {
  attachments?: Record<string, Uint8Array>;
  knownEventUids?: string[];
  mailboxes?: string[];
}) {
  return buildFakeHost({
    appleId: "kris@icloud.com",
    mailboxes: (opts.mailboxes ?? ["INBOX"]).map((name) => box(name, [])),
    ...(opts.attachments ? { attachments: opts.attachments } : {}),
    ...(opts.knownEventUids ? { knownEventUids: opts.knownEventUids } : {}),
  });
}

describe("detectCalendarBundles", () => {
  it("classifies a CANCEL invite, keys it by thread root, records it on the root's metadata, and writes a cancel-email marker", async () => {
    const m = msg({ uid: 50, messageId: "<invite@example.com>", attachments: [CALENDAR_PART] });
    const { host, stored } = bundleHost({
      attachments: {
        [buildAttachmentRef("INBOX", 50, "2")]: icsBytes(ics({ method: "CANCEL", uid: "evt-1" })),
      },
    });
    const meta = metaFor(["invite@example.com"]);
    const changed = new Set<string>();

    const bundles = await detectCalendarBundles(
      host,
      "session-1",
      [{ ...m, mailbox: "INBOX" }],
      meta,
      changed
    );

    expect(bundles.get("invite@example.com")).toEqual({
      uid: "evt-1",
      kind: "cancel",
      eventKnown: false,
    });
    // The decision now rides on the root's ThreadMeta (one store document per
    // root, shared with the home-channel resolution) rather than its own key.
    expect(meta.get("invite@example.com")!.bundle).toEqual({
      classified: { uid: "evt-1", kind: "cancel" },
    });
    expect(changed.has("invite@example.com")).toBe(true);
    expect(stored.get("cancel-email:evt-1")).toBeTruthy();
  });

  it("marks eventKnown true when the calendar product has already synced an event for this UID", async () => {
    const m = msg({ uid: 50, messageId: "<invite-known@example.com>", attachments: [CALENDAR_PART] });
    const { host } = bundleHost({
      attachments: {
        [buildAttachmentRef("INBOX", 50, "2")]: icsBytes(
          ics({ method: "CANCEL", uid: "evt-known" })
        ),
      },
      knownEventUids: ["evt-known"],
    });

    const bundles = await detectCalendarBundles(
      host,
      "session-1",
      [{ ...m, mailbox: "INBOX" }],
      metaFor(["invite-known@example.com"]),
      new Set()
    );

    expect(bundles.get("invite-known@example.com")).toEqual({
      uid: "evt-known",
      kind: "cancel",
      eventKnown: true,
    });
  });

  it("classifies a REQUEST/SEQUENCE>0 update and writes NO cancel-email marker", async () => {
    const m = msg({ uid: 51, messageId: "<update@example.com>", attachments: [CALENDAR_PART] });
    const { host, stored } = bundleHost({
      attachments: {
        [buildAttachmentRef("INBOX", 51, "2")]: icsBytes(
          ics({ method: "REQUEST", uid: "evt-2", sequence: 1 })
        ),
      },
    });

    const bundles = await detectCalendarBundles(
      host,
      "session-1",
      [{ ...m, mailbox: "INBOX" }],
      metaFor(["update@example.com"]),
      new Set()
    );

    expect(bundles.get("update@example.com")).toEqual({
      uid: "evt-2",
      kind: "update",
      eventKnown: false,
    });
    expect(stored.get("cancel-email:evt-2")).toBeUndefined();
  });

  it("does not bundle a bare initial invite (REQUEST/SEQUENCE 0)", async () => {
    const m = msg({ uid: 52, messageId: "<bare-invite@example.com>", attachments: [CALENDAR_PART] });
    const { host } = bundleHost({
      attachments: {
        [buildAttachmentRef("INBOX", 52, "2")]: icsBytes(
          ics({ method: "REQUEST", uid: "evt-3", sequence: 0 })
        ),
      },
    });

    const bundles = await detectCalendarBundles(
      host,
      "session-1",
      [{ ...m, mailbox: "INBOX" }],
      metaFor(["bare-invite@example.com"]),
      new Set()
    );

    expect(bundles.has("bare-invite@example.com")).toBe(false);
  });

  it("does not bundle an RSVP reply (METHOD:REPLY)", async () => {
    const m = msg({ uid: 53, messageId: "<rsvp@example.com>", attachments: [CALENDAR_PART] });
    const { host } = bundleHost({
      attachments: {
        [buildAttachmentRef("INBOX", 53, "2")]: icsBytes(
          ics({ method: "REPLY", uid: "evt-4", sequence: 1 })
        ),
      },
    });

    const bundles = await detectCalendarBundles(
      host,
      "session-1",
      [{ ...m, mailbox: "INBOX" }],
      metaFor(["rsvp@example.com"]),
      new Set()
    );

    expect(bundles.has("rsvp@example.com")).toBe(false);
  });

  it("scans every message in a thread — a later CANCEL after an earlier bare invite still bundles", async () => {
    const bareInvite = msg({
      uid: 54,
      messageId: "<root-multi@example.com>",
      date: new Date("2026-07-15T09:00:00Z"),
      attachments: [CALENDAR_PART],
    });
    const cancelUpdate = msg({
      uid: 55,
      messageId: "<followup-multi@example.com>",
      references: ["<root-multi@example.com>"],
      date: new Date("2026-07-15T10:00:00Z"),
      attachments: [CALENDAR_PART],
    });
    const { host } = bundleHost({
      attachments: {
        [buildAttachmentRef("INBOX", 54, "2")]: icsBytes(
          ics({ method: "REQUEST", uid: "evt-5", sequence: 0 })
        ),
        [buildAttachmentRef("INBOX", 55, "2")]: icsBytes(ics({ method: "CANCEL", uid: "evt-5" })),
      },
    });

    const bundles = await detectCalendarBundles(
      host,
      "session-1",
      [
        { ...bareInvite, mailbox: "INBOX" },
        { ...cancelUpdate, mailbox: "INBOX" },
      ],
      metaFor(["root-multi@example.com"]),
      new Set()
    );

    expect(bundles.get("root-multi@example.com")).toEqual({
      uid: "evt-5",
      kind: "cancel",
      eventKnown: false,
    });
  });

  it("a message with no calendar part is completely unaffected: no fetchAttachment call, no bundle", async () => {
    const m = msg({ uid: 56, messageId: "<plain@example.com>" });
    const { host, fetchAttachmentCalls } = bundleHost({});

    const bundles = await detectCalendarBundles(
      host,
      "session-1",
      [{ ...m, mailbox: "INBOX" }],
      metaFor(["plain@example.com"]),
      new Set()
    );

    expect(fetchAttachmentCalls).toHaveLength(0);
    expect(bundles.size).toBe(0);
  });

  it("a non-calendar attachment (e.g. a PDF) is not fetched as a calendar part", async () => {
    const m = msg({
      uid: 57,
      messageId: "<pdf@example.com>",
      attachments: [
        { partNumber: "2", fileName: "invoice.pdf", mimeType: "application/pdf", size: 1000, encoding: "base64" },
      ],
    });
    const { host, fetchAttachmentCalls } = bundleHost({});

    const bundles = await detectCalendarBundles(
      host,
      "session-1",
      [{ ...m, mailbox: "INBOX" }],
      metaFor(["pdf@example.com"]),
      new Set()
    );

    expect(fetchAttachmentCalls).toHaveLength(0);
    expect(bundles.size).toBe(0);
  });

  it("returns an empty map for an empty message list (no I/O)", async () => {
    const { host, fetchAttachmentCalls } = bundleHost({});

    const bundles = await detectCalendarBundles(host, "session-1", [], new Map(), new Set());

    expect(fetchAttachmentCalls).toHaveLength(0);
    expect(bundles.size).toBe(0);
  });

  it("selects the message's own mailbox (e.g. Sent) before fetching its attachment", async () => {
    const m = msg({
      uid: 58,
      messageId: "<from-sent@example.com>",
      from: [{ address: "kris@icloud.com", name: "Kris" }],
      attachments: [{ ...CALENDAR_PART, fileName: "cancel.ics", mimeType: "application/ics" }],
    });
    const { host, fetchAttachmentCalls } = bundleHost({
      mailboxes: ["INBOX", SENT_BOX],
      attachments: {
        [buildAttachmentRef(SENT_BOX, 58, "2")]: icsBytes(ics({ method: "CANCEL", uid: "evt-6" })),
      },
    });

    const bundles = await detectCalendarBundles(
      host,
      "session-1",
      [{ ...m, mailbox: SENT_BOX }],
      metaFor(["from-sent@example.com"]),
      new Set()
    );

    expect(fetchAttachmentCalls).toEqual([{ mailbox: SENT_BOX, uid: 58, partNumber: "2" }]);
    expect(bundles.get("from-sent@example.com")).toEqual({
      uid: "evt-6",
      kind: "cancel",
      eventKnown: false,
    });
  });

  it("reuses a recorded classification and never re-fetches the same root's ICS", async () => {
    const m = msg({ uid: 59, messageId: "<cached@example.com>", attachments: [CALENDAR_PART] });
    const { host, fetchAttachmentCalls } = bundleHost({
      attachments: {
        [buildAttachmentRef("INBOX", 59, "2")]: icsBytes(
          ics({ method: "CANCEL", uid: "evt-cached" })
        ),
      },
    });
    // The same map a later pass would rebuild from the store.
    const meta = metaFor(["cached@example.com"]);
    const merged: MailMessage[] = [{ ...m, mailbox: "INBOX" }];

    const first = await detectCalendarBundles(host, "session-1", merged, meta, new Set());
    expect(first.get("cached@example.com")).toEqual({
      uid: "evt-cached",
      kind: "cancel",
      eventKnown: false,
    });
    expect(fetchAttachmentCalls).toHaveLength(1);

    const second = await detectCalendarBundles(host, "session-1", merged, meta, new Set());
    expect(second.get("cached@example.com")).toEqual({
      uid: "evt-cached",
      kind: "cancel",
      eventKnown: false,
    });
    expect(fetchAttachmentCalls).toHaveLength(1); // still 1 — no re-fetch
  });

  it("keeps returning the bundle once the ICS-bearing message ages out of the recent window", async () => {
    const icsMsg = msg({
      uid: 62,
      messageId: "<root-aged@example.com>",
      date: new Date("2026-06-01T09:00:00Z"),
      attachments: [CALENDAR_PART],
    });
    const followUp = msg({
      uid: 63,
      messageId: "<reply-aged@example.com>",
      references: ["<root-aged@example.com>"],
      date: new Date("2026-07-14T09:00:00Z"),
    });
    const { host, fetchAttachmentCalls } = bundleHost({
      attachments: {
        [buildAttachmentRef("INBOX", 62, "2")]: icsBytes(
          ics({ method: "CANCEL", uid: "evt-aged" })
        ),
      },
    });
    const meta = metaFor(["root-aged@example.com"]);

    const first = await detectCalendarBundles(
      host,
      "session-1",
      [
        { ...icsMsg, mailbox: "INBOX" },
        { ...followUp, mailbox: "INBOX" },
      ],
      meta,
      new Set()
    );
    expect(first.get("root-aged@example.com")).toEqual({
      uid: "evt-aged",
      kind: "cancel",
      eventKnown: false,
    });
    expect(fetchAttachmentCalls).toHaveLength(1);

    // Pass 2: only the in-window reply. Without the recorded decision the root
    // would silently un-bundle, flipping its primary `source` and creating a
    // duplicate link row.
    const second = await detectCalendarBundles(
      host,
      "session-1",
      [{ ...followUp, mailbox: "INBOX" }],
      meta,
      new Set()
    );
    expect(second.get("root-aged@example.com")).toEqual({
      uid: "evt-aged",
      kind: "cancel",
      eventKnown: false,
    });
    expect(fetchAttachmentCalls).toHaveLength(1); // no re-fetch attempted
  });

  it("records an explicit 'no bundle' decision for a bare invite so it is never re-classified", async () => {
    const m = msg({ uid: 64, messageId: "<bare-cached@example.com>", attachments: [CALENDAR_PART] });
    const { host, fetchAttachmentCalls } = bundleHost({
      attachments: {
        [buildAttachmentRef("INBOX", 64, "2")]: icsBytes(
          ics({ method: "REQUEST", uid: "evt-bare", sequence: 0 })
        ),
      },
    });
    const meta = metaFor(["bare-cached@example.com"]);
    const merged: MailMessage[] = [{ ...m, mailbox: "INBOX" }];

    const first = await detectCalendarBundles(host, "session-1", merged, meta, new Set());
    expect(first.has("bare-cached@example.com")).toBe(false);
    expect(fetchAttachmentCalls).toHaveLength(1);
    // "Evaluated, doesn't bundle" must stay distinguishable from "never
    // evaluated", hence the wrapping object.
    expect(meta.get("bare-cached@example.com")!.bundle).toEqual({ classified: null });

    const second = await detectCalendarBundles(host, "session-1", merged, meta, new Set());
    expect(second.has("bare-cached@example.com")).toBe(false);
    expect(fetchAttachmentCalls).toHaveLength(1); // reused the recorded decision
  });
});

describe("mailSync — calendar thread bundling end-to-end", () => {
  it("bundles a CANCEL invite onto an ALREADY-SYNCED event's thread and omits its title key", async () => {
    const cancelMsg = msg({
      uid: 60,
      messageId: "<cancel-e2e@example.com>",
      subject: "Cancelled: Team sync",
      attachments: [{ ...CALENDAR_PART, fileName: "cancel.ics" }],
    });
    const { host, savedLinks, stored } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [box("INBOX", [cancelMsg])],
      attachments: {
        [buildAttachmentRef("INBOX", 60, "2")]: icsBytes(ics({ method: "CANCEL", uid: "evt-e2e" })),
      },
      // The calendar product already owns this event's title.
      knownEventUids: ["evt-e2e"],
    });
    await host.set("state", state({ INBOX: { uidValidity: 1, lastUid: 0 } }));

    await mailSync(host, [INBOX_CHANNEL], RECENT_ISO);

    const link = linkFor(savedLinks, "icloud-mail:thread:cancel-e2e@example.com");
    expect(link.sources).toEqual(["icaluid:evt-e2e"]);
    expect("title" in link).toBe(false);
    expect(stored.get("cancel-email:evt-e2e")).toBeTruthy();
    // The decision is persisted on the root's single metadata document,
    // alongside its home channel.
    expect(stored.get("thread:cancel-e2e@example.com")).toEqual({
      channelId: "mail:INBOX",
      bundle: { classified: { uid: "evt-e2e", kind: "cancel" } },
    });
  });

  it("bundles a CANCEL invite onto a NOT-YET-SYNCED event's thread and SETS the title — never 'Untitled'", async () => {
    const cancelMsg = msg({
      uid: 65,
      messageId: "<cancel-unsynced@example.com>",
      subject: "Cancelled: Offsite planning",
      attachments: [{ ...CALENDAR_PART, fileName: "cancel.ics" }],
    });
    const { host, savedLinks } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [box("INBOX", [cancelMsg])],
      attachments: {
        [buildAttachmentRef("INBOX", 65, "2")]: icsBytes(
          ics({ method: "CANCEL", uid: "evt-unsynced" })
        ),
      },
      // No knownEventUids — the calendar has never synced this UID, so with
      // the title key omitted the runtime's INSERT path would substitute the
      // literal "Untitled" placeholder, permanently.
    });
    await host.set("state", state({ INBOX: { uidValidity: 1, lastUid: 0 } }));

    await mailSync(host, [INBOX_CHANNEL], RECENT_ISO);

    const link = linkFor(savedLinks, "icloud-mail:thread:cancel-unsynced@example.com");
    expect(link.sources).toEqual(["icaluid:evt-unsynced"]);
    expect(link.title).toBe("Cancelled: Offsite planning");
  });

  it("a plain reply with no calendar attachment is unaffected", async () => {
    const plain = msg({ uid: 61, messageId: "<plain-e2e@example.com>", subject: "Just chatting" });
    const { host, savedLinks, fetchAttachmentCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [box("INBOX", [plain])],
    });
    await host.set("state", state({ INBOX: { uidValidity: 1, lastUid: 0 } }));

    await mailSync(host, [INBOX_CHANNEL], RECENT_ISO);

    const link = linkFor(savedLinks, "icloud-mail:thread:plain-e2e@example.com");
    expect(link.sources).toBeUndefined();
    expect(link.title).toBe("Just chatting");
    expect(fetchAttachmentCalls).toHaveLength(0);
  });

  it("re-uses the persisted bundle decision across passes without re-fetching the ICS", async () => {
    const cancelMsg = msg({
      uid: 66,
      messageId: "<persisted-e2e@example.com>",
      subject: "Cancelled: Standup",
      attachments: [{ ...CALENDAR_PART, fileName: "cancel.ics" }],
    });
    const { host, fetchAttachmentCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      mailboxes: [box("INBOX", [cancelMsg])],
      attachments: {
        [buildAttachmentRef("INBOX", 66, "2")]: icsBytes(
          ics({ method: "CANCEL", uid: "evt-persisted" })
        ),
      },
    });

    await mailSync(host, [INBOX_CHANNEL], RECENT_ISO);
    expect(fetchAttachmentCalls).toHaveLength(1);

    await mailSync(host, [INBOX_CHANNEL], RECENT_ISO);
    expect(fetchAttachmentCalls).toHaveLength(1); // read back from the store
  });
});
