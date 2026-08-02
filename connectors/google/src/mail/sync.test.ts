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
  onNoteReactionChangedFn,
  drainPendingRsvpsFn,
  processEmailThreadsFn,
  REACTION_SEND_DELAY_MS,
  sendReactionEmailFn,
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
        saveNote: vi.fn(async () => null),
        channelSyncCompleted: vi.fn(async () => {}),
        setThreadToDo: vi.fn(async () => {}),
        archiveLinks: vi.fn(async () => {}),
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
      scheduleReactionSend: vi.fn(async () => {}),
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

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  registeredIcs.clear();
});

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

/** A plain (non-forward) compose draft: `draft.forward` unset, so onCreateLinkFn
 *  takes the toEmails/ccEmails/bccEmails addRecipient branch rather than
 *  delegating to onCreateLinkForwardFn. */
function composeDraft(overrides: Partial<CreateLinkDraft> = {}): CreateLinkDraft {
  return {
    channelId: "INBOX",
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

describe("onCreateLinkFn — plain compose (no draft.forward)", () => {
  it("carries a curated recipient's display name into the To header", async () => {
    vi.spyOn(GmailApi.prototype, "getProfile").mockResolvedValue({
      emailAddress: "me@example.com",
    });
    vi.spyOn(GmailApi.prototype, "getUserInfo").mockResolvedValue({
      email: "me@example.com",
      name: "Me Myself",
    });
    const sendNewMessage = vi
      .spyOn(GmailApi.prototype, "sendNewMessage")
      .mockResolvedValue({ id: "sent-compose-1", threadId: "sent-thread-compose-1" });
    const { host } = makeHost();

    const link = await onCreateLinkFn(
      host,
      composeDraft({
        recipients: [
          {
            id: "c-dana" as Uuid,
            name: "Robin Fielder",
            externalAccountId: "dana@example.com",
            role: null,
          },
        ],
      })
    );

    expect(sendNewMessage).toHaveBeenCalledTimes(1);
    const raw = decodeRawMessage(sendNewMessage.mock.calls[0][0]);
    expect(raw).toContain('To: "Robin Fielder" <dana@example.com>');
    expect(link?.type).toBe("email");
  });

  it("does not send two copies to the same Gmail mailbox reached via a dot variant", async () => {
    // A picker-resolved recipient ("dana@gmail.com") and a separately typed
    // invite address ("d.ana@gmail.com") are the same Gmail mailbox — Gmail
    // ignores dots in the local part. The dedupe key must recognize this
    // ROW-identity (canonicalizeEmail), not just an exact lowercase match,
    // or the compose sends the same person two copies.
    vi.spyOn(GmailApi.prototype, "getProfile").mockResolvedValue({
      emailAddress: "me@example.com",
    });
    vi.spyOn(GmailApi.prototype, "getUserInfo").mockResolvedValue({
      email: "me@example.com",
      name: "Me Myself",
    });
    const sendNewMessage = vi
      .spyOn(GmailApi.prototype, "sendNewMessage")
      .mockResolvedValue({ id: "sent-compose-2", threadId: "sent-thread-compose-2" });
    const { host } = makeHost();

    await onCreateLinkFn(
      host,
      composeDraft({
        recipients: [
          {
            id: "c-dana" as Uuid,
            name: null,
            externalAccountId: "dana@gmail.com",
            role: null,
          },
        ],
        inviteEmails: ["d.ana@gmail.com"],
      })
    );

    expect(sendNewMessage).toHaveBeenCalledTimes(1);
    const raw = decodeRawMessage(sendNewMessage.mock.calls[0][0]);
    const toHeaderLine = raw
      .split("\r\n")
      .find((line) => line.startsWith("To:"));
    expect(toHeaderLine).toBe("To: dana@gmail.com");
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

  it("sends nothing when the curated recipient is entirely the organizer's own Gmail alias variant", async () => {
    // The picker resolved the reply's sole curated recipient to a contact
    // record for "krisbraun@gmail.com" — a dot-variant of the organizer's own
    // connected mailbox "kris.braun@gmail.com" that hadn't been merged into
    // their primary contact. resolveOutboundReplyRecipients' curated-path
    // self-filter (Case 1) still recognizes it as self via baseEmail and
    // drops it, so the reply resolves to zero recipients rather than being
    // sent back to the organizer. Because this is a curated (non-empty
    // accessContacts) send with no deliverable recipient, the connector
    // surfaces a deliveryError instead of silently no-op'ing.
    const send = vi.spyOn(GmailApi.prototype, "sendNewMessage");
    const sendReply = vi.spyOn(GmailApi.prototype, "sendMessage");
    vi.spyOn(GmailApi.prototype, "getProfile").mockResolvedValue({
      emailAddress: "kris.braun@gmail.com",
    });
    vi.spyOn(GmailApi.prototype, "getUserInfo").mockResolvedValue({
      email: "kris.braun@gmail.com",
    });
    const { host } = makeHost();

    const res = await onNoteCreatedFn(
      host,
      replyNote(
        [{ externalAccountId: "krisbraun@gmail.com", role: null }],
        { accessContacts: ["c-alias"] }
      ),
      calThread({
        accessContacts: [
          { id: "c-me", email: "kris.braun@gmail.com" },
          { id: "c-alias", email: "krisbraun@gmail.com" },
        ],
      })
    );

    expect(send).not.toHaveBeenCalled();
    expect(sendReply).not.toHaveBeenCalled();
    expect(res).toEqual({
      deliveryError: {
        code: "no_recipients",
        message: "This reply had no deliverable recipients.",
      },
    });
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

  it("carries a curated (platform-resolved) recipient's display name into the To header", async () => {
    // note.recipients non-null is Case 1 (curated) in resolveOutboundReplyRecipients
    // — the only case that carries a display name — as opposed to the header-driven
    // fallback cases exercised by the test above, which always resolve to name: null.
    vi.spyOn(GmailApi.prototype, "getThread").mockResolvedValue(
      gmailAliasReplyThread()
    );
    vi.spyOn(GmailApi.prototype, "getProfile").mockResolvedValue({
      emailAddress: "kris.braun@gmail.com",
    });
    vi.spyOn(GmailApi.prototype, "getUserInfo").mockResolvedValue({
      email: "kris.braun@gmail.com",
    });
    const send = vi
      .spyOn(GmailApi.prototype, "sendMessage")
      .mockResolvedValue({ id: "sent-10", threadId: "gmail-thread-1" });
    const { host } = makeHost();

    await onNoteCreatedFn(
      host,
      plainReplyNote({
        recipients: [
          {
            id: "c-hilary",
            name: "Hilary Collier",
            externalAccountId: "hilary.collier@example.com",
            role: null,
          },
        ],
      }),
      plainThread()
    );

    expect(send).toHaveBeenCalledTimes(1);
    const raw = decodeRawMessage(send.mock.calls[0][0]);
    expect(raw).toContain('To: "Hilary Collier" <hilary.collier@example.com>');
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

/**
 * ICS bodies keyed by the attachment id Gmail would hand out for them.
 *
 * Gmail never leaves a calendar part inline: it synthesizes a filename
 * (`invite.ics`) and moves the body out to `attachmentId`, so reading the ICS
 * takes a second `messages.attachments.get` call. Fixtures below build that
 * real shape and register the body here, and {@link serveIcsAttachments}
 * stubs `fetch` to return it — so these tests exercise the same two-step read
 * production performs rather than a payload shape Gmail never produces.
 */
const registeredIcs = new Map<string, string>();

/** Stubs `fetch` so `messages.attachments.get` serves the registered bodies. */
function serveIcsAttachments(): void {
  vi.stubGlobal(
    "fetch",
    vi.fn(async (url: string) => {
      const attachmentId = url.split("/attachments/")[1]?.split("?")[0];
      const ics = attachmentId ? registeredIcs.get(attachmentId) : undefined;
      if (!ics) return new Response(null, { status: 404 });
      return new Response(
        JSON.stringify({ data: b64url(ics), size: ics.length }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    })
  );
}

/** A calendar part shaped the way Gmail really delivers one. */
function icsAttachmentPart(ics: string): GmailMessagePart {
  const attachmentId = `att-${registeredIcs.size + 1}`;
  registeredIcs.set(attachmentId, ics);
  serveIcsAttachments();
  return {
    mimeType: "text/calendar",
    filename: "invite.ics",
    headers: [],
    body: { size: ics.length, attachmentId },
  };
}

/** A single-message GmailThread carrying a calendar ICS part. */
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
        icsAttachmentPart(ics),
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

/** ICS body for one attendee response. */
function replyIcs(
  partstat: "DECLINED" | "ACCEPTED" | "TENTATIVE",
  opts: { uid?: string; comment?: string } = {}
): string {
  const lines = [
    "BEGIN:VCALENDAR",
    "METHOD:REPLY",
    "BEGIN:VEVENT",
    `UID:${opts.uid ?? "uid-rsvp@google.com"}`,
    `ATTENDEE;PARTSTAT=${partstat};CN=Beth Round:mailto:beth@example.test`,
  ];
  if (opts.comment) lines.push(`COMMENT:${opts.comment}`);
  lines.push("END:VEVENT", "END:VCALENDAR");
  return lines.join("\r\n");
}

/** A Gmail conversation carrying one RSVP notification, plus optional plain mail. */
function rsvpThread(
  threadId: string,
  ics: string,
  opts: { withPlainReply?: boolean } = {}
): GmailThread {
  const rsvp: GmailMessage = {
    id: `${threadId}-msg-1`,
    threadId,
    labelIds: ["INBOX"],
    snippet: "Beth Round has declined this invitation.",
    historyId: "1",
    internalDate: "1700000000000",
    sizeEstimate: 500,
    payload: part("multipart/mixed", {
      headers: [
        ["From", "Beth Round <beth@example.test>"],
        ["To", "me@example.com"],
        ["Subject", "Declined: Weekly sync @ Tue Aug 4, 2026"],
        // Real Google RSVP notifications are machine-generated; this header
        // lets facet tests below tell "computed from the folded notification"
        // apart from "computed from the surviving human reply".
        ["Auto-Submitted", "auto-generated"],
      ],
      parts: [
        part("text/plain", { data: "Beth Round has declined this invitation." }),
        icsAttachmentPart(ics),
      ],
    }),
  };
  const messages = [rsvp];
  if (opts.withPlainReply) {
    messages.push({
      id: `${threadId}-msg-2`,
      threadId,
      labelIds: ["INBOX"],
      snippet: "No problem",
      historyId: "2",
      internalDate: "1700000060000",
      sizeEstimate: 200,
      payload: part("text/plain", {
        data: "No problem, let's find another time.",
        headers: [
          ["From", "Beth Round <beth@example.test>"],
          ["To", "me@example.com"],
          ["Subject", "Re: Declined: Weekly sync @ Tue Aug 4, 2026"],
        ],
      }),
    });
  }
  return { id: threadId, historyId: "1", messages };
}

/** Capture every saveNote/saveLink call the sync makes. */
function captureSaves(host: GmailSyncHost, opts: { noteId?: string | null } = {}) {
  const notes: Record<string, unknown>[] = [];
  const links: NewLinkWithNotes[] = [];
  (host.tools.integrations.saveNote as ReturnType<typeof vi.fn>).mockImplementation(
    async (n: Record<string, unknown>) => {
      notes.push(n);
      return opts.noteId === undefined ? "N" : opts.noteId;
    }
  );
  (host.tools.integrations.saveLink as ReturnType<typeof vi.fn>).mockImplementation(
    async (l: NewLinkWithNotes) => {
      links.push(l);
      return "T";
    }
  );
  return { notes, links };
}

describe("processEmailThreadsFn — attendee responses fold onto the event", () => {
  it("writes a note to the event thread and saves no email link", async () => {
    const { host } = makeHost();
    const { notes, links } = captureSaves(host);

    await processEmailThreadsFn(
      host,
      [rsvpThread("rsvp-declined", replyIcs("DECLINED"))],
      false,
      "INBOX"
    );

    expect(notes).toHaveLength(1);
    expect(notes[0]).toMatchObject({
      thread: { source: "icaluid:uid-rsvp@google.com" },
      key: "rsvp-declined-msg-1",
      content: "Beth Round declined.",
      contentType: "markdown",
      // The external timestamp (the RSVP message's internalDate), not sync time.
      created: new Date(1700000000000),
      unread: true,
      author: { email: "beth@example.test", name: "Beth Round" },
    });
    expect(links).toHaveLength(0);
  });

  it("carries the responder's personal note into the quote", async () => {
    const { host } = makeHost();
    const { notes } = captureSaves(host);

    await processEmailThreadsFn(
      host,
      [
        rsvpThread(
          "rsvp-comment",
          replyIcs("DECLINED", { comment: "Could we move this to Thursday?" })
        ),
      ],
      false,
      "INBOX"
    );

    expect(notes[0].content).toBe(
      "Beth Round declined.\n\n> Could we move this to Thursday?"
    );
  });

  it("writes no note at all for a bare acceptance, and saves no email link", async () => {
    const { host } = makeHost();
    const { notes, links } = captureSaves(host);

    await processEmailThreadsFn(
      host,
      [rsvpThread("rsvp-accepted", replyIcs("ACCEPTED"))],
      false,
      "INBOX"
    );

    // The guest list already shows the acceptance. Writing a note is the only
    // thing that could mark the organiser's event thread unread, so we write none.
    expect(notes).toHaveLength(0);
    expect(links).toHaveLength(0);
  });

  it("writes a note for an acceptance carrying a personal comment", async () => {
    const { host } = makeHost();
    const { notes } = captureSaves(host);

    await processEmailThreadsFn(
      host,
      [
        rsvpThread(
          "rsvp-accepted-comment",
          replyIcs("ACCEPTED", { comment: "Sounds good, I'll bring the deck" })
        ),
      ],
      false,
      "INBOX"
    );

    expect(notes).toHaveLength(1);
    expect(notes[0]).toMatchObject({
      content: "Beth Round accepted.\n\n> Sounds good, I'll bring the deck",
      unread: true,
    });
  });

  it("writes a note when an acceptance reverses an earlier decline", async () => {
    const { host, store } = makeHost();
    const { notes } = captureSaves(host);

    await processEmailThreadsFn(
      host,
      [rsvpThread("rsvp-declined", replyIcs("DECLINED"))],
      false,
      "INBOX"
    );
    expect(store.get("rsvp:uid-rsvp@google.com:beth@example.test")).toBe("DECLINED");

    await processEmailThreadsFn(
      host,
      [rsvpThread("rsvp-accepted", replyIcs("ACCEPTED"))],
      false,
      "INBOX"
    );

    // Two notes: the decline, then the reversal.
    expect(notes).toHaveLength(2);
    expect(notes[1]).toMatchObject({ content: "Beth Round accepted." });
    // The outstanding non-acceptance is resolved, so the key is gone.
    expect(store.has("rsvp:uid-rsvp@google.com:beth@example.test")).toBe(false);
  });

  it("marks a folded response read during the initial backfill", async () => {
    const { host } = makeHost();
    const { notes } = captureSaves(host);

    await processEmailThreadsFn(
      host,
      [rsvpThread("rsvp-declined", replyIcs("DECLINED"))],
      true,
      "INBOX"
    );

    // Explicit false, not an omitted flag: omitting leaves the scoped-note
    // trigger's unread standing, which is what broke the original guard.
    expect(notes[0]).toMatchObject({ unread: false });
  });

  it("keeps ordinary correspondence in its own email thread", async () => {
    const { host } = makeHost();
    const { notes, links } = captureSaves(host);

    await processEmailThreadsFn(
      host,
      [rsvpThread("rsvp-mixed", replyIcs("DECLINED"), { withPlainReply: true })],
      false,
      "INBOX"
    );

    expect(notes).toHaveLength(1);
    expect(links).toHaveLength(1);
    const keys = (links[0].notes ?? []).map(
      (n) => (n as { key?: string }).key
    );
    expect(keys).toEqual(["rsvp-mixed-msg-2"]);

    // The preview came from thread.messages[0] (the folded RSVP
    // notification) before this fix — it must now reflect the surviving
    // human reply instead.
    expect(links[0].preview).toBe("No problem");

    // Facets must be computed from the surviving human reply, not the
    // folded notification: the RSVP message carries an Auto-Submitted
    // header (see rsvpThread), so picking it would classify this thread as
    // automated even though a real person wrote the surviving message.
    expect(links[0].facets?.automation).toBe("human");
  });

  it("keeps the email thread when the event thread cannot be resolved", async () => {
    const { host } = makeHost();
    // null = no thread carries `icaluid:<uid>` yet (calendar hasn't synced).
    const { notes, links } = captureSaves(host, { noteId: null });

    await processEmailThreadsFn(
      host,
      [rsvpThread("rsvp-orphan", replyIcs("DECLINED"))],
      false,
      "INBOX"
    );

    expect(notes).toHaveLength(1);
    expect(links).toHaveLength(1);
    const keys = (links[0].notes ?? []).map(
      (n) => (n as { key?: string }).key
    );
    expect(keys).toEqual(["rsvp-orphan-msg-1"]);
  });

  it("records a pending retry when the event has not synced yet", async () => {
    const { host, store } = makeHost();
    captureSaves(host, { noteId: null });

    await processEmailThreadsFn(
      host,
      [rsvpThread("rsvp-pending", replyIcs("DECLINED"))],
      false,
      "INBOX"
    );

    expect(store.get("pending-rsvp:rsvp-pending")).toMatchObject({
      threadId: "rsvp-pending",
    });
  });

  it("does not track a conversation that also carries real correspondence", async () => {
    const { host, store } = makeHost();
    captureSaves(host, { noteId: null });

    await processEmailThreadsFn(
      host,
      [
        rsvpThread("rsvp-mixed", replyIcs("DECLINED"), {
          withPlainReply: true,
        }),
      ],
      false,
      "INBOX"
    );

    // Archiving later must never hide a human reply, so a mixed conversation
    // is left alone entirely.
    expect(store.get("pending-rsvp:rsvp-mixed")).toBeUndefined();
  });
});

describe("drainPendingRsvpsFn — retract once the event arrives", () => {
  /** Seeds one pending entry and the Gmail thread the retry re-reads. */
  function seedPending(
    host: GmailSyncHost,
    store: Map<string, unknown>,
    opts: {
      firstSeen?: string;
      partstat?: "DECLINED" | "ACCEPTED" | "TENTATIVE";
    } = {}
  ) {
    // Declined by default: a bare acceptance now writes no note, so it cannot
    // exercise the fold-and-retract path these tests cover.
    const gmailThread = rsvpThread(
      "rsvp-late",
      replyIcs(opts.partstat ?? "DECLINED")
    );
    store.set("pending-rsvp:rsvp-late", {
      threadId: "rsvp-late",
      channelId: "INBOX",
      firstSeen: opts.firstSeen ?? new Date().toISOString(),
    });
    (host.tools.store.list as ReturnType<typeof vi.fn>).mockImplementation(
      async (prefix: string) =>
        [...store.keys()].filter((k) => k.startsWith(prefix))
    );
    vi.spyOn(GmailApi.prototype, "getThread").mockResolvedValue(gmailThread);
  }

  it("folds the response and archives the standalone email thread", async () => {
    const { host, store } = makeHost();
    const { notes } = captureSaves(host, { noteId: "N" });
    seedPending(host, store);

    await drainPendingRsvpsFn(host);

    expect(notes).toHaveLength(1);
    expect(notes[0]).toMatchObject({
      thread: { source: "icaluid:uid-rsvp@google.com" },
    });
    expect(host.tools.integrations.archiveLinks).toHaveBeenCalledWith({
      meta: { threadId: "rsvp-late" },
    });
    expect(store.has("pending-rsvp:rsvp-late")).toBe(false);
  });

  it("applies the same unread rule the first pass would have", async () => {
    const { host, store } = makeHost();
    const { notes } = captureSaves(host, { noteId: "N" });
    const declined = rsvpThread("rsvp-late", replyIcs("DECLINED"));
    store.set("pending-rsvp:rsvp-late", {
      threadId: "rsvp-late",
      channelId: "INBOX",
      initialSync: false,
      firstSeen: new Date().toISOString(),
    });
    (host.tools.store.list as ReturnType<typeof vi.fn>).mockImplementation(
      async (prefix: string) =>
        [...store.keys()].filter((k) => k.startsWith(prefix))
    );
    vi.spyOn(GmailApi.prototype, "getThread").mockResolvedValue(declined);

    await drainPendingRsvpsFn(host);

    // A decline is worth surfacing; an acceptance is not. Retrying must not
    // change that, or a late fold is noisier than a timely one.
    expect(notes[0]).toMatchObject({ unread: true });
  });

  it("leaves a response first seen during the initial backfill read", async () => {
    const { host, store } = makeHost();
    const { notes } = captureSaves(host, { noteId: "N" });
    const declined = rsvpThread("rsvp-late", replyIcs("DECLINED"));
    store.set("pending-rsvp:rsvp-late", {
      threadId: "rsvp-late",
      channelId: "INBOX",
      initialSync: true,
      firstSeen: new Date().toISOString(),
    });
    (host.tools.store.list as ReturnType<typeof vi.fn>).mockImplementation(
      async (prefix: string) =>
        [...store.keys()].filter((k) => k.startsWith(prefix))
    );
    vi.spyOn(GmailApi.prototype, "getThread").mockResolvedValue(declined);

    await drainPendingRsvpsFn(host);

    // Explicit false, not an omitted flag: omitting leaves the scoped-note
    // trigger's unread standing, same convention as the live fold path.
    expect(notes[0]).toMatchObject({ unread: false });
  });

  it("keeps the entry and archives nothing while the event is still missing", async () => {
    const { host, store } = makeHost();
    captureSaves(host, { noteId: null });
    seedPending(host, store);

    await drainPendingRsvpsFn(host);

    expect(host.tools.integrations.archiveLinks).not.toHaveBeenCalled();
    expect(store.has("pending-rsvp:rsvp-late")).toBe(true);
  });

  it("writes no note when the deferred response was a bare acceptance", async () => {
    const { host, store } = makeHost();
    const { notes } = captureSaves(host, { noteId: "N" });
    seedPending(host, store, { partstat: "ACCEPTED" });

    await drainPendingRsvpsFn(host);

    expect(notes).toHaveLength(0);
    // Still retracted: nothing was left for the standalone email thread to show.
    expect(host.tools.integrations.archiveLinks).toHaveBeenCalledWith({
      meta: { threadId: "rsvp-late" },
    });
    expect(store.has("pending-rsvp:rsvp-late")).toBe(false);
  });

  it("gives up on an entry older than the retry window", async () => {
    const { host, store } = makeHost();
    captureSaves(host, { noteId: "N" });
    seedPending(host, store, {
      firstSeen: new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString(),
    });

    await drainPendingRsvpsFn(host);

    expect(host.tools.integrations.archiveLinks).not.toHaveBeenCalled();
    expect(store.has("pending-rsvp:rsvp-late")).toBe(false);
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

// A plain Gmail thread for reaction round-trips: message "msg-orig-1" from
// Hilary, addressed to the connected mailbox (self) with Annie on Cc.
function reactionThread(): GmailThread {
  return gmailAliasReplyThread();
}

function reactionNote(over: Record<string, unknown> = {}) {
  return {
    id: "n-react",
    key: "msg-orig-1",
    author: { id: "c-me" },
    ...over,
  } as unknown as import("@plotday/twister").Note;
}

describe("onNoteReactionChangedFn", () => {
  it("schedules a deferred send when a reaction is added (send-undo window)", async () => {
    const { host } = makeHost();
    const schedule = host.scheduler.scheduleReactionSend as ReturnType<
      typeof vi.fn
    >;
    const before = Date.now();

    await onNoteReactionChangedFn(host, reactionNote(), plainThread(), "💖", true);

    expect(schedule).toHaveBeenCalledTimes(1);
    const [key, threadId, channelId, noteKey, emoji, runAt] =
      schedule.mock.calls[0];
    expect(key).toBe("mail:reaction-send:msg-orig-1:💖");
    expect(threadId).toBe("gmail-thread-1");
    expect(channelId).toBe("INBOX");
    expect(noteKey).toBe("msg-orig-1");
    expect(emoji).toBe("💖");
    expect((runAt as Date).getTime()).toBeGreaterThanOrEqual(
      before + REACTION_SEND_DELAY_MS - 50
    );
  });

  it("cancels a still-pending send when the reaction is removed before it fires", async () => {
    const { host } = makeHost();
    const trash = vi.spyOn(GmailApi.prototype, "trashMessage");

    await onNoteReactionChangedFn(host, reactionNote(), plainThread(), "💖", false);

    expect(host.scheduler.cancelScheduledTask).toHaveBeenCalledWith(
      "mail:reaction-send:msg-orig-1:💖"
    );
    // Nothing was sent, so nothing is trashed.
    expect(trash).not.toHaveBeenCalled();
  });

  it("retracts an already-sent reaction by trashing our reaction email", async () => {
    const { host, store } = makeHost();
    store.set("reaction-msg:msg-orig-1:💖", "reaction-sent-1");
    const trash = vi
      .spyOn(GmailApi.prototype, "trashMessage")
      .mockResolvedValue(undefined);

    await onNoteReactionChangedFn(host, reactionNote(), plainThread(), "💖", false);

    expect(host.scheduler.cancelScheduledTask).toHaveBeenCalled();
    expect(trash).toHaveBeenCalledWith("reaction-sent-1");
    expect(store.has("reaction-msg:msg-orig-1:💖")).toBe(false);
  });

  it("ignores workspace custom-emoji reactions (no Gmail equivalent)", async () => {
    const { host } = makeHost();
    await onNoteReactionChangedFn(
      host,
      reactionNote(),
      plainThread(),
      "slack:T0/party_parrot",
      true
    );
    expect(host.scheduler.scheduleReactionSend).not.toHaveBeenCalled();
  });

  it("ignores non-Gmail threads (no threadId in meta)", async () => {
    const { host } = makeHost();
    await onNoteReactionChangedFn(
      host,
      reactionNote(),
      plainThread({ meta: { calendarId: "primary" } }),
      "💖",
      true
    );
    expect(host.scheduler.scheduleReactionSend).not.toHaveBeenCalled();
  });
});

describe("sendReactionEmailFn", () => {
  it("sends a reaction email reply-all to the other participants, threaded on the reacted message", async () => {
    vi.spyOn(GmailApi.prototype, "getThread").mockResolvedValue(reactionThread());
    vi.spyOn(GmailApi.prototype, "getProfile").mockResolvedValue({
      emailAddress: "kris.braun@gmail.com",
    });
    vi.spyOn(GmailApi.prototype, "getUserInfo").mockResolvedValue({
      email: "kris.braun@gmail.com",
      name: "Kris",
    });
    const send = vi
      .spyOn(GmailApi.prototype, "sendMessage")
      .mockResolvedValue({ id: "reaction-sent-1", threadId: "gmail-thread-1" });
    const { host, store } = makeHost();

    await sendReactionEmailFn(host, "gmail-thread-1", "INBOX", "msg-orig-1", "💖");

    expect(send).toHaveBeenCalledTimes(1);
    const raw = decodeRawMessage(send.mock.calls[0][0]);
    expect(raw).toContain("In-Reply-To: <orig@mail.gmail.com>");
    expect(raw).toContain("Content-Type: text/vnd.google.email-reaction+json");
    expect(JSON.parse(decodeMimePart(raw, "text/vnd.google.email-reaction+json"))).toEqual(
      { version: 1, emoji: "💖" }
    );
    // Reply-all: original sender + Cc, excluding the connected mailbox (self).
    expect(raw).toContain("hilary.collier@example.com");
    expect(raw).toContain("annie@example.com");
    expect(raw).not.toContain("krisbraun@gmail.com");
    // Sent id is recorded for later retraction + echo suppression.
    expect(store.get("reaction-msg:msg-orig-1:💖")).toBe("reaction-sent-1");
    expect(store.get("sent:reaction-sent-1")).toBe(true);
  });

  it("is idempotent: a re-dispatched task does not send a second email", async () => {
    const { host, store } = makeHost();
    store.set("reaction-msg:msg-orig-1:💖", "reaction-sent-1");
    const send = vi.spyOn(GmailApi.prototype, "sendMessage");

    await sendReactionEmailFn(host, "gmail-thread-1", "INBOX", "msg-orig-1", "💖");

    expect(send).not.toHaveBeenCalled();
  });
});
