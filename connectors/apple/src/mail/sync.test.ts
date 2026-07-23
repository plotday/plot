import { describe, expect, it } from "vitest";
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

import { mailIncrementalSync } from "./sync";
import type { MailHost, MailSyncState } from "./mail-host";

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

  const integrations = {
    saveLinks: async (links: NewLinkWithNotes[]): Promise<(string | null)[]> => {
      savedLinks.push(...links);
      return links.map(() => null);
    },
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

  return { host, stored, savedLinks, searchCalls };
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
