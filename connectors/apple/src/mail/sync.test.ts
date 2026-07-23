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

import { mailIncrementalSync, reconcileTodoFlags } from "./sync";
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

/** Minimal in-memory MailHost — no real IMAP. Captures search() calls and saveLinks() output. */
function buildFakeHost(opts: {
  appleId: string;
  inbox: MailboxFixture;
  sent?: (MailboxFixture & { specialUse?: string }) | null;
}) {
  const stored = new Map<string, unknown>();
  const savedLinks: NewLinkWithNotes[] = [];
  const searchCalls: SearchCall[] = [];
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
      const fixture = mailboxes.get(selected);
      if (!fixture) return [];
      return uids
        .map((uid) => fixture.messagesByUid.get(uid))
        .filter((m): m is ImapMessage => m !== undefined);
    },
    setFlags: async (): Promise<void> => {},
    disconnect: async (): Promise<void> => {},
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
  };

  return { host, stored, savedLinks, searchCalls, setThreadToDo };
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
