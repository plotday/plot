import { describe, expect, it, vi } from "vitest";
import type { CreateLinkDraft, Thread } from "@plotday/twister";
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
}): { host: MailHost; sent: SmtpMessage[]; flagCalls: Array<{ uids: number[]; flags: string[]; op: string }> } {
  const sent: SmtpMessage[] = [];
  const flagCalls: Array<{ uids: number[]; flags: string[]; op: string }> = [];
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
  const store = new Map<string, unknown>();
  const host = {
    imap, smtp,
    integrations: {} as never,
    appleId: "me@icloud.com",
    appPassword: "pw",
    set: vi.fn(async (key: string, value: unknown) => {
      store.set(key, value);
    }),
    get: vi.fn(async (key: string) => store.get(key)),
    clear: async () => {},
    channelSyncCompleted: async () => {},
  } as unknown as MailHost;
  return { host, sent, flagCalls };
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

  it("no-ops when nothing resolves or the thread isn't apple-mail", async () => {
    const none = mockHost({ inboxMessages: [] });
    await onThreadReadFn(none.host, mailThread(), {} as never, false);
    expect(none.flagCalls).toHaveLength(0);

    const cal = mockHost({ inboxMessages: inbox });
    await onThreadToDoFn(cal.host, mailThread({ meta: { syncProvider: "apple" } as never }), {} as never, true, {});
    expect(cal.flagCalls).toHaveLength(0);
  });

  it("no-ops silently (no throw, no setFlags) when IMAP resolve fails", async () => {
    const { host, flagCalls } = mockHost({ searchError: new Error("connection refused") });
    await expect(onThreadReadFn(host, mailThread(), {} as never, false)).resolves.toBeUndefined();
    expect(flagCalls).toHaveLength(0);
  });
});
