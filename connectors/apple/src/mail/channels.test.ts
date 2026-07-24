import { describe, expect, it, vi } from "vitest";
import type { ImapMailbox } from "@plotday/twister/tools/imap";

import { getMailChannels } from "./channels";
import type { MailHost } from "./mail-host";

/** Build a MailHost whose imap.listMailboxes resolves to `boxes` (or throws `boxes` if it's an Error). */
function mockHost(
  boxes: ImapMailbox[] | Error
): { host: MailHost; disconnect: ReturnType<typeof vi.fn> } {
  const disconnect = vi.fn(async () => {});
  const imap = {
    connect: async () => "session",
    disconnect,
    listMailboxes: async () => {
      if (boxes instanceof Error) throw boxes;
      return boxes;
    },
  };
  const host = {
    imap,
    integrations: {} as never,
    smtp: {} as never,
    files: {} as never,
    appleId: "me@icloud.com",
    appPassword: "pw",
    set: async () => {},
    get: async () => undefined,
    clear: async () => {},
    channelSyncCompleted: async () => {},
    queueWritebackDrain: async () => {},
    knownEventUids: async () => new Set<string>(),
  } as unknown as MailHost;
  return { host, disconnect };
}

function box(overrides: Partial<ImapMailbox> & { name: string }): ImapMailbox {
  return { delimiter: "/", flags: [], ...overrides };
}

describe("getMailChannels", () => {
  it("excludes containers flagged \\Noselect, even without a matching specialUse", async () => {
    const { host } = mockHost([
      box({ name: "INBOX" }),
      box({ name: "[Gmail]", flags: ["\\Noselect", "\\HasChildren"] }),
    ]);
    const channels = await getMailChannels(host);
    expect(channels.map((c) => c.id)).toEqual(["INBOX"]);
  });

  it("excludes Sent, Drafts, Trash, and Junk by specialUse", async () => {
    const { host } = mockHost([
      box({ name: "INBOX" }),
      box({ name: "Sent Messages", specialUse: "\\Sent" }),
      box({ name: "Drafts", specialUse: "\\Drafts" }),
      box({ name: "Deleted Messages", specialUse: "\\Trash" }),
      box({ name: "Junk", specialUse: "\\Junk" }),
    ]);
    const channels = await getMailChannels(host);
    expect(channels.map((c) => c.id)).toEqual(["INBOX"]);
  });

  it("excludes a Sent mailbox identified only by name, when the server advertises no specialUse (matches resolveSentMailbox's fallback)", async () => {
    const { host } = mockHost([
      box({ name: "INBOX" }),
      box({ name: "Sent Messages" }), // no specialUse — server omits SPECIAL-USE
    ]);
    const channels = await getMailChannels(host);
    expect(channels.map((c) => c.id)).toEqual(["INBOX"]);
  });

  it.each(["Sent", "Sent Messages", "Sent Items", "Sent Mail"])(
    "excludes the known Sent name %j when the server advertises no specialUse",
    async (name) => {
      const { host } = mockHost([box({ name: "INBOX" }), box({ name })]);
      const channels = await getMailChannels(host);
      expect(channels.map((c) => c.id)).toEqual(["INBOX"]);
    }
  );

  it("excludes a Sent mailbox name case-insensitively and with surrounding whitespace", async () => {
    const { host } = mockHost([box({ name: "INBOX" }), box({ name: "  SENT items  " })]);
    const channels = await getMailChannels(host);
    expect(channels.map((c) => c.id)).toEqual(["INBOX"]);
  });

  it("keeps a near-miss mailbox name like \"Sentiment\" selectable as a channel", async () => {
    const { host } = mockHost([box({ name: "INBOX" }), box({ name: "Sentiment" })]);
    const channels = await getMailChannels(host);
    expect(channels.map((c) => c.id).sort()).toEqual(["INBOX", "Sentiment"]);
  });

  it("keeps a near-miss mailbox name like \"Sent by client\" selectable as a channel", async () => {
    const { host } = mockHost([box({ name: "INBOX" }), box({ name: "Sent by client" })]);
    const channels = await getMailChannels(host);
    expect(channels.map((c) => c.id).sort()).toEqual(["INBOX", "Sent by client"]);
  });

  it("keeps an \\Archive mailbox", async () => {
    const { host } = mockHost([
      box({ name: "INBOX" }),
      box({ name: "Archive", specialUse: "\\Archive" }),
    ]);
    const channels = await getMailChannels(host);
    expect(channels.map((c) => c.id)).toEqual(["INBOX", "Archive"]);
  });

  it("enables only INBOX by default", async () => {
    const { host } = mockHost([
      box({ name: "INBOX" }),
      box({ name: "Archive", specialUse: "\\Archive" }),
      box({ name: "Work" }),
    ]);
    const channels = await getMailChannels(host);
    expect(channels.find((c) => c.id === "INBOX")?.enabledByDefault).toBe(true);
    expect(channels.find((c) => c.id === "Archive")?.enabledByDefault).toBe(false);
    expect(channels.find((c) => c.id === "Work")?.enabledByDefault).toBe(false);
  });

  it("titles INBOX as \"Inbox\", not the raw name", async () => {
    const { host } = mockHost([box({ name: "INBOX" })]);
    const channels = await getMailChannels(host);
    expect(channels[0].title).toBe("Inbox");
  });

  it.each(["Inbox", "inbox"])(
    "recognizes a mixed/lower-case mailbox name %j as Inbox (title + enabledByDefault)",
    async (name) => {
      const { host } = mockHost([box({ name })]);
      const channels = await getMailChannels(host);
      expect(channels[0].title).toBe("Inbox");
      expect(channels[0].enabledByDefault).toBe(true);
    }
  );

  it("renders a nested folder's full path with \" / \", for a \"/\" delimiter", async () => {
    const { host } = mockHost([
      box({ name: "INBOX" }),
      box({ name: "Archive/2024", delimiter: "/", specialUse: "\\Archive" }),
    ]);
    const channels = await getMailChannels(host);
    expect(channels.find((c) => c.id === "Archive/2024")?.title).toBe("Archive / 2024");
  });

  it("renders a nested folder's full path with \" / \", for a \".\" delimiter", async () => {
    const { host } = mockHost([
      box({ name: "INBOX" }),
      box({ name: "Archive.2024", delimiter: ".", specialUse: "\\Archive" }),
    ]);
    const channels = await getMailChannels(host);
    expect(channels.find((c) => c.id === "Archive.2024")?.title).toBe("Archive / 2024");
  });

  it("still returns other folders when the account has no INBOX", async () => {
    const { host } = mockHost([
      box({ name: "Archive", specialUse: "\\Archive" }),
      box({ name: "Work" }),
    ]);
    const channels = await getMailChannels(host);
    expect(channels.map((c) => c.id).sort()).toEqual(["Archive", "Work"]);
  });

  it("disconnects the session even when listMailboxes throws", async () => {
    const { host, disconnect } = mockHost(new Error("boom"));
    await expect(getMailChannels(host)).rejects.toThrow("boom");
    expect(disconnect).toHaveBeenCalledTimes(1);
  });
});
