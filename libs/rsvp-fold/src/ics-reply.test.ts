import { describe, expect, it } from "vitest";

import { parseIcsReply } from "./ics-reply";

const FALLBACK = { name: null };

/**
 * Real capture from a Google Calendar-generated reply (bare acceptance, no
 * comment). Structure — property spellings, escaping, line folding — is
 * preserved verbatim; only the organizer/attendee identities are anonymised.
 */
const GOOGLE_ACCEPTED = [
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
].join("\r\n");

/**
 * Real capture from a Google Calendar-generated reply carrying a note — the
 * note lives in Google's `X-RESPONSE-COMMENT` parameter on the ATTENDEE line,
 * not the standard COMMENT property.
 */
const GOOGLE_TENTATIVE = [
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
].join("\r\n");

/**
 * Real capture from a Microsoft Exchange-generated reply — the note lives in
 * the standard COMMENT property, and the comment carries an RFC 5545 escaped
 * comma and a trailing escaped newline (`\,` and `\n`).
 */
const MS_ACCEPTED = [
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
].join("\r\n");

/** Minimal synthetic reply for edge cases the real captures don't exercise. */
const BASE = [
  "BEGIN:VCALENDAR",
  "METHOD:REPLY",
  "BEGIN:VEVENT",
  "UID:uid-1@example.test",
  "ATTENDEE;PARTSTAT=ACCEPTED:mailto:beth@example.test",
  "END:VEVENT",
  "END:VCALENDAR",
].join("\r\n");

describe("parseIcsReply", () => {
  it("reads PARTSTAT and attendee from a Google-generated reply", () => {
    const r = parseIcsReply(GOOGLE_ACCEPTED, { name: null });
    expect(r).toMatchObject({
      partstat: "ACCEPTED",
      attendeeName: "Beth Round",
      attendeeEmail: "beth@example.test",
      comment: null,
      occurrence: null,
    });
  });

  it("reads Google's X-RESPONSE-COMMENT parameter", () => {
    const r = parseIcsReply(GOOGLE_TENTATIVE, { name: null });
    expect(r).toMatchObject({
      partstat: "TENTATIVE",
      comment: "This is my reply for maybe",
    });
  });

  it("reads Microsoft's COMMENT property", () => {
    const r = parseIcsReply(MS_ACCEPTED, { name: null });
    expect(r).toMatchObject({
      partstat: "ACCEPTED",
      attendeeName: "Ana Ruiz",
      attendeeEmail: "ana@example.test",
      comment: "Uh huh, here's my comment",
    });
  });

  it("prefers the COMMENT property over X-RESPONSE-COMMENT when both are present", () => {
    // Not a real-world combination (each provider only ever emits one), but
    // pins the precedence so a future reordering of the `||` chain is caught.
    const both = MS_ACCEPTED.replace(
      "ATTENDEE;PARTSTAT=ACCEPTED;CN=Ana Ruiz:mailto:ana@example.test",
      'ATTENDEE;PARTSTAT=ACCEPTED;CN=Ana Ruiz;X-RESPONSE-COMMENT="from the parameter":mailto:ana@example.test'
    );
    const r = parseIcsReply(both, { name: null });
    expect(r?.comment).toBe("Uh huh, here's my comment");
  });

  it("falls back to the supplied sender name when the ATTENDEE has no CN", () => {
    const r = parseIcsReply(BASE, { name: "Fallback Name" });
    expect(r).toMatchObject({
      attendeeName: "Fallback Name",
      attendeeEmail: "beth@example.test",
    });
  });

  it("returns null when the ATTENDEE line has no resolvable address (no email fallback — a malformed address drops the reply rather than misattributing it to the notification's sender)", () => {
    // The property line still ends in a colon (an ATTENDEE line always has
    // one) — only the address after `mailto:` is missing.
    const noAddress = BASE.replace("mailto:beth@example.test", "mailto:");
    expect(parseIcsReply(noAddress, { name: "Notification Sender" })).toBeNull();
  });

  it("returns null for a non-REPLY method", () => {
    const request = BASE.replace("METHOD:REPLY", "METHOD:REQUEST");
    expect(parseIcsReply(request, FALLBACK)).toBeNull();
  });

  it("returns null when there is no ATTENDEE line", () => {
    const noAttendee = BASE.replace(/^ATTENDEE.*\r\n/m, "");
    expect(parseIcsReply(noAttendee, FALLBACK)).toBeNull();
  });

  it("returns null for an unrecognised PARTSTAT", () => {
    const pending = BASE.replace("PARTSTAT=ACCEPTED", "PARTSTAT=NEEDS-ACTION");
    expect(parseIcsReply(pending, FALLBACK)).toBeNull();
  });

  it("reads RECURRENCE-ID as the occurrence, and null when absent", () => {
    const withOccurrence = BASE.replace(
      "END:VEVENT",
      "RECURRENCE-ID:20260804T140000Z\r\nEND:VEVENT"
    );
    const withOccurrenceReply = parseIcsReply(withOccurrence, FALLBACK);
    expect(withOccurrenceReply?.occurrence?.toISOString()).toBe(
      "2026-08-04T14:00:00.000Z"
    );
    expect(withOccurrenceReply?.allDay).toBe(false);

    const bareReply = parseIcsReply(BASE, FALLBACK);
    expect(bareReply?.occurrence).toBeNull();
  });
});
