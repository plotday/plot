import { describe, expect, it } from "vitest";

// Reach into the Gmail connector's lower-level helpers directly — the package
// only exports its `Gmail` class through its entry point (see the sibling
// gmail-quote-strip test for the same pattern).
import {
  buildNewEmailMessage,
  buildReplyMessage,
  syncGmailMailboxIncremental,
} from "../../../../../../public/connectors/gmail/src/gmail-api";

/** Decode a base64url-encoded raw RFC 2822 message back to a UTF-8 string. */
function decodeRaw(b64url: string): string {
  const b64 = b64url.replace(/-/g, "+").replace(/_/g, "/");
  const bin = atob(b64);
  const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
  return new TextDecoder().decode(bytes);
}

function headerLines(raw: string): string[] {
  return decodeRaw(raw).split("\r\n\r\n")[0].split("\r\n");
}

/** True if any header LINE begins with `name:` (case-insensitive). */
function hasHeader(raw: string, name: string): boolean {
  const re = new RegExp(`^${name}:`, "i");
  return headerLines(raw).some((line) => re.test(line));
}

describe("buildNewEmailMessage — header injection", () => {
  it("strips CRLF injected into the subject", () => {
    const raw = buildNewEmailMessage({
      to: ["a@example.com"],
      from: "me@example.com",
      subject: "Hello\r\nBcc: evil@example.com\r\nX-Injected: 1",
      body: "hi",
    });
    // The injected text must not become its own header line.
    expect(hasHeader(raw, "Bcc")).toBe(false);
    expect(hasHeader(raw, "X-Injected")).toBe(false);
    // The subject value survives as a single folded-free line.
    expect(
      headerLines(raw).some((l) => l.startsWith("Subject: Hello"))
    ).toBe(true);
  });

  it("strips CRLF injected into recipient addresses", () => {
    const raw = buildNewEmailMessage({
      to: ["a@example.com\r\nBcc: evil@example.com"],
      cc: ["c@example.com\nX-Evil: 1"],
      from: "me@example.com",
      subject: "Hi",
      body: "hi",
    });
    expect(hasHeader(raw, "Bcc")).toBe(false);
    expect(hasHeader(raw, "X-Evil")).toBe(false);
  });
});

describe("buildReplyMessage — header injection", () => {
  it("strips CRLF from subject, recipients, and threading headers", () => {
    const raw = buildReplyMessage({
      to: ["a@example.com"],
      cc: [],
      from: "me@example.com",
      subject: "Status\r\nBcc: evil@example.com",
      body: "ok",
      messageId: "<m1@example.com>\r\nX-Injected: 1",
      references: "<ref@example.com>\r\nX-Evil: 2",
    });
    expect(hasHeader(raw, "Bcc")).toBe(false);
    expect(hasHeader(raw, "X-Injected")).toBe(false);
    expect(hasHeader(raw, "X-Evil")).toBe(false);
    expect(
      headerLines(raw).some((l) => l.startsWith("Subject: Re: Status"))
    ).toBe(true);
  });
});

describe("buildReplyMessage — body transfer encoding", () => {
  it("base64-encodes the text body when declaring a non-identity encoding (no raw 8-bit body under a mismatched CTE)", () => {
    const body = "Olá, café — 你好";
    const raw = buildReplyMessage({
      to: ["a@example.com"],
      cc: [],
      from: "me@example.com",
      subject: "Hi",
      body,
      messageId: "<m1@example.com>",
      references: "",
      attachments: [
        {
          fileName: "f.txt",
          mimeType: "text/plain",
          data: new TextEncoder().encode("file contents"),
        },
      ],
    });
    const msg = decodeRaw(raw);

    // The declared encoding must match what we actually emit.
    expect(msg).not.toContain("quoted-printable");
    expect(msg).toContain("Content-Transfer-Encoding: base64");

    // The raw body must NOT appear verbatim (it would, if inserted unencoded
    // under a base64/quoted-printable declaration).
    expect(msg).not.toContain(body);

    // The base64 of the UTF-8 body must appear.
    const b64body = btoa(
      String.fromCharCode(...new TextEncoder().encode(body))
    );
    expect(msg).toContain(b64body);
  });
});

describe("syncGmailMailboxIncremental — failed-fetch handling", () => {
  function fakeApi(opts: {
    history: any[];
    historyId: string;
    fail?: Set<string>;
  }) {
    const fetched: string[] = [];
    return {
      fetched,
      api: {
        async getHistory() {
          return { history: opts.history, historyId: opts.historyId };
        },
        async getThread(id: string) {
          fetched.push(id);
          if (opts.fail?.has(id)) throw new Error(`boom ${id}`);
          return { id, historyId: "x", messages: [] };
        },
      } as any,
    };
  }

  it("reports failed thread fetches instead of silently dropping them", async () => {
    const { api } = fakeApi({
      history: [
        {
          id: "1",
          messagesAdded: [
            { message: { threadId: "t1" } },
            { message: { threadId: "t2" } },
          ],
        },
      ],
      historyId: "200",
      fail: new Set(["t2"]),
    });

    const result = await syncGmailMailboxIncremental(api, "100");
    expect(result.expired).toBe(false);
    if (result.expired) return;
    expect(result.historyId).toBe("200");
    expect(result.threads.map((t) => t.id)).toEqual(["t1"]);
    expect(result.failedThreadIds).toEqual(["t2"]);
  });

  it("re-fetches previously-failed threads passed via retryThreadIds", async () => {
    const { api, fetched } = fakeApi({
      history: [],
      historyId: "300",
    });

    const result = await syncGmailMailboxIncremental(api, "200", ["t2"]);
    expect(result.expired).toBe(false);
    if (result.expired) return;
    expect(fetched).toContain("t2");
    expect(result.threads.map((t) => t.id)).toEqual(["t2"]);
    expect(result.failedThreadIds).toEqual([]);
  });

  it("does not double-fetch a thread that is both changed and in the retry set", async () => {
    const { api, fetched } = fakeApi({
      history: [
        { id: "1", messagesAdded: [{ message: { threadId: "t1" } }] },
      ],
      historyId: "400",
    });

    const result = await syncGmailMailboxIncremental(api, "300", ["t1"]);
    expect(result.expired).toBe(false);
    expect(fetched.filter((id) => id === "t1")).toHaveLength(1);
  });
});
