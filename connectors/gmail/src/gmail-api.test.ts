import { afterEach, describe, expect, it, vi } from "vitest";
import {
  GmailApi,
  buildNewEmailMessage,
  buildReplyMessage,
  stripQuotedReply,
  transformGmailThread,
  type AttachmentData,
  type GmailMessage,
  type GmailMessagePart,
  type GmailThread,
} from "./gmail-api";

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

// Gmail API returns part bodies as base64url. Encode fixtures the same way the
// real API does so `extractBody`'s atob/replace decode path is exercised.
function b64url(s: string): string {
  return Buffer.from(s, "utf8")
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");
}

function part(
  mimeType: string,
  opts: {
    data?: string;
    parts?: GmailMessagePart[];
    headers?: Array<[string, string]>;
    filename?: string;
  } = {}
): GmailMessagePart {
  return {
    mimeType,
    filename: opts.filename,
    headers: (opts.headers ?? []).map(([name, value]) => ({ name, value })),
    body:
      opts.data !== undefined
        ? { size: opts.data.length, data: b64url(opts.data) }
        : undefined,
    parts: opts.parts,
  };
}

function thread(opts: {
  from: string;
  to?: string;
  subject?: string;
  snippet?: string;
  payload: GmailMessagePart;
}): GmailThread {
  const headers = [
    { name: "From", value: opts.from },
    ...(opts.to ? [{ name: "To", value: opts.to }] : []),
    ...(opts.subject ? [{ name: "Subject", value: opts.subject }] : []),
  ];
  const message: GmailMessage = {
    id: "msg-1",
    threadId: "thread-1",
    labelIds: ["INBOX"],
    snippet: opts.snippet ?? "snippet-without-body-marker",
    historyId: "1",
    internalDate: "1700000000000",
    payload: { ...opts.payload, headers: [...headers, ...opts.payload.headers] },
    sizeEstimate: 1000,
  };
  return { id: "thread-1", historyId: "1", messages: [message] };
}

function firstNoteContent(t: GmailThread): string {
  const result = transformGmailThread(t);
  return result.notes?.[0]?.content ?? "";
}

describe("GmailApi.call empty-body responses", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("stopWatch resolves when Gmail returns 204 No Content (empty body)", async () => {
    // Gmail's users.stop endpoint returns 204 No Content with an EMPTY body.
    // Parsing an empty body with response.json() throws
    // "SyntaxError: Unexpected end of JSON input" — which escaped through
    // setupWatch()'s unguarded stopWatch() recovery and surfaced as an
    // unhandled twist exception (PostHog 019eff7f).
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () => new Response(null, { status: 204, statusText: "No Content" })
      )
    );
    const api = new GmailApi("test-token");
    await expect(api.stopWatch()).resolves.toBeUndefined();
  });

  it("call returns parsed JSON for a normal response (regression)", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(JSON.stringify({ emailAddress: "kris@plot.day" }), {
            status: 200,
            headers: { "Content-Type": "application/json" },
          })
      )
    );
    const api = new GmailApi("test-token");
    await expect(api.getProfile()).resolves.toEqual({
      emailAddress: "kris@plot.day",
    });
  });
});

describe("forwarded email body extraction", () => {
  it("keeps the body of an inline HTML forward (Gmail wraps it in gmail_quote)", () => {
    // Gmail's "Forward" composes the original inside <div class="gmail_quote">,
    // the SAME wrapper it uses for reply quotes — so the reply-stripper wrongly
    // deletes the forwarded content, leaving an empty note.
    const html =
      '<div dir="ltr"><br>' +
      '<div class="gmail_quote gmail_quote_container">' +
      '<div dir="ltr" class="gmail_attr">---------- Forwarded message ---------<br>' +
      "From: <strong>Porter Airlines</strong> &lt;flyporter@notifications.flyporter.com&gt;<br>" +
      "Date: Wed, Aug 19, 2026<br>Subject: Booking details<br>To: Kris<br></div><br>" +
      "<div>Your booking is confirmed. Confirmation code: BOOKINGCONFIRM123. Gate at YYZ.</div>" +
      "</div></div>";
    const t = thread({
      from: "Forwarder <fwd@example.com>",
      to: "kris@plot.day",
      subject: "Fwd: Booking details",
      payload: part("multipart/alternative", {
        parts: [
          part("text/plain", {
            data:
              "---------- Forwarded message ---------\r\nFrom: Porter Airlines\r\n\r\n" +
              "Your booking is confirmed. Confirmation code: BOOKINGCONFIRM123.",
          }),
          part("text/html", { data: html }),
        ],
      }),
    });
    expect(firstNoteContent(t)).toContain("BOOKINGCONFIRM123");
  });

  it("keeps the body of a plain-text forward", () => {
    const t = thread({
      from: "Forwarder <fwd@example.com>",
      to: "kris@plot.day",
      subject: "Fwd: Booking details",
      // Exact 10/10-dash separator that the strip path matches literally.
      payload: part("text/plain", {
        data:
          "---------- Forwarded message ----------\r\n" +
          "From: Porter Airlines\r\nSubject: Booking details\r\n\r\n" +
          "Your booking is confirmed. Confirmation code: PLAINFWD456.",
      }),
    });
    expect(firstNoteContent(t)).toContain("PLAINFWD456");
  });

  it("keeps the body of a forward attached as message/rfc822", () => {
    const t = thread({
      from: "Forwarder <fwd@example.com>",
      to: "kris@plot.day",
      subject: "Fwd: Booking details",
      payload: part("multipart/mixed", {
        parts: [
          part("text/plain", { data: "" }), // forwarder added no note
          part("message/rfc822", {
            parts: [
              part("multipart/alternative", {
                parts: [
                  part("text/plain", {
                    data:
                      "Your booking is confirmed. Confirmation code: RFC822FWD789.",
                  }),
                  part("text/html", {
                    data:
                      "<div>Your booking is confirmed. Confirmation code: RFC822FWD789.</div>",
                  }),
                ],
              }),
            ],
          }),
        ],
      }),
    });
    expect(firstNoteContent(t)).toContain("RFC822FWD789");
  });

  it("still strips quoted replies (regression guard — HTML)", () => {
    const html =
      '<div dir="ltr">Thanks, that works for me!' +
      '<div class="gmail_quote">' +
      '<div dir="ltr" class="gmail_attr">On Mon, Jun 1, 2026 at 9:00 AM Bob &lt;bob@example.com&gt; wrote:<br></div>' +
      '<blockquote class="gmail_quote">SECRETQUOTEDREPLY must be stripped</blockquote>' +
      "</div></div>";
    const t = thread({
      from: "Bob <bob@example.com>",
      to: "kris@plot.day",
      subject: "Re: lunch",
      payload: part("text/html", { data: html }),
    });
    const content = firstNoteContent(t);
    expect(content).toContain("Thanks, that works for me!");
    expect(content).not.toContain("SECRETQUOTEDREPLY");
  });

  it("still strips quoted replies (regression guard — plain text)", () => {
    const reply = stripQuotedReply(
      "My answer is yes.\r\nOn Mon, Jun 1, 2026, Bob wrote:\r\n> old message text",
      "text"
    );
    expect(reply).toContain("My answer is yes.");
    expect(reply).not.toContain("old message text");
  });
});

describe("outbound MIME bodies (multipart/alternative HTML + plain)", () => {
  const markdownBody =
    "**Exploring burnout**\n\n" +
    "Is burnout caused by too much work? I think either could work, " +
    "and the key will be positioning and messaging for our first session.";

  it("buildReplyMessage emits multipart/alternative with text and html parts", () => {
    const raw = decodeRawMessage(
      buildReplyMessage({
        to: ["phil467@gmail.com"],
        cc: ["kris@plot.day"],
        from: "beth@plot.day",
        subject: "Workshop ideas",
        body: markdownBody,
        messageId: "<abc@mail.gmail.com>",
        references: "<root@mail.gmail.com>",
      })
    );

    expect(raw).toContain("Content-Type: multipart/alternative");
    expect(raw).toContain('Content-Type: text/plain; charset="UTF-8"');
    expect(raw).toContain('Content-Type: text/html; charset="UTF-8"');

    // HTML part renders markdown (no literal ** asterisks reach the reader).
    const html = decodeMimePart(raw, "text/html");
    expect(html).toContain("<strong>Exploring burnout</strong>");
    expect(html).not.toContain("**Exploring burnout**");

    // Plain part is clean text — markdown syntax stripped, sentence intact on
    // one logical line (no hard mid-sentence wrap that the recipient would see).
    const text = decodeMimePart(raw, "text/plain");
    expect(text).toContain("Exploring burnout");
    expect(text).not.toContain("**");
    expect(text).toContain(
      "Is burnout caused by too much work? I think either could work, and the key will be positioning and messaging for our first session."
    );
  });

  it("buildReplyMessage with attachments nests alternative inside multipart/mixed", () => {
    const attachments: AttachmentData[] = [
      {
        fileName: "notes.txt",
        mimeType: "text/plain",
        data: new TextEncoder().encode("hello"),
      },
    ];
    const raw = decodeRawMessage(
      buildReplyMessage({
        to: ["phil467@gmail.com"],
        cc: [],
        from: "beth@plot.day",
        subject: "Workshop ideas",
        body: markdownBody,
        messageId: "<abc@mail.gmail.com>",
        references: "",
        attachments,
      })
    );

    expect(raw).toContain("Content-Type: multipart/mixed");
    expect(raw).toContain("Content-Type: multipart/alternative");
    expect(raw).toContain('Content-Type: text/html; charset="UTF-8"');
    expect(raw).toContain('Content-Disposition: attachment; filename="notes.txt"');
    expect(decodeMimePart(raw, "text/html")).toContain(
      "<strong>Exploring burnout</strong>"
    );
  });

  it("buildNewEmailMessage emits multipart/alternative with text and html parts", () => {
    const raw = decodeRawMessage(
      buildNewEmailMessage({
        to: ["phil467@gmail.com"],
        from: "beth@plot.day",
        subject: "Workshop ideas",
        body: markdownBody,
      })
    );

    expect(raw).toContain("Content-Type: multipart/alternative");
    expect(decodeMimePart(raw, "text/html")).toContain(
      "<strong>Exploring burnout</strong>"
    );
    expect(decodeMimePart(raw, "text/plain")).not.toContain("**");
  });
});
