import { describe, expect, it } from "vitest";
import type { ImapMessage } from "@plotday/twister/tools/imap";

import { fetchOriginalMessage, resolveThreadMessages } from "./imap-fetch";
import type { MailHost } from "./mail-host";

function mockHost(messagesByUid: Record<number, Partial<ImapMessage>>): {
  host: MailHost;
  calls: { searched: unknown[]; selected: string[] };
} {
  const calls = { searched: [] as unknown[], selected: [] as string[] };
  const uids = Object.keys(messagesByUid).map(Number);
  const imap = {
    connect: async () => "session",
    disconnect: async () => {},
    listMailboxes: async () => [],
    selectMailbox: async (_s: string, box: string) => {
      calls.selected.push(box);
      return { name: box, exists: 0, recent: 0, uidValidity: 1, uidNext: 100 };
    },
    search: async (_s: string, criteria: unknown) => {
      calls.searched.push(criteria);
      return uids;
    },
    fetchMessages: async (_s: string, u: number[]) =>
      u.map((uid) => ({ uid, flags: [], ...messagesByUid[uid] }) as ImapMessage),
    setFlags: async () => {},
  };
  const host = {
    imap,
    integrations: {} as never,
    smtp: {} as never,
    appleId: "me@icloud.com",
    appPassword: "pw",
    set: async () => {},
    get: async () => undefined,
    clear: async () => {},
    channelSyncCompleted: async () => {},
  } as unknown as MailHost;
  return { host, calls };
}

describe("resolveThreadMessages", () => {
  it("keeps only messages whose thread root matches and returns the latest", async () => {
    const { host, calls } = mockHost({
      1: {
        messageId: "<root@x.com>",
        subject: "Lunch?",
        date: new Date("2026-07-15T10:00:00Z"),
      },
      2: {
        messageId: "<reply@x.com>",
        references: ["<root@x.com>"],
        subject: "Re: Lunch?",
        date: new Date("2026-07-15T11:00:00Z"),
      },
      3: {
        messageId: "<other@x.com>",
        subject: "Unrelated",
        date: new Date("2026-07-15T09:00:00Z"),
      },
    });
    const res = await resolveThreadMessages(host, "session", "root@x.com", "Re: Lunch?");
    expect(res.inboxUids.sort()).toEqual([1, 2]);
    expect(res.latest?.uid).toBe(2);
    expect(calls.selected).toContain("INBOX");
    // Subject is stripped to its base for the search.
    expect(calls.searched[0]).toMatchObject({ subject: "Lunch?" });
  });

  it("returns an empty resolution when nothing matches the root", async () => {
    const { host } = mockHost({
      1: { messageId: "<a@x.com>", subject: "Hi", date: new Date() },
    });
    const res = await resolveThreadMessages(host, "session", "nope@x.com", "Hi");
    expect(res.inboxUids).toEqual([]);
    expect(res.latest).toBeNull();
  });
});

/** A MailHost whose IMAP serves distinct message sets per mailbox — INBOX and
 *  a discoverable "Sent Messages" mailbox (specialUse "\Sent") — so
 *  `fetchOriginalMessage`'s INBOX-then-Sent fallback can be exercised.
 *  `search`/`fetchMessages` key off whichever mailbox was last SELECTed. */
function mockMultiMailboxHost(opts: {
  inbox?: Record<number, Partial<ImapMessage>>;
  sent?: Record<number, Partial<ImapMessage>>;
}): {
  host: MailHost;
  calls: { searched: unknown[]; selected: string[] };
} {
  const calls = { searched: [] as unknown[], selected: [] as string[] };
  const inbox = opts.inbox ?? {};
  const sent = opts.sent ?? {};
  let current = "INBOX";
  const imap = {
    connect: async () => "session",
    disconnect: async () => {},
    listMailboxes: async () => [
      { name: "INBOX", delimiter: "/", flags: [] },
      { name: "Sent Messages", delimiter: "/", flags: [], specialUse: "\\Sent" },
    ],
    selectMailbox: async (_s: string, box: string) => {
      calls.selected.push(box);
      current = box;
      return { name: box, exists: 0, recent: 0, uidValidity: 1, uidNext: 100 };
    },
    search: async (_s: string, criteria: unknown) => {
      calls.searched.push(criteria);
      const store = current === "INBOX" ? inbox : sent;
      return Object.keys(store).map(Number);
    },
    fetchMessages: async (_s: string, u: number[]) => {
      const store = current === "INBOX" ? inbox : sent;
      return u.map((uid) => ({ uid, flags: [], ...store[uid] }) as ImapMessage);
    },
    setFlags: async () => {},
  };
  const host = {
    imap,
    integrations: {} as never,
    smtp: {} as never,
    appleId: "me@icloud.com",
    appPassword: "pw",
    set: async () => {},
    get: async () => undefined,
    clear: async () => {},
    channelSyncCompleted: async () => {},
  } as unknown as MailHost;
  return { host, calls };
}

describe("fetchOriginalMessage", () => {
  it("finds a message in INBOX by its stripped Message-ID", async () => {
    const { host } = mockMultiMailboxHost({
      inbox: {
        1: { messageId: "<root@x.com>", subject: "Lunch?", date: new Date("2026-07-15T10:00:00Z") },
      },
    });
    const found = await fetchOriginalMessage(host, "session", "root@x.com", "Lunch?");
    expect(found?.mailbox).toBe("INBOX");
    expect(found?.message.uid).toBe(1);
    expect(found?.message.messageId).toBe("<root@x.com>");
  });

  it("falls back to the Sent mailbox when the id isn't in INBOX", async () => {
    const { host } = mockMultiMailboxHost({
      inbox: { 1: { messageId: "<other@x.com>", subject: "Lunch?", date: new Date() } },
      sent: { 5: { messageId: "<sent-root@x.com>", subject: "Lunch?", date: new Date() } },
    });
    const found = await fetchOriginalMessage(host, "session", "sent-root@x.com", "Lunch?");
    expect(found?.mailbox).toBe("Sent Messages");
    expect(found?.message.uid).toBe(5);
  });

  it("returns null when the id is absent from both INBOX and Sent", async () => {
    const { host } = mockMultiMailboxHost({
      inbox: { 1: { messageId: "<other@x.com>", subject: "Lunch?", date: new Date() } },
      sent: { 5: { messageId: "<other2@x.com>", subject: "Lunch?", date: new Date() } },
    });
    const found = await fetchOriginalMessage(host, "session", "nope@x.com", "Lunch?");
    expect(found).toBeNull();
  });
});
