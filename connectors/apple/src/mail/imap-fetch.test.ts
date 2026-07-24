import { describe, expect, it } from "vitest";
import type { ImapMailbox, ImapMessage } from "@plotday/twister/tools/imap";

import { fetchOriginalMessage, isSentMailbox, resolveSentMailbox, resolveThreadMessages } from "./imap-fetch";
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
    queueWritebackDrain: async () => {},
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
    queueWritebackDrain: async () => {},
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

/** A MailHost whose imap.listMailboxes resolves to `boxes`, for exercising
 *  resolveSentMailbox's mailbox-picking logic directly. */
function mockListMailboxesHost(boxes: ImapMailbox[]): MailHost {
  const imap = {
    connect: async () => "session",
    disconnect: async () => {},
    listMailboxes: async () => boxes,
    selectMailbox: async () => ({ name: "", exists: 0, recent: 0, uidValidity: 1, uidNext: 1 }),
    search: async () => [],
    fetchMessages: async () => [],
    setFlags: async () => {},
  };
  return {
    imap,
    integrations: {} as never,
    smtp: {} as never,
    appleId: "me@icloud.com",
    appPassword: "pw",
    set: async () => {},
    get: async () => undefined,
    clear: async () => {},
    channelSyncCompleted: async () => {},
    queueWritebackDrain: async () => {},
  } as unknown as MailHost;
}

function box(overrides: Partial<ImapMailbox> & { name: string }): ImapMailbox {
  return { delimiter: "/", flags: [], ...overrides };
}

describe("resolveSentMailbox", () => {
  it("finds a Sent mailbox by name when the server advertises no specialUse at all — the same mailbox getMailChannels excludes as Sent", async () => {
    const host = mockListMailboxesHost([box({ name: "INBOX" }), box({ name: "Sent Messages" })]);
    expect(await resolveSentMailbox(host, "session")).toBe("Sent Messages");
  });

  it("prefers a specialUse \\Sent mailbox over a mere name match, when both exist", async () => {
    const host = mockListMailboxesHost([
      box({ name: "INBOX" }),
      box({ name: "Sent Items", specialUse: "\\Sent" }),
      box({ name: "Sent Mail" }), // also a known name, but isn't the real Sent box
    ]);
    expect(await resolveSentMailbox(host, "session")).toBe("Sent Items");
  });

  it("returns null when no mailbox is discoverable as Sent", async () => {
    const host = mockListMailboxesHost([box({ name: "INBOX" }), box({ name: "Archive" })]);
    expect(await resolveSentMailbox(host, "session")).toBeNull();
  });

  it.each(["Sent", "Sent Messages", "Sent Items", "Sent Mail"])(
    "finds a Sent mailbox by the known name %j when the server advertises no specialUse",
    async (name) => {
      const host = mockListMailboxesHost([box({ name: "INBOX" }), box({ name })]);
      expect(await resolveSentMailbox(host, "session")).toBe(name);
    }
  );

  it("finds a Sent mailbox by name case-insensitively and with surrounding whitespace", async () => {
    const host = mockListMailboxesHost([box({ name: "INBOX" }), box({ name: "  SENT items  " })]);
    expect(await resolveSentMailbox(host, "session")).toBe("  SENT items  ");
  });

  it("does not treat a near-miss name like \"Sentiment\" as Sent when no other candidate exists", async () => {
    const host = mockListMailboxesHost([box({ name: "INBOX" }), box({ name: "Sentiment" })]);
    expect(await resolveSentMailbox(host, "session")).toBeNull();
  });

  it("does not treat a near-miss name like \"Sent by client\" as Sent when no other candidate exists", async () => {
    const host = mockListMailboxesHost([box({ name: "INBOX" }), box({ name: "Sent by client" })]);
    expect(await resolveSentMailbox(host, "session")).toBeNull();
  });
});

describe("isSentMailbox", () => {
  it("matches on specialUse \\Sent regardless of name", () => {
    expect(isSentMailbox({ name: "Elsewhere", specialUse: "\\Sent" })).toBe(true);
  });

  it("matches specialUse \\Sent even when the name matches nothing at all", () => {
    expect(isSentMailbox({ name: "Archive", specialUse: "\\Sent" })).toBe(true);
  });

  it.each(["Sent", "Sent Messages", "Sent Items", "Sent Mail"])(
    "matches the known name %j with no specialUse",
    (name) => {
      expect(isSentMailbox({ name })).toBe(true);
    }
  );

  it("matches a known name case-insensitively and with surrounding whitespace", () => {
    expect(isSentMailbox({ name: "  SENT MESSAGES  " })).toBe(true);
    expect(isSentMailbox({ name: "sent" })).toBe(true);
  });

  it("does not match an unrelated mailbox", () => {
    expect(isSentMailbox({ name: "Archive" })).toBe(false);
    expect(isSentMailbox({ name: "INBOX", specialUse: "\\Archive" })).toBe(false);
  });

  it("does not match a mailbox whose name merely starts with \"sent\"", () => {
    expect(isSentMailbox({ name: "Sentiment" })).toBe(false);
    expect(isSentMailbox({ name: "Sent by client" })).toBe(false);
  });
});
