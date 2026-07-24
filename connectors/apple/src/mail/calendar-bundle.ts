/**
 * Mail-side half of mail↔calendar thread bundling (see `apple.ts`'s
 * `buildEventSources()` for the calendar side, which already emits
 * `["apple-calendar:<uid>", "icaluid:<uid>"]`). When an inbound email
 * carries a `text/calendar`/`application/ics` MIME part, this classifies its
 * relationship to the referenced event so `sync.ts` can decide whether to
 * bundle the mail thread onto the same Plot thread as the calendar event via
 * the shared `icaluid:<uid>` alias.
 *
 * Ports the Google connector's `classifyCalendarThread` decision
 * (`google/src/mail/gmail-api.ts`) — the product-approved rule for which ICS
 * methods bundle vs. skip — adapted to a single already-fetched ICS blob
 * rather than a Gmail message tree (IMAP has no equivalent of Gmail's
 * pre-fetched `payload` structure, so `sync.ts` fetches the ICS bytes itself
 * and hands the decoded text to `classifyICS`).
 */

/** Raw classification of one ICS blob, before the mail sync pass resolves
 *  whether the calendar product has already synced an event for that UID. */
export type ClassifiedICS = { uid: string; kind: "cancel" | "update" };

/**
 * A classified ICS bundle plus `eventKnown`: whether the calendar product
 * has already synced an event for this UID (via `MailHost.knownEventUids`,
 * resolved once per `detectCalendarBundles` pass — see `sync.ts`). Drives
 * `transform.ts`'s title-omission decision: omit `title` (let the synced
 * calendar event own it) only when `eventKnown` is true; otherwise set
 * `title` from the email subject so the thread never falls back to the
 * runtime's "Untitled" placeholder while waiting for the calendar side to
 * sync (or when it never will — mail-only setups, a cancelled-before-sync
 * event, an out-of-window/disabled calendar).
 */
export type CalendarBundle = ClassifiedICS & { eventKnown: boolean };

const CALENDAR_MIME_TYPES = new Set(["text/calendar", "application/ics"]);

/** Whether an attachment's MIME type is a calendar invite/update/reply part. */
export function isCalendarAttachment(mimeType: string): boolean {
  return CALENDAR_MIME_TYPES.has(mimeType.toLowerCase());
}

/**
 * Unfold RFC 5545 continuation lines (CRLF/LF + leading space/tab is a
 * continuation of the previous line's value) and read a property's value.
 * Unscoped — matches the property anywhere in the ICS text, which is
 * correct for `METHOD` (a VCALENDAR-level property that sits outside
 * `BEGIN:VEVENT`/`END:VEVENT`; the existing `parseICSEvents`/`parseVEvent`
 * in `../calendar/ics-parser` parses only VEVENT-scoped properties and has
 * no `method` field at all) as well as for `UID`/`SEQUENCE` (VEVENT-scoped,
 * but a calendar invite email carries exactly one VEVENT).
 */
function icsProp(ics: string, name: string): string | null {
  const unfolded = ics.replace(/\r?\n[ \t]/g, "");
  const re = new RegExp(`^${name}(?:;[^:\\r\\n]*)?:(.*)$`, "im");
  const m = unfolded.match(re);
  return m ? m[1].trim() : null;
}

/**
 * Classify one ICS (VCALENDAR) text's relationship to its event, per the
 * product-approved rule (see module doc):
 *
 * | ICS content                              | Action  |
 * |-------------------------------------------|---------|
 * | `METHOD:CANCEL`                            | bundle  |
 * | `METHOD:REQUEST` with `SEQUENCE > 0`       | bundle  |
 * | `METHOD:REQUEST` with `SEQUENCE == 0`      | skip    |
 * | `METHOD:REPLY` (an RSVP)                   | skip    |
 *
 * Returns `null` for "skip" (including no parseable UID at all) so callers
 * can uniformly treat every non-bundling case — RSVP, bare invite, or
 * unparseable text — the same way.
 */
export function classifyICS(ics: string): ClassifiedICS | null {
  const uid = icsProp(ics, "UID");
  if (!uid) return null;

  const method = (icsProp(ics, "METHOD") ?? "").toUpperCase();
  if (method === "CANCEL") return { uid, kind: "cancel" };
  if (method === "REQUEST") {
    const seq = parseInt(icsProp(ics, "SEQUENCE") ?? "0", 10);
    if (seq > 0) return { uid, kind: "update" };
  }
  // METHOD:REPLY, or REQUEST/SEQUENCE 0 → skip.
  return null;
}
