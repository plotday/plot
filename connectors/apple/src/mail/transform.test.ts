import { describe, expect, it } from "vitest";
import type { ImapMessage } from "@plotday/twister/tools/imap";

import { rootMessageId, mailSource, transformMessages } from "./transform";

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

const ctx = {
  channelId: "mail:INBOX",
  appleId: "kris@icloud.com",
  fromSent: false,
  initialSync: true,
};

describe("rootMessageId / mailSource", () => {
  it("uses References[0] as the thread root when present", () => {
    const m = msg({ references: ["<root@example.com>", "<parent@example.com>"] });
    expect(rootMessageId(m)).toBe("root@example.com");
    expect(mailSource(rootMessageId(m)!)).toBe("icloud-mail:thread:root@example.com");
  });
  it("falls back to the message's own Message-ID", () => {
    expect(rootMessageId(msg({ references: undefined }))).toBe("m1@example.com");
  });
  it("returns null when there is no id to thread on", () => {
    expect(rootMessageId(msg({ references: undefined, messageId: undefined }))).toBeNull();
  });
});

describe("transformMessages", () => {
  it("groups a reply onto its parent's thread and keys a note per message", () => {
    const parent = msg({ uid: 1, messageId: "<m1@example.com>" });
    const reply = msg({
      uid: 2,
      messageId: "<m2@example.com>",
      references: ["<m1@example.com>"],
      from: [{ address: "bob@example.com", name: "Bob" }],
      date: new Date("2026-07-15T11:00:00Z"),
      bodyText: "Sure!",
    });
    const links = transformMessages([parent, reply], ctx);
    expect(links).toHaveLength(1);
    const link = links[0];
    expect(link.source).toBe("icloud-mail:thread:m1@example.com");
    expect(link.channelId).toBe("mail:INBOX");
    expect(link.type).toBe("email");
    // one note per message, keyed by message-id
    expect(link.notes?.map((n) => (n as { key?: string }).key).sort()).toEqual(["m1@example.com", "m2@example.com"]);
    // thread author = earliest message's sender
    expect((link.author as { email?: string } | undefined)?.email).toBe("jane@example.com");
    // initial sync suppresses unread
    expect(link.unread).toBe(false);
  });

  it("marks the owner's own message authoredBySelf and does not set its note author", () => {
    const mine = msg({
      uid: 3,
      messageId: "<mine@example.com>",
      from: [{ address: "kris@icloud.com", name: "Kris" }],
    });
    const link = transformMessages([mine], ctx)[0];
    const note = link.notes![0];
    expect(note.authoredBySelf).toBe(true);
    expect(note.author).toBeUndefined();
  });

  it("prefers html body and marks contentType html", () => {
    const m = msg({ uid: 4, bodyText: undefined, bodyHtml: "<p>hi</p>" });
    const note = transformMessages([m], ctx)[0].notes![0];
    expect(note.contentType).toBe("html");
    expect(note.content).toBe("<p>hi</p>");
  });

  it("detects single-part html in bodyText via the heuristic", () => {
    const m = msg({ uid: 5, bodyText: "<div>Newsletter</div>", bodyHtml: undefined });
    const note = transformMessages([m], ctx)[0].notes![0];
    expect(note.contentType).toBe("html");
  });

  it("on incremental sync marks the thread unread when a message is unseen", () => {
    const m = msg({ uid: 6, flags: [] }); // no \\Seen
    const link = transformMessages([m], { ...ctx, initialSync: false })[0];
    expect(link.unread).toBe(true);
  });
});
