import { describe, expect, it } from "vitest";
import {
  stripQuotedReply,
  transformGmailThread,
  type GmailMessage,
  type GmailMessagePart,
  type GmailThread,
} from "./gmail-api";

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
