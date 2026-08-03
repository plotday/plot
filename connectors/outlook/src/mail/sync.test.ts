import { beforeEach, describe, expect, it, vi } from "vitest";

import type { CreateLinkDraft, NewLinkWithNotes } from "@plotday/twister";
import { priorRsvpKey } from "@plotday/rsvp-fold";

/**
 * Regression coverage for Gmail-alias-aware self-exclusion in the Outlook
 * connector. The connected Outlook mailbox routinely forwards from or
 * sends-as a Gmail address, and Gmail ignores dots (and anything after a
 * "+") in the local part — so a header may address the user through a
 * variant that never string-matches the connected mailbox
 * ("krisbraun@gmail.com" vs "kris.braun@gmail.com"). Before this fix, a
 * plain `toLowerCase()` comparison treated that variant as a third-party
 * recipient and replied to the user's own address.
 */
const { graphApi } = vi.hoisted(() => ({
  graphApi: {
    createDraft: vi.fn(),
    createReplyDraft: vi.fn(),
    updateMessage: vi.fn(),
    getMessage: vi.fn(),
    getConversationMessages: vi.fn(),
    getMimeContent: vi.fn(),
    send: vi.fn(),
  },
}));
vi.mock("./graph-mail-api", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./graph-mail-api")>();
  return { ...actual, GraphMailApi: vi.fn(() => graphApi) };
});
// ensureUserEmailFn reads user_email from store; seed it to avoid a getProfile call.
import {
  onCreateLinkFn,
  onNoteCreatedFn,
  processConversationsFn,
  type OutlookMailSyncHost,
} from "./sync";
import type { GraphMessage } from "./graph-mail-api";

beforeEach(() => {
  vi.clearAllMocks();
});

function makeHost(initial: Record<string, unknown> = {}) {
  const map = new Map<string, unknown>(
    Object.entries({
      enabled_channels: ["inbox"],
      ...initial,
    })
  );
  return {
    map,
    host: {
      id: "ti-1",
      get: vi.fn(async (k: string) => (map.has(k) ? map.get(k) : null)),
      set: vi.fn(async (k: string, v: unknown) => {
        map.set(k, v);
      }),
      clear: vi.fn(async (k: string) => {
        map.delete(k);
      }),
      tools: {
        integrations: { get: vi.fn(async () => ({ token: "tok", scopes: [] })) },
        files: { read: vi.fn() },
      },
    } as never,
  };
}

function replyThread(accountEmail: string) {
  return {
    id: "T",
    meta: { channelId: "inbox", conversationId: "conv-1" },
    accessContacts: [{ id: "c-me", email: accountEmail }],
  } as never;
}

/** A plain reply note with no curated recipients/access constraint — drives
 *  the header-derived reply-all fallback (Case 3 in resolveOutboundReplyRecipients). */
function replyAllNote() {
  return {
    id: "n1",
    author: { id: "c-me" },
    content: "Sounds good",
    accessContacts: null,
    recipients: null,
    actions: [],
  } as never;
}

describe("onNoteCreatedFn — Gmail alias addressed to the connected mailbox", () => {
  it("does not address the reply back to a dot-variant of the account", async () => {
    // The connected Outlook mailbox forwards from a Gmail address; the
    // original message addressed a dot-variant of it. That variant is the
    // user, so it must not appear as an outbound recipient.
    const accountEmail = "kris.braun@gmail.com";
    graphApi.getConversationMessages.mockResolvedValue([
      {
        id: "msg-1",
        isDraft: false,
        from: { emailAddress: { address: "annie@example.com" } },
        toRecipients: [{ emailAddress: { address: "krisbraun@gmail.com" } }],
        ccRecipients: [],
      },
    ]);
    graphApi.createReplyDraft.mockResolvedValue({
      id: "d1",
      internetMessageId: "<imid-1>",
    });
    graphApi.updateMessage.mockResolvedValue(undefined);
    graphApi.getMessage.mockResolvedValue({
      id: "d1",
      internetMessageId: "<imid-1>",
      conversationId: "conv-1",
    });
    graphApi.send.mockResolvedValue(undefined);

    const { host } = makeHost({ user_email: accountEmail });

    await onNoteCreatedFn(host, replyAllNote(), replyThread(accountEmail));

    expect(graphApi.updateMessage).toHaveBeenCalledTimes(1);
    const updateBody = graphApi.updateMessage.mock.calls[0][1];
    expect(updateBody.toRecipients).toEqual([
      { emailAddress: { address: "annie@example.com" } },
    ]);
    expect(updateBody.ccRecipients).toEqual([]);
  });
});

function calThread(over: Record<string, unknown> = {}) {
  return {
    id: "T",
    title: "Weekly sync",
    meta: { calendarId: "cal-1", iCalUId: "uid-123", syncableId: "cal-1" },
    accessContacts: [
      { id: "c-me", email: "kris.braun@gmail.com" },
      { id: "c-alias", email: "krisbraun@gmail.com" },
    ],
    ...over,
  } as never;
}

function curatedCalReplyNote(
  recipients: Array<{ externalAccountId: string; role: string | null }>,
  over: Record<string, unknown> = {}
) {
  return {
    id: "n1",
    author: { id: "c-me" },
    content: "See you there",
    accessContacts: ["c-alias"],
    recipients: recipients.map((r) => ({
      id: r.externalAccountId,
      name: null,
      externalAccountId: r.externalAccountId,
      role: r.role,
    })),
    actions: [],
    ...over,
  } as never;
}

function composeDraft(overrides: Partial<CreateLinkDraft> = {}): CreateLinkDraft {
  return {
    channelId: "inbox",
    type: "email",
    status: null,
    title: "Q3 planning",
    noteContent: "Let's sync on this",
    contacts: [],
    recipients: [],
    inviteEmails: [],
    ...overrides,
  } as CreateLinkDraft;
}

describe("onCreateLinkFn — recipient dedupe recognizes Gmail dot variants", () => {
  it("does not send two copies to the same Gmail mailbox reached via a dot variant", async () => {
    // A picker-resolved recipient ("dana@gmail.com") and a separately typed
    // invite address ("d.ana@gmail.com") are the same Gmail mailbox — Gmail
    // ignores dots in the local part. The dedupe key must recognize this
    // ROW-identity (canonicalizeEmail), not just an exact lowercase match,
    // or the compose sends the same person two copies.
    graphApi.createDraft.mockResolvedValue({
      id: "cd1",
      internetMessageId: "<imid-3>",
      conversationId: "conv-3",
    });
    graphApi.send.mockResolvedValue(undefined);
    const { host } = makeHost({ user_email: "me@work.com" });

    await onCreateLinkFn(
      host,
      composeDraft({
        recipients: [
          {
            id: "c-dana",
            name: null,
            externalAccountId: "dana@gmail.com",
            role: null,
          },
        ] as never,
        inviteEmails: ["d.ana@gmail.com"],
      })
    );

    expect(graphApi.createDraft).toHaveBeenCalledTimes(1);
    const body = graphApi.createDraft.mock.calls[0][0];
    expect(body.toRecipients).toHaveLength(1);
    expect(body.toRecipients).toEqual([
      { emailAddress: { address: "dana@gmail.com" } },
    ]);
  });
});

describe("onNoteCreatedFn — calendar reply whose curated recipients are all self", () => {
  it("resolves to zero recipients and surfaces a deliveryError, rather than emailing the organizer their own reply", async () => {
    // The calendar-reply call site passes empty headerTo/headerCc and no
    // headerFrom to resolveOutboundReplyRecipients, so the self-reply
    // fallback there can never fire for this path. If the note's curated
    // recipient set is entirely dot/+tag variants of the organizer's own
    // connected mailbox, the reply must resolve to no recipients rather
    // than being sent back to the organizer.
    const { host } = makeHost({ user_email: "kris.braun@gmail.com" });

    const res = await onNoteCreatedFn(
      host,
      curatedCalReplyNote([{ externalAccountId: "krisbraun@gmail.com", role: null }]),
      calThread()
    );

    expect(graphApi.createDraft).not.toHaveBeenCalled();
    expect(res).toEqual({
      deliveryError: {
        code: "no_recipients",
        message: "This reply had no deliverable recipients.",
      },
    });
  });
});

// ---------------------------------------------------------------------------
// processConversationsFn — attendee responses fold onto the event thread
// ---------------------------------------------------------------------------

/** Minimal in-memory OutlookMailSyncHost for processConversationsFn. */
function makeFoldHost(initial: Record<string, unknown> = {}) {
  const map = new Map<string, unknown>(
    Object.entries({
      enabled_channels: ["inbox"],
      user_email: "organizer@example.test",
      // Non-empty so getWellKnownFn's cache hit skips getWellKnownFolderIds —
      // irrelevant here anyway since every call below passes forceChannelId.
      wellknown_folders: { inbox: "folder-inbox-id" },
      ...initial,
    })
  );
  const host = {
    id: "ti-1",
    get: vi.fn(async (k: string) => (map.has(k) ? map.get(k) : null)),
    set: vi.fn(async (k: string, v: unknown) => {
      map.set(k, v);
    }),
    setMany: vi.fn(async (entries: [string, unknown][]) => {
      for (const [k, v] of entries) map.set(k, v);
    }),
    clear: vi.fn(async (k: string) => {
      map.delete(k);
    }),
    tools: {
      integrations: {
        get: vi.fn(async () => ({ token: "tok", scopes: [] })),
        saveLink: vi.fn(async () => "T"),
        saveNote: vi.fn(async () => "N"),
        channelSyncCompleted: vi.fn(async () => {}),
        setThreadToDo: vi.fn(async () => {}),
      },
      files: { read: vi.fn() },
      network: { createWebhook: vi.fn(), deleteWebhook: vi.fn() },
      store: {
        acquireLock: vi.fn(async () => true),
        releaseLock: vi.fn(async () => {}),
        list: vi.fn(async () => []),
      },
    },
    scheduler: {
      onOutlookMailWebhook: undefined,
      setupMailboxSubscription: vi.fn(async () => {}),
      renewMailboxSubscription: vi.fn(async () => {}),
      scheduleMailboxRenewal: vi.fn(async () => {}),
      scheduleSelfHealCheck: vi.fn(async () => {}),
      cancelScheduledTask: vi.fn(async () => {}),
      scheduleDrain: vi.fn(async () => {}),
      queueRenewSubscription: vi.fn(async () => {}),
      requeueInitialSync: vi.fn(async () => {}),
    },
  } as unknown as OutlookMailSyncHost;
  return { host, map };
}

/** Capture every saveNote/saveLink call the sync makes. */
function captureSaves(
  host: OutlookMailSyncHost,
  opts: { noteId?: string | null } = {}
) {
  const notes: Record<string, unknown>[] = [];
  const links: NewLinkWithNotes[] = [];
  (
    host.tools.integrations.saveNote as ReturnType<typeof vi.fn>
  ).mockImplementation(async (n: Record<string, unknown>) => {
    notes.push(n);
    return opts.noteId === undefined ? "N" : opts.noteId;
  });
  (
    host.tools.integrations.saveLink as ReturnType<typeof vi.fn>
  ).mockImplementation(async (l: NewLinkWithNotes) => {
    links.push(l);
    return "T";
  });
  return { notes, links };
}

/** A calendar-reply ICS body for one attendee response. */
function replyIcs(
  partstat: "DECLINED" | "ACCEPTED" | "TENTATIVE",
  opts: { uid?: string; comment?: string; recurrenceId?: string } = {}
): string {
  const lines = [
    "BEGIN:VCALENDAR",
    "METHOD:REPLY",
    "BEGIN:VEVENT",
    `UID:${opts.uid ?? "uid-rsvp@example.test"}`,
    `ATTENDEE;PARTSTAT=${partstat};CN=Beth Round:mailto:beth@example.test`,
  ];
  if (opts.comment) lines.push(`COMMENT:${opts.comment}`);
  if (opts.recurrenceId) lines.push(`RECURRENCE-ID:${opts.recurrenceId}`);
  lines.push("END:VEVENT", "END:VCALENDAR");
  return lines.join("\r\n");
}

/** A Microsoft-shaped raw MIME body carrying one `text/calendar` reply part. */
function rsvpMime(ics: string): string {
  return (
    [
      "MIME-Version: 1.0",
      "From: Beth Round <beth@example.test>",
      "Subject: RSVP notification",
      "Content-Type: text/calendar; method=REPLY",
      "Content-Transfer-Encoding: 7bit",
    ].join("\r\n") +
    "\r\n\r\n" +
    ics
  );
}

/** A Graph message flagged by the classifyOutlookCalendar pre-filter as an RSVP. */
function rsvpMessage(
  id: string,
  conversationId: string,
  meetingMessageType:
    | "meetingAccepted"
    | "meetingDeclined"
    | "meetingTentativelyAccepted",
  uid: string
): GraphMessage {
  return {
    id,
    conversationId,
    internetMessageId: `<${id}>`,
    subject: "RSVP notification",
    from: { emailAddress: { name: "Beth Round", address: "beth@example.test" } },
    toRecipients: [{ emailAddress: { address: "organizer@example.test" } }],
    ccRecipients: [],
    receivedDateTime: "2026-08-04T14:00:00.000Z",
    isRead: true,
    isDraft: false,
    body: { contentType: "text", content: "Beth Round has responded." },
    bodyPreview: "Beth Round has responded.",
    meetingMessageType,
    event: { iCalUId: uid },
  } as GraphMessage;
}

/** An ordinary (non-RSVP) human reply in the same conversation. */
function plainReplyMessage(id: string, conversationId: string): GraphMessage {
  return {
    id,
    conversationId,
    internetMessageId: `<${id}>`,
    subject: "Re: RSVP notification",
    from: { emailAddress: { name: "Beth Round", address: "beth@example.test" } },
    toRecipients: [{ emailAddress: { address: "organizer@example.test" } }],
    ccRecipients: [],
    receivedDateTime: "2026-08-04T14:05:00.000Z",
    isRead: true,
    isDraft: false,
    body: { contentType: "text", content: "No problem, let's find another time." },
    bodyPreview: "No problem, let's find another time.",
  } as GraphMessage;
}

describe("processConversationsFn — attendee responses fold onto the event", () => {
  let mimeById: Map<string, string>;

  beforeEach(() => {
    mimeById = new Map();
    graphApi.getMimeContent.mockImplementation(
      async (id: string) => mimeById.get(id) ?? null
    );
  });

  it("writes a note to the event thread and saves no email link", async () => {
    const { host } = makeFoldHost();
    const { notes, links } = captureSaves(host);
    const uid = "uid-rsvp@example.test";
    const msg = rsvpMessage("msg-decline", "conv-decline", "meetingDeclined", uid);
    mimeById.set("msg-decline", rsvpMime(replyIcs("DECLINED", { uid })));

    await processConversationsFn(
      host,
      [{ messages: [msg], attachmentsByMessageId: new Map(), parentHeaders: null }],
      false,
      "inbox"
    );

    expect(notes).toHaveLength(1);
    expect(notes[0]).toMatchObject({
      thread: { source: `icaluid:${uid}` },
      key: "<msg-decline>",
      content: "Beth Round declined.",
      contentType: "markdown",
      created: new Date("2026-08-04T14:00:00.000Z"),
      unread: true,
      author: { email: "beth@example.test", name: "Beth Round" },
      deferUntilThread: true,
    });
    expect(links).toHaveLength(0);
  });

  it("carries the responder's personal note into the quote", async () => {
    const { host } = makeFoldHost();
    const { notes } = captureSaves(host);
    const uid = "uid-rsvp-comment@example.test";
    const msg = rsvpMessage("msg-decline-comment", "conv-decline-comment", "meetingDeclined", uid);
    mimeById.set(
      "msg-decline-comment",
      rsvpMime(replyIcs("DECLINED", { uid, comment: "Could we move this to Thursday?" }))
    );

    await processConversationsFn(
      host,
      [{ messages: [msg], attachmentsByMessageId: new Map(), parentHeaders: null }],
      false,
      "inbox"
    );

    expect(notes[0].content).toBe(
      "Beth Round declined.\n\n> Could we move this to Thursday?"
    );
  });

  it("writes no note at all for a bare acceptance, and saves no email link", async () => {
    const { host } = makeFoldHost();
    const { notes, links } = captureSaves(host);
    const uid = "uid-rsvp-accept@example.test";
    const msg = rsvpMessage("msg-accept", "conv-accept", "meetingAccepted", uid);
    mimeById.set("msg-accept", rsvpMime(replyIcs("ACCEPTED", { uid })));

    await processConversationsFn(
      host,
      [{ messages: [msg], attachmentsByMessageId: new Map(), parentHeaders: null }],
      false,
      "inbox"
    );

    // The guest list already shows the acceptance. Writing a note is the only
    // thing that could mark the organiser's event thread unread, so we write
    // none — and the responses-only conversation creates no email thread.
    expect(notes).toHaveLength(0);
    expect(links).toHaveLength(0);
  });

  it("writes a note for an acceptance carrying a personal comment", async () => {
    const { host } = makeFoldHost();
    const { notes } = captureSaves(host);
    const uid = "uid-rsvp-accept-comment@example.test";
    const msg = rsvpMessage("msg-accept-comment", "conv-accept-comment", "meetingAccepted", uid);
    mimeById.set(
      "msg-accept-comment",
      rsvpMime(replyIcs("ACCEPTED", { uid, comment: "Sounds good, I'll bring the deck" }))
    );

    await processConversationsFn(
      host,
      [{ messages: [msg], attachmentsByMessageId: new Map(), parentHeaders: null }],
      false,
      "inbox"
    );

    expect(notes).toHaveLength(1);
    expect(notes[0]).toMatchObject({
      content: "Beth Round accepted.\n\n> Sounds good, I'll bring the deck",
      unread: true,
    });
  });

  it("writes a note when an acceptance reverses an earlier decline", async () => {
    const { host, map } = makeFoldHost();
    const { notes } = captureSaves(host);
    const uid = "uid-rsvp-reversal@example.test";

    const declineMsg = rsvpMessage("msg-reversal-1", "conv-reversal-1", "meetingDeclined", uid);
    mimeById.set("msg-reversal-1", rsvpMime(replyIcs("DECLINED", { uid })));
    await processConversationsFn(
      host,
      [{ messages: [declineMsg], attachmentsByMessageId: new Map(), parentHeaders: null }],
      false,
      "inbox"
    );
    const key = priorRsvpKey(uid, "beth@example.test", null);
    expect(map.get(key)).toBe("DECLINED");

    const acceptMsg = rsvpMessage("msg-reversal-2", "conv-reversal-2", "meetingAccepted", uid);
    mimeById.set("msg-reversal-2", rsvpMime(replyIcs("ACCEPTED", { uid })));
    await processConversationsFn(
      host,
      [{ messages: [acceptMsg], attachmentsByMessageId: new Map(), parentHeaders: null }],
      false,
      "inbox"
    );

    // Two notes: the decline, then the reversal.
    expect(notes).toHaveLength(2);
    expect(notes[1]).toMatchObject({ content: "Beth Round accepted." });
    // The outstanding non-acceptance is resolved, so the key is gone.
    expect(map.has(key)).toBe(false);
  });

  it("does not let a decline on one occurrence suppress an acceptance on another", async () => {
    const { host, map } = makeFoldHost();
    const { notes } = captureSaves(host);
    const uid = "uid-rsvp-recurring@example.test";

    // Beth declines the Aug 4 occurrence of a recurring standup.
    const aug4Decline = rsvpMessage("msg-aug4", "conv-aug4", "meetingDeclined", uid);
    mimeById.set(
      "msg-aug4",
      rsvpMime(replyIcs("DECLINED", { uid, recurrenceId: "20260804T140000Z" }))
    );
    await processConversationsFn(
      host,
      [{ messages: [aug4Decline], attachmentsByMessageId: new Map(), parentHeaders: null }],
      false,
      "inbox"
    );
    expect(notes).toHaveLength(1);
    const aug4Key = priorRsvpKey(
      uid,
      "beth@example.test",
      new Date("2026-08-04T14:00:00Z")
    );
    expect(map.get(aug4Key)).toBe("DECLINED");

    // Two weeks later she bare-accepts a different occurrence of the same
    // series (same UID, different RECURRENCE-ID). The Aug 4 decline must not
    // be read as an outstanding non-acceptance for the Aug 18 occurrence.
    const aug18Accept = rsvpMessage("msg-aug18", "conv-aug18", "meetingAccepted", uid);
    mimeById.set(
      "msg-aug18",
      rsvpMime(replyIcs("ACCEPTED", { uid, recurrenceId: "20260818T140000Z" }))
    );
    await processConversationsFn(
      host,
      [{ messages: [aug18Accept], attachmentsByMessageId: new Map(), parentHeaders: null }],
      false,
      "inbox"
    );

    // No second note: the bare acceptance on the Aug 18 occurrence stays
    // suppressed, and the Aug 4 decline's key is untouched.
    expect(notes).toHaveLength(1);
    expect(map.get(aug4Key)).toBe("DECLINED");
  });

  it("marks a folded response read during the initial backfill", async () => {
    const { host } = makeFoldHost();
    const { notes } = captureSaves(host);
    const uid = "uid-rsvp-initial@example.test";
    const msg = rsvpMessage("msg-initial", "conv-initial", "meetingDeclined", uid);
    mimeById.set("msg-initial", rsvpMime(replyIcs("DECLINED", { uid })));

    await processConversationsFn(
      host,
      [{ messages: [msg], attachmentsByMessageId: new Map(), parentHeaders: null }],
      true,
      "inbox"
    );

    // Explicit false, not an omitted flag: a note already surfaces as unread
    // by the time this field is read, so only an explicit false overrides it.
    expect(notes[0]).toMatchObject({ unread: false });
  });

  it("passes deferUntilThread so the platform holds a miss instead of us retrying it", async () => {
    const { host } = makeFoldHost();
    const { notes } = captureSaves(host);
    const uid = "uid-rsvp-defer@example.test";
    const msg = rsvpMessage("msg-defer", "conv-defer", "meetingDeclined", uid);
    mimeById.set("msg-defer", rsvpMime(replyIcs("DECLINED", { uid })));

    await processConversationsFn(
      host,
      [{ messages: [msg], attachmentsByMessageId: new Map(), parentHeaders: null }],
      false,
      "inbox"
    );

    expect(notes[0]).toMatchObject({ deferUntilThread: true });
  });

  it("drops the email thread on a miss too, and still records the outcome", async () => {
    const { host, map } = makeFoldHost();
    // null = no thread carries `icaluid:<uid>` yet (calendar hasn't synced).
    // The platform parks the deferUntilThread note rather than returning it
    // to us, so the message is folded away exactly as a successful fold
    // would be, and no standalone email thread is created for it.
    const { notes, links } = captureSaves(host, { noteId: null });
    const uid = "uid-rsvp-orphan@example.test";
    const msg = rsvpMessage("msg-orphan", "conv-orphan", "meetingDeclined", uid);
    mimeById.set("msg-orphan", rsvpMime(replyIcs("DECLINED", { uid })));

    await processConversationsFn(
      host,
      [{ messages: [msg], attachmentsByMessageId: new Map(), parentHeaders: null }],
      false,
      "inbox"
    );

    expect(notes).toHaveLength(1);
    expect(notes[0]).toMatchObject({ deferUntilThread: true });
    expect(links).toHaveLength(0);
    // Recorded regardless of saveNote's return value — a deferred note
    // returns no id, and gating on it would leave this decline's reversal
    // state unrecorded forever.
    const key = priorRsvpKey(uid, "beth@example.test", null);
    expect(map.get(key)).toBe("DECLINED");
  });

  it("leaves the message as ordinary mail when the raw MIME carries no parseable reply", async () => {
    const { host } = makeFoldHost();
    const { notes, links } = captureSaves(host);
    const uid = "uid-rsvp-nomime@example.test";
    // The pre-filter flags this message (meetingAccepted + iCalUId), but the
    // raw MIME carries no calendar part at all — extractOutlookReply returns
    // null. Without the ICS there is no comment and no occurrence, so folding
    // would mis-scope the dedup key; the safe direction is ordinary mail.
    const msg = rsvpMessage("msg-nomime", "conv-nomime", "meetingAccepted", uid);
    mimeById.set(
      "msg-nomime",
      [
        "MIME-Version: 1.0",
        "From: Beth Round <beth@example.test>",
        "Content-Type: text/plain",
        "",
        "Beth Round has responded.",
      ].join("\r\n")
    );

    await processConversationsFn(
      host,
      [{ messages: [msg], attachmentsByMessageId: new Map(), parentHeaders: null }],
      false,
      "inbox"
    );

    expect(notes).toHaveLength(0);
    expect(links).toHaveLength(1);
    const keys = (links[0].notes ?? []).map((n) => (n as { key?: string }).key);
    expect(keys).toEqual(["<msg-nomime>"]);
  });

  it("leaves the message as ordinary mail when the MIME fetch itself misses (e.g. 404)", async () => {
    const { host } = makeFoldHost();
    const { notes, links } = captureSaves(host);
    const uid = "uid-rsvp-no-mime-fetch@example.test";
    const msg = rsvpMessage("msg-no-mime-fetch", "conv-no-mime-fetch", "meetingDeclined", uid);
    // mimeById has no entry — getMimeContent resolves null (404).

    await processConversationsFn(
      host,
      [{ messages: [msg], attachmentsByMessageId: new Map(), parentHeaders: null }],
      false,
      "inbox"
    );

    expect(notes).toHaveLength(0);
    expect(links).toHaveLength(1);
  });

  it("keeps ordinary correspondence in its own email thread, dropping only the folded RSVP message", async () => {
    const { host } = makeFoldHost();
    const { notes, links } = captureSaves(host);
    const uid = "uid-rsvp-mixed@example.test";
    const rsvp = rsvpMessage("msg-mixed-1", "conv-mixed", "meetingDeclined", uid);
    const reply = plainReplyMessage("msg-mixed-2", "conv-mixed");
    mimeById.set("msg-mixed-1", rsvpMime(replyIcs("DECLINED", { uid })));

    await processConversationsFn(
      host,
      [{ messages: [rsvp, reply], attachmentsByMessageId: new Map(), parentHeaders: null }],
      false,
      "inbox"
    );

    expect(notes).toHaveLength(1); // the folded RSVP note on the event thread
    expect(links).toHaveLength(1); // the conversation, minus the folded message
    const keys = (links[0].notes ?? []).map((n) => (n as { key?: string }).key);
    expect(keys).toEqual(["<msg-mixed-2>"]);

    // The folded RSVP was the only calendar-classifiable message in this
    // conversation — its own thread must not get bundled onto the event's
    // thread via a shared `sources` element (that would merge the surviving
    // human reply onto the calendar event thread too).
    expect(links[0].sources ?? []).not.toContain(`icaluid:${uid}`);

    // Signals/noteKey must point at a note that still exists — the RSVP
    // message (14:00) sorts before the reply (14:05), so an unfiltered
    // "parent" pick would select the folded message instead.
    expect(links[0].signals?.noteKey).toBe("<msg-mixed-2>");
    expect(keys).toContain(links[0].signals?.noteKey);

    // The preview must come from the surviving reply, not the folded RSVP
    // notification (whose bodyPreview seeded transformOutlookConversation's
    // original preview since it sorted first).
    expect(links[0].preview).toBe("No problem, let's find another time.");
  });

  it("degrades a single candidate's failed MIME fetch to ordinary mail without aborting the rest of the batch", async () => {
    const { host } = makeFoldHost();
    const { notes, links } = captureSaves(host);
    const goodUid = "uid-rsvp-batch-good@example.test";
    const badUid = "uid-rsvp-batch-bad@example.test";
    const badMsg = rsvpMessage("msg-batch-bad", "conv-batch-bad", "meetingDeclined", badUid);
    const goodMsg = rsvpMessage("msg-batch-good", "conv-batch-good", "meetingDeclined", goodUid);

    graphApi.getMimeContent.mockImplementation(async (id: string) => {
      if (id === "msg-batch-bad") throw new Error("500 from Graph");
      if (id === "msg-batch-good") {
        return rsvpMime(replyIcs("DECLINED", { uid: goodUid }));
      }
      return null;
    });

    await processConversationsFn(
      host,
      [
        { messages: [badMsg], attachmentsByMessageId: new Map(), parentHeaders: null },
        { messages: [goodMsg], attachmentsByMessageId: new Map(), parentHeaders: null },
      ],
      false,
      "inbox"
    );

    // The failing fetch degrades ITS OWN message to ordinary mail rather
    // than throwing out of the batch, so its conversation still gets a
    // (non-folded) email thread.
    expect(links).toHaveLength(1);
    const badLinkKeys = (links[0].notes ?? []).map((n) => (n as { key?: string }).key);
    expect(badLinkKeys).toEqual(["<msg-batch-bad>"]);

    // The other conversation in the same batch still folds normally — a
    // single Graph error must not fail every conversation in the batch.
    expect(notes).toHaveLength(1);
    expect(notes[0]).toMatchObject({ thread: { source: `icaluid:${goodUid}` } });
  });

  it("does not read prior state for a decline, a tentative, or a commented acceptance", async () => {
    const { host } = makeFoldHost();
    captureSaves(host);
    const getSpy = host.get as ReturnType<typeof vi.fn>;

    const shapes: Array<{
      partstat: "DECLINED" | "TENTATIVE" | "ACCEPTED";
      meetingMessageType: "meetingDeclined" | "meetingTentativelyAccepted" | "meetingAccepted";
      comment?: string;
    }> = [
      { partstat: "DECLINED", meetingMessageType: "meetingDeclined" },
      { partstat: "TENTATIVE", meetingMessageType: "meetingTentativelyAccepted" },
      { partstat: "ACCEPTED", meetingMessageType: "meetingAccepted", comment: "Sounds good" },
    ];

    for (const shape of shapes) {
      getSpy.mockClear();
      const uid = `uid-no-prior-read-${shape.partstat}@example.test`;
      const msgId = `msg-no-prior-read-${shape.partstat}`;
      const msg = rsvpMessage(msgId, `conv-no-prior-read-${shape.partstat}`, shape.meetingMessageType, uid);
      mimeById.set(msgId, rsvpMime(replyIcs(shape.partstat, { uid, comment: shape.comment })));

      await processConversationsFn(
        host,
        [{ messages: [msg], attachmentsByMessageId: new Map(), parentHeaders: null }],
        false,
        "inbox"
      );

      const priorKey = priorRsvpKey(uid, "beth@example.test", null);
      expect(getSpy).not.toHaveBeenCalledWith(priorKey);
    }
  });
});
