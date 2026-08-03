import { describe, expect, it } from "vitest";

import { extractOutlookReply } from "./outlook-ics-reply";

const CRLF = "\r\n";

/**
 * Real capture from a Google Calendar-generated reply (bare acceptance, no
 * comment) — same anonymised content as `@plotday/rsvp-fold`'s
 * `ics-reply.test.ts` GOOGLE_ACCEPTED. Structure — property spellings,
 * escaping, line folding — is preserved verbatim; only identities are
 * anonymised.
 */
const GOOGLE_ICS_ACCEPTED = [
  "BEGIN:VCALENDAR",
  "PRODID:-//Google Inc//Google Calendar 70.9054//EN",
  "VERSION:2.0",
  "CALSCALE:GREGORIAN",
  "METHOD:REPLY",
  "BEGIN:VEVENT",
  "DTSTART:20260803T150000Z",
  "DTEND:20260803T153000Z",
  "DTSTAMP:20260803T145144Z",
  "ORGANIZER;CN=Event Organizer:mailto:organizer@example.test",
  "UID:040000008200E00074C5B7101A82E0080000000057E690055723DD01000000000000000",
  " 010000000AA3D563406A91946998F2774AAD4D280",
  "ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;CN=Beth Ro",
  " und;X-NUM-GUESTS=0:mailto:beth@example.test",
  "CREATED:20260803T145127Z",
  "LAST-MODIFIED:20260803T145140Z",
  "LOCATION:Microsoft Teams Meeting",
  "SEQUENCE:1",
  "STATUS:CONFIRMED",
  "SUMMARY:Test replies",
  "END:VEVENT",
  "END:VCALENDAR",
].join(CRLF);

/**
 * Real capture from a Google Calendar-generated reply carrying a note — the
 * note lives in Google's `X-RESPONSE-COMMENT` parameter, not the standard
 * `COMMENT` property. Same anonymised content as the library's
 * GOOGLE_TENTATIVE.
 */
const GOOGLE_ICS_TENTATIVE = [
  "BEGIN:VCALENDAR",
  "PRODID:-//Google Inc//Google Calendar 70.9054//EN",
  "VERSION:2.0",
  "CALSCALE:GREGORIAN",
  "METHOD:REPLY",
  "BEGIN:VEVENT",
  "DTSTART:20260803T150000Z",
  "DTEND:20260803T153000Z",
  "DTSTAMP:20260803T145203Z",
  "ORGANIZER;CN=Event Organizer:mailto:organizer@example.test",
  "UID:040000008200E00074C5B7101A82E0080000000057E690055723DD01000000000000000",
  " 010000000AA3D563406A91946998F2774AAD4D280",
  "ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=TENTATIVE;CN=Beth ",
  ' Round;X-NUM-GUESTS=0;X-RESPONSE-COMMENT="This is my reply for maybe":mailto',
  " :beth@example.test",
  "CREATED:20260803T145127Z",
  "LAST-MODIFIED:20260803T145202Z",
  "LOCATION:Microsoft Teams Meeting",
  "SEQUENCE:1",
  "STATUS:CONFIRMED",
  "SUMMARY:Test replies",
  "END:VEVENT",
  "END:VCALENDAR",
].join(CRLF);

/**
 * Real capture from a Microsoft Exchange-generated reply — the note lives
 * in the standard COMMENT property. Same anonymised content as the
 * library's MS_ACCEPTED.
 */
const MS_ICS_ACCEPTED = [
  "BEGIN:VCALENDAR",
  "METHOD:REPLY",
  "PRODID:Microsoft Exchange Server 2010",
  "VERSION:2.0",
  "BEGIN:VEVENT",
  "ATTENDEE;PARTSTAT=ACCEPTED;CN=Ana Ruiz:mailto:ana@example.test",
  "COMMENT;LANGUAGE=en-US:Uh huh\\, here's my comment\\n",
  "UID:2sfjkg3asr2hofgcgfsi51ks84@google.com",
  "SUMMARY;LANGUAGE=en-US:Accepted: Hey outlook",
  "DTSTART;TZID=Eastern Standard Time:20260803T113000",
  "DTEND;TZID=Eastern Standard Time:20260803T120000",
  "SEQUENCE:0",
  "X-MICROSOFT-CDO-ALLDAYEVENT:FALSE",
  "END:VEVENT",
  "END:VCALENDAR",
].join(CRLF);

/**
 * A synthetic, differently-shaped reply — not a real capture — used only to
 * prove the duplicate-attachment precedence test actually exercises
 * precedence rather than two identical parts happening to agree.
 */
const OTHER_ICS_DECLINED = [
  "BEGIN:VCALENDAR",
  "METHOD:REPLY",
  "BEGIN:VEVENT",
  "UID:uid-other@example.test",
  "ATTENDEE;PARTSTAT=DECLINED;CN=Someone Else:mailto:someone-else@example.test",
  "END:VEVENT",
  "END:VCALENDAR",
].join(CRLF);

const FALLBACK = { name: null, email: "organizer@example.test" };

/** Base64-encode ASCII text the same way a mail client would for a `base64` part. */
function b64(text: string): string {
  return btoa(text);
}

/** One MIME part: headers + a blank line + body, CRLF throughout. */
function mimePart(headers: string[], body: string): string {
  return headers.join(CRLF) + CRLF + CRLF + body;
}

/**
 * A `multipart/mixed` Google-shaped message: a `multipart/alternative`
 * (text/plain, text/html, text/calendar) plus a sibling `application/ics`
 * attachment — the real captured shape (see fixtures README).
 */
function googleShapedMessage(opts: {
  calendarEncoding: "7bit" | "base64";
  calendarIcs: string;
  attachmentIcs?: string;
}): string {
  const innerBoundary = "inner_boundary_0001";
  const outerBoundary = "outer_boundary_0002";

  const plainPart = mimePart(
    [
      'Content-Type: text/plain; charset="UTF-8"',
      "Content-Transfer-Encoding: base64",
    ],
    b64("Beth Round has accepted this invitation.")
  );
  const htmlPart = mimePart(
    ['Content-Type: text/html; charset="UTF-8"', "Content-Transfer-Encoding: quoted-printable"],
    "<p>Beth Round has accepted this invitation.</p>"
  );
  const calendarBody =
    opts.calendarEncoding === "base64"
      ? b64(opts.calendarIcs)
      : opts.calendarIcs;
  const calendarPart = mimePart(
    [
      'Content-Type: text/calendar; method=REPLY; charset="UTF-8"',
      `Content-Transfer-Encoding: ${opts.calendarEncoding}`,
    ],
    calendarBody
  );

  const alternative =
    `Content-Type: multipart/alternative; boundary="${innerBoundary}"${CRLF}${CRLF}` +
    [plainPart, htmlPart, calendarPart]
      .map((p) => `--${innerBoundary}${CRLF}${p}`)
      .join(CRLF) +
    CRLF +
    `--${innerBoundary}--`;

  const attachmentPart = mimePart(
    [
      'Content-Type: application/ics; name="invite.ics"',
      'Content-Disposition: attachment; filename="invite.ics"',
      "Content-Transfer-Encoding: base64",
    ],
    b64(opts.attachmentIcs ?? opts.calendarIcs)
  );

  const mixedBody =
    `--${outerBoundary}${CRLF}${alternative}${CRLF}` +
    `--${outerBoundary}${CRLF}${attachmentPart}${CRLF}` +
    `--${outerBoundary}--`;

  return (
    [
      "MIME-Version: 1.0",
      "From: Beth Round <beth@example.test>",
      "To: Plot Test <plot.test.1@example.test>",
      "Subject: Accepted: Test replies @ Mon 2026-08-03 11am - 11:30am (EDT) (Plot Test)",
      "Date: Mon, 3 Aug 2026 14:51:44 +0000",
      "Message-ID: <google-reply-1@example.test>",
      `Content-Type: multipart/mixed; boundary="${outerBoundary}"`,
    ].join(CRLF) +
    CRLF +
    CRLF +
    mixedBody
  );
}

/**
 * A `multipart/alternative` Microsoft-shaped message — text/plain,
 * text/html, text/calendar (base64) — and critically NO attachment part at
 * all (per the fixtures README, `X-MS-Has-Attach` is empty for these).
 */
function microsoftShapedMessage(icsBody: string): string {
  const boundary = "ms_boundary_0003";
  const plainPart = mimePart(
    ['Content-Type: text/plain; charset="us-ascii"', "Content-Transfer-Encoding: base64"],
    b64('Ana Ruiz has accepted this invitation with a note: "Uh huh, here\'s my comment"')
  );
  const htmlPart = mimePart(
    ['Content-Type: text/html; charset="us-ascii"', "Content-Transfer-Encoding: quoted-printable"],
    "<p>Ana Ruiz has accepted this invitation.</p>"
  );
  const calendarPart = mimePart(
    ['Content-Type: text/calendar; method=REPLY; charset="us-ascii"', "Content-Transfer-Encoding: base64"],
    b64(icsBody)
  );

  const body =
    [plainPart, htmlPart, calendarPart]
      .map((p) => `--${boundary}${CRLF}${p}`)
      .join(CRLF) +
    CRLF +
    `--${boundary}--`;

  return (
    [
      "MIME-Version: 1.0",
      "From: Ana Ruiz <ana@example.test>",
      "To: Plot Test <plot.test.1@example.test>",
      "Subject: Accepted: Hey outlook",
      "Date: Mon, 3 Aug 2026 15:30:00 +0000",
      "Message-ID: <ms-reply-1@example.test>",
      `Content-Type: multipart/alternative; boundary="${boundary}"`,
    ].join(CRLF) +
    CRLF +
    CRLF +
    body
  );
}

/** A plain message with no calendar part at all (an ordinary reply). */
function plainMessage(): string {
  const boundary = "plain_boundary_0004";
  const plainPart = mimePart(
    ["Content-Type: text/plain; charset=\"UTF-8\"", "Content-Transfer-Encoding: 7bit"],
    "Sounds good, see you then!"
  );
  const htmlPart = mimePart(
    ["Content-Type: text/html; charset=\"UTF-8\"", "Content-Transfer-Encoding: 7bit"],
    "<p>Sounds good, see you then!</p>"
  );
  const body =
    [plainPart, htmlPart].map((p) => `--${boundary}${CRLF}${p}`).join(CRLF) +
    CRLF +
    `--${boundary}--`;

  return (
    [
      "MIME-Version: 1.0",
      "From: Beth Round <beth@example.test>",
      "To: Plot Test <plot.test.1@example.test>",
      "Subject: Re: Test replies",
      "Date: Mon, 3 Aug 2026 16:00:00 +0000",
      "Message-ID: <plain-1@example.test>",
      `Content-Type: multipart/alternative; boundary="${boundary}"`,
    ].join(CRLF) +
    CRLF +
    CRLF +
    body
  );
}

describe("extractOutlookReply", () => {
  it("extracts the reply from a Google-generated message's text/calendar part", () => {
    const mime = googleShapedMessage({
      calendarEncoding: "7bit",
      calendarIcs: GOOGLE_ICS_ACCEPTED,
    });
    const reply = extractOutlookReply(mime, FALLBACK);
    expect(reply).toMatchObject({
      partstat: "ACCEPTED",
      attendeeName: "Beth Round",
      attendeeEmail: "beth@example.test",
      comment: null,
    });
  });

  it("extracts the reply from a Microsoft-generated message with NO attachment", () => {
    const mime = microsoftShapedMessage(MS_ICS_ACCEPTED);
    const reply = extractOutlookReply(mime, FALLBACK);
    expect(reply).toMatchObject({
      partstat: "ACCEPTED",
      attendeeName: "Ana Ruiz",
      attendeeEmail: "ana@example.test",
      comment: "Uh huh, here's my comment",
    });
  });

  it("prefers the text/calendar part over a duplicate application/ics attachment", () => {
    const mime = googleShapedMessage({
      calendarEncoding: "7bit",
      calendarIcs: GOOGLE_ICS_ACCEPTED, // ACCEPTED / Beth Round
      attachmentIcs: OTHER_ICS_DECLINED, // DECLINED / Someone Else
    });
    const reply = extractOutlookReply(mime, FALLBACK);
    expect(reply).toMatchObject({
      partstat: "ACCEPTED",
      attendeeName: "Beth Round",
      attendeeEmail: "beth@example.test",
    });
  });

  it("decodes a base64 text/calendar part", () => {
    const mime = googleShapedMessage({
      calendarEncoding: "base64",
      calendarIcs: GOOGLE_ICS_TENTATIVE,
    });
    const reply = extractOutlookReply(mime, FALLBACK);
    expect(reply).toMatchObject({
      partstat: "TENTATIVE",
      comment: "This is my reply for maybe",
    });
  });

  it("returns null when the message carries no calendar part", () => {
    const mime = plainMessage();
    expect(extractOutlookReply(mime, FALLBACK)).toBeNull();
  });

  it("degrades safely (returns null, does not throw) on malformed MIME: a multipart Content-Type with no boundary= parameter", () => {
    const mime = [
      "MIME-Version: 1.0",
      "From: Beth Round <beth@example.test>",
      "Content-Type: multipart/mixed",
      "",
      "whatever body — there is no boundary to split on",
    ].join(CRLF);
    expect(() => extractOutlookReply(mime, FALLBACK)).not.toThrow();
    expect(extractOutlookReply(mime, FALLBACK)).toBeNull();
  });

  it("degrades safely (returns null, does not throw) on a truncated multipart body (no closing boundary, no parts at all)", () => {
    const mime = [
      "MIME-Version: 1.0",
      "From: Beth Round <beth@example.test>",
      'Content-Type: multipart/mixed; boundary="cut_off_boundary"',
      "",
      "the connection dropped mid-download and this body was never a real",
      "multipart payload — no --cut_off_boundary delimiter appears anywhere",
    ].join(CRLF);
    expect(() => extractOutlookReply(mime, FALLBACK)).not.toThrow();
    expect(extractOutlookReply(mime, FALLBACK)).toBeNull();
  });
});
