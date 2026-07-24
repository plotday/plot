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

import { buildAttachmentRef } from "./attachments";
import {
  detectCalendarBundles,
  mailIncrementalSync,
  mailInitialSync,
  reconcileTodoFlags,
} from "./sync";
import type { MailHost, MailSyncState } from "./mail-host";
import type { MailMessage } from "./transform";

/** One mock mailbox: its selectMailbox() status, search() results, and messages by uid. */
type MailboxFixture = {
  name: string;
  status: ImapMailboxStatus;
  searchUids: number[];
  messagesByUid: Map<number, ImapMessage>;
};

type SearchCall = { mailbox: string; criteria: ImapSearchCriteria };
type FetchCall = { mailbox: string; uids: number[] };
type FetchAttachmentCall = { mailbox: string; uid: number; partNumber: string };

/** Minimal in-memory MailHost — no real IMAP. Captures search() calls and saveLinks() output. */
function buildFakeHost(opts: {
  appleId: string;
  inbox: MailboxFixture;
  sent?: (MailboxFixture & { specialUse?: string }) | null;
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
   * synced yet), which is the common case for these mail-only fixtures —
   * see the eventKnown/title consequence tested in the "calendar thread
   * bundling" describe blocks below.
   */
  knownEventUids?: string[];
}) {
  const stored = new Map<string, unknown>();
  const savedLinks: NewLinkWithNotes[] = [];
  const searchCalls: SearchCall[] = [];
  const fetchCalls: FetchCall[] = [];
  const fetchAttachmentCalls: FetchAttachmentCall[] = [];
  let selected = "INBOX";

  const mailboxes = new Map<string, MailboxFixture>();
  mailboxes.set(opts.inbox.name, opts.inbox);
  if (opts.sent) mailboxes.set(opts.sent.name, opts.sent);

  const imap = {
    connect: async (): Promise<ImapSession> => "session-1",
    listMailboxes: async (): Promise<ImapMailbox[]> => {
      if (!opts.sent) return [];
      return [
        {
          name: opts.sent.name,
          delimiter: "/",
          flags: [],
          specialUse: opts.sent.specialUse ?? "\\Sent",
        },
      ];
    },
    selectMailbox: async (_session: ImapSession, mailbox: string): Promise<ImapMailboxStatus> => {
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
      return mailboxes.get(selected)?.searchUids ?? [];
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
      savedLinks.push(...links);
      return links.map(() => null);
    },
    // Read-direction to-do reconciliation (reconcileTodoFlags) — see
    // write.test.ts (Task 4) for the write-direction marker-ordering
    // coverage, and the tests below for the read-direction wiring.
    setThreadToDo,
  } as unknown as Integrations;

  // Not exercised by this file's tests (sync-in only); satisfies MailHost's
  // required `smtp` field. See write.test.ts (Task 5) for real SMTP mocking.
  const smtp = {} as unknown as Smtp;
  // Not exercised by this file's tests (sync-in only, no attachment
  // download/write-back); satisfies MailHost's required `files` field.
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
    get: async <T>(key: string): Promise<T | undefined> => stored.get(key) as T | undefined,
    clear: async (key: string): Promise<void> => {
      stored.delete(key);
    },
    channelSyncCompleted: async (): Promise<void> => {},
    // Not exercised by this file's tests (sync-in only, no flag write-back);
    // satisfies MailHost's required `queueWritebackDrain` field. See
    // write.test.ts (Task 5) for the real write-back defer/drain coverage.
    queueWritebackDrain: async (): Promise<void> => {},
    knownEventUids: async (): Promise<Set<string>> => new Set(opts.knownEventUids ?? []),
  };

  return { host, stored, savedLinks, searchCalls, fetchCalls, fetchAttachmentCalls, setThreadToDo };
}

const CHANNEL_ID = "mail:INBOX";
const RECENT_ISO = "2026-07-15T00:00:00Z"; // within the DEFAULT/plan history window of "today"

function msg(over: Partial<ImapMessage>): ImapMessage {
  return {
    uid: 1,
    flags: [],
    from: [{ address: "jane@example.com", name: "Jane" }],
    to: [{ address: "kris@icloud.com", name: "Kris" }],
    messageId: "<m1@example.com>",
    date: new Date("2026-07-15T10:00:00Z"),
    subject: "Lunch?",
    bodyText: "Can we meet?",
    ...over,
  };
}

describe("mailIncrementalSync", () => {
  it("merges an owner Sent reply and an inbound reply into one unread thread (Finding 1 guard)", async () => {
    const ownerSent = msg({
      uid: 10,
      messageId: "<root@icloud.com>",
      from: [{ address: "kris@icloud.com", name: "Kris" }],
      to: [{ address: "jane@example.com", name: "Jane" }],
      flags: ["\\Seen"],
      date: new Date("2026-07-15T09:00:00Z"),
      subject: "Proposal",
      bodyText: "Here's the proposal",
    });
    const reply = msg({
      uid: 20,
      messageId: "<reply@example.com>",
      references: ["<root@icloud.com>"],
      from: [{ address: "jane@example.com", name: "Jane" }],
      to: [{ address: "kris@icloud.com", name: "Kris" }],
      flags: [], // unseen inbound reply
      date: new Date("2026-07-15T10:00:00Z"),
      bodyText: "Sounds good",
    });

    const { host, savedLinks } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: {
        name: "INBOX",
        status: {
          name: "INBOX",
          exists: 20,
          recent: 1,
          uidValidity: 1,
          uidNext: 21,
          unseen: 1,
        },
        searchUids: [20],
        messagesByUid: new Map([[20, reply]]),
      },
      sent: {
        name: "Sent Messages",
        specialUse: "\\Sent",
        status: {
          name: "Sent Messages",
          exists: 10,
          recent: 0,
          uidValidity: 1,
          uidNext: 11,
        },
        searchUids: [10],
        messagesByUid: new Map([[10, ownerSent]]),
      },
    });

    const state: MailSyncState = { uidValidity: 1, lastUid: 5, syncHistoryMin: RECENT_ISO };
    await host.set(`state_${CHANNEL_ID}`, state);

    await mailIncrementalSync(host, CHANNEL_ID);

    const rootLinks = savedLinks.filter((l) => l.source === "icloud-mail:thread:root@icloud.com");
    expect(rootLinks).toHaveLength(1);
    expect(rootLinks[0].unread).toBe(true);
  });

  it("bounds the new-mail search by the plan floor instead of fetching the whole mailbox (Finding 2 guard)", async () => {
    const { host, searchCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: {
        name: "INBOX",
        status: {
          name: "INBOX",
          exists: 100000,
          recent: 0,
          uidValidity: 1,
          uidNext: 100000,
          unseen: 0,
        },
        searchUids: [],
        messagesByUid: new Map(),
      },
      sent: null,
    });

    // Dormant account: cursor never advanced past 0.
    const state: MailSyncState = { uidValidity: 1, lastUid: 0, syncHistoryMin: RECENT_ISO };
    await host.set(`state_${CHANNEL_ID}`, state);

    await mailIncrementalSync(host, CHANNEL_ID);

    expect(searchCalls.length).toBeGreaterThan(0);
    // The old bug searched `{ uid: [1..uidNext-1] }` — an unbounded whole-mailbox
    // range. That shape must never appear now; every search must be date-floored.
    expect(searchCalls.every((c) => c.criteria.uid === undefined)).toBe(true);
    expect(searchCalls.some((c) => c.criteria.since !== undefined)).toBe(true);
  });
});

describe("mailIncrementalSync — CONDSTORE modseq gating", () => {
  const SENT_BOX = "Sent Messages";

  /** An INBOX-only fixture carrying a given HIGHESTMODSEQ; searchUids/messagesByUid
   *  are populated with one message so a broken gate (fetching when it
   *  shouldn't) is caught by the fetchCalls/savedLinks assertions. */
  function inboxFixture(highestModSeq: number | undefined, uid: number): MailboxFixture {
    return {
      name: "INBOX",
      status: { name: "INBOX", exists: 1, recent: 0, uidValidity: 1, uidNext: uid + 1, unseen: 0, ...(highestModSeq !== undefined ? { highestModSeq } : {}) },
      searchUids: [uid],
      messagesByUid: new Map([[uid, msg({ uid, messageId: `<inbox-${uid}@x.com>`, flags: [] })]]),
    };
  }

  function sentFixture(highestModSeq: number | undefined, uid: number): MailboxFixture & { specialUse?: string } {
    return {
      name: SENT_BOX,
      specialUse: "\\Sent",
      status: { name: SENT_BOX, exists: 1, recent: 0, uidValidity: 1, uidNext: uid + 1, ...(highestModSeq !== undefined ? { highestModSeq } : {}) },
      searchUids: [uid],
      messagesByUid: new Map([
        [
          uid,
          msg({
            uid,
            messageId: `<sent-${uid}@icloud.com>`,
            from: [{ address: "kris@icloud.com", name: "Kris" }],
            flags: ["\\Seen"],
          }),
        ],
      ]),
    };
  }

  it("gate hit: both mailboxes unchanged — no fetch, no saveLinks, cursors preserved", async () => {
    const { host, savedLinks, fetchCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: inboxFixture(100, 30),
      sent: sentFixture(50, 40),
    });
    const state: MailSyncState = {
      uidValidity: 1,
      lastUid: 5,
      syncHistoryMin: RECENT_ISO,
      lastModSeq: 100,
      sentLastModSeq: 50,
    };
    await host.set(`state_${CHANNEL_ID}`, state);

    await mailIncrementalSync(host, CHANNEL_ID);

    expect(fetchCalls).toHaveLength(0);
    expect(savedLinks).toHaveLength(0);
    const next = await host.get<MailSyncState>(`state_${CHANNEL_ID}`);
    expect(next?.lastModSeq).toBe(100);
    expect(next?.sentLastModSeq).toBe(50);
    expect(next?.lastUid).toBe(5);
  });

  it("gate miss: INBOX modseq advanced — full rescan runs, nextState.lastModSeq updates", async () => {
    const { host, savedLinks, fetchCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: inboxFixture(101, 30),
      sent: null,
    });
    const state: MailSyncState = {
      uidValidity: 1,
      lastUid: 0,
      syncHistoryMin: RECENT_ISO,
      lastModSeq: 100,
    };
    await host.set(`state_${CHANNEL_ID}`, state);

    await mailIncrementalSync(host, CHANNEL_ID);

    expect(fetchCalls.length).toBeGreaterThan(0);
    expect(savedLinks.some((l) => l.source === "icloud-mail:thread:inbox-30@x.com")).toBe(true);
    const next = await host.get<MailSyncState>(`state_${CHANNEL_ID}`);
    expect(next?.lastModSeq).toBe(101);
  });

  it("no CONDSTORE support: highestModSeq undefined — always full rescan", async () => {
    const { host, savedLinks, fetchCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: inboxFixture(undefined, 30),
      sent: null,
    });
    const state: MailSyncState = {
      uidValidity: 1,
      lastUid: 0,
      syncHistoryMin: RECENT_ISO,
      lastModSeq: 100, // stored from a prior CONDSTORE-capable poll; must not matter
    };
    await host.set(`state_${CHANNEL_ID}`, state);

    await mailIncrementalSync(host, CHANNEL_ID);

    expect(fetchCalls.length).toBeGreaterThan(0);
    expect(savedLinks.some((l) => l.source === "icloud-mail:thread:inbox-30@x.com")).toBe(true);
    const next = await host.get<MailSyncState>(`state_${CHANNEL_ID}`);
    expect(next?.lastModSeq).toBeUndefined();
  });

  it("no baseline yet: state.lastModSeq undefined with a defined highestModSeq — full rescan this pass, cursor seeded for next time", async () => {
    const { host, savedLinks, fetchCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: inboxFixture(55, 30),
      sent: null,
    });
    const state: MailSyncState = {
      uidValidity: 1,
      lastUid: 0,
      syncHistoryMin: RECENT_ISO,
      // lastModSeq intentionally omitted — state written before this shipped.
    };
    await host.set(`state_${CHANNEL_ID}`, state);

    await mailIncrementalSync(host, CHANNEL_ID);

    expect(fetchCalls.length).toBeGreaterThan(0);
    expect(savedLinks.some((l) => l.source === "icloud-mail:thread:inbox-30@x.com")).toBe(true);
    const next = await host.get<MailSyncState>(`state_${CHANNEL_ID}`);
    expect(next?.lastModSeq).toBe(55);
  });

  it("INBOX unchanged + Sent changed must not corrupt an INBOX-rooted thread (regression)", async () => {
    // INBOX modseq is unchanged (100 → 100) but Sent advanced (60 → 61). An
    // owner reply sent from Apple Mail (or Plot, whose Sent copy re-ingests)
    // threads onto an already-read INBOX thread without ever touching
    // INBOX's own modseq. The combined gate must still rescan INBOX so the
    // thread is rebuilt from its complete message set, not just the Sent
    // reply — otherwise the reply's "Re: …" subject and owner sender
    // overwrite the thread's real title/author.
    const orig = msg({
      uid: 30,
      messageId: "<orig@x>",
      subject: "Original",
      from: [{ address: "alice@example.com", name: "Alice" }],
      to: [{ address: "kris@icloud.com", name: "Kris" }],
      flags: ["\\Seen"],
      date: new Date("2026-07-14T09:00:00Z"),
    });
    const reply = msg({
      uid: 40,
      messageId: "<reply@x>",
      references: ["<orig@x>"],
      subject: "Re: Original",
      from: [{ address: "kris@icloud.com", name: "Kris" }],
      to: [{ address: "alice@example.com", name: "Alice" }],
      flags: ["\\Seen"],
      date: new Date("2026-07-15T10:00:00Z"),
    });

    const { host, savedLinks, fetchCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: {
        name: "INBOX",
        status: {
          name: "INBOX",
          exists: 1,
          recent: 0,
          uidValidity: 1,
          uidNext: 31,
          unseen: 0,
          highestModSeq: 100, // unchanged from state.lastModSeq below
        },
        searchUids: [30],
        messagesByUid: new Map([[30, orig]]),
      },
      sent: {
        name: SENT_BOX,
        specialUse: "\\Sent",
        status: {
          name: SENT_BOX,
          exists: 1,
          recent: 0,
          uidValidity: 1,
          uidNext: 41,
          highestModSeq: 61, // advanced from state.sentLastModSeq below
        },
        searchUids: [40],
        messagesByUid: new Map([[40, reply]]),
      },
    });

    const state: MailSyncState = {
      uidValidity: 1,
      lastUid: 25,
      syncHistoryMin: RECENT_ISO,
      lastModSeq: 100,
      sentLastModSeq: 60,
    };
    await host.set(`state_${CHANNEL_ID}`, state);

    await mailIncrementalSync(host, CHANNEL_ID);

    // Proves INBOX was rescanned even though its own modseq didn't move.
    expect(fetchCalls.some((c) => c.mailbox === "INBOX")).toBe(true);

    const rootLinks = savedLinks.filter((l) => l.source === "icloud-mail:thread:orig@x");
    expect(rootLinks).toHaveLength(1);
    expect(rootLinks[0].title).toBe("Original");
    expect((rootLinks[0].author as { email?: string } | undefined)?.email).toBe(
      "alice@example.com"
    );
  });

  it("combined gate: INBOX unchanged, Sent advanced — BOTH mailboxes are fetched", async () => {
    const { host, savedLinks, fetchCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: inboxFixture(100, 30),
      sent: sentFixture(61, 40),
    });
    const state: MailSyncState = {
      uidValidity: 1,
      lastUid: 5,
      syncHistoryMin: RECENT_ISO,
      lastModSeq: 100,
      sentLastModSeq: 60,
    };
    await host.set(`state_${CHANNEL_ID}`, state);

    await mailIncrementalSync(host, CHANNEL_ID);

    // A change on either side must rescan both, so a thread rooted in the
    // unchanged mailbox is never rebuilt from a partial message set.
    expect(fetchCalls.some((c) => c.mailbox === "INBOX")).toBe(true);
    expect(fetchCalls.some((c) => c.mailbox === SENT_BOX)).toBe(true);
    expect(savedLinks.some((l) => l.source === "icloud-mail:thread:sent-40@icloud.com")).toBe(true);
    expect(savedLinks.some((l) => l.source === "icloud-mail:thread:inbox-30@x.com")).toBe(true);
    const next = await host.get<MailSyncState>(`state_${CHANNEL_ID}`);
    expect(next?.lastModSeq).toBe(100);
    expect(next?.sentLastModSeq).toBe(61);
  });

  it("combined gate: INBOX advanced, Sent unchanged — BOTH mailboxes are fetched", async () => {
    const { host, savedLinks, fetchCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: inboxFixture(101, 30),
      sent: sentFixture(50, 40),
    });
    const state: MailSyncState = {
      uidValidity: 1,
      lastUid: 0,
      syncHistoryMin: RECENT_ISO,
      lastModSeq: 100,
      sentLastModSeq: 50,
    };
    await host.set(`state_${CHANNEL_ID}`, state);

    await mailIncrementalSync(host, CHANNEL_ID);

    // A change on either side must rescan both, so a thread rooted in the
    // unchanged mailbox is never rebuilt from a partial message set.
    expect(fetchCalls.some((c) => c.mailbox === "INBOX")).toBe(true);
    expect(fetchCalls.some((c) => c.mailbox === SENT_BOX)).toBe(true);
    expect(savedLinks.some((l) => l.source === "icloud-mail:thread:inbox-30@x.com")).toBe(true);
    expect(savedLinks.some((l) => l.source === "icloud-mail:thread:sent-40@icloud.com")).toBe(true);
    const next = await host.get<MailSyncState>(`state_${CHANNEL_ID}`);
    expect(next?.lastModSeq).toBe(101);
    expect(next?.sentLastModSeq).toBe(50);
  });

  it("runInitialBackfill persists lastModSeq and sentLastModSeq", async () => {
    const { host } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: inboxFixture(77, 30),
      sent: sentFixture(33, 40),
    });

    await mailInitialSync(host, "INBOX", CHANNEL_ID, undefined);

    const state = await host.get<MailSyncState>(`state_${CHANNEL_ID}`);
    expect(state?.lastModSeq).toBe(77);
    expect(state?.sentLastModSeq).toBe(33);
  });

  it("runInitialBackfill persists lastModSeq without a Sent box (sentLastModSeq stays undefined)", async () => {
    const { host } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: inboxFixture(77, 30),
      sent: null,
    });

    await mailInitialSync(host, "INBOX", CHANNEL_ID, undefined);

    const state = await host.get<MailSyncState>(`state_${CHANNEL_ID}`);
    expect(state?.lastModSeq).toBe(77);
    expect(state?.sentLastModSeq).toBeUndefined();
  });
});

describe("mailIncrementalSync — to-do ⟷ \\Flagged wiring", () => {
  /** A single-message INBOX fixture, flagged or not, for exercising the
   *  reconcileTodoFlags call sites inside runInitialBackfill /
   *  mailIncrementalSync end-to-end (as opposed to the direct
   *  `reconcileTodoFlags` unit tests below). */
  function flaggedFixture(flagged: boolean) {
    return {
      name: "INBOX",
      status: { name: "INBOX", exists: 1, recent: 0, uidValidity: 1, uidNext: 2, unseen: 0 },
      searchUids: [1],
      messagesByUid: new Map([
        [
          1,
          msg({
            uid: 1,
            messageId: "<root@x.com>",
            flags: flagged ? ["\\Flagged"] : [],
          }),
        ],
      ]),
    };
  }

  it("propagates a message newly flagged in Apple Mail to Plot's to-do state", async () => {
    const { host, stored, setThreadToDo } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: flaggedFixture(true),
      sent: null,
    });
    await host.set("auth_actor_id", "actor-1");
    await host.set(`state_${CHANNEL_ID}`, {
      uidValidity: 1,
      lastUid: 0,
      syncHistoryMin: RECENT_ISO,
    } satisfies MailSyncState);

    await mailIncrementalSync(host, CHANNEL_ID);

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
      inbox: flaggedFixture(true),
      sent: null,
    });
    await host.set("auth_actor_id", "actor-1");
    await host.set("flagged:root@x.com", true); // e.g. onThreadToDoFn's own prior write
    await host.set(`state_${CHANNEL_ID}`, {
      uidValidity: 1,
      lastUid: 0,
      syncHistoryMin: RECENT_ISO,
    } satisfies MailSyncState);

    await mailIncrementalSync(host, CHANNEL_ID);

    expect(setThreadToDo).not.toHaveBeenCalled();
  });

  it("seeds the marker on initial sync without propagating a to-do", async () => {
    const { host, stored, setThreadToDo } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: flaggedFixture(true),
      sent: null,
    });
    await host.set("auth_actor_id", "actor-1");
    // No `state_<channelId>` cursor stored → mailIncrementalSync takes the
    // "no cursor yet" branch and runs a full initial backfill.

    await mailIncrementalSync(host, CHANNEL_ID);

    expect(setThreadToDo).not.toHaveBeenCalled();
    expect(stored.get("flagged:root@x.com")).toBe(true);
  });

  it("skips reconciliation entirely with no stored auth_actor_id", async () => {
    const { host, stored, setThreadToDo } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: flaggedFixture(true),
      sent: null,
    });
    await host.set(`state_${CHANNEL_ID}`, {
      uidValidity: 1,
      lastUid: 0,
      syncHistoryMin: RECENT_ISO,
    } satisfies MailSyncState);

    await mailIncrementalSync(host, CHANNEL_ID);

    expect(setThreadToDo).not.toHaveBeenCalled();
    expect(stored.get("flagged:root@x.com")).toBeUndefined();
  });
});

describe("reconcileTodoFlags", () => {
  /** Minimal MailHost stub for reconcileTodoFlags' unit tests — it only
   *  ever touches `get`/`set` and `integrations.setThreadToDo`. */
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

  function flaggedMsg(flagged: boolean, over: Partial<MailMessage> = {}): MailMessage {
    return {
      uid: 1,
      flags: flagged ? ["\\Flagged"] : [],
      mailbox: "INBOX",
      messageId: "<root@x.com>",
      date: new Date("2026-07-15T10:00:00Z"),
      subject: "Lunch?",
      ...over,
    };
  }

  it("a newly-flagged thread propagates once and updates the marker", async () => {
    const { host, store, setThreadToDo } = buildHost({ actorId: "actor-1" });

    await reconcileTodoFlags(host, [flaggedMsg(true)], false);

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

    await reconcileTodoFlags(host, [flaggedMsg(false)], false);

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

    await reconcileTodoFlags(host, [flaggedMsg(true)], false);

    expect(setThreadToDo).not.toHaveBeenCalled();
  });

  it("skips the whole reconciliation with no stored auth_actor_id", async () => {
    const { host, store, setThreadToDo } = buildHost({});

    await reconcileTodoFlags(host, [flaggedMsg(true)], false);

    expect(setThreadToDo).not.toHaveBeenCalled();
    expect(store.get("flagged:root@x.com")).toBeUndefined();
  });

  it("on initial sync, seeds the marker but never calls setThreadToDo", async () => {
    const { host, store, setThreadToDo } = buildHost({ actorId: "actor-1" });

    await reconcileTodoFlags(host, [flaggedMsg(true)], true);

    expect(setThreadToDo).not.toHaveBeenCalled();
    expect(store.get("flagged:root@x.com")).toBe(true);
  });

  it("ignores a message with no resolvable thread root", async () => {
    const { host, setThreadToDo } = buildHost({ actorId: "actor-1" });

    await reconcileTodoFlags(host, [flaggedMsg(true, { messageId: undefined })], false);

    expect(setThreadToDo).not.toHaveBeenCalled();
  });
});

/** Build a minimal VCALENDAR/VEVENT ICS blob (same shape as
 *  calendar-bundle.test.ts's helper — duplicated locally per this file's
 *  existing convention of self-contained fixtures, see `msg()` above). */
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

describe("detectCalendarBundles", () => {
  it("classifies a CANCEL invite, returns it keyed by thread root, and writes a cancel-email marker", async () => {
    const m = msg({
      uid: 50,
      messageId: "<invite@example.com>",
      attachments: [
        { partNumber: "2", fileName: "invite.ics", mimeType: "text/calendar", size: 100, encoding: "8bit" },
      ],
    });
    const bytes = icsBytes(ics({ method: "CANCEL", uid: "evt-1" }));
    const { host, stored } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: { name: "INBOX", status: { name: "INBOX", exists: 1, recent: 0, uidValidity: 1, uidNext: 2 }, searchUids: [], messagesByUid: new Map() },
      sent: null,
      attachments: { [buildAttachmentRef("INBOX", 50, "2")]: bytes },
    });

    const merged: MailMessage[] = [{ ...m, mailbox: "INBOX" }];
    const bundles = await detectCalendarBundles(host, "session-1", merged);

    expect(bundles.get("invite@example.com")).toEqual({ uid: "evt-1", kind: "cancel", eventKnown: false });
    expect(stored.get("cancel-email:evt-1")).toBeTruthy();
  });

  it("marks eventKnown true when the calendar product has already synced an event for this UID (FIX 1)", async () => {
    const m = msg({
      uid: 50,
      messageId: "<invite-known@example.com>",
      attachments: [
        { partNumber: "2", fileName: "invite.ics", mimeType: "text/calendar", size: 100, encoding: "8bit" },
      ],
    });
    const bytes = icsBytes(ics({ method: "CANCEL", uid: "evt-known" }));
    const { host } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: { name: "INBOX", status: { name: "INBOX", exists: 1, recent: 0, uidValidity: 1, uidNext: 2 }, searchUids: [], messagesByUid: new Map() },
      sent: null,
      attachments: { [buildAttachmentRef("INBOX", 50, "2")]: bytes },
      knownEventUids: ["evt-known"],
    });

    const merged: MailMessage[] = [{ ...m, mailbox: "INBOX" }];
    const bundles = await detectCalendarBundles(host, "session-1", merged);

    expect(bundles.get("invite-known@example.com")).toEqual({
      uid: "evt-known",
      kind: "cancel",
      eventKnown: true,
    });
  });

  it("classifies a REQUEST/SEQUENCE>0 update, returns it, and writes NO cancel-email marker", async () => {
    const m = msg({
      uid: 51,
      messageId: "<update@example.com>",
      attachments: [
        { partNumber: "2", fileName: "update.ics", mimeType: "text/calendar", size: 100, encoding: "8bit" },
      ],
    });
    const bytes = icsBytes(ics({ method: "REQUEST", uid: "evt-2", sequence: 1 }));
    const { host, stored } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: { name: "INBOX", status: { name: "INBOX", exists: 1, recent: 0, uidValidity: 1, uidNext: 2 }, searchUids: [], messagesByUid: new Map() },
      sent: null,
      attachments: { [buildAttachmentRef("INBOX", 51, "2")]: bytes },
    });

    const merged: MailMessage[] = [{ ...m, mailbox: "INBOX" }];
    const bundles = await detectCalendarBundles(host, "session-1", merged);

    expect(bundles.get("update@example.com")).toEqual({ uid: "evt-2", kind: "update", eventKnown: false });
    expect(stored.get("cancel-email:evt-2")).toBeUndefined();
  });

  it("does not bundle a bare initial invite (REQUEST/SEQUENCE 0)", async () => {
    const m = msg({
      uid: 52,
      messageId: "<bare-invite@example.com>",
      attachments: [
        { partNumber: "2", fileName: "invite.ics", mimeType: "text/calendar", size: 100, encoding: "8bit" },
      ],
    });
    const bytes = icsBytes(ics({ method: "REQUEST", uid: "evt-3", sequence: 0 }));
    const { host } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: { name: "INBOX", status: { name: "INBOX", exists: 1, recent: 0, uidValidity: 1, uidNext: 2 }, searchUids: [], messagesByUid: new Map() },
      sent: null,
      attachments: { [buildAttachmentRef("INBOX", 52, "2")]: bytes },
    });

    const merged: MailMessage[] = [{ ...m, mailbox: "INBOX" }];
    const bundles = await detectCalendarBundles(host, "session-1", merged);

    expect(bundles.has("bare-invite@example.com")).toBe(false);
  });

  it("does not bundle an RSVP reply (METHOD:REPLY)", async () => {
    const m = msg({
      uid: 53,
      messageId: "<rsvp@example.com>",
      attachments: [
        { partNumber: "2", fileName: "reply.ics", mimeType: "text/calendar", size: 100, encoding: "8bit" },
      ],
    });
    const bytes = icsBytes(ics({ method: "REPLY", uid: "evt-4", sequence: 1 }));
    const { host } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: { name: "INBOX", status: { name: "INBOX", exists: 1, recent: 0, uidValidity: 1, uidNext: 2 }, searchUids: [], messagesByUid: new Map() },
      sent: null,
      attachments: { [buildAttachmentRef("INBOX", 53, "2")]: bytes },
    });

    const merged: MailMessage[] = [{ ...m, mailbox: "INBOX" }];
    const bundles = await detectCalendarBundles(host, "session-1", merged);

    expect(bundles.has("rsvp@example.com")).toBe(false);
  });

  it("scans every message in a thread, not just the first — a later CANCEL after an earlier bare invite still bundles", async () => {
    const bareInvite = msg({
      uid: 54,
      messageId: "<root-multi@example.com>",
      date: new Date("2026-07-15T09:00:00Z"),
      attachments: [
        { partNumber: "2", fileName: "invite.ics", mimeType: "text/calendar", size: 100, encoding: "8bit" },
      ],
    });
    const cancelUpdate = msg({
      uid: 55,
      messageId: "<followup-multi@example.com>",
      references: ["<root-multi@example.com>"],
      date: new Date("2026-07-15T10:00:00Z"),
      attachments: [
        { partNumber: "2", fileName: "cancel.ics", mimeType: "text/calendar", size: 100, encoding: "8bit" },
      ],
    });
    const { host } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: { name: "INBOX", status: { name: "INBOX", exists: 1, recent: 0, uidValidity: 1, uidNext: 2 }, searchUids: [], messagesByUid: new Map() },
      sent: null,
      attachments: {
        [buildAttachmentRef("INBOX", 54, "2")]: icsBytes(ics({ method: "REQUEST", uid: "evt-5", sequence: 0 })),
        [buildAttachmentRef("INBOX", 55, "2")]: icsBytes(ics({ method: "CANCEL", uid: "evt-5" })),
      },
    });

    const merged: MailMessage[] = [
      { ...bareInvite, mailbox: "INBOX" },
      { ...cancelUpdate, mailbox: "INBOX" },
    ];
    const bundles = await detectCalendarBundles(host, "session-1", merged);

    expect(bundles.get("root-multi@example.com")).toEqual({ uid: "evt-5", kind: "cancel", eventKnown: false });
  });

  it("a message with no calendar part is completely unaffected: no fetchAttachment call, no bundle", async () => {
    const m = msg({ uid: 56, messageId: "<plain@example.com>" });
    const { host, fetchAttachmentCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: { name: "INBOX", status: { name: "INBOX", exists: 1, recent: 0, uidValidity: 1, uidNext: 2 }, searchUids: [], messagesByUid: new Map() },
      sent: null,
    });

    const merged: MailMessage[] = [{ ...m, mailbox: "INBOX" }];
    const bundles = await detectCalendarBundles(host, "session-1", merged);

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
    const { host, fetchAttachmentCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: { name: "INBOX", status: { name: "INBOX", exists: 1, recent: 0, uidValidity: 1, uidNext: 2 }, searchUids: [], messagesByUid: new Map() },
      sent: null,
    });

    const merged: MailMessage[] = [{ ...m, mailbox: "INBOX" }];
    const bundles = await detectCalendarBundles(host, "session-1", merged);

    expect(fetchAttachmentCalls).toHaveLength(0);
    expect(bundles.size).toBe(0);
  });

  it("returns an empty map for an empty message list (no I/O)", async () => {
    const { host, fetchAttachmentCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: { name: "INBOX", status: { name: "INBOX", exists: 0, recent: 0, uidValidity: 1, uidNext: 1 }, searchUids: [], messagesByUid: new Map() },
      sent: null,
    });

    const bundles = await detectCalendarBundles(host, "session-1", []);

    expect(fetchAttachmentCalls).toHaveLength(0);
    expect(bundles.size).toBe(0);
  });

  it("selects the message's own mailbox (e.g. Sent) before fetching its attachment", async () => {
    const m = msg({
      uid: 58,
      messageId: "<from-sent@example.com>",
      from: [{ address: "kris@icloud.com", name: "Kris" }],
      attachments: [
        { partNumber: "2", fileName: "cancel.ics", mimeType: "application/ics", size: 100, encoding: "8bit" },
      ],
    });
    const { host, fetchAttachmentCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: { name: "INBOX", status: { name: "INBOX", exists: 0, recent: 0, uidValidity: 1, uidNext: 1 }, searchUids: [], messagesByUid: new Map() },
      sent: {
        name: "Sent Messages",
        specialUse: "\\Sent",
        status: { name: "Sent Messages", exists: 1, recent: 0, uidValidity: 1, uidNext: 2 },
        searchUids: [],
        messagesByUid: new Map(),
      },
      attachments: {
        [buildAttachmentRef("Sent Messages", 58, "2")]: icsBytes(ics({ method: "CANCEL", uid: "evt-6" })),
      },
    });

    const merged: MailMessage[] = [{ ...m, mailbox: "Sent Messages" }];
    const bundles = await detectCalendarBundles(host, "session-1", merged);

    expect(fetchAttachmentCalls).toEqual([{ mailbox: "Sent Messages", uid: 58, partNumber: "2" }]);
    expect(bundles.get("from-sent@example.com")).toEqual({ uid: "evt-6", kind: "cancel", eventKnown: false });
  });

  it("persists the classification and never re-fetches the same root's ICS on a later pass (FIX 4)", async () => {
    const m = msg({
      uid: 59,
      messageId: "<cached@example.com>",
      attachments: [
        { partNumber: "2", fileName: "cancel.ics", mimeType: "text/calendar", size: 100, encoding: "8bit" },
      ],
    });
    const { host, fetchAttachmentCalls, stored } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: { name: "INBOX", status: { name: "INBOX", exists: 1, recent: 0, uidValidity: 1, uidNext: 2 }, searchUids: [], messagesByUid: new Map() },
      sent: null,
      attachments: { [buildAttachmentRef("INBOX", 59, "2")]: icsBytes(ics({ method: "CANCEL", uid: "evt-cached" })) },
    });

    const merged: MailMessage[] = [{ ...m, mailbox: "INBOX" }];
    const first = await detectCalendarBundles(host, "session-1", merged);
    expect(first.get("cached@example.com")).toEqual({ uid: "evt-cached", kind: "cancel", eventKnown: false });
    expect(fetchAttachmentCalls).toHaveLength(1);
    expect(stored.get("bundle:cached@example.com")).toEqual({
      classified: { uid: "evt-cached", kind: "cancel" },
    });

    // A second pass over the SAME message set must reuse the persisted
    // decision instead of re-fetching the ICS attachment.
    const second = await detectCalendarBundles(host, "session-1", merged);
    expect(second.get("cached@example.com")).toEqual({ uid: "evt-cached", kind: "cancel", eventKnown: false });
    expect(fetchAttachmentCalls).toHaveLength(1); // still 1 — no re-fetch
  });

  it("keeps returning the bundle once the ICS-bearing message ages out of the recent window (FIX 4 correctness)", async () => {
    const icsMsg = msg({
      uid: 62,
      messageId: "<root-aged@example.com>",
      date: new Date("2026-06-01T09:00:00Z"),
      attachments: [
        { partNumber: "2", fileName: "cancel.ics", mimeType: "text/calendar", size: 100, encoding: "8bit" },
      ],
    });
    const followUp = msg({
      uid: 63,
      messageId: "<reply-aged@example.com>",
      references: ["<root-aged@example.com>"],
      date: new Date("2026-07-14T09:00:00Z"),
    });
    const { host, fetchAttachmentCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: { name: "INBOX", status: { name: "INBOX", exists: 1, recent: 0, uidValidity: 1, uidNext: 2 }, searchUids: [], messagesByUid: new Map() },
      sent: null,
      attachments: { [buildAttachmentRef("INBOX", 62, "2")]: icsBytes(ics({ method: "CANCEL", uid: "evt-aged" })) },
    });

    // Pass 1: both messages present, ICS-bearing message classified.
    const first = await detectCalendarBundles(host, "session-1", [
      { ...icsMsg, mailbox: "INBOX" },
      { ...followUp, mailbox: "INBOX" },
    ]);
    expect(first.get("root-aged@example.com")).toEqual({ uid: "evt-aged", kind: "cancel", eventKnown: false });
    expect(fetchAttachmentCalls).toHaveLength(1);

    // Pass 2: simulates the ICS-bearing message aging out of the 30-day
    // recent-window rescan — only the follow-up reply is in this pass's
    // `messages`. Without the persisted decision, this root would find no
    // calendar part at all and silently un-bundle — flipping the DB's
    // primary `source` and creating a duplicate link row (see FIX 4's
    // doc). The cached decision must still apply.
    const second = await detectCalendarBundles(host, "session-1", [
      { ...followUp, mailbox: "INBOX" },
    ]);
    expect(second.get("root-aged@example.com")).toEqual({ uid: "evt-aged", kind: "cancel", eventKnown: false });
    expect(fetchAttachmentCalls).toHaveLength(1); // no re-fetch attempted
  });

  it("persists an explicit 'no bundle' decision for a bare invite so it is never re-classified (FIX 4)", async () => {
    const m = msg({
      uid: 64,
      messageId: "<bare-cached@example.com>",
      attachments: [
        { partNumber: "2", fileName: "invite.ics", mimeType: "text/calendar", size: 100, encoding: "8bit" },
      ],
    });
    const { host, fetchAttachmentCalls, stored } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: { name: "INBOX", status: { name: "INBOX", exists: 1, recent: 0, uidValidity: 1, uidNext: 2 }, searchUids: [], messagesByUid: new Map() },
      sent: null,
      attachments: {
        [buildAttachmentRef("INBOX", 64, "2")]: icsBytes(ics({ method: "REQUEST", uid: "evt-bare", sequence: 0 })),
      },
    });

    const merged: MailMessage[] = [{ ...m, mailbox: "INBOX" }];
    const first = await detectCalendarBundles(host, "session-1", merged);
    expect(first.has("bare-cached@example.com")).toBe(false);
    expect(fetchAttachmentCalls).toHaveLength(1);
    expect(stored.get("bundle:bare-cached@example.com")).toEqual({ classified: null });

    const second = await detectCalendarBundles(host, "session-1", merged);
    expect(second.has("bare-cached@example.com")).toBe(false);
    expect(fetchAttachmentCalls).toHaveLength(1); // still 1 — reused the cached "no bundle" decision
  });
});

describe("mailIncrementalSync — calendar thread bundling end-to-end", () => {
  it("bundles a CANCEL invite email onto an ALREADY-SYNCED event's thread and omits its title key", async () => {
    const cancelMsg = msg({
      uid: 60,
      messageId: "<cancel-e2e@example.com>",
      subject: "Cancelled: Team sync",
      attachments: [
        { partNumber: "2", fileName: "cancel.ics", mimeType: "text/calendar", size: 100, encoding: "8bit" },
      ],
    });
    const { host, savedLinks, stored } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: {
        name: "INBOX",
        status: { name: "INBOX", exists: 1, recent: 1, uidValidity: 1, uidNext: 61, unseen: 1 },
        searchUids: [60],
        messagesByUid: new Map([[60, cancelMsg]]),
      },
      sent: null,
      attachments: {
        [buildAttachmentRef("INBOX", 60, "2")]: icsBytes(ics({ method: "CANCEL", uid: "evt-e2e" })),
      },
      // The calendar product has already synced an event for "evt-e2e" —
      // the calendar owns the title, so it must be omitted here.
      knownEventUids: ["evt-e2e"],
    });

    const state: MailSyncState = { uidValidity: 1, lastUid: 0, syncHistoryMin: RECENT_ISO };
    await host.set(`state_${CHANNEL_ID}`, state);

    await mailIncrementalSync(host, CHANNEL_ID);

    const link = savedLinks.find((l) => l.source === "icloud-mail:thread:cancel-e2e@example.com");
    expect(link).toBeDefined();
    expect(link!.sources).toEqual(["icaluid:evt-e2e"]);
    expect("title" in link!).toBe(false);
    expect(stored.get("cancel-email:evt-e2e")).toBeTruthy();
  });

  it("FIX 1: bundles a CANCEL invite email onto a NOT-YET-SYNCED event's thread and SETS the title from the subject — never 'Untitled'", async () => {
    const cancelMsg = msg({
      uid: 65,
      messageId: "<cancel-unsynced@example.com>",
      subject: "Cancelled: Offsite planning",
      attachments: [
        { partNumber: "2", fileName: "cancel.ics", mimeType: "text/calendar", size: 100, encoding: "8bit" },
      ],
    });
    const { host, savedLinks } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: {
        name: "INBOX",
        status: { name: "INBOX", exists: 1, recent: 1, uidValidity: 1, uidNext: 66, unseen: 1 },
        searchUids: [65],
        messagesByUid: new Map([[65, cancelMsg]]),
      },
      sent: null,
      attachments: {
        [buildAttachmentRef("INBOX", 65, "2")]: icsBytes(ics({ method: "CANCEL", uid: "evt-unsynced" })),
      },
      // No knownEventUids — the calendar product (mail-only setup, disabled
      // calendar, or an event cancelled before it ever synced) has never
      // synced this UID. Before FIX 1 this thread would have shipped with
      // its `title` key omitted, and the runtime's INSERT path would
      // substitute the literal "Untitled" placeholder — permanently.
    });

    const state: MailSyncState = { uidValidity: 1, lastUid: 0, syncHistoryMin: RECENT_ISO };
    await host.set(`state_${CHANNEL_ID}`, state);

    await mailIncrementalSync(host, CHANNEL_ID);

    const link = savedLinks.find((l) => l.source === "icloud-mail:thread:cancel-unsynced@example.com");
    expect(link).toBeDefined();
    // Still bundles — thread convergence with the calendar event is never
    // skipped, even though the calendar hasn't synced it yet.
    expect(link!.sources).toEqual(["icaluid:evt-unsynced"]);
    // But `title` IS set — no "Untitled" fallback.
    expect(link!.title).toBe("Cancelled: Offsite planning");
  });

  it("a plain reply with no calendar attachment is unaffected: no icaluid, title present, no attachment fetch", async () => {
    const plain = msg({ uid: 61, messageId: "<plain-e2e@example.com>", subject: "Just chatting" });
    const { host, savedLinks, fetchAttachmentCalls } = buildFakeHost({
      appleId: "kris@icloud.com",
      inbox: {
        name: "INBOX",
        status: { name: "INBOX", exists: 1, recent: 1, uidValidity: 1, uidNext: 62, unseen: 1 },
        searchUids: [61],
        messagesByUid: new Map([[61, plain]]),
      },
      sent: null,
    });

    const state: MailSyncState = { uidValidity: 1, lastUid: 0, syncHistoryMin: RECENT_ISO };
    await host.set(`state_${CHANNEL_ID}`, state);

    await mailIncrementalSync(host, CHANNEL_ID);

    const link = savedLinks.find((l) => l.source === "icloud-mail:thread:plain-e2e@example.com");
    expect(link).toBeDefined();
    expect(link!.sources).toBeUndefined();
    expect(link!.title).toBe("Just chatting");
    expect(fetchAttachmentCalls).toHaveLength(0);
  });
});
