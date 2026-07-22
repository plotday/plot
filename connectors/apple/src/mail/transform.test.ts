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

  it("on incremental sync marks the thread unread when a NEW message is unseen", () => {
    const m = msg({ uid: 6, flags: [] }); // no \\Seen
    const link = transformMessages([m], {
      ...ctx,
      initialSync: false,
      newUids: [6],
    })[0];
    expect(link.unread).toBe(true);
  });

  it("does NOT re-mark an existing unseen thread unread on incremental (read preserved)", () => {
    // uid 6 is a recent-window rescan re-fetch, NOT new mail (not in newUids).
    // A message read in Plot but still unseen on IMAP must keep Plot's read
    // state — `unread` is left untouched, never re-asserted true.
    const m = msg({ uid: 6, flags: [] }); // unseen on IMAP
    const link = transformMessages([m], {
      ...ctx,
      initialSync: false,
      newUids: [],
    })[0];
    expect(link.unread).toBeUndefined();
  });

  it("propagates an Apple Mail read: incremental marks the thread read when all seen", () => {
    const m = msg({ uid: 6, flags: ["\\Seen"] });
    const link = transformMessages([m], {
      ...ctx,
      initialSync: false,
      newUids: [],
    })[0];
    expect(link.unread).toBe(false);
  });

  it("sets author null (not the connector) when a message has no From", () => {
    const m = msg({ uid: 9, from: undefined });
    const link = transformMessages([m], ctx)[0];
    expect(link.author).toBeNull();
    expect(link.notes![0].author).toBeNull();
    expect(link.notes![0].authoredBySelf).toBeUndefined();
  });

  it("credits the owner as thread author for an owner-originated thread", () => {
    const mine = msg({ uid: 10, from: [{ address: "kris@icloud.com", name: "Kris" }] });
    const link = transformMessages([mine], ctx)[0];
    expect((link.author as { email?: string } | undefined)?.email).toBe("kris@icloud.com");
  });

  it("merges an owner Sent message and an inbound unseen reply into one unread thread on incremental sync", () => {
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
      flags: [],
      date: new Date("2026-07-15T10:00:00Z"),
      bodyText: "Sounds good",
    });
    const links = transformMessages([ownerSent, reply], {
      ...ctx,
      initialSync: false,
      newUids: [20], // the inbound reply is the newly-arrived INBOX message
    });
    expect(links).toHaveLength(1);
    expect(links[0].unread).toBe(true);
    type NoteLike = { key?: string; authoredBySelf?: boolean; author?: { email?: string } | null };
    const byKey = Object.fromEntries(
      links[0].notes!.map((n) => [(n as NoteLike).key, n as NoteLike])
    );
    expect(byKey["root@icloud.com"].authoredBySelf).toBe(true);
    expect(byKey["reply@example.com"].author?.email).toBe("jane@example.com");
    expect((links[0].author as { email?: string } | undefined)?.email).toBe("kris@icloud.com");
  });
});
