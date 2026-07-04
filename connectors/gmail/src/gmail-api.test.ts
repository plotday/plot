import { afterEach, describe, expect, it, vi } from "vitest";
import {
  GmailApi,
  buildForwardMessage,
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

  it("strips Apple Mail quoted replies (<blockquote type=\"cite\">)", () => {
    // Apple Mail (Mail.app / iPhone Mail) wraps the "On <date>, <name> wrote:"
    // attribution and the quoted history in <blockquote type="cite">. The
    // quoted history here ALSO contains a nested gmail_quote (the original was
    // sent from Gmail), so the earliest boundary — the first cite blockquote —
    // must win, not the later nested gmail_quote.
    const html =
      '<body dir="auto">Sounds good, I will call you at 1:30pm.' +
      "<div><br></div><div>Talk soon,</div><div><br></div>" +
      '<div>Alice Example<br id="lineBreakAtBeginningOfSignature">' +
      '<div dir="ltr"><br></div><div dir="ltr"><br>' +
      '<blockquote type="cite">On Jan 2, 2026, at 8:03 PM, Bob Example ' +
      "&lt;bob@example.com&gt; wrote:<br><br></blockquote></div>" +
      '<blockquote type="cite"><div dir="ltr">Thanks Alice.' +
      "SECRETAPPLEQUOTE must be stripped." +
      '<div class="gmail_quote gmail_quote_container">nested older quote</div>' +
      "</div></blockquote></body>";
    const reply = stripQuotedReply(html, "html");
    expect(reply).toContain("Sounds good, I will call you");
    expect(reply).toContain("Talk soon,");
    expect(reply).toContain("Alice Example");
    expect(reply).not.toContain("On Jan 2, 2026");
    expect(reply).not.toContain("SECRETAPPLEQUOTE");
    expect(reply).not.toContain("nested older quote");
  });

  it("strips Yahoo Mail quoted replies (yahoo_quoted container)", () => {
    const html =
      '<div class="ydp2bd977f2yahoo-style-wrap">' +
      '<div dir="ltr">Hi Bob, thanks for the update.</div>' +
      '<div><br></div><div class="ydp2bd977f2signature">' +
      '<div dir="ltr">Kind regards, Alice</div></div></div>' +
      "<div><br></div><div><br></div>" +
      '<div id="yahoo_quoted_3231833225" class="yahoo_quoted">' +
      "<div>On Saturday, 16 May 2026 at 22:17:45 BST, Bob Example wrote:</div>" +
      "<div>SECRETYAHOOQUOTE must be stripped</div></div>";
    const reply = stripQuotedReply(html, "html");
    expect(reply).toContain("Hi Bob, thanks for the update");
    expect(reply).toContain("Kind regards, Alice");
    expect(reply).not.toContain("On Saturday, 16 May 2026");
    expect(reply).not.toContain("SECRETYAHOOQUOTE");
  });

  it("keeps an Apple Mail forwarded message (blockquote type=cite around forward)", () => {
    // A forward wrapped in a cite blockquote must be preserved — the forwarded
    // content IS the note. The forward guard runs before quote stripping.
    const html =
      '<body dir="auto">FYI below<div><br></div>' +
      '<blockquote type="cite">Begin forwarded message:<br><br>' +
      "From: Someone &lt;someone@example.com&gt;<br>" +
      "Subject: KEEPAPPLEFWD789<br>To: Alice<br><br>" +
      "The booking is confirmed.</blockquote></body>";
    const reply = stripQuotedReply(html, "html");
    expect(reply).toContain("KEEPAPPLEFWD789");
    expect(reply).toContain("The booking is confirmed.");
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

describe("buildForwardMessage", () => {
  it("uses a Fwd: subject and includes the quoted original + forwarder message", () => {
    const raw = decodeRawMessage(
      buildForwardMessage({
        to: ["bob@example.com"],
        cc: [],
        from: "me@example.com",
        subject: "Q3 budget",
        body: "See below.",
        originalHeader: "From: Alice <alice@example.com>\nSubject: Q3 budget",
        originalBody: "Let's meet Thursday.",
      })
    );
    expect(raw).toContain("Subject: Fwd: Q3 budget");
    expect(raw).not.toContain("In-Reply-To:");

    // Body content lives base64-encoded inside the multipart/alternative
    // plain-text part, so decode that part rather than scanning the raw
    // (still-encoded) message for the literal text.
    const text = decodeMimePart(raw, "text/plain");
    expect(text).toContain("See below.");
    expect(text).toContain("Let's meet Thursday.");
  });

  it("keeps an existing Fwd: prefix instead of doubling it", () => {
    const raw = decodeRawMessage(
      buildForwardMessage({
        to: ["b@x.com"],
        cc: [],
        from: "m@x.com",
        subject: "Fwd: hi",
        body: "",
        originalHeader: "From: a@x.com",
        originalBody: "hi",
      })
    );
    expect(raw).toContain("Subject: Fwd: hi");
    expect(raw).not.toContain("Fwd: Fwd:");
  });

  it("emits a Bcc header without exposing bcc addresses in To/Cc", () => {
    const raw = decodeRawMessage(
      buildForwardMessage({
        to: ["bob@example.com"],
        cc: ["carol@example.com"],
        bcc: ["dave@example.com"],
        from: "me@example.com",
        subject: "Q3 budget",
        body: "",
        originalHeader: "From: Alice <alice@example.com>",
        originalBody: "hi",
      })
    );
    expect(raw).toContain("Bcc: dave@example.com");
    expect(raw).toContain("To: bob@example.com");
    expect(raw).not.toContain("To: bob@example.com, dave@example.com");
    expect(raw).not.toContain("Cc: carol@example.com, dave@example.com");
  });

  it("omits the Bcc header entirely when there are no bcc recipients", () => {
    const raw = decodeRawMessage(
      buildForwardMessage({
        to: ["bob@example.com"],
        cc: [],
        from: "me@example.com",
        subject: "Q3 budget",
        body: "",
        originalHeader: "From: Alice <alice@example.com>",
        originalBody: "hi",
      })
    );
    expect(raw).not.toContain("Bcc:");
  });
});
