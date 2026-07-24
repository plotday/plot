import { describe, expect, it } from "vitest";
import { ActionType } from "@plotday/twister";

import { rootMessageId, mailSource, transformMessages, type MailMessage } from "./transform";

function msg(over: Partial<MailMessage>): MailMessage {
  return {
    uid: 1,
    flags: [],
    from: [{ address: "jane@example.com", name: "Jane" }],
    to: [{ address: "kris@icloud.com", name: "Kris" }],
    messageId: "<m1@example.com>",
    date: new Date("2026-07-15T10:00:00Z"),
    subject: "Lunch?",
    bodyText: "Can we meet?",
    mailbox: "INBOX",
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

describe("transformMessages — calendar thread bundling", () => {
  it("known UID: adds icaluid to sources and OMITS the title key when the thread's root has a cancel bundle for an already-synced event", () => {
    const m = msg({ uid: 30, messageId: "<invite@example.com>" });
    const bundles = new Map([
      ["invite@example.com", { uid: "evt-1", kind: "cancel" as const, eventKnown: true }],
    ]);
    const link = transformMessages([m], { ...ctx, calendarBundles: bundles })[0];

    expect(link.sources).toEqual(["icaluid:evt-1"]);
    // The title key must be ABSENT (not null, not ""), per plot.ts's "Omit
    // to preserve the existing title" contract — the runtime's title field
    // is last-writer-wins, so setting it (even to the same subject) would
    // clobber the calendar event's title on every mail sync pass.
    expect("title" in link).toBe(false);
  });

  it("known UID: adds icaluid to sources and OMITS the title key when the thread's root has an update bundle for an already-synced event", () => {
    const m = msg({ uid: 31, messageId: "<invite2@example.com>" });
    const bundles = new Map([
      ["invite2@example.com", { uid: "evt-2", kind: "update" as const, eventKnown: true }],
    ]);
    const link = transformMessages([m], { ...ctx, calendarBundles: bundles })[0];

    expect(link.sources).toEqual(["icaluid:evt-2"]);
    expect("title" in link).toBe(false);
  });

  it("unknown UID (FIX 1): still adds icaluid to sources, but SETS the title from the subject when no synced event exists yet for a cancel bundle", () => {
    const m = msg({ uid: 34, messageId: "<invite-unsynced@example.com>", subject: "Cancelled: Offsite" });
    const bundles = new Map([
      ["invite-unsynced@example.com", { uid: "evt-4", kind: "cancel" as const, eventKnown: false }],
    ]);
    const link = transformMessages([m], { ...ctx, calendarBundles: bundles })[0];

    // Thread convergence is never skipped — the icaluid alias is still
    // present so a later-synced calendar event still bundles onto this
    // same thread.
    expect(link.sources).toEqual(["icaluid:evt-4"]);
    // But the title key MUST be present — otherwise the runtime's INSERT
    // path (no synced event yet to draw a title from) substitutes the
    // literal "Untitled" placeholder, permanently.
    expect("title" in link).toBe(true);
    expect(link.title).toBe("Cancelled: Offsite");
  });

  it("unknown UID (FIX 1): still adds icaluid to sources, but SETS the title from the subject when no synced event exists yet for an update bundle", () => {
    const m = msg({ uid: 35, messageId: "<update-unsynced@example.com>", subject: "Updated: Offsite" });
    const bundles = new Map([
      ["update-unsynced@example.com", { uid: "evt-5", kind: "update" as const, eventKnown: false }],
    ]);
    const link = transformMessages([m], { ...ctx, calendarBundles: bundles })[0];

    expect(link.sources).toEqual(["icaluid:evt-5"]);
    expect("title" in link).toBe(true);
    expect(link.title).toBe("Updated: Offsite");
  });

  it("leaves title and sources untouched when no bundle matches the thread's root", () => {
    const m = msg({ uid: 32, messageId: "<plain@example.com>" });
    const bundles = new Map([
      ["someone-elses-root@example.com", { uid: "evt-3", kind: "cancel" as const, eventKnown: true }],
    ]);
    const link = transformMessages([m], { ...ctx, calendarBundles: bundles })[0];

    expect(link.sources).toBeUndefined();
    expect(link.title).toBe("Lunch?");
  });

  it("leaves title and sources untouched when calendarBundles is omitted entirely (regression / backward compat)", () => {
    const m = msg({ uid: 33, messageId: "<noctx@example.com>" });
    const link = transformMessages([m], ctx)[0];

    expect(link.sources).toBeUndefined();
    expect(link.title).toBe("Lunch?");
  });
});

type ActionLike = {
  type?: ActionType;
  ref?: string;
  fileName?: string;
  fileSize?: number | null;
  mimeType?: string;
};

describe("transformMessages attachments", () => {
  it("maps message.attachments to fileRef actions with a mailbox:uid:partNumber ref", () => {
    const m = msg({
      uid: 11,
      mailbox: "INBOX",
      attachments: [
        { partNumber: "2", fileName: "invoice.pdf", mimeType: "application/pdf", size: 1234, encoding: "base64" },
      ],
    });
    const note = transformMessages([m], ctx)[0].notes![0] as unknown as { actions?: ActionLike[] };
    expect(note.actions).toHaveLength(1);
    expect(note.actions![0]).toEqual({
      type: ActionType.fileRef,
      ref: "INBOX:11:2",
      fileName: "invoice.pdf",
      fileSize: 1234,
      mimeType: "application/pdf",
    });
  });

  it("maps multiple attachment parts to multiple fileRef actions", () => {
    const m = msg({
      uid: 12,
      attachments: [
        { partNumber: "2", fileName: "a.png", mimeType: "image/png", size: 10, encoding: "base64" },
        { partNumber: "3", fileName: "b.png", mimeType: "image/png", size: 20, encoding: "base64" },
      ],
    });
    const note = transformMessages([m], ctx)[0].notes![0] as unknown as { actions?: ActionLike[] };
    expect(note.actions?.map((a) => a.ref)).toEqual(["INBOX:12:2", "INBOX:12:3"]);
  });

  it("encodes the message's own mailbox (e.g. Sent) into the ref, not a hardcoded INBOX", () => {
    const m = msg({
      uid: 13,
      mailbox: "Sent Messages",
      attachments: [
        { partNumber: "2", fileName: "doc.pdf", mimeType: "application/pdf", size: 99, encoding: "base64" },
      ],
    });
    const note = transformMessages([m], ctx)[0].notes![0] as unknown as { actions?: ActionLike[] };
    expect(note.actions![0].ref).toBe("Sent%20Messages:13:2");
  });

  it("leaves actions unset (not an empty array) for a message with no attachments", () => {
    const m = msg({ uid: 14 });
    const note = transformMessages([m], ctx)[0].notes![0] as unknown as { actions?: ActionLike[] };
    expect(note.actions).toBeUndefined();
  });

  it("FIX 6: omits an inline calendar part whose fileName is the synthesized 'attachment' placeholder", () => {
    const m = msg({
      uid: 15,
      attachments: [
        { partNumber: "2", fileName: "attachment", mimeType: "text/calendar", size: 100, encoding: "8bit" },
      ],
    });
    const note = transformMessages([m], ctx)[0].notes![0] as unknown as { actions?: ActionLike[] };
    // No real attachment to download — must not become an empty array either.
    expect(note.actions).toBeUndefined();
  });

  it("FIX 6: keeps a genuinely-named calendar attachment (e.g. invite.ics) as a normal fileRef action", () => {
    const m = msg({
      uid: 16,
      attachments: [
        { partNumber: "2", fileName: "invite.ics", mimeType: "text/calendar", size: 100, encoding: "8bit" },
      ],
    });
    const note = transformMessages([m], ctx)[0].notes![0] as unknown as { actions?: ActionLike[] };
    expect(note.actions).toHaveLength(1);
    expect(note.actions![0].fileName).toBe("invite.ics");
  });

  it("FIX 6: keeps sibling non-calendar attachments alongside a suppressed synthesized calendar part", () => {
    const m = msg({
      uid: 17,
      attachments: [
        { partNumber: "2", fileName: "photo.png", mimeType: "image/png", size: 10, encoding: "base64" },
        { partNumber: "3", fileName: "attachment", mimeType: "application/ics", size: 100, encoding: "8bit" },
      ],
    });
    const note = transformMessages([m], ctx)[0].notes![0] as unknown as { actions?: ActionLike[] };
    expect(note.actions).toHaveLength(1);
    expect(note.actions![0].fileName).toBe("photo.png");
  });

  it("FIX 6: does NOT suppress a non-calendar attachment that happens to be literally named 'attachment'", () => {
    const m = msg({
      uid: 18,
      attachments: [
        { partNumber: "2", fileName: "attachment", mimeType: "application/pdf", size: 100, encoding: "base64" },
      ],
    });
    const note = transformMessages([m], ctx)[0].notes![0] as unknown as { actions?: ActionLike[] };
    expect(note.actions).toHaveLength(1);
  });
});
