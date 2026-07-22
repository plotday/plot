import { describe, expect, it, vi } from "vitest";
import type { Thread } from "@plotday/twister";
import type { Note } from "@plotday/twister/plot";
import type { ImapMessage } from "@plotday/twister/tools/imap";
import type { SmtpMessage, SmtpSendResult } from "@plotday/twister/tools/smtp";

import type { MailHost } from "./mail-host";
import { onNoteCreatedFn } from "./write";

/** A MailHost whose IMAP returns `inboxMessages` from search+fetch and whose
 *  SMTP records the sent message (or throws `sendError`). */
function mockHost(opts: {
  inboxMessages?: Partial<ImapMessage>[];
  sendError?: Error;
}): { host: MailHost; sent: SmtpMessage[] } {
  const sent: SmtpMessage[] = [];
  const uids = (opts.inboxMessages ?? []).map((_m, i) => i + 1);
  const imap = {
    connect: async () => "s",
    disconnect: async () => {},
    listMailboxes: async () => [],
    selectMailbox: async (_s: string, box: string) => ({
      name: box, exists: 0, recent: 0, uidValidity: 1, uidNext: 99,
    }),
    search: async () => uids,
    fetchMessages: async (_s: string, u: number[]) =>
      u.map((uid) => ({ uid, flags: [], ...(opts.inboxMessages ?? [])[uid - 1] }) as ImapMessage),
    setFlags: async () => {},
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
  const host = {
    imap, smtp,
    integrations: {} as never,
    appleId: "me@icloud.com",
    appPassword: "pw",
    set: vi.fn(async () => {}),
    get: vi.fn(async () => undefined),
    clear: async () => {},
    channelSyncCompleted: async () => {},
  } as unknown as MailHost;
  return { host, sent };
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
});
