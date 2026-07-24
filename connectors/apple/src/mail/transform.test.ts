import { describe, expect, it } from "vitest";
import { ActionType } from "@plotday/twister";

import {
  rootMessageId,
  mailSource,
  messageKey,
  transformMessages,
  type MailMessage,
  type TransformCtx,
} from "./transform";

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

/**
 * `channelByRoot` and `initialRoots` are per-root, so most tests want "every
 * root in this batch, homed to one channel". These helpers build that from the
 * batch itself so a test only states what it is actually asserting.
 */
function rootsOf(messages: MailMessage[]): string[] {
  return [...new Set(messages.map((m) => rootMessageId(m)).filter((r): r is string => !!r))];
}

/** A ctx homing every root in `messages` to `channelId`. */
function ctxFor(
  messages: MailMessage[],
  over: Partial<TransformCtx> & { channelId?: string } = {}
): TransformCtx {
  const { channelId = "mail:INBOX", ...rest } = over;
  const roots = rootsOf(messages);
  return {
    appleId: "kris@icloud.com",
    channelByRoot: new Map(roots.map((r) => [r, channelId])),
    // Historically every transform test ran with `initialSync: true`; keep
    // that default so the suite's read-state expectations are unchanged.
    initialRoots: new Set(roots),
    newMessages: new Set<string>(),
    ...rest,
  };
}

/** Incremental variant: nothing is a first-time backfill. */
function incrementalCtxFor(
  messages: MailMessage[],
  over: Partial<TransformCtx> & { channelId?: string } = {}
): TransformCtx {
  return ctxFor(messages, { initialRoots: new Set<string>(), ...over });
}

/** Run a batch with the default "all roots initial, one channel" context. */
function transform(messages: MailMessage[], over: Partial<TransformCtx> & { channelId?: string } = {}) {
  return transformMessages(messages, ctxFor(messages, over));
}

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
    const links = transform([parent, reply]);
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
    const link = transform([mine])[0];
    const note = link.notes![0];
    expect(note.authoredBySelf).toBe(true);
    expect(note.author).toBeUndefined();
  });

  it("prefers html body and marks contentType html", () => {
    const m = msg({ uid: 4, bodyText: undefined, bodyHtml: "<p>hi</p>" });
    const note = transform([m])[0].notes![0];
    expect(note.contentType).toBe("html");
    expect(note.content).toBe("<p>hi</p>");
  });

  it("detects single-part html in bodyText via the heuristic", () => {
    const m = msg({ uid: 5, bodyText: "<div>Newsletter</div>", bodyHtml: undefined });
    const note = transform([m])[0].notes![0];
    expect(note.contentType).toBe("html");
  });

  it("on incremental sync marks the thread unread when a NEW message is unseen", () => {
    const m = msg({ uid: 6, flags: [] }); // no \\Seen
    const link = transformMessages(
      [m],
      incrementalCtxFor([m], { newMessages: new Set([messageKey(m)]) })
    )[0];
    expect(link.unread).toBe(true);
  });

  it("does NOT re-mark an existing unseen thread unread on incremental (read preserved)", () => {
    // uid 6 is a recent-window rescan re-fetch, NOT new mail (not in
    // newMessages). A message read in Plot but still unseen on IMAP must keep
    // Plot's read state — `unread` is left untouched, never re-asserted true.
    const m = msg({ uid: 6, flags: [] }); // unseen on IMAP
    const link = transformMessages([m], incrementalCtxFor([m]))[0];
    expect(link.unread).toBeUndefined();
  });

  it("propagates an Apple Mail read: incremental marks the thread read when all seen", () => {
    const m = msg({ uid: 6, flags: ["\\Seen"] });
    const link = transformMessages([m], incrementalCtxFor([m]))[0];
    expect(link.unread).toBe(false);
  });

  it("sets author null (not the connector) when a message has no From", () => {
    const m = msg({ uid: 9, from: undefined });
    const link = transform([m])[0];
    expect(link.author).toBeNull();
    expect(link.notes![0].author).toBeNull();
    expect(link.notes![0].authoredBySelf).toBeUndefined();
  });

  it("credits the owner as thread author for an owner-originated thread", () => {
    const mine = msg({ uid: 10, from: [{ address: "kris@icloud.com", name: "Kris" }] });
    const link = transform([mine])[0];
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
    const links = transformMessages(
      [ownerSent, reply],
      incrementalCtxFor([ownerSent, reply], {
        // the inbound reply is the newly-arrived INBOX message
        newMessages: new Set([messageKey(reply)]),
      })
    );
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

/**
 * The email link type declares `sharingModel: "message"`, whose contract is
 * that EVERY ingested note carries its own recipient set (never null) — the
 * thread roster is then the union across messages. Without per-note access
 * contacts the model degrades to thread-wide visibility, so someone added to
 * a later reply would retroactively see the whole earlier conversation.
 */
describe("transformMessages — per-note access contacts (message sharing model)", () => {
  type NoteLike = { key?: string; accessContacts?: Array<{ email?: string }> | null };
  const emailsOf = (n: NoteLike | undefined) =>
    (n?.accessContacts ?? []).map((c) => c.email).sort();

  const notesByKey = (link: { notes?: unknown[] }) =>
    Object.fromEntries((link.notes ?? []).map((n) => [(n as NoteLike).key, n as NoteLike]));

  it("scopes each note to that message's own From/To/Cc, not the thread union", () => {
    const first = msg({
      uid: 1,
      messageId: "<m1@example.com>",
      from: [{ address: "jane@example.com", name: "Jane" }],
      to: [{ address: "kris@icloud.com", name: "Kris" }],
    });
    // Bob is added to the conversation only on the second message.
    const second = msg({
      uid: 2,
      messageId: "<m2@example.com>",
      references: ["<m1@example.com>"],
      from: [{ address: "jane@example.com", name: "Jane" }],
      to: [{ address: "kris@icloud.com", name: "Kris" }],
      cc: [{ address: "bob@example.com", name: "Bob" }],
      date: new Date("2026-07-15T11:00:00Z"),
    });

    const byKey = notesByKey(transform([first, second])[0]);

    // Bob was not on the first message, so he must not see it.
    expect(emailsOf(byKey["m1@example.com"])).toEqual([
      "jane@example.com",
      "kris@icloud.com",
    ]);
    expect(emailsOf(byKey["m2@example.com"])).toEqual([
      "bob@example.com",
      "jane@example.com",
      "kris@icloud.com",
    ]);
  });

  it("always includes the connection owner, even when the message doesn't name them", () => {
    // Mailing-list / alias / Bcc delivery: the owner's own address appears in
    // no header. Their own note must not be redacted from them.
    const listMail = msg({
      uid: 3,
      messageId: "<list@example.com>",
      from: [{ address: "news@list.example.com", name: "List" }],
      to: [{ address: "everyone@list.example.com" }],
      cc: undefined,
    });

    const byKey = notesByKey(transform([listMail])[0]);

    expect(emailsOf(byKey["list@example.com"])).toEqual([
      "everyone@list.example.com",
      "kris@icloud.com",
      "news@list.example.com",
    ]);
  });

  it("matches the owner's address case-insensitively rather than adding a duplicate", () => {
    const mixedCase = msg({
      uid: 4,
      messageId: "<m4@example.com>",
      from: [{ address: "jane@example.com", name: "Jane" }],
      to: [{ address: "Kris@iCloud.com", name: "Kris" }],
    });

    const byKey = notesByKey(transform([mixedCase])[0]);

    expect(emailsOf(byKey["m4@example.com"])).toEqual([
      "Kris@iCloud.com",
      "jane@example.com",
    ]);
  });

  it("still sets the thread roster to the union across every message", () => {
    const first = msg({ uid: 1, messageId: "<m1@example.com>" });
    const second = msg({
      uid: 2,
      messageId: "<m2@example.com>",
      references: ["<m1@example.com>"],
      cc: [{ address: "bob@example.com", name: "Bob" }],
      date: new Date("2026-07-15T11:00:00Z"),
    });

    const link = transform([first, second])[0];

    expect((link.accessContacts ?? []).map((c) => c.email).sort()).toEqual([
      "bob@example.com",
      "jane@example.com",
      "kris@icloud.com",
    ]);
  });
});

describe("transformMessages — calendar thread bundling", () => {
  it("known UID: adds icaluid to sources and OMITS the title key when the thread's root has a cancel bundle for an already-synced event", () => {
    const m = msg({ uid: 30, messageId: "<invite@example.com>" });
    const bundles = new Map([
      ["invite@example.com", { uid: "evt-1", kind: "cancel" as const, eventKnown: true }],
    ]);
    const link = transform([m], { calendarBundles: bundles })[0];

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
    const link = transform([m], { calendarBundles: bundles })[0];

    expect(link.sources).toEqual(["icaluid:evt-2"]);
    expect("title" in link).toBe(false);
  });

  it("unknown UID (FIX 1): still adds icaluid to sources, but SETS the title from the subject when no synced event exists yet for a cancel bundle", () => {
    const m = msg({ uid: 34, messageId: "<invite-unsynced@example.com>", subject: "Cancelled: Offsite" });
    const bundles = new Map([
      ["invite-unsynced@example.com", { uid: "evt-4", kind: "cancel" as const, eventKnown: false }],
    ]);
    const link = transform([m], { calendarBundles: bundles })[0];

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
    const link = transform([m], { calendarBundles: bundles })[0];

    expect(link.sources).toEqual(["icaluid:evt-5"]);
    expect("title" in link).toBe(true);
    expect(link.title).toBe("Updated: Offsite");
  });

  it("leaves title and sources untouched when no bundle matches the thread's root", () => {
    const m = msg({ uid: 32, messageId: "<plain@example.com>" });
    const bundles = new Map([
      ["someone-elses-root@example.com", { uid: "evt-3", kind: "cancel" as const, eventKnown: true }],
    ]);
    const link = transform([m], { calendarBundles: bundles })[0];

    expect(link.sources).toBeUndefined();
    expect(link.title).toBe("Lunch?");
  });

  it("leaves title and sources untouched when calendarBundles is omitted entirely (regression / backward compat)", () => {
    const m = msg({ uid: 33, messageId: "<noctx@example.com>" });
    const link = transform([m])[0];

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
    const note = transform([m])[0].notes![0] as unknown as { actions?: ActionLike[] };
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
    const note = transform([m])[0].notes![0] as unknown as { actions?: ActionLike[] };
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
    const note = transform([m])[0].notes![0] as unknown as { actions?: ActionLike[] };
    expect(note.actions![0].ref).toBe("Sent%20Messages:13:2");
  });

  it("leaves actions unset (not an empty array) for a message with no attachments", () => {
    const m = msg({ uid: 14 });
    const note = transform([m])[0].notes![0] as unknown as { actions?: ActionLike[] };
    expect(note.actions).toBeUndefined();
  });

  it("FIX 6: omits an inline calendar part whose fileName is the synthesized 'attachment' placeholder", () => {
    const m = msg({
      uid: 15,
      attachments: [
        { partNumber: "2", fileName: "attachment", mimeType: "text/calendar", size: 100, encoding: "8bit" },
      ],
    });
    const note = transform([m])[0].notes![0] as unknown as { actions?: ActionLike[] };
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
    const note = transform([m])[0].notes![0] as unknown as { actions?: ActionLike[] };
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
    const note = transform([m])[0].notes![0] as unknown as { actions?: ActionLike[] };
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
    const note = transform([m])[0].notes![0] as unknown as { actions?: ActionLike[] };
    expect(note.actions).toHaveLength(1);
  });
});

/**
 * A merged pass hands ONE call every enabled mailbox plus Sent, so identity,
 * initial-ness and the home channel all become per-message / per-root rather
 * than per-batch. These are the properties that only hold once that is true.
 */
describe("transformMessages — merged multi-mailbox batch", () => {
  it("rebuilds a thread from BOTH folders as one link with the union of notes", () => {
    const archived = msg({
      uid: 7,
      mailbox: "Archive",
      messageId: "<m1@example.com>",
      date: new Date("2026-07-15T10:00:00Z"),
      subject: "Lunch?",
    });
    const reply = msg({
      uid: 3,
      mailbox: "INBOX",
      messageId: "<m2@example.com>",
      references: ["<m1@example.com>"],
      date: new Date("2026-07-15T11:00:00Z"),
    });

    const links = transformMessages(
      [archived, reply],
      incrementalCtxFor([archived, reply], { channelId: "mail:Archive" })
    );

    expect(links).toHaveLength(1);
    expect(links[0].channelId).toBe("mail:Archive");
    expect(links[0].notes?.map((n) => (n as { key?: string }).key).sort()).toEqual([
      "m1@example.com",
      "m2@example.com",
    ]);
    // The originator is the older Archive message, so the title comes from it.
    expect(links[0].title).toBe("Lunch?");
  });

  it("does NOT treat an unseen message as new because another MAILBOX has the same uid", () => {
    // IMAP uids are unique only within a mailbox. Archive uid 42 is old mail
    // the recent-window rescan re-fetched; INBOX uid 42 is genuinely new. A
    // bare-uid "new" set would make the Archive copy look new and re-mark its
    // thread unread on every poll, forever.
    const archiveOld = msg({
      uid: 42,
      mailbox: "Archive",
      messageId: "<old@example.com>",
      flags: [],
      date: new Date("2026-01-01T10:00:00Z"),
    });
    const inboxNew = msg({
      uid: 42,
      mailbox: "INBOX",
      messageId: "<new@example.com>",
      flags: [],
    });

    const links = transformMessages(
      [archiveOld, inboxNew],
      incrementalCtxFor([archiveOld, inboxNew], {
        newMessages: new Set([messageKey(inboxNew)]),
      })
    );

    const bySource = Object.fromEntries(links.map((l) => [l.source, l]));
    expect(bySource["icloud-mail:thread:old@example.com"].unread).toBeUndefined();
    expect(bySource["icloud-mail:thread:new@example.com"].unread).toBe(true);
  });

  it("orders same-timestamp messages from different folders by folder, not by fetch order", () => {
    // Two DISTINCT messages of one thread bearing the same timestamp, held in
    // different folders. Without a tie-break their order — and with it the
    // originator that sets `title` and `author` — would come from whichever
    // mailbox the merged pass happened to fetch first.
    const fromArchive = msg({
      uid: 1,
      mailbox: "Archive",
      messageId: "<a@example.com>",
      subject: "Archive subject",
      from: [{ address: "archie@example.com", name: "Archie" }],
    });
    const fromInbox = msg({
      uid: 2,
      mailbox: "INBOX",
      messageId: "<b@example.com>",
      references: ["<a@example.com>"],
      subject: "Inbox subject",
      from: [{ address: "ingrid@example.com", name: "Ingrid" }],
    });

    const forward = transformMessages(
      [fromArchive, fromInbox],
      incrementalCtxFor([fromArchive, fromInbox], { channelId: "mail:Archive" })
    );
    const reversed = transformMessages(
      [fromInbox, fromArchive],
      incrementalCtxFor([fromInbox, fromArchive], { channelId: "mail:Archive" })
    );

    expect(forward).toEqual(reversed);
    expect(forward[0].notes?.map((n) => (n as { key?: string }).key)).toEqual([
      "b@example.com",
      "a@example.com",
    ]);
    expect(forward[0].title).toBe("Inbox subject");
  });

  it("messageKey qualifies a uid by its mailbox", () => {
    expect(messageKey(msg({ uid: 42, mailbox: "INBOX" }))).toBe("INBOX 42");
    expect(messageKey(msg({ uid: 42, mailbox: "Archive/2024" }))).toBe("Archive/2024 42");
    expect(messageKey(msg({ uid: 42, mailbox: "INBOX" }))).not.toBe(
      messageKey(msg({ uid: 42, mailbox: "Archive" }))
    );
  });

  it("homes each root to its OWN channel within one call", () => {
    const inbox = msg({ uid: 1, mailbox: "INBOX", messageId: "<a@example.com>" });
    const archived = msg({ uid: 2, mailbox: "Archive", messageId: "<b@example.com>" });

    const links = transformMessages([inbox, archived], {
      appleId: "kris@icloud.com",
      channelByRoot: new Map([
        ["a@example.com", "mail:INBOX"],
        ["b@example.com", "mail:Archive"],
      ]),
      initialRoots: new Set<string>(),
      newMessages: new Set<string>(),
    });

    const bySource = Object.fromEntries(links.map((l) => [l.source, l]));
    expect(bySource["icloud-mail:thread:a@example.com"].channelId).toBe("mail:INBOX");
    expect(bySource["icloud-mail:thread:b@example.com"].channelId).toBe("mail:Archive");
  });

  it("keeps channelId and meta.syncableId equal on every emitted link", () => {
    // Disable-time archiving ANDs the two filters, so a divergence would make
    // the link unreachable by cleanup.
    const inbox = msg({ uid: 1, mailbox: "INBOX", messageId: "<a@example.com>" });
    const archived = msg({ uid: 2, mailbox: "Archive/2024", messageId: "<b@example.com>" });

    const links = transformMessages([inbox, archived], {
      appleId: "kris@icloud.com",
      channelByRoot: new Map([
        ["a@example.com", "mail:INBOX"],
        ["b@example.com", "mail:Archive/2024"],
      ]),
      initialRoots: new Set<string>(),
      newMessages: new Set<string>(),
    });

    expect(links).toHaveLength(2);
    for (const link of links) {
      expect(link.channelId).not.toBeNull();
      expect((link.meta as { syncableId?: string }).syncableId).toBe(link.channelId);
    }
  });

  it("skips a root the caller failed to resolve a channel for, rather than emitting a null channel", () => {
    const known = msg({ uid: 1, messageId: "<a@example.com>" });
    const orphan = msg({ uid: 2, messageId: "<b@example.com>" });

    const links = transformMessages([known, orphan], {
      appleId: "kris@icloud.com",
      channelByRoot: new Map([["a@example.com", "mail:INBOX"]]),
      initialRoots: new Set<string>(),
      newMessages: new Set<string>(),
    });

    expect(links.map((l) => l.source)).toEqual(["icloud-mail:thread:a@example.com"]);
  });
});

describe("transformMessages — per-root initial-ness", () => {
  it("gives a root in initialRoots unread:false AND archived:false", () => {
    const m = msg({ uid: 1, flags: [] });
    const link = transformMessages([m], ctxFor([m]))[0];
    expect(link.unread).toBe(false);
    expect(link.archived).toBe(false);
  });

  it("gives a NON-initial root with a new unseen message unread:true and no archived key", () => {
    const m = msg({ uid: 1, flags: [] });
    const link = transformMessages(
      [m],
      incrementalCtxFor([m], { newMessages: new Set([messageKey(m)]) })
    )[0];
    expect(link.unread).toBe(true);
    expect("archived" in link).toBe(false);
  });

  it("leaves a known root with only OLD unseen mail with neither an unread nor an archived key", () => {
    // This is the case a batch-wide initialSync:true would clobber: the user
    // archived the thread and read it in Plot, and a newly-enabled sibling
    // folder's backfill must not resurrect it.
    const m = msg({ uid: 1, flags: [] });
    const link = transformMessages([m], incrementalCtxFor([m]))[0];
    expect("unread" in link).toBe(false);
    expect("archived" in link).toBe(false);
  });

  it("applies initial-ness per root inside ONE mixed call", () => {
    // A merged pass backfills a newly-enabled folder while incrementally
    // syncing one that already has a cursor. Neither batch-wide value is
    // correct for both roots.
    const backfilled = msg({
      uid: 1,
      mailbox: "Archive",
      messageId: "<old@example.com>",
      flags: [],
    });
    const live = msg({ uid: 2, mailbox: "INBOX", messageId: "<live@example.com>", flags: [] });

    const links = transformMessages([backfilled, live], {
      appleId: "kris@icloud.com",
      channelByRoot: new Map([
        ["old@example.com", "mail:Archive"],
        ["live@example.com", "mail:INBOX"],
      ]),
      initialRoots: new Set(["old@example.com"]),
      newMessages: new Set([messageKey(live)]),
    });

    const bySource = Object.fromEntries(links.map((l) => [l.source, l]));
    expect(bySource["icloud-mail:thread:old@example.com"].unread).toBe(false);
    expect(bySource["icloud-mail:thread:old@example.com"].archived).toBe(false);
    expect(bySource["icloud-mail:thread:live@example.com"].unread).toBe(true);
    expect("archived" in bySource["icloud-mail:thread:live@example.com"]).toBe(false);
  });
});

describe("transformMessages — duplicate copies across folders", () => {
  const inboxCopy = msg({
    uid: 5,
    mailbox: "INBOX",
    messageId: "<dup@example.com>",
    flags: ["\\Seen"],
  });
  const archiveCopy = msg({
    uid: 9,
    mailbox: "Archive",
    messageId: "<dup@example.com>",
    flags: [],
  });

  it("emits ONE note for a message held in two folders", () => {
    const link = transformMessages(
      [inboxCopy, archiveCopy],
      incrementalCtxFor([inboxCopy, archiveCopy], { channelId: "mail:INBOX" })
    )[0];
    expect(link.notes).toHaveLength(1);
  });

  it("resolves order-independently when BOTH copies are in the home mailbox (duplicate delivery)", () => {
    // Regression guard: the home-mailbox short-circuit used to fire on the
    // FIRST copy found to be in the home mailbox, without checking whether
    // the incoming copy was ALSO in the home mailbox — so two copies BOTH
    // delivered to the home folder (a duplicate-delivery case, distinct from
    // "one copy in home, one elsewhere") picked whichever came first in the
    // input array, contradicting dedupeCopies' own "must not depend on fetch
    // order" contract.
    const older = msg({
      uid: 7,
      mailbox: "INBOX",
      messageId: "<homedup@example.com>",
      flags: ["\\Seen"],
    });
    const newer = msg({
      uid: 9,
      mailbox: "INBOX",
      messageId: "<homedup@example.com>",
      flags: [],
    });
    const forward = transformMessages(
      [older, newer],
      incrementalCtxFor([older, newer], { channelId: "mail:INBOX" })
    )[0];
    const reversed = transformMessages(
      [newer, older],
      incrementalCtxFor([newer, older], { channelId: "mail:INBOX" })
    )[0];
    expect(forward).toEqual(reversed);
    expect(forward.notes).toHaveLength(1);
    // The deterministic tie-break (lower uid) picks `older`, which is
    // \Seen — proves which copy actually won, not just that the two runs
    // agree with each other.
    expect(forward.unread).toBe(false);
  });

  it("keeps the copy in the thread's home mailbox regardless of input order", () => {
    const ref = (msgs: MailMessage[]) => {
      const link = transformMessages(
        msgs,
        incrementalCtxFor(msgs, { channelId: "mail:Archive" })
      )[0];
      return (link.notes![0] as unknown as { actions?: ActionLike[] }).actions;
    };
    // Attachment refs encode the surviving copy's mailbox + uid.
    const withAttachments = (m: MailMessage) => ({
      ...m,
      attachments: [
        { partNumber: "2", fileName: "a.pdf", mimeType: "application/pdf", size: 1, encoding: "base64" },
      ],
    });
    const a = withAttachments(inboxCopy);
    const b = withAttachments(archiveCopy);
    expect(ref([a, b])![0].ref).toBe("Archive:9:2");
    expect(ref([b, a])![0].ref).toBe("Archive:9:2");
  });

  it("falls back to INBOX-first when neither copy is in the home mailbox, stably under reversal", () => {
    const forward = transformMessages(
      [archiveCopy, inboxCopy],
      incrementalCtxFor([archiveCopy, inboxCopy], { channelId: "mail:Projects" })
    );
    const reversed = transformMessages(
      [inboxCopy, archiveCopy],
      incrementalCtxFor([inboxCopy, archiveCopy], { channelId: "mail:Projects" })
    );
    expect(forward).toEqual(reversed);
    // INBOX's copy is \Seen; picking it deterministically means the thread
    // reads as read rather than flipping with fetch order.
    expect(forward[0].unread).toBe(false);
  });

  it("takes the surviving copy's flags, so read state does not depend on fetch order", () => {
    const forward = transformMessages(
      [inboxCopy, archiveCopy],
      incrementalCtxFor([inboxCopy, archiveCopy], { channelId: "mail:Archive" })
    )[0];
    const reversed = transformMessages(
      [archiveCopy, inboxCopy],
      incrementalCtxFor([archiveCopy, inboxCopy], { channelId: "mail:Archive" })
    )[0];
    // Archive is home and its copy is unseen (and not new) → no unread key.
    expect("unread" in forward).toBe(false);
    expect(forward).toEqual(reversed);
  });

  it("does not merge two DIFFERENT messages that merely share a uid across mailboxes", () => {
    const a = msg({ uid: 42, mailbox: "INBOX", messageId: "<a@example.com>" });
    const b = msg({
      uid: 42,
      mailbox: "Archive",
      messageId: "<b@example.com>",
      references: ["<a@example.com>"],
    });
    const link = transformMessages([a, b], incrementalCtxFor([a, b]))[0];
    expect(link.notes).toHaveLength(2);
  });
});

describe("transformMessages — Sent-only roots", () => {
  const sentOnly = msg({
    uid: 4,
    mailbox: "Sent Messages",
    messageId: "<mine@icloud.com>",
    from: [{ address: "kris@icloud.com", name: "Kris" }],
    subject: "Re: something older than the window",
    flags: ["\\Seen"],
  });

  it("omits BOTH title and unread when the batch saw only the owner's Sent copies", () => {
    // The inbound half of the conversation is outside the fetched window, so
    // this batch knows neither the real subject nor the read state. Both keys
    // are last-writer-wins, and a present key of ANY value overwrites.
    const link = transformMessages(
      [sentOnly],
      incrementalCtxFor([sentOnly], { sentMailbox: "Sent Messages" })
    )[0];
    expect("title" in link).toBe(false);
    expect("unread" in link).toBe(false);
  });

  it("sets title and unread normally as soon as ONE non-Sent message is in the batch", () => {
    const inbound = msg({
      uid: 8,
      mailbox: "INBOX",
      messageId: "<theirs@example.com>",
      references: ["<mine@icloud.com>"],
      subject: "The real subject",
      date: new Date("2026-07-15T09:00:00Z"),
      flags: ["\\Seen"],
    });
    const batch = [sentOnly, inbound];
    const link = transformMessages(
      batch,
      incrementalCtxFor(batch, { sentMailbox: "Sent Messages" })
    )[0];
    expect(link.title).toBe("The real subject");
    expect(link.unread).toBe(false);
  });

  it("still marks a never-before-seen Sent-only root read, so a backfill cannot notify", () => {
    // `initialRoots` wins over the omit rule for `unread`: omitting the key on
    // INSERT falls through to the database default (unread) and notifies for a
    // thread the user has never been shown.
    const link = transformMessages(
      [sentOnly],
      ctxFor([sentOnly], { sentMailbox: "Sent Messages" })
    )[0];
    expect(link.unread).toBe(false);
    expect(link.archived).toBe(false);
  });

  it("an INITIAL Sent-only root gets a title from the subject, never 'Untitled' — CRITICAL", () => {
    // `initialRoots` must win for `title` too, exactly like it does for
    // `unread` above — NOT just for `unread`. This is an INSERT (the root
    // has never been synced before), and `title` is the one field the
    // runtime has NO fallback default for: an omitted key on INSERT makes
    // the runtime substitute the literal placeholder "Untitled", and every
    // later pass for a still-Sent-only thread would keep omitting the key
    // too — so it stays "Untitled" PERMANENTLY. A degraded "Re: …" subject
    // from the Sent copy is strictly better, and gets overwritten with the
    // real subject the moment an inbound message enters the window.
    //
    // DO NOT "fix" this back to omitting `title` here — that reintroduces
    // the permanent-Untitled regression. See `sync.test.ts`'s "never
    // 'Untitled'" assertion for the analogous calendar-bundle trap.
    const link = transformMessages(
      [sentOnly],
      ctxFor([sentOnly], { sentMailbox: "Sent Messages" })
    )[0];
    expect(link.title).toBe("Re: something older than the window");
  });

  it("a NON-initial (already-known) Sent-only root still omits title, unlike the initial case", () => {
    // Once Plot already has this thread, omitting `title` PRESERVES the
    // existing (possibly real, non-degraded) title instead of clobbering it
    // with a Sent-copy subject the batch can't be sure is authoritative.
    const link = transformMessages(
      [sentOnly],
      incrementalCtxFor([sentOnly], { sentMailbox: "Sent Messages" })
    )[0];
    expect("title" in link).toBe(false);
    expect("unread" in link).toBe(false);
  });

  it("does not apply the rule when the caller passes no Sent mailbox", () => {
    const link = transformMessages([sentOnly], incrementalCtxFor([sentOnly]))[0];
    expect(link.title).toBe("Re: something older than the window");
  });
});
