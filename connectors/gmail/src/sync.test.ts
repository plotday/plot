import { afterEach, describe, expect, it, vi } from "vitest";

import type { CreateLinkDraft, Uuid } from "@plotday/twister";

import { GmailApi, GmailApiError, type GmailHeader, type GmailMessage } from "./gmail-api";
import { type GmailSyncHost, onCreateLinkFn } from "./sync";

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
    expect(raw).toContain("Bcc: eve@example.com");
    expect(raw).toContain("To: bob@example.com");
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
});
