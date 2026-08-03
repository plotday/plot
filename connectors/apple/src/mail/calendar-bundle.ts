/**
 * Mail-side classification of a calendar MIME part, and the bundling half of
 * how an email meets its event (see `apple.ts`'s `buildEventSources()` for the
 * calendar side, which already emits
 * `["apple-calendar:<uid>", "icaluid:<uid>"]`). When an inbound email carries
 * a `text/calendar`/`application/ics` MIME part, this classifies its
 * relationship to the referenced event so `sync.ts` can decide whether to
 * bundle the mail thread onto the same Plot thread as the calendar event via
 * the shared `icaluid:<uid>` alias.
 *
 * Bundling is not the only way a calendar part reaches the event's thread.
 * `sync.ts` routes an attendee response (`METHOD:REPLY`) to a separate FOLD:
 * the response is attached to the event's thread as a note of its own — or, if
 * it is a bare acceptance saying nothing the guest list does not already show,
 * dropped entirely — and its message is kept out of the mail thread either
 * way. A response never reaches `classifyICS` in a sync pass, so the
 * non-bundling verdict this file gives one says nothing about what becomes of
 * the message.
 *
 * Ports the Google connector's `classifyCalendarThread` decision
 * (`google/src/mail/gmail-api.ts`) — the product-approved rule for which ICS
 * methods bundle vs. skip — adapted to a single already-fetched ICS blob
 * rather than a Gmail message tree (IMAP has no equivalent of Gmail's
 * pre-fetched `payload` structure, so `sync.ts` fetches the ICS bytes itself
 * and hands the decoded text to `classifyICS`).
 */

import { icsProp } from "@plotday/rsvp-fold";

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
 * Classify one ICS (VCALENDAR) text's relationship to its event, per the
 * product-approved rule (see module doc):
 *
 * | ICS content                          | Action                                     |
 * |--------------------------------------|--------------------------------------------|
 * | `METHOD:CANCEL`                      | bundle                                     |
 * | `METHOD:REQUEST` with `SEQUENCE > 0` | bundle                                     |
 * | `METHOD:REQUEST` with `SEQUENCE == 0`| skip                                       |
 * | `METHOD:REPLY` (an RSVP)             | folded onto the event thread (see sync.ts) |
 *
 * Returns `null` for everything that does not bundle (including no parseable
 * UID at all) so callers can uniformly treat every non-bundling case — RSVP,
 * bare invite, or unparseable text — the same way. A `METHOD:REPLY` still
 * returns `null` here, but in a sync pass it is folded before this function is
 * ever offered the part, so that `null` is only reachable from another caller.
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
