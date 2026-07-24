import { describe, expect, it, vi } from "vitest";
import { ActionType, type CreateLinkDraft, type Thread } from "@plotday/twister";
import type { Note } from "@plotday/twister/plot";
import type { ImapMessage } from "@plotday/twister/tools/imap";
import type { SmtpMessage, SmtpSendResult } from "@plotday/twister/tools/smtp";

import type { MailHost } from "./mail-host";
import { onCreateLinkFn, onNoteCreatedFn, onThreadReadFn, onThreadToDoFn } from "./write";

/** A MailHost whose IMAP returns `inboxMessages` from search+fetch and whose
 *  SMTP records the sent message (or throws `sendError`). `set`/`get` are
 *  backed by a real Map (not independent no-ops) so a single mockHost()
 *  instance can exercise the compose dedup path across sequential calls.
 *  `flagCalls` records every `imap.setFlags` invocation for write-back tests.
 *  `searchError`, if set, makes `imap.search` reject — simulating a transient
 *  IMAP failure inside `resolveThreadMessages` (after connect+selectMailbox,
 *  so it also exercises the `disconnect` path via the inner `finally`). */
function mockHost(opts: {
  inboxMessages?: Partial<ImapMessage>[];
  sendError?: Error;
  searchError?: Error;
  files?: Record<string, { data: Uint8Array; fileName: string; mimeType: string; fileSize: number }>;
  attachmentBytes?: Record<string, Uint8Array>;
  attachmentFailing?: Set<string>;
}): {
  host: MailHost;
  sent: SmtpMessage[];
  flagCalls: Array<{ uids: number[]; flags: string[]; op: string }>;
  fileReads: string[];
  queuedDrains: string[];
} {
  const sent: SmtpMessage[] = [];
  const flagCalls: Array<{ uids: number[]; flags: string[]; op: string }> = [];
  const fileReads: string[] = [];
  const queuedDrains: string[] = [];
  const uids = (opts.inboxMessages ?? []).map((_m, i) => i + 1);
  const imap = {
    connect: async () => "s",
    disconnect: async () => {},
    listMailboxes: async () => [],
    selectMailbox: async (_s: string, box: string) => ({
      name: box, exists: 0, recent: 0, uidValidity: 1, uidNext: 99,
    }),
    search: async () => {
      if (opts.searchError) throw opts.searchError;
      return uids;
    },
    fetchMessages: async (_s: string, u: number[]) =>
      u.map((uid) => ({ uid, flags: [], ...(opts.inboxMessages ?? [])[uid - 1] }) as ImapMessage),
    setFlags: async (_s: string, uids: number[], flags: string[], op: string) => {
      flagCalls.push({ uids, flags, op });
    },
    fetchAttachment: async (_s: string, _uid: number, partNumber: string) => {
      if (opts.attachmentFailing?.has(partNumber)) throw new Error(`fetch failed: ${partNumber}`);
      const bytes = opts.attachmentBytes?.[partNumber];
      if (!bytes) throw new Error(`no such part: ${partNumber}`);
      return bytes;
    },
  };
  const smtp = {
    connect: async () => "smtp",
    disconnect: async () => {},
    send: async (_s: string, m: SmtpMessage): Promise<SmtpSendResult> => {
      if (opts.sendError) throw opts.sendError;
      sent.push(m);
      return { messageId: "<sent-123@plot.day>", accepted: m.to.map((a) => a.address), rejected: [] };
    },
  };
  const files = {
    read: vi.fn(async (fileId: string) => {
      fileReads.push(fileId);
      const file = opts.files?.[fileId];
      if (!file) throw new Error(`no such file: ${fileId}`);
      return file;
    }),
  };
  const store = new Map<string, unknown>();
  const host = {
    imap, smtp,
    // Only `setThreadToDo` is exercised by these tests (the read-direction
    // reconciliation lives in sync.ts/sync.test.ts); stubbed here so any
    // future write.ts code path that reaches for it doesn't hit `undefined`.
    integrations: { setThreadToDo: vi.fn() } as never,
    files,
    appleId: "me@icloud.com",
    appPassword: "pw",
    set: vi.fn(async (key: string, value: unknown) => {
      store.set(key, value);
    }),
    get: vi.fn(async (key: string) => store.get(key)),
    clear: vi.fn(async (key: string) => {
      store.delete(key);
    }),
    channelSyncCompleted: async () => {},
    queueWritebackDrain: vi.fn(async (id: string) => {
      queuedDrains.push(id);
    }),
  } as unknown as MailHost;
  return { host, sent, flagCalls, fileReads, queuedDrains };
}

function mailThread(over: Partial<Thread> = {}): Thread {
  return {
    id: "t1", created: new Date(), archived: false, tags: {}, reactions: {},
    title: "Lunch?", focus: {} as never, type: null, access: "members",
    accessContacts: [], meta: { syncProvider: "apple-mail", rootMessageId: "root@x.com", channelId: "mail:INBOX" },
    ...over,
  } as unknown as Thread;
}

function replyNote(over: Partial<Note> = {}): Note {
  return { content: "Sounds good!", recipients: null, ...over } as unknown as Note;
}

describe("onNoteCreatedFn", () => {
  it("no-ops for non-apple-mail threads", async () => {
    const { host, sent } = mockHost({});
    const out = await onNoteCreatedFn(host, replyNote(), mailThread({ meta: { syncProvider: "apple" } as never }));
    expect(out).toBeUndefined();
    expect(sent).toHaveLength(0);
  });

  it("reply-alls from the latest message, threads it, and returns the sent key", async () => {
    const { host, sent } = mockHost({
      inboxMessages: [
        { messageId: "<root@x.com>", from: [{ address: "jane@x.com" }], to: [{ address: "me@icloud.com" }],
          subject: "Lunch?", date: new Date("2026-07-15T10:00:00Z") },
        { messageId: "<r2@x.com>", references: ["<root@x.com>"], from: [{ address: "jane@x.com" }],
          to: [{ address: "me@icloud.com" }, { address: "bob@x.com" }], subject: "Re: Lunch?",
          date: new Date("2026-07-15T11:00:00Z") },
      ],
    });
    const out = await onNoteCreatedFn(host, replyNote(), mailThread());
    expect(sent).toHaveLength(1);
    const m = sent[0];
    expect(m.subject).toBe("Re: Lunch?");
    expect(m.to.map((a) => a.address).sort()).toEqual(["bob@x.com", "jane@x.com"]);
    expect(m.inReplyTo).toBe("<r2@x.com>");
    expect(m.references?.[m.references.length - 1]).toBe("<r2@x.com>");
    expect(m.from.address).toBe("me@icloud.com");
    expect(out).toEqual({ key: "sent-123@plot.day", deliveryError: null });
  });

  it("uses curated note.recipients when present (role-split)", async () => {
    const { host, sent } = mockHost({ inboxMessages: [
      { messageId: "<root@x.com>", subject: "Lunch?", date: new Date("2026-07-15T10:00:00Z") },
    ] });
    const note = replyNote({
      recipients: [
        { id: "1", name: null, externalAccountId: "a@x.com", role: "to" },
        { id: "2", name: null, externalAccountId: "c@x.com", role: "cc" },
      ] as never,
    });
    await onNoteCreatedFn(host, note, mailThread());
    expect(sent[0].to.map((a) => a.address)).toEqual(["a@x.com"]);
    expect(sent[0].cc?.map((a) => a.address)).toEqual(["c@x.com"]);
  });

  it("returns a deliveryError (no throw) when the send is rejected", async () => {
    const { host } = mockHost({
      inboxMessages: [{ messageId: "<root@x.com>", from: [{ address: "jane@x.com" }], subject: "Lunch?", date: new Date() }],
      sendError: new Error("RCPT TO failed: 550 rejected"),
    });
    const out = await onNoteCreatedFn(host, replyNote(), mailThread());
    expect(out).toMatchObject({ deliveryError: { code: "rejected" } });
  });

  it("returns no_recipients when nothing resolves and no curated set", async () => {
    const { host } = mockHost({ inboxMessages: [] });
    const out = await onNoteCreatedFn(host, replyNote(), mailThread({ accessContacts: [] }));
    expect(out).toMatchObject({ deliveryError: { code: "no_recipients" } });
  });

  // Mid-thread recipient changes: the email link type declares
  // `supportsContactChanges`, so the user can add or drop people on an
  // existing thread. Those edits reach the connector as the note's access
  // list, which the reply path must honour — deriving recipients from the
  // latest message's headers alone silently drops whoever was just added.
  it("addresses someone added mid-thread who is not on the latest message", async () => {
    const { host, sent } = mockHost({
      inboxMessages: [
        { messageId: "<root@x.com>", from: [{ address: "jane@x.com", name: "Jane" }],
          to: [{ address: "me@icloud.com" }], subject: "Lunch?", date: new Date("2026-07-15T10:00:00Z") },
      ],
    });
    const note = replyNote({
      // No curated `recipients` (older runtime): the access list is the only
      // signal that Bob was added.
      accessContacts: ["c-jane", "c-bob"] as never,
      author: { id: "c-me" } as never,
    });
    const thread = mailThread({
      accessContacts: [
        { id: "c-jane", email: "jane@x.com", name: "Jane" },
        { id: "c-bob", email: "bob@x.com", name: "Bob" },
        { id: "c-me", email: "me@icloud.com", name: "Me" },
      ] as never,
    });

    await onNoteCreatedFn(host, note, thread);

    expect(sent[0].to.map((a) => a.address).sort()).toEqual(["bob@x.com", "jane@x.com"]);
  });

  it("drops a header participant the user removed from this note's access list", async () => {
    const { host, sent } = mockHost({
      inboxMessages: [
        { messageId: "<root@x.com>", from: [{ address: "jane@x.com", name: "Jane" }],
          to: [{ address: "me@icloud.com" }], cc: [{ address: "bob@x.com" }],
          subject: "Lunch?", date: new Date("2026-07-15T10:00:00Z") },
      ],
    });
    const note = replyNote({
      accessContacts: ["c-jane"] as never,
      author: { id: "c-me" } as never,
    });
    const thread = mailThread({
      accessContacts: [
        { id: "c-jane", email: "jane@x.com", name: "Jane" },
        { id: "c-bob", email: "bob@x.com", name: "Bob" },
        { id: "c-me", email: "me@icloud.com", name: "Me" },
      ] as never,
    });

    await onNoteCreatedFn(host, note, thread);

    expect(sent[0].to.map((a) => a.address)).toEqual(["jane@x.com"]);
    expect(sent[0].cc ?? []).toEqual([]);
  });

  it("sends nothing, and reports no failure, for a note shared with nobody but its author", async () => {
    // Under the message sharing model a user can write a note on a mail
    // thread that is private to them. That isn't a send that failed — it's a
    // note that was never addressed to anyone, so it must not surface
    // "Failed to send".
    const { host, sent } = mockHost({
      inboxMessages: [
        { messageId: "<root@x.com>", from: [{ address: "jane@x.com" }],
          subject: "Lunch?", date: new Date("2026-07-15T10:00:00Z") },
      ],
    });
    const note = replyNote({
      accessContacts: ["c-me"] as never,
      author: { id: "c-me" } as never,
    });
    const thread = mailThread({
      accessContacts: [{ id: "c-me", email: "me@icloud.com", name: "Me" }] as never,
    });

    const out = await onNoteCreatedFn(host, note, thread);

    expect(sent).toHaveLength(0);
    expect(out).toBeUndefined();
  });

  it("still surfaces no_recipients when the user chose people but none are addressable", async () => {
    const { host, sent } = mockHost({ inboxMessages: [] });
    const note = replyNote({
      accessContacts: ["c-me", "c-ghost"] as never,
      author: { id: "c-me" } as never,
    });
    const thread = mailThread({
      accessContacts: [
        { id: "c-me", email: "me@icloud.com", name: "Me" },
        // A contact with no email address — chosen, but not addressable.
        { id: "c-ghost", email: null, name: "Ghost" },
      ] as never,
    });

    const out = await onNoteCreatedFn(host, note, thread);

    expect(sent).toHaveLength(0);
    expect(out).toMatchObject({ deliveryError: { code: "no_recipients" } });
  });

  it("keeps display names on header-derived recipients", async () => {
    const { host, sent } = mockHost({
      inboxMessages: [
        { messageId: "<root@x.com>", from: [{ address: "jane@x.com", name: "Jane Doe" }],
          to: [{ address: "me@icloud.com" }], subject: "Lunch?", date: new Date("2026-07-15T10:00:00Z") },
      ],
    });

    await onNoteCreatedFn(host, replyNote(), mailThread());

    expect(sent[0].to).toEqual([{ address: "jane@x.com", name: "Jane Doe" }]);
  });

  it("never addresses the reply to the connection owner's own address", async () => {
    const { host, sent } = mockHost({
      inboxMessages: [
        { messageId: "<root@x.com>", from: [{ address: "jane@x.com" }],
          to: [{ address: "me@icloud.com" }, { address: "bob@x.com" }],
          subject: "Lunch?", date: new Date("2026-07-15T10:00:00Z") },
      ],
    });

    await onNoteCreatedFn(host, replyNote(), mailThread());

    expect(sent[0].to.map((a) => a.address)).not.toContain("me@icloud.com");
  });

  it("proceeds via the accessContacts + root-id fallback when IMAP resolve throws", async () => {
    const { host, sent } = mockHost({ searchError: new Error("connection refused") });
    const note = replyNote({
      recipients: [
        { id: "1", name: null, externalAccountId: "jane@x.com", role: "to" },
      ] as never,
    });
    const out = await onNoteCreatedFn(host, note, mailThread());
    expect(sent).toHaveLength(1);
    expect(sent[0].inReplyTo).toBe("<root@x.com>");
    expect(out).toEqual({ key: "sent-123@plot.day", deliveryError: null });
  });

  it("reads ActionType.file note actions via Files.read and attaches their bytes", async () => {
    const data = new Uint8Array([1, 2, 3]);
    const { host, sent, fileReads } = mockHost({
      inboxMessages: [{ messageId: "<root@x.com>", from: [{ address: "jane@x.com" }], subject: "Lunch?", date: new Date() }],
      files: { "file-1": { data, fileName: "photo.png", mimeType: "image/png", fileSize: 3 } },
    });
    const note = replyNote({
      actions: [
        { type: ActionType.file, fileId: "file-1", fileName: "photo.png", fileSize: 3, mimeType: "image/png" },
      ] as never,
    });
    await onNoteCreatedFn(host, note, mailThread());
    expect(fileReads).toEqual(["file-1"]);
    expect(sent[0].attachments).toEqual([
      { fileName: "photo.png", mimeType: "image/png", data },
    ]);
  });

  it("omits attachments entirely (no empty array) when the note has no file actions", async () => {
    const { host, sent } = mockHost({
      inboxMessages: [{ messageId: "<root@x.com>", from: [{ address: "jane@x.com" }], subject: "Lunch?", date: new Date() }],
    });
    await onNoteCreatedFn(host, replyNote(), mailThread());
    expect(sent[0].attachments).toBeUndefined();
  });

  it("skips a file that fails to read and still sends the rest of the message", async () => {
    const { host, sent, fileReads } = mockHost({
      inboxMessages: [{ messageId: "<root@x.com>", from: [{ address: "jane@x.com" }], subject: "Lunch?", date: new Date() }],
      files: {}, // "missing" throws inside the mock files.read
    });
    const note = replyNote({
      actions: [
        { type: ActionType.file, fileId: "missing", fileName: "x.png", fileSize: 1, mimeType: "image/png" },
      ] as never,
    });
    const out = await onNoteCreatedFn(host, note, mailThread());
    expect(fileReads).toEqual(["missing"]);
    expect(sent).toHaveLength(1);
    expect(sent[0].attachments).toBeUndefined();
    expect(out).toEqual({ key: "sent-123@plot.day", deliveryError: null });
  });
});

function emailDraft(over: Partial<CreateLinkDraft> = {}): CreateLinkDraft {
  return {
    channelId: "mail:INBOX",
    type: "email",
    status: null,
    title: "Coffee next week?",
    noteContent: "Are you free Tuesday?",
    contacts: [],
    recipients: [{ id: "1", name: null, externalAccountId: "jane@x.com", role: "to" }] as never,
    inviteEmails: ["bob@x.com"],
    ...over,
  } as unknown as CreateLinkDraft;
}

describe("onCreateLinkFn", () => {
  it("returns null for non-email link types", async () => {
    const { host } = mockHost({});
    expect(await onCreateLinkFn(host, emailDraft({ type: "event" }))).toBeNull();
  });

  it("sends the composed mail and roots the link source at the sent Message-ID", async () => {
    const { host, sent } = mockHost({});
    const out = await onCreateLinkFn(host, emailDraft(), new Date("2026-07-20T00:00:00Z"));
    expect(sent).toHaveLength(1);
    expect(sent[0].to.map((a) => a.address).sort()).toEqual(["bob@x.com", "jane@x.com"]);
    expect(sent[0].subject).toBe("Coffee next week?");
    expect(out?.source).toBe("icloud-mail:thread:sent-123@plot.day");
    expect(out?.type).toBe("email");
    expect(out?.originatingNote).toEqual({ key: "sent-123@plot.day", deliveryError: null });
    // `notes[0]` types as `Omit<NewNote, "thread">`, which — due to a TS
    // keyof-of-union quirk — excludes `key` even though NewNote allows it;
    // cast to read the field the runtime actually receives at this shape.
    const rootNote = out?.notes?.[0] as unknown as { key?: string; authoredBySelf?: boolean } | undefined;
    expect(rootNote?.key).toBe("sent-123@plot.day");
    expect(rootNote?.authoredBySelf).toBe(true);
    // channelId omitted so the platform auto-fills from the draft.
    expect(out?.channelId ?? null).toBeNull();
  });

  it("surfaces a send failure on the originating note without a link source", async () => {
    const { host } = mockHost({ sendError: new Error("550 rejected") });
    const out = await onCreateLinkFn(host, emailDraft());
    expect(out?.originatingNote?.deliveryError).toMatchObject({ code: "rejected" });
    expect(out?.source).toBeUndefined();
  });

  it("returns no_recipients when the draft has no addresses", async () => {
    const { host } = mockHost({});
    const out = await onCreateLinkFn(host, emailDraft({ recipients: [] as never, inviteEmails: [] }));
    expect(out?.originatingNote?.deliveryError).toMatchObject({ code: "no_recipients" });
  });

  it("reads draft.attachments via Files.read and attaches their bytes to the composed mail", async () => {
    const data = new Uint8Array([9, 9, 9]);
    const { host, sent, fileReads } = mockHost({
      files: { "file-2": { data, fileName: "agenda.pdf", mimeType: "application/pdf", fileSize: 3 } },
    });
    const draft = emailDraft({
      attachments: [{ fileId: "file-2", fileName: "agenda.pdf", mimeType: "application/pdf", fileSize: 3 }],
    } as never);
    await onCreateLinkFn(host, draft, new Date("2026-07-20T00:00:00Z"));
    expect(fileReads).toEqual(["file-2"]);
    expect(sent[0].attachments).toEqual([
      { fileName: "agenda.pdf", mimeType: "application/pdf", data },
    ]);
  });

  it("omits attachments entirely when the draft has none", async () => {
    const { host, sent } = mockHost({});
    await onCreateLinkFn(host, emailDraft(), new Date("2026-07-20T00:00:00Z"));
    expect(sent[0].attachments).toBeUndefined();
  });

  it("dedupes an identical re-invoked draft inside the window, but re-sends on different content or after the window", async () => {
    const { host, sent } = mockHost({});
    const draft = emailDraft();
    const t0 = new Date("2026-07-20T00:00:00Z");

    const first = await onCreateLinkFn(host, draft, t0);
    expect(sent).toHaveLength(1);

    // Same content, 5 minutes later — still inside the 10-minute window: no
    // second SMTP send; the dedup hit reuses the prior root id.
    const dup = await onCreateLinkFn(host, draft, new Date(t0.getTime() + 5 * 60 * 1000));
    expect(sent).toHaveLength(1);
    expect(dup?.originatingNote?.key).toBe(first?.originatingNote?.key);

    // Different content → distinct dedup key → sends again.
    await onCreateLinkFn(host, emailDraft({ title: "Something else" }), new Date(t0.getTime() + 5 * 60 * 1000));
    expect(sent).toHaveLength(2);

    // Same original content again, but past the 10-minute window → sends again.
    await onCreateLinkFn(host, draft, new Date(t0.getTime() + 11 * 60 * 1000));
    expect(sent).toHaveLength(3);
  });
});

function forwardDraft(over: Partial<CreateLinkDraft> = {}): CreateLinkDraft {
  return {
    channelId: "mail:INBOX",
    type: "email",
    status: null,
    title: "Coffee next week?",
    noteContent: "Check this out!",
    contacts: [],
    recipients: [{ id: "1", name: null, externalAccountId: "jane@x.com", role: "to" }] as never,
    inviteEmails: ["bob@x.com"],
    forward: { key: "root@x.com" },
    ...over,
  } as unknown as CreateLinkDraft;
}

const originalMessage: Partial<ImapMessage> = {
  messageId: "<root@x.com>",
  from: [{ address: "sender@x.com", name: "Sender Person" }],
  to: [{ address: "me@icloud.com" }],
  subject: "Original subject line",
  date: new Date("2026-07-10T09:00:00Z"),
  bodyText: "This is the original message body.",
};

describe("onCreateLinkFn (forward)", () => {
  it("builds a Fwd: subject, omits In-Reply-To/References, and composes forwarder-note-on-top body", async () => {
    const { host, sent } = mockHost({ inboxMessages: [originalMessage] });
    const out = await onCreateLinkFn(host, forwardDraft(), new Date("2026-07-20T00:00:00Z"));
    expect(sent).toHaveLength(1);
    const m = sent[0];
    expect(m.subject).toBe("Fwd: Coffee next week?");
    expect(m.inReplyTo).toBeUndefined();
    expect(m.references).toBeUndefined();
    // Forwarder's own note sits above the quoted attribution block + original body.
    const text = m.text ?? "";
    const noteIdx = text.indexOf("Check this out!");
    const separatorIdx = text.indexOf("---------- Forwarded message ----------");
    const bodyIdx = text.indexOf("This is the original message body.");
    expect(noteIdx).toBeGreaterThanOrEqual(0);
    expect(separatorIdx).toBeGreaterThan(noteIdx);
    expect(bodyIdx).toBeGreaterThan(separatorIdx);
    expect(m.text).toContain("From: Sender Person <sender@x.com>");
    expect(m.text).toContain("Subject: Original subject line");
    expect(m.text).toContain("To: me@icloud.com");
    expect(m.to.map((a) => a.address).sort()).toEqual(["bob@x.com", "jane@x.com"]);
    expect(out?.source).toBe("icloud-mail:thread:sent-123@plot.day");
    expect(out?.type).toBe("email");
    expect(out?.originatingNote).toEqual({
      key: "sent-123@plot.day",
      externalContent: text,
      deliveryError: null,
    });
    // externalContent must equal exactly what was sent, so the Sent-mailbox
    // re-ingest's baseline hash matches and Plot's clean forwarder note
    // (draft.noteContent only) is preserved instead of overwritten by the
    // full quoted blob that IMAP will read back.
    expect(out?.originatingNote?.externalContent).toBe(m.text);
  });

  it("leaves an already-prefixed Fwd: subject unchanged", async () => {
    const { host, sent } = mockHost({ inboxMessages: [originalMessage] });
    await onCreateLinkFn(
      host,
      forwardDraft({ title: "Fwd: Already prefixed" }),
      new Date("2026-07-20T00:00:00Z")
    );
    expect(sent[0].subject).toBe("Fwd: Already prefixed");
  });

  it("re-attaches the original message's attachments", async () => {
    const data = new Uint8Array([1, 2, 3]);
    const withAttachment = {
      ...originalMessage,
      attachments: [
        { partNumber: "2", fileName: "photo.png", mimeType: "image/png", size: 3, encoding: "base64" },
      ],
    };
    const { host, sent } = mockHost({
      inboxMessages: [withAttachment],
      attachmentBytes: { "2": data },
    });
    await onCreateLinkFn(host, forwardDraft(), new Date("2026-07-20T00:00:00Z"));
    expect(sent[0].attachments).toEqual([{ fileName: "photo.png", mimeType: "image/png", data }]);
  });

  it("skips an attachment part that fails to fetch and still sends the forward", async () => {
    const data = new Uint8Array([4, 5]);
    const withAttachments = {
      ...originalMessage,
      attachments: [
        { partNumber: "2", fileName: "bad.png", mimeType: "image/png", size: 1, encoding: "base64" },
        { partNumber: "3", fileName: "good.png", mimeType: "image/png", size: 2, encoding: "base64" },
      ],
    };
    const { host, sent } = mockHost({
      inboxMessages: [withAttachments],
      attachmentBytes: { "3": data },
      attachmentFailing: new Set(["2"]),
    });
    await onCreateLinkFn(host, forwardDraft(), new Date("2026-07-20T00:00:00Z"));
    expect(sent).toHaveLength(1);
    expect(sent[0].attachments).toEqual([{ fileName: "good.png", mimeType: "image/png", data }]);
  });

  it("returns a not_found deliveryError when the original message can't be located", async () => {
    const { host } = mockHost({ inboxMessages: [] });
    const out = await onCreateLinkFn(host, forwardDraft(), new Date("2026-07-20T00:00:00Z"));
    expect(out?.originatingNote?.deliveryError).toMatchObject({ code: "not_found" });
    expect(out?.source).toBeUndefined();
  });

  it("returns an imap_unavailable deliveryError (does not throw) when fetching the original message throws", async () => {
    const { host, sent } = mockHost({
      inboxMessages: [originalMessage],
      searchError: new Error("connection refused"),
    });
    const out = await onCreateLinkFn(host, forwardDraft(), new Date("2026-07-20T00:00:00Z"));
    expect(out?.originatingNote?.deliveryError).toMatchObject({ code: "imap_unavailable" });
    expect(out?.source).toBeUndefined();
    expect(sent).toHaveLength(0);
  });

  it("returns no_recipients when the forward draft has no addresses", async () => {
    const { host } = mockHost({ inboxMessages: [originalMessage] });
    const out = await onCreateLinkFn(
      host,
      forwardDraft({ recipients: [] as never, inviteEmails: [] }),
      new Date("2026-07-20T00:00:00Z")
    );
    expect(out?.originatingNote?.deliveryError).toMatchObject({ code: "no_recipients" });
  });

  it("surfaces a send failure on the originating note without a link source", async () => {
    const { host } = mockHost({
      inboxMessages: [originalMessage],
      sendError: new Error("550 rejected"),
    });
    const out = await onCreateLinkFn(host, forwardDraft(), new Date("2026-07-20T00:00:00Z"));
    expect(out?.originatingNote?.deliveryError).toMatchObject({ code: "rejected" });
    expect(out?.source).toBeUndefined();
  });

  it("dedupes an identical re-invoked forward inside the window, but re-sends on different content or after the window", async () => {
    const { host, sent } = mockHost({ inboxMessages: [originalMessage] });
    const draft = forwardDraft();
    const t0 = new Date("2026-07-20T00:00:00Z");

    const first = await onCreateLinkFn(host, draft, t0);
    expect(sent).toHaveLength(1);

    // Same content, 5 minutes later — still inside the 10-minute window: no
    // second SMTP send; the dedup hit reuses the prior root id.
    const dup = await onCreateLinkFn(host, draft, new Date(t0.getTime() + 5 * 60 * 1000));
    expect(sent).toHaveLength(1);
    expect(dup?.originatingNote?.key).toBe(first?.originatingNote?.key);
    // The dedup-hit return must carry the same externalContent baseline as
    // the original send, not omit it — otherwise a re-invoked dispatch loses
    // sync-baseline protection for the note the first send already sent.
    expect(dup?.originatingNote?.externalContent).toBe(first?.originatingNote?.externalContent);
    expect(dup?.originatingNote?.externalContent).toBe(sent[0].text);

    // Different content → distinct dedup key → sends again.
    await onCreateLinkFn(
      host,
      forwardDraft({ noteContent: "A different note" }),
      new Date(t0.getTime() + 5 * 60 * 1000)
    );
    expect(sent).toHaveLength(2);

    // Same original content again, but past the 10-minute window → sends again.
    await onCreateLinkFn(host, draft, new Date(t0.getTime() + 11 * 60 * 1000));
    expect(sent).toHaveLength(3);
  });
});

describe("onThreadReadFn / onThreadToDoFn", () => {
  const inbox = [
    { messageId: "<root@x.com>", subject: "Lunch?", date: new Date("2026-07-15T10:00:00Z") },
    { messageId: "<r2@x.com>", references: ["<root@x.com>"], subject: "Re: Lunch?", date: new Date("2026-07-15T11:00:00Z") },
  ];

  it("adds \\Seen on read and removes it on unread across the thread's uids", async () => {
    const read = mockHost({ inboxMessages: inbox });
    await onThreadReadFn(read.host, mailThread(), {} as never, false);
    expect(read.flagCalls).toEqual([{ uids: [1, 2], flags: ["\\Seen"], op: "add" }]);

    const unread = mockHost({ inboxMessages: inbox });
    await onThreadReadFn(unread.host, mailThread(), {} as never, true);
    expect(unread.flagCalls[0].op).toBe("remove");
  });

  it("toggles \\Flagged for to-do", async () => {
    const todo = mockHost({ inboxMessages: inbox });
    await onThreadToDoFn(todo.host, mailThread(), {} as never, true, {});
    expect(todo.flagCalls).toEqual([{ uids: [1, 2], flags: ["\\Flagged"], op: "add" }]);
  });

  it("sets the flagged:<rootId> echo-dedup marker BEFORE writing \\Flagged over IMAP", async () => {
    const { host, flagCalls } = mockHost({ inboxMessages: inbox });
    const setFlagsSpy = vi.spyOn(host.imap, "setFlags");

    await onThreadToDoFn(host, mailThread(), {} as never, true, {});

    expect(host.set).toHaveBeenCalledWith("flagged:root@x.com", true);
    const setCallOrder = (host.set as ReturnType<typeof vi.fn>).mock.invocationCallOrder[0];
    const setFlagsCallOrder = setFlagsSpy.mock.invocationCallOrder[0];
    expect(setCallOrder).toBeLessThan(setFlagsCallOrder);
    expect(flagCalls).toEqual([{ uids: [1, 2], flags: ["\\Flagged"], op: "add" }]);
  });

  it("marks the marker false when clearing the to-do", async () => {
    const { host } = mockHost({ inboxMessages: inbox });
    await onThreadToDoFn(host, mailThread(), {} as never, false, {});
    expect(host.set).toHaveBeenCalledWith("flagged:root@x.com", false);
  });

  it("no-ops when nothing resolves or the thread isn't apple-mail — not a failure, so no defer/drain", async () => {
    const none = mockHost({ inboxMessages: [] });
    await onThreadReadFn(none.host, mailThread(), {} as never, false);
    expect(none.flagCalls).toHaveLength(0);
    expect(none.host.set).not.toHaveBeenCalled();
    expect(none.queuedDrains).toHaveLength(0);

    const cal = mockHost({ inboxMessages: inbox });
    await onThreadToDoFn(cal.host, mailThread({ meta: { syncProvider: "apple" } as never }), {} as never, true, {});
    expect(cal.flagCalls).toHaveLength(0);
    expect(cal.host.set).not.toHaveBeenCalled();
    expect(cal.queuedDrains).toHaveLength(0);
  });

  it("defers a durable retry (persists the desired flag + queues the drain) when IMAP resolve fails for a read toggle", async () => {
    const { host, flagCalls, queuedDrains } = mockHost({
      searchError: new Error("connection refused"),
    });
    await expect(onThreadReadFn(host, mailThread(), {} as never, false)).resolves.toBeUndefined();
    expect(flagCalls).toHaveLength(0);
    expect(host.set).toHaveBeenCalledWith("writeback:read:root@x.com", {
      title: "Lunch?",
      flag: "\\Seen",
      operation: "add",
    });
    expect(queuedDrains).toEqual(["read:root@x.com"]);
  });

  it("defers a durable retry keyed \"todo\" when IMAP resolve fails for a to-do toggle", async () => {
    const { host, flagCalls, queuedDrains } = mockHost({
      searchError: new Error("connection refused"),
    });
    await expect(
      onThreadToDoFn(host, mailThread(), {} as never, true, {})
    ).resolves.toBeUndefined();
    expect(flagCalls).toHaveLength(0);
    expect(host.set).toHaveBeenCalledWith("writeback:todo:root@x.com", {
      title: "Lunch?",
      flag: "\\Flagged",
      operation: "add",
    });
    expect(queuedDrains).toEqual(["todo:root@x.com"]);
    // The echo-dedup marker is set unconditionally BEFORE the IMAP attempt,
    // so it still reflects Plot's intent even though the write itself
    // deferred to the writeback retry queue (see onThreadToDoFn's doc).
    expect(host.set).toHaveBeenCalledWith("flagged:root@x.com", true);
  });

  // Discriminating tests for the stale-payload bug: a direct write that
  // resolves WITHOUT deferring (success, or a superseding no-op) must clear
  // any `writeback:${kind}:${rootId}` payload left by an earlier failed
  // toggle. Without this, an opposite toggle that succeeds directly leaves
  // the stale payload in place, and the still-queued drain later re-applies
  // the OLD operation — see setThreadFlag's doc comment.
  it("clears any stale writeback payload on a successful direct \\Seen write", async () => {
    const { host } = mockHost({ inboxMessages: inbox });
    await onThreadReadFn(host, mailThread(), {} as never, false);
    expect(host.clear).toHaveBeenCalledWith("writeback:read:root@x.com");
  });

  it("clears any stale writeback payload on a successful direct \\Flagged write", async () => {
    const { host } = mockHost({ inboxMessages: inbox });
    await onThreadToDoFn(host, mailThread(), {} as never, true, {});
    expect(host.clear).toHaveBeenCalledWith("writeback:todo:root@x.com");
  });

  it("clears any stale writeback payload on a superseding no-op (no INBOX uids to flag)", async () => {
    const { host, flagCalls } = mockHost({ inboxMessages: [] });
    await onThreadToDoFn(host, mailThread(), {} as never, true, {});
    expect(flagCalls).toHaveLength(0);
    expect(host.clear).toHaveBeenCalledWith("writeback:todo:root@x.com");
  });
});
