import { afterEach, describe, expect, it, vi } from "vitest";

import type { CreateLinkDraft, NewLinkWithNotes, Uuid } from "@plotday/twister";

import {
  GmailApi,
  GmailApiError,
  UserInfoError,
  type GmailHeader,
  type GmailMessage,
  type GmailMessagePart,
  type GmailThread,
} from "./gmail-api";
import {
  type GmailSyncHost,
  onCreateLinkFn,
  onNoteCreatedFn,
  processEmailThreadsFn,
} from "./sync";

/** Decode the base64url raw message the Gmail send API would receive. */
function decodeRawMessage(b64url: string): string {
  const b64 = b64url.replace(/-/g, "+").replace(/_/g, "/");
  return Buffer.from(b64, "base64").toString("utf8");
}

/** Decode the base64 body of the first MIME part declaring `mimeType`. */
function decodeMimePart(raw: string, mimeType: string): string {
  const segments = raw.split(/\r\n--[^\r\n]+(?:--)?\r\n?/);
  for (const seg of segments) {
    if (!seg.includes(`Content-Type: ${mimeType}`)) continue;
    const blank = seg.indexOf("\r\n\r\n");
    if (blank === -1) continue;
    const b64 = seg.slice(blank + 4).replace(/\r\n/g, "").trim();
    return Buffer.from(b64, "base64").toString("utf8");
  }
  return "";
}

/** base64url-encode a string the way the Gmail API encodes part bodies. */
function b64url(s: string): string {
  return Buffer.from(s, "utf8").toString("base64").replace(/\+/g, "-").replace(/\//g, "_");
}

/** A source Gmail message to be forwarded, with a plain-text body. */
function sourceMessage(): GmailMessage {
  const headers: GmailHeader[] = [
    { name: "From", value: "Alice <alice@example.com>" },
    { name: "Date", value: "Wed, 1 Jul 2026 10:00:00 -0700" },
    { name: "Subject", value: "Q3 budget" },
    { name: "To", value: "me@example.com" },
  ];
  return {
    id: "msg-1",
    threadId: "orig-thread",
    labelIds: ["INBOX"],
    snippet: "Let's meet Thursday.",
    historyId: "1",
    internalDate: "1700000000000",
    sizeEstimate: 100,
    payload: {
      mimeType: "text/plain",
      headers,
      body: { size: 21, data: b64url("Let's meet Thursday.") },
    },
  };
}

/** Minimal in-memory GmailSyncHost for onCreateLinkFn (compose/forward). */
function makeHost(): { host: GmailSyncHost; store: Map<string, unknown> } {
  const store = new Map<string, unknown>([["enabled_channels", ["INBOX"]]]);
  const host = {
    id: "twist-instance-1",
    get: vi.fn(async (key: string) => (store.has(key) ? store.get(key) : null)),
    set: vi.fn(async (key: string, value: unknown) => {
      store.set(key, value);
    }),
    setMany: vi.fn(async (entries: [string, unknown][]) => {
      for (const [key, value] of entries) store.set(key, value);
    }),
    clear: vi.fn(async (key: string) => {
      store.delete(key);
    }),
    tools: {
      integrations: {
        get: vi.fn(async () => ({ token: "tok", scopes: [] })),
        saveLink: vi.fn(async () => null),
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
      onGmailWebhook: undefined,
      setupMailboxWebhook: vi.fn(async () => {}),
      renewMailboxWatch: vi.fn(async () => {}),
      scheduleMailboxRenewal: vi.fn(async () => {}),
      scheduleSelfHealCheck: vi.fn(async () => {}),
      cancelScheduledTask: vi.fn(async () => {}),
      queueIncrementalSync: vi.fn(async () => {}),
      queueWriteBackRetry: vi.fn(async () => {}),
    },
  } as unknown as GmailSyncHost;
  return { host, store };
}

function forwardDraft(overrides: Partial<CreateLinkDraft> = {}): CreateLinkDraft {
  return {
    channelId: "INBOX",
    type: "email",
    status: null,
    title: "Q3",
    noteContent: "fyi",
    contacts: [],
    inviteEmails: ["bob@example.com"],
    forward: { key: "msg-1" },
    ...overrides,
  } as CreateLinkDraft;
}

afterEach(() => vi.restoreAllMocks());

describe("onCreateLinkFn — draft.forward", () => {
  it("builds and sends a native Gmail forward of the source message", async () => {
    vi.spyOn(GmailApi.prototype, "getMessage").mockResolvedValue(sourceMessage());
    vi.spyOn(GmailApi.prototype, "getProfile").mockResolvedValue({
      emailAddress: "me@example.com",
    });
    vi.spyOn(GmailApi.prototype, "getUserInfo").mockResolvedValue({
      email: "me@example.com",
      name: "Me Myself",
    });
    const sendNewMessage = vi
      .spyOn(GmailApi.prototype, "sendNewMessage")
      .mockResolvedValue({ id: "sent-1", threadId: "sent-thread-1" });
    const { host } = makeHost();

    const link = await onCreateLinkFn(host, forwardDraft());

    expect(sendNewMessage).toHaveBeenCalledTimes(1);
    const raw = decodeRawMessage(sendNewMessage.mock.calls[0][0]);
    // draft.title ("Q3") wins over the source message's own Subject header.
    expect(raw).toContain("Subject: Fwd: Q3");
    expect(raw).toContain("To: bob@example.com");
    expect(raw).not.toContain("In-Reply-To:");
    // From carries the account's display name, not a bare address, so Gmail
    // shows the sender's name in the recipient's inbox.
    expect(raw).toContain('From: "Me Myself" <me@example.com>');

    const text = decodeMimePart(raw, "text/plain");
    expect(text).toContain("fyi"); // forwarder's own message
    expect(text).toContain("Let's meet Thursday."); // quoted original body
    expect(text).toContain("From: Alice <alice@example.com>"); // quoted original header

    expect(link?.type).toBe("email");
    expect(link?.source).toContain("sent-thread-1");
    expect(link?.originatingNote).toEqual({ key: "sent-1", deliveryError: null });
  });

  it("uses the source message's own Subject when the draft has no title", async () => {
    vi.spyOn(GmailApi.prototype, "getMessage").mockResolvedValue(sourceMessage());
    vi.spyOn(GmailApi.prototype, "getProfile").mockResolvedValue({
      emailAddress: "me@example.com",
    });
    vi.spyOn(GmailApi.prototype, "getUserInfo").mockResolvedValue({
      email: "me@example.com",
      name: "Me Myself",
    });
    const sendNewMessage = vi
      .spyOn(GmailApi.prototype, "sendNewMessage")
      .mockResolvedValue({ id: "sent-2", threadId: "sent-thread-2" });
    const { host } = makeHost();

    await onCreateLinkFn(host, forwardDraft({ title: "" }));

    const raw = decodeRawMessage(sendNewMessage.mock.calls[0][0]);
    expect(raw).toContain("Subject: Fwd: Q3 budget");
  });

  it("surfaces a deliveryError instead of throwing when the send fails permanently", async () => {
    vi.spyOn(GmailApi.prototype, "getMessage").mockResolvedValue(sourceMessage());
    vi.spyOn(GmailApi.prototype, "getProfile").mockResolvedValue({
      emailAddress: "me@example.com",
    });
    vi.spyOn(GmailApi.prototype, "getUserInfo").mockResolvedValue({
      email: "me@example.com",
      name: "Me Myself",
    });
    vi.spyOn(GmailApi.prototype, "sendNewMessage").mockRejectedValue(
      new GmailApiError(400, "Bad Request", "Recipient address rejected")
    );
    const { host } = makeHost();

    const link = await onCreateLinkFn(host, forwardDraft());

    expect(link?.originatingNote?.deliveryError).toBeTruthy();
    expect(link?.source).toBeUndefined();
  });

  it("surfaces a not_found deliveryError (does not throw) when the source message is gone", async () => {
    // The user deleted the original in Gmail after it synced into Plot, so the
    // forward key now 404s — an expected, user-visible failure.
    vi.spyOn(GmailApi.prototype, "getMessage").mockRejectedValue(
      new GmailApiError(404, "Not Found", "Requested entity was not found.")
    );
    const sendNewMessage = vi.spyOn(GmailApi.prototype, "sendNewMessage");
    const { host } = makeHost();

    const link = await onCreateLinkFn(host, forwardDraft());

    expect(link?.originatingNote?.deliveryError).toEqual({
      code: "not_found",
      message:
        "The original message could not be found — it may have been deleted.",
    });
    expect(link?.source).toBeUndefined();
    // Never attempted a send once the source couldn't be fetched.
    expect(sendNewMessage).not.toHaveBeenCalled();
  });

  it("rethrows a non-4xx source-fetch failure (5xx stays unexpected)", async () => {
    vi.spyOn(GmailApi.prototype, "getMessage").mockRejectedValue(
      new GmailApiError(500, "Internal Server Error", "backend error")
    );
    const { host } = makeHost();

    await expect(onCreateLinkFn(host, forwardDraft())).rejects.toMatchObject({
      status: 500,
    });
  });

  it("returns null when there are no recipients to forward to", async () => {
    const { host } = makeHost();

    const link = await onCreateLinkFn(
      host,
      forwardDraft({ inviteEmails: [], recipients: [] })
    );

    expect(link).toBeNull();
  });

  it("keeps a bcc-role recipient out of the visible To/Cc headers", async () => {
    vi.spyOn(GmailApi.prototype, "getMessage").mockResolvedValue(sourceMessage());
    vi.spyOn(GmailApi.prototype, "getProfile").mockResolvedValue({
      emailAddress: "me@example.com",
    });
    vi.spyOn(GmailApi.prototype, "getUserInfo").mockResolvedValue({
      email: "me@example.com",
      name: "Me Myself",
    });
    const sendNewMessage = vi
      .spyOn(GmailApi.prototype, "sendNewMessage")
      .mockResolvedValue({ id: "sent-3", threadId: "sent-thread-3" });
    const { host } = makeHost();

    await onCreateLinkFn(
      host,
      forwardDraft({
        inviteEmails: [],
        recipients: [
          {
            id: "c1" as Uuid,
            name: "Bob",
            externalAccountId: "bob@example.com",
            role: "to",
          },
          {
            id: "c2" as Uuid,
            name: "Eve",
            externalAccountId: "eve@example.com",
            role: "bcc",
          },
        ],
      })
    );

    const raw = decodeRawMessage(sendNewMessage.mock.calls[0][0]);
    expect(raw).toContain('Bcc: "Eve" <eve@example.com>');
    expect(raw).toContain('To: "Bob" <bob@example.com>');
    expect(raw).not.toContain("To: bob@example.com, eve@example.com");
  });

  it("falls back to a bare email From header when the display-name lookup fails", async () => {
    vi.spyOn(GmailApi.prototype, "getMessage").mockResolvedValue(sourceMessage());
    vi.spyOn(GmailApi.prototype, "getProfile").mockResolvedValue({
      emailAddress: "me@example.com",
    });
    vi.spyOn(GmailApi.prototype, "getUserInfo").mockRejectedValue(
      new Error("UserInfo error: 401 Unauthorized")
    );
    const sendNewMessage = vi
      .spyOn(GmailApi.prototype, "sendNewMessage")
      .mockResolvedValue({ id: "sent-4", threadId: "sent-thread-4" });
    const { host } = makeHost();

    await onCreateLinkFn(host, forwardDraft());

    const raw = decodeRawMessage(sendNewMessage.mock.calls[0][0]);
    expect(raw).toContain("From: me@example.com");
    expect(raw).not.toContain('From: "');
  });

  it("logs an error naming the allowlist when the userinfo lookup is blocked (403)", async () => {
    vi.spyOn(GmailApi.prototype, "getMessage").mockResolvedValue(sourceMessage());
    vi.spyOn(GmailApi.prototype, "getProfile").mockResolvedValue({
      emailAddress: "me@example.com",
    });
    vi.spyOn(GmailApi.prototype, "getUserInfo").mockRejectedValue(
      new UserInfoError(403, "Forbidden")
    );
    const sendNewMessage = vi
      .spyOn(GmailApi.prototype, "sendNewMessage")
      .mockResolvedValue({ id: "sent-5", threadId: "sent-thread-5" });
    const onError = vi.spyOn(console, "error").mockImplementation(() => {});
    const { host } = makeHost();

    await onCreateLinkFn(host, forwardDraft());

    // The send still goes out — the display name is best-effort.
    const raw = decodeRawMessage(sendNewMessage.mock.calls[0][0]);
    expect(raw).toContain("From: me@example.com");
    expect(raw).not.toContain('From: "');
    // A 403 is a misconfiguration, not a transient blip: say so loudly, and
    // name the two things that actually cause it.
    const logged = onError.mock.calls.map((c) => String(c[0])).join("\n");
    expect(logged).toMatch(/allowlist/i);
    expect(logged).toMatch(/profile/i);
  });

  it("logs an error and sends bare when userinfo returns no display name", async () => {
    vi.spyOn(GmailApi.prototype, "getMessage").mockResolvedValue(sourceMessage());
    vi.spyOn(GmailApi.prototype, "getProfile").mockResolvedValue({
      emailAddress: "me@example.com",
    });
    // A grant without the `profile` scope still returns 200 here — just with
    // no `name` claim. This degrades silently unless it's called out.
    vi.spyOn(GmailApi.prototype, "getUserInfo").mockResolvedValue({
      email: "me@example.com",
    });
    const sendNewMessage = vi
      .spyOn(GmailApi.prototype, "sendNewMessage")
      .mockResolvedValue({ id: "sent-6", threadId: "sent-thread-6" });
    const onError = vi.spyOn(console, "error").mockImplementation(() => {});
    const { host } = makeHost();

    await onCreateLinkFn(host, forwardDraft());

    const raw = decodeRawMessage(sendNewMessage.mock.calls[0][0]);
    expect(raw).toContain("From: me@example.com");
    expect(raw).not.toContain('From: "');
    const logged = onError.mock.calls.map((c) => String(c[0])).join("\n");
    expect(logged).toMatch(/profile/i);
    expect(logged).toMatch(/re-auth/i);
  });
});

function calThread(over: Record<string, unknown> = {}) {
  return {
    id: "T",
    title: "Weekly sync",
    meta: { calendarId: "primary", iCalUID: "uid-123", syncableId: "primary" },
    accessContacts: [
      { id: "c-org", email: "org@x.com" },
      { id: "c-me", email: "me@example.com" },
      { id: "c-bob", email: "bob@x.com" },
    ],
    ...over,
  } as unknown as import("@plotday/twister").Thread;
}
function replyNote(recipients: Array<{ externalAccountId: string; role: string | null; name?: string | null }>, over: Record<string, unknown> = {}) {
  return {
    id: "n1",
    author: { id: "c-me" },
    content: "See you there",
    recipients: recipients.map((r) => ({ id: r.externalAccountId, name: r.name ?? null, externalAccountId: r.externalAccountId, role: r.role })),
    accessContacts: null,
    actions: [],
    ...over,
  } as unknown as import("@plotday/twister").Note;
}

describe("onNoteCreatedFn — calendar event thread", () => {
  it("sends a fresh email to all attendees on the first reply and stores threading state", async () => {
    const send = vi
      .spyOn(GmailApi.prototype, "sendNewMessage")
      .mockResolvedValue({ id: "sent-1", threadId: "gt-1" });
    vi.spyOn(GmailApi.prototype, "getProfile").mockResolvedValue({ emailAddress: "me@example.com" });
    vi.spyOn(GmailApi.prototype, "getUserInfo").mockResolvedValue({ email: "me@example.com", name: "Me" });
    const { host, store } = makeHost();

    const res = await onNoteCreatedFn(
      host,
      replyNote([
        { externalAccountId: "org@x.com", role: null },
        { externalAccountId: "bob@x.com", role: null },
      ]),
      calThread()
    );

    expect(send).toHaveBeenCalledTimes(1);
    const raw = decodeRawMessage(send.mock.calls[0][0]);
    expect(raw).toContain("To: org@x.com, bob@x.com");
    expect(raw).toContain("Subject: Weekly sync");
    expect(raw).toContain("X-Plot-Event-UID: uid-123");
    expect(store.get("cal-reply:uid-123")).toMatchObject({ gmailThreadId: "gt-1" });
    expect(res).toEqual({ key: "sent-1", deliveryError: null });
  });

  it("threads the second reply into the stored conversation", async () => {
    vi.spyOn(GmailApi.prototype, "getProfile").mockResolvedValue({ emailAddress: "me@example.com" });
    vi.spyOn(GmailApi.prototype, "getUserInfo").mockResolvedValue({ email: "me@example.com", name: "Me" });
    const sendReply = vi
      .spyOn(GmailApi.prototype, "sendMessage")
      .mockResolvedValue({ id: "sent-2", threadId: "gt-1" });
    const { host } = makeHost();
    await host.set("cal-reply:uid-123", { gmailThreadId: "gt-1", seedMessageId: "<seed@plot.day>" });

    await onNoteCreatedFn(host, replyNote([{ externalAccountId: "bob@x.com", role: null }]), calThread());

    expect(sendReply).toHaveBeenCalledTimes(1);
    expect(sendReply.mock.calls[0][1]).toBe("gt-1");
    const raw = decodeRawMessage(sendReply.mock.calls[0][0]);
    expect(raw).toContain("In-Reply-To: <seed@plot.day>");
    expect(raw).toContain("X-Plot-Event-UID: uid-123");
  });

  it("carries the recipient's display name into the To header", async () => {
    const send = vi
      .spyOn(GmailApi.prototype, "sendNewMessage")
      .mockResolvedValue({ id: "sent-named", threadId: "gt-named" });
    vi.spyOn(GmailApi.prototype, "getProfile").mockResolvedValue({ emailAddress: "me@example.com" });
    vi.spyOn(GmailApi.prototype, "getUserInfo").mockResolvedValue({ email: "me@example.com", name: "Me" });
    const { host } = makeHost();

    await onNoteCreatedFn(
      host,
      replyNote([{ externalAccountId: "org@x.com", role: null, name: "Org Person" }]),
      calThread()
    );

    expect(send).toHaveBeenCalledTimes(1);
    const raw = decodeRawMessage(send.mock.calls[0][0]);
    expect(raw).toContain('To: "Org Person" <org@x.com>');
  });

  it("private note (no deliverable recipients) sends nothing", async () => {
    const send = vi.spyOn(GmailApi.prototype, "sendNewMessage").mockResolvedValue({ id: "x", threadId: "y" });
    vi.spyOn(GmailApi.prototype, "getProfile").mockResolvedValue({ emailAddress: "me@example.com" });
    const { host } = makeHost();

    const res = await onNoteCreatedFn(
      host,
      replyNote([], { recipients: [], accessContacts: ["c-me"] }),
      calThread()
    );
    expect(send).not.toHaveBeenCalled();
    expect(res).toBeUndefined();
  });
});

/** A plain (non-calendar) Gmail thread whose sole message addressed the
 *  connected mailbox via a dot-variant of its own address. */
function gmailAliasReplyThread(): GmailThread {
  const message: GmailMessage = {
    id: "msg-orig-1",
    threadId: "gmail-thread-1",
    labelIds: ["INBOX"],
    snippet: "Hi Kris",
    historyId: "1",
    internalDate: "1700000000000",
    sizeEstimate: 100,
    payload: {
      mimeType: "text/plain",
      headers: [
        { name: "Message-ID", value: "<orig@mail.gmail.com>" },
        { name: "From", value: "Hilary Collier <hilary.collier@example.com>" },
        { name: "To", value: "krisbraun@gmail.com" },
        { name: "Cc", value: "annie@example.com" },
        { name: "Subject", value: "Surprise Tribute Video" },
      ],
      body: { size: 10, data: b64url("Hi Kris") },
    },
  };
  return { id: "gmail-thread-1", historyId: "1", messages: [message] };
}

function plainThread(over: Record<string, unknown> = {}) {
  return {
    id: "T2",
    title: "Surprise Tribute Video",
    meta: { channelId: "INBOX", threadId: "gmail-thread-1" },
    accessContacts: [
      { id: "c-me", email: "kris.braun@gmail.com" },
      { id: "c-hilary", email: "hilary.collier@example.com" },
      { id: "c-annie", email: "annie@example.com" },
    ],
    ...over,
  } as unknown as import("@plotday/twister").Thread;
}

function plainReplyNote(over: Record<string, unknown> = {}) {
  return {
    id: "n2",
    author: { id: "c-me" },
    content: "Sounds good!",
    recipients: null,
    accessContacts: null,
    actions: [],
    ...over,
  } as unknown as import("@plotday/twister").Note;
}

describe("onNoteCreatedFn — plain Gmail thread reply-all", () => {
  it("excludes the connected mailbox's own dot-variant alias address from the outbound recipients", async () => {
    vi.spyOn(GmailApi.prototype, "getThread").mockResolvedValue(
      gmailAliasReplyThread()
    );
    // The account's canonical/connected address (with dot) never literally
    // matches the alias form the original message was addressed to
    // (krisbraun@gmail.com) — Gmail treats both as the same mailbox.
    vi.spyOn(GmailApi.prototype, "getProfile").mockResolvedValue({
      emailAddress: "kris.braun@gmail.com",
    });
    vi.spyOn(GmailApi.prototype, "getUserInfo").mockResolvedValue({
      email: "kris.braun@gmail.com",
    });
    const send = vi
      .spyOn(GmailApi.prototype, "sendMessage")
      .mockResolvedValue({ id: "sent-9", threadId: "gmail-thread-1" });
    const { host } = makeHost();

    await onNoteCreatedFn(host, plainReplyNote(), plainThread());

    expect(send).toHaveBeenCalledTimes(1);
    const raw = decodeRawMessage(send.mock.calls[0][0]);
    expect(raw).not.toContain("krisbraun@gmail.com");
    expect(raw).toContain("hilary.collier@example.com");
  });
});

/** A Gmail thread the user sent between two of their own linked addresses:
 *  From = their other linked identity, To = the connected mailbox. Both are
 *  the same person, so a reply must fall back to the original sender. */
function selfEmailReplyThread(): GmailThread {
  const message: GmailMessage = {
    id: "msg-self-1",
    threadId: "gmail-self-thread-1",
    labelIds: ["INBOX"],
    snippet: "note to self",
    historyId: "1",
    internalDate: "1700000000000",
    sizeEstimate: 100,
    payload: {
      mimeType: "text/plain",
      headers: [
        { name: "Message-ID", value: "<self-orig@mail.gmail.com>" },
        { name: "From", value: "kris.work@example.com" },
        { name: "To", value: "kris.braun@gmail.com" },
        { name: "Subject", value: "Note to self" },
      ],
      body: { size: 12, data: b64url("note to self") },
    },
  };
  return { id: "gmail-self-thread-1", historyId: "1", messages: [message] };
}

function selfThread(over: Record<string, unknown> = {}) {
  return {
    id: "T-self",
    title: "Note to self",
    meta: { channelId: "INBOX", threadId: "gmail-self-thread-1" },
    accessContacts: [
      { id: "c-me", email: "kris.braun@gmail.com" },
      { id: "c-work", email: "kris.work@example.com" },
    ],
    ...over,
  } as unknown as import("@plotday/twister").Thread;
}

describe("onNoteCreatedFn — self-email thread reply", () => {
  it("addresses the original sender when a default (uncurated) reply resolves to only self", async () => {
    vi.spyOn(GmailApi.prototype, "getThread").mockResolvedValue(
      selfEmailReplyThread()
    );
    // Connected mailbox = one linked identity; the note is authored as the
    // OTHER linked identity, so both original participants are self.
    vi.spyOn(GmailApi.prototype, "getProfile").mockResolvedValue({
      emailAddress: "kris.braun@gmail.com",
    });
    vi.spyOn(GmailApi.prototype, "getUserInfo").mockResolvedValue({
      email: "kris.braun@gmail.com",
    });
    const send = vi
      .spyOn(GmailApi.prototype, "sendMessage")
      .mockResolvedValue({ id: "sent-self", threadId: "gmail-self-thread-1" });
    const { host } = makeHost();

    // Default reply: accessContacts null (uncurated), authored as the work identity.
    await onNoteCreatedFn(
      host,
      plainReplyNote({ author: { id: "c-work" }, accessContacts: null }),
      selfThread()
    );

    expect(send).toHaveBeenCalledTimes(1);
    const raw = decodeRawMessage(send.mock.calls[0][0]);
    expect(raw).toContain("kris.work@example.com");
  });
});

/** Build a GmailMessagePart, encoding `data` as base64url like the real API. */
function part(
  mimeType: string,
  opts: {
    data?: string;
    parts?: GmailMessagePart[];
    headers?: Array<[string, string]>;
  } = {}
): GmailMessagePart {
  return {
    mimeType,
    headers: (opts.headers ?? []).map(([name, value]) => ({ name, value })),
    body:
      opts.data !== undefined
        ? { size: opts.data.length, data: b64url(opts.data) }
        : undefined,
    parts: opts.parts,
  };
}

/** A single-message GmailThread carrying a `text/calendar` ICS part. */
function calendarUpdateThread(threadId: string, ics: string): GmailThread {
  const message: GmailMessage = {
    id: `${threadId}-msg-1`,
    threadId,
    labelIds: ["INBOX"],
    snippet: "Event updated",
    historyId: "1",
    internalDate: "1700000000000",
    sizeEstimate: 500,
    payload: part("multipart/mixed", {
      headers: [
        ["From", "calendar-notification@google.com"],
        ["To", "me@example.com"],
        ["Subject", "Updated: Weekly sync"],
      ],
      parts: [
        part("text/plain", { data: "The event has been updated." }),
        part("text/calendar", { data: ics }),
      ],
    }),
  };
  return { id: threadId, historyId: "1", messages: [message] };
}

function gmailThreadWithIcsUpdate(uid: string): GmailThread {
  const ics = `BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:${uid}\r\nSEQUENCE:2\r\nEND:VEVENT\r\nEND:VCALENDAR`;
  return calendarUpdateThread("cal-update-thread", ics);
}

function gmailThreadWithIcsCancel(uid: string): GmailThread {
  const ics = `BEGIN:VCALENDAR\r\nMETHOD:CANCEL\r\nBEGIN:VEVENT\r\nUID:${uid}\r\nEND:VEVENT\r\nEND:VCALENDAR`;
  return calendarUpdateThread("cal-cancel-thread", ics);
}

describe("processEmailThreadsFn — calendar-thread bundling", () => {
  it("adds icaluid:<uid> to sources when the conversation is a calendar update", async () => {
    const { host } = makeHost();
    const saved: NewLinkWithNotes[] = [];
    (host.tools.integrations.saveLink as ReturnType<typeof vi.fn>).mockImplementation(
      async (l: NewLinkWithNotes) => {
        saved.push(l);
        return "T";
      }
    );

    await processEmailThreadsFn(
      host,
      [gmailThreadWithIcsUpdate("uid-1")],
      false,
      "INBOX"
    );

    expect(saved[0].sources).toContain("icaluid:uid-1");
  });

  it("records a cancel-email marker for a cancellation email", async () => {
    const { host, store } = makeHost();

    await processEmailThreadsFn(
      host,
      [gmailThreadWithIcsCancel("uid-1")],
      false,
      "INBOX"
    );

    expect(store.get("cancel-email:uid-1")).toBeTruthy();
  });
});

/** A single-message GmailThread carrying `labels`, with a plain-text body. */
function labelledThread(threadId: string, labels: string[]): GmailThread {
  const message: GmailMessage = {
    id: `${threadId}-msg-1`,
    threadId,
    labelIds: labels,
    snippet: "Probably easier to show this with a real example.",
    historyId: "1",
    internalDate: "1700000000000",
    sizeEstimate: 100,
    payload: part("text/plain", {
      data: "Probably easier to show this with a real example.",
      headers: [
        ["From", "Alice <alice@example.com>"],
        ["To", "me@example.com"],
        ["Subject", "New role?"],
        ["Date", "Wed, 1 Jul 2026 10:00:00 -0700"],
      ],
    }),
  };
  return { id: threadId, historyId: "1", messages: [message] };
}

describe("processEmailThreadsFn — archived/trashed in Gmail", () => {
  const setThreadToDoOf = (host: GmailSyncHost) =>
    host.tools.integrations.setThreadToDo as ReturnType<typeof vi.fn>;
  const saveLinkOf = (host: GmailSyncHost) =>
    host.tools.integrations.saveLink as ReturnType<typeof vi.fn>;

  it("marks a previously-synced thread read once it leaves every enabled channel", async () => {
    const { host, store } = makeHost();
    store.set("auth_actor_id", "actor-1");
    // We synced this thread while it was still in the inbox.
    store.set("unread:archived-thread", true);

    // Archived in Gmail: INBOX is gone. IMPORTANT survives but isn't enabled.
    await processEmailThreadsFn(
      host,
      [labelledThread("archived-thread", ["IMPORTANT", "UNREAD"])],
      false
    );

    expect(setThreadToDoOf(host)).toHaveBeenCalledWith(
      "https://mail.google.com/mail/u/0/#inbox/archived-thread",
      "actor-1",
      false
    );
  });

  it("does not archive the thread in Plot when it is archived in Gmail", async () => {
    const { host, store } = makeHost();
    store.set("auth_actor_id", "actor-1");
    store.set("unread:archived-thread", true);

    await processEmailThreadsFn(
      host,
      [labelledThread("archived-thread", ["IMPORTANT"])],
      false
    );

    // Archiving in Gmail must never archive in Plot — the thread stays, it
    // just stops being unread.
    expect(saveLinkOf(host)).not.toHaveBeenCalled();
  });

  it("marks a trashed thread read too", async () => {
    const { host, store } = makeHost();
    store.set("auth_actor_id", "actor-1");
    store.set("unread:trashed-thread", true);

    await processEmailThreadsFn(
      host,
      [labelledThread("trashed-thread", ["TRASH", "UNREAD"])],
      false
    );

    expect(setThreadToDoOf(host)).toHaveBeenCalledWith(
      "https://mail.google.com/mail/u/0/#inbox/trashed-thread",
      "actor-1",
      false
    );
  });

  it("caches the thread as read so a later re-unread in Gmail still syncs", async () => {
    const { host, store } = makeHost();
    store.set("auth_actor_id", "actor-1");
    store.set("unread:archived-thread", true);

    await processEmailThreadsFn(
      host,
      [labelledThread("archived-thread", ["IMPORTANT", "UNREAD"])],
      false
    );

    expect(store.get("unread:archived-thread")).toBe(false);
  });

  it("ignores a thread it has never synced", async () => {
    const { host, store } = makeHost();
    store.set("auth_actor_id", "actor-1");
    // No `unread:*` key: mailbox-wide history surfaces threads from labels the
    // user never chose to sync. Those were never ours to mark read.

    await processEmailThreadsFn(
      host,
      [labelledThread("foreign-thread", ["IMPORTANT"])],
      false
    );

    expect(setThreadToDoOf(host)).not.toHaveBeenCalled();
    expect(store.get("unread:foreign-thread")).toBeUndefined();
  });

  it("leaves a thread still in an enabled channel alone", async () => {
    const { host, store } = makeHost();
    store.set("auth_actor_id", "actor-1");
    store.set("unread:inbox-thread", true);

    await processEmailThreadsFn(
      host,
      [labelledThread("inbox-thread", ["INBOX", "UNREAD"])],
      false
    );

    // Still in the inbox — normal sync path, no read stamp.
    expect(setThreadToDoOf(host)).not.toHaveBeenCalled();
    expect(saveLinkOf(host)).toHaveBeenCalled();
  });

  it("does not mark threads read during an initial backfill", async () => {
    const { host, store } = makeHost();
    store.set("auth_actor_id", "actor-1");
    store.set("unread:archived-thread", true);

    // forceChannelId is set during per-channel backfill; a thread that no
    // longer carries the label must not be read-stamped by a backfill pass.
    await processEmailThreadsFn(
      host,
      [labelledThread("archived-thread", ["IMPORTANT"])],
      true,
      "INBOX"
    );

    expect(setThreadToDoOf(host)).not.toHaveBeenCalled();
  });
});
