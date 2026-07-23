import { afterEach, describe, expect, it, vi } from "vitest";
import {
  GmailApi,
  buildForwardMessage,
  buildNewEmailMessage,
  buildReplyMessage,
  canonicalizeGmailAddress,
  classifyCalendarThread,
  formatFromHeader,
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

  it("getUserInfo fetches the display name from Google's userinfo endpoint", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(
          JSON.stringify({ email: "kris@plot.day", name: "Kris Braun" }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    );
    vi.stubGlobal("fetch", fetchMock);
    const api = new GmailApi("test-token");

    await expect(api.getUserInfo()).resolves.toEqual({
      email: "kris@plot.day",
      name: "Kris Braun",
    });
    expect(fetchMock).toHaveBeenCalledWith(
      "https://www.googleapis.com/oauth2/v3/userinfo",
      { headers: { Authorization: "Bearer test-token" } }
    );
  });

  it("getUserInfo throws on a non-OK response", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () => new Response(null, { status: 401, statusText: "Unauthorized" })
      )
    );
    const api = new GmailApi("test-token");

    await expect(api.getUserInfo()).rejects.toThrow("UserInfo error: 401");
  });
});

describe("formatFromHeader", () => {
  it("quotes the display name around the email when a name is available", () => {
    expect(formatFromHeader("kris@plot.day", "Kris Braun")).toBe(
      '"Kris Braun" <kris@plot.day>'
    );
  });

  it("falls back to a bare email when no name is available", () => {
    expect(formatFromHeader("kris@plot.day")).toBe("kris@plot.day");
    expect(formatFromHeader("kris@plot.day", null)).toBe("kris@plot.day");
    expect(formatFromHeader("kris@plot.day", "")).toBe("kris@plot.day");
  });

  it("escapes quotes and backslashes in the name", () => {
    expect(formatFromHeader("kris@plot.day", 'Kris "K" Braun')).toBe(
      '"Kris \\"K\\" Braun" <kris@plot.day>'
    );
    expect(formatFromHeader("kris@plot.day", "Kris\\Braun")).toBe(
      '"Kris\\\\Braun" <kris@plot.day>'
    );
  });

  it("strips CRLF injection attempts from both name and email", () => {
    expect(
      formatFromHeader("kris@plot.day", "Kris\r\nBcc: evil@example.com")
    ).toBe('"Kris Bcc: evil@example.com" <kris@plot.day>');
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

  it("strips plain-text quoted replies whose 'On ... wrote:' attribution is itself quote-prefixed", () => {
    // Some clients (observed from a real reply) emit the attribution line
    // WITH a leading "> " rather than leaving it unquoted, e.g.:
    //   Reply text.
    //   > On Jun 1, 2026, at 9:00 AM, Bob <bob@example.com> wrote:
    //   > old message text
    const reply = stripQuotedReply(
      "My answer is yes.\r\n> On Mon, Jun 1, 2026, at 9:00 AM, Bob <bob@example.com> wrote:\r\n> old message text",
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

  it("strips Outlook-for-Mac quoted replies whose header labels the date line 'Date:' (not 'Sent:') and carries a Cc:", () => {
    // Outlook for Mac / "new Outlook" wraps a reply's quoted history in a
    // bold "From: / Date: / To: / Cc: / Subject:" header block — labelling
    // the date line "Date:" rather than the desktop-Outlook "Sent:", and
    // adding a Cc: line. The header detector only recognized "Sent:", so the
    // whole quoted chain (which itself embeds an "On ... wrote:" line) leaked
    // into the note body.
    const cc =
      "Carol Example &lt;carol@example.com&gt;; " +
      "Dan Example &lt;dan@example.com&gt;; " +
      "Erin Example &lt;erin@example.com&gt;; " +
      "Frank Example &lt;frank@example.com&gt;";
    const html =
      '<div dir="ltr">Great to have you onboard! Looking forward to meeting you soon.</div>' +
      "<div>Alice</div>" +
      "<div>" +
      "<b>From:</b> Bob Example &lt;bob@example.com&gt;<br>" +
      "<b>Date:</b> Wednesday, July 22, 2026 at 10:24 PM<br>" +
      "<b>To:</b> Wael Example &lt;wael@example.com&gt;<br>" +
      "<b>Cc:</b> " +
      cc +
      "<br>" +
      "<b>Subject:</b> Re: Welcome to the board!<br>" +
      "</div>" +
      "<div>Welcome! SECRETOUTLOOKMAC must be stripped." +
      "<br>On Wed, Jul 22, 2026, 20:56 Someone &lt;someone@example.com&gt; wrote:" +
      "<br>older quoted history</div>";
    const reply = stripQuotedReply(html, "html");
    expect(reply).toContain("Great to have you onboard");
    expect(reply).toContain("Alice");
    expect(reply).not.toContain("SECRETOUTLOOKMAC");
    expect(reply).not.toContain("Bob Example");
    expect(reply).not.toContain("older quoted history");
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

  it("buildNewEmailMessage emits extraHeaders (Message-ID + X-Plot-Event-UID)", () => {
    const raw = decodeRawMessage(
      buildNewEmailMessage({
        to: ["a@example.com"],
        from: "me@plot.day",
        subject: "Standup",
        body: "hi",
        extraHeaders: [
          "Message-ID: <plot-evt-1@plot.day>",
          "X-Plot-Event-UID: uid-123",
        ],
      })
    );
    expect(raw).toContain("Message-ID: <plot-evt-1@plot.day>");
    expect(raw).toContain("X-Plot-Event-UID: uid-123");
  });

  it("buildReplyMessage emits extraHeaders and strips CRLF injection", () => {
    const raw = decodeRawMessage(
      buildReplyMessage({
        to: ["a@example.com"],
        cc: [],
        from: "me@plot.day",
        subject: "Standup",
        body: "hi",
        messageId: "<orig@x>",
        references: "",
        extraHeaders: ["X-Plot-Event-UID: uid-123\r\nBcc: evil@x"],
      })
    );
    expect(raw).toContain("X-Plot-Event-UID: uid-123 Bcc: evil@x");
    // the injected CRLF was collapsed to a space (single header line)
    expect(raw).not.toMatch(/X-Plot-Event-UID:.*\r\nBcc: evil@x/);
  });

  it("buildReplyMessage renders named recipients in the To header", () => {
    const raw = decodeRawMessage(
      buildReplyMessage({
        to: [formatFromHeader("dana@x.com", "Robin Fielder")],
        cc: [],
        from: "me@x.com",
        subject: "Re: x",
        body: "hi",
        messageId: "<m@x>",
        references: "",
      })
    );
    expect(raw).toContain('To: "Robin Fielder" <dana@x.com>');
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

describe("transformGmailThread sender classification", () => {
  it("marks a no-reply From sender contact as automated", () => {
    const t = thread({
      from: "Susan Braun <notify@payments.interac.ca>",
      to: "me@x.com",
      subject: "INTERAC e-Transfer",
      payload: part("text/plain", { data: "hi" }),
    });
    const link = transformGmailThread(t);
    const sender = (
      link.accessContacts as Array<{ email: string; automated?: boolean }>
    ).find((c) => c.email === "notify@payments.interac.ca");
    expect(sender?.automated).toBe(true);
    const author = link.notes![0].author as {
      email?: string;
      automated?: boolean;
    };
    expect(author.automated).toBe(true);
  });

  it("does not mark an ordinary From sender as automated", () => {
    const t = thread({
      from: "Bob Smith <bob@company.com>",
      to: "me@x.com",
      subject: "hi",
      payload: part("text/plain", { data: "hi" }),
    });
    const link = transformGmailThread(t);
    const sender = (
      link.accessContacts as Array<{ email: string; automated?: boolean }>
    ).find((c) => c.email === "bob@company.com");
    expect(sender?.automated).toBeFalsy();
  });
});

describe("classifyCalendarThread", () => {
  const icsUpdate =
    "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:uid-1\r\nSEQUENCE:2\r\nEND:VEVENT\r\nEND:VCALENDAR";
  const icsInvite =
    "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:uid-1\r\nSEQUENCE:0\r\nEND:VEVENT\r\nEND:VCALENDAR";
  const icsCancel =
    "BEGIN:VCALENDAR\r\nMETHOD:CANCEL\r\nBEGIN:VEVENT\r\nUID:uid-1\r\nEND:VEVENT\r\nEND:VCALENDAR";
  const icsReply =
    "BEGIN:VCALENDAR\r\nMETHOD:REPLY\r\nBEGIN:VEVENT\r\nUID:uid-1\r\nEND:VEVENT\r\nEND:VCALENDAR";

  /** Minimal well-typed GmailMessage wrapping the given top-level payload. */
  function baseMessage(payload: GmailMessagePart): GmailMessage {
    return {
      id: "m1",
      threadId: "t1",
      labelIds: ["INBOX"],
      snippet: "snippet",
      historyId: "1",
      internalDate: "1700000000000",
      sizeEstimate: 500,
      payload,
    };
  }

  const msgWithIcs = (ics: string): GmailMessage =>
    baseMessage(
      part("multipart/mixed", {
        parts: [part("text/calendar", { data: ics })],
      })
    );

  const msgWithHeader = (uid: string): GmailMessage =>
    baseMessage(
      part("text/plain", {
        data: "reply body",
        headers: [["X-Plot-Event-UID", uid]],
      })
    );

  it("bundles an update (METHOD:REQUEST SEQUENCE>0)", () => {
    expect(classifyCalendarThread([msgWithIcs(icsUpdate)])).toEqual({
      uid: "uid-1",
      kind: "update",
    });
  });

  it("bundles a cancellation (METHOD:CANCEL)", () => {
    expect(classifyCalendarThread([msgWithIcs(icsCancel)])).toEqual({
      uid: "uid-1",
      kind: "cancel",
    });
  });

  it("bundles a reply chain (X-Plot-Event-UID header)", () => {
    expect(classifyCalendarThread([msgWithHeader("uid-9")])).toEqual({
      uid: "uid-9",
      kind: "reply",
    });
  });

  it("skips a bare invite (SEQUENCE 0)", () => {
    expect(classifyCalendarThread([msgWithIcs(icsInvite)])).toBeNull();
  });

  it("skips an RSVP (METHOD:REPLY)", () => {
    expect(classifyCalendarThread([msgWithIcs(icsReply)])).toBeNull();
  });
});

describe("canonicalizeGmailAddress", () => {
  it("strips dots from the local part of a gmail.com address", () => {
    expect(canonicalizeGmailAddress("kris.braun@gmail.com")).toBe(
      "krisbraun@gmail.com"
    );
    expect(canonicalizeGmailAddress("krisbraun@gmail.com")).toBe(
      "krisbraun@gmail.com"
    );
  });

  it("strips a +tag suffix from the local part", () => {
    expect(canonicalizeGmailAddress("kris.braun+updates@gmail.com")).toBe(
      "krisbraun@gmail.com"
    );
  });

  it("normalizes googlemail.com to the same canonical form as gmail.com", () => {
    expect(canonicalizeGmailAddress("kris.braun@googlemail.com")).toBe(
      "krisbraun@gmail.com"
    );
  });

  it("lowercases but otherwise leaves non-Gmail domains untouched", () => {
    expect(canonicalizeGmailAddress("Kris.Braun@Example.com")).toBe(
      "kris.braun@example.com"
    );
  });

  it("returns the lowercased input unchanged when there's no @", () => {
    expect(canonicalizeGmailAddress("not-an-email")).toBe("not-an-email");
  });
});
