/**
 * Presentation for attendee responses folded onto a calendar event's thread.
 *
 * A calendar system's own notification email states the response in one
 * sentence and then repeats the entire event — dial-in, When, Location,
 * Guests — all of which the event thread already shows. Only the response
 * itself and the responder's personal note are new, so that is all these
 * notes carry.
 */

/**
 * One attendee's response to a calendar invitation, in the shape the fold rule
 * needs. Providers supply this from whatever they have — an iCalendar part, a
 * provider-specific message type — so this library stays independent of any
 * one of them.
 */
export type RsvpReply = {
  partstat: "ACCEPTED" | "DECLINED" | "TENTATIVE";
  /** Display name, when the provider gives one. */
  attendeeName: string | null;
  attendeeEmail: string;
  /** The instance responded to; null when the response covers the whole series. */
  occurrence: Date | null;
  /** The occurrence was all-day — affects date formatting only. */
  allDay: boolean;
  /** The responder's personal note, when they wrote one. */
  comment: string | null;
};

const VERBS: Record<RsvpReply["partstat"], string> = {
  DECLINED: "declined",
  ACCEPTED: "accepted",
  TENTATIVE: "tentatively accepted",
};

/**
 * Format an occurrence date the same way a cancellation note on the same
 * event thread does, so the two annotations on a recurring series read
 * alike. All-day occurrences are pinned to UTC because their instant is a
 * bare date; timed ones use the worker's zone, which is UTC — a late-evening
 * local occurrence can therefore format as the following day, exactly as the
 * cancellation note already does.
 */
function formatOccurrence(occurrence: Date, allDay: boolean): string {
  return occurrence.toLocaleDateString("en-US", {
    dateStyle: "long",
    ...(allDay ? { timeZone: "UTC" } : {}),
  });
}

/** Markdown blockquote, one `>` per line, so multi-line notes stay quoted. */
function blockquote(text: string): string {
  return text
    .split("\n")
    .map((line) => `> ${line}`.trimEnd())
    .join("\n");
}

/**
 * The note body for one attendee response. Names the occurrence only when the
 * response was to a single instance of a series, and appends the responder's
 * personal note as a blockquote when they wrote one.
 */
export function composeRsvpNote(reply: RsvpReply): string {
  const who = reply.attendeeName ?? reply.attendeeEmail;
  const verb = VERBS[reply.partstat];
  const where = reply.occurrence
    ? ` the ${formatOccurrence(reply.occurrence, reply.allDay)} occurrence`
    : "";
  const sentence = `${who} ${verb}${where}.`;
  return reply.comment
    ? `${sentence}\n\n${blockquote(reply.comment)}`
    : sentence;
}

/**
 * Whether an attendee response warrants a note on the event thread.
 *
 * A bare acceptance repeats what the event's guest list already shows, so it
 * earns no note. That is also the only way to keep it from raising unread:
 * attaching a note surfaces the thread as unread for every recipient except
 * the note's author, and no field a connector passes to `saveNote` can
 * suppress that. Writing nothing is the guarantee.
 *
 * Everything else is genuinely new information and gets a note:
 * a decline or a tentative changes whether the meeting works; an acceptance
 * carrying a personal comment is a message from a person; and an acceptance
 * that reverses an earlier decline or tentative is a real change of state,
 * which `hadPriorNonAccept` reports from connector-local storage.
 */
export function shouldEmitRsvpNote(
  reply: RsvpReply,
  hadPriorNonAccept: boolean
): boolean {
  if (reply.partstat !== "ACCEPTED") return true;
  if (reply.comment) return true;
  return hadPriorNonAccept;
}

/**
 * Whether a stored fold marker represents an outstanding non-acceptance — a
 * decline or a tentative the attendee has not since reversed.
 *
 * Pass the result as `shouldEmitRsvpNote`'s `hadPriorNonAccept`. Reading the
 * VALUE rather than testing for presence is what lets one marker serve both
 * this question and {@link alreadyFolded}.
 */
export function isNonAcceptance(stored: string | null | undefined): boolean {
  return stored === "DECLINED" || stored === "TENTATIVE";
}

/**
 * Whether this exact response has already been folded onto the event thread.
 *
 * Re-emitting a note the thread already carries is not harmless: the note
 * upserts by key, but its unread intent is applied again and marks the thread
 * unread for every recipient but the author — so a recipient who has since read
 * the thread sees it go unread again for no new information. Providers re-deliver
 * the same response routinely (a mail subscription that fires on `updated`, a
 * re-sync, a webhook replay), so this must be checked before emitting.
 *
 * Compares the stored marker against the incoming `partstat`, so a genuine
 * CHANGE of response (decline then accept) is not suppressed.
 */
export function alreadyFolded(
  stored: string | null | undefined,
  reply: RsvpReply
): boolean {
  return stored === reply.partstat;
}

/**
 * Storage key holding the last response actually folded onto the event thread
 * for one attendee on one event. Set on every response a connector emits a
 * note for — never on one it suppresses. A bare acceptance leaves it unset
 * ONLY when there was no prior non-acceptance, because that's the one case
 * where no note is emitted (see {@link shouldEmitRsvpNote}); a bare
 * acceptance that reverses a prior decline or tentative DOES get a note, and
 * DOES set this key to `"ACCEPTED"` — that stored `"ACCEPTED"` is exactly
 * what lets a later repeat of that same acceptance be recognised by
 * {@link alreadyFolded} instead of re-emitted.
 *
 * The value serves two questions from the same marker: {@link isNonAcceptance}
 * reads it to tell whether an incoming acceptance is a genuine reversal, and
 * {@link alreadyFolded} reads it to tell whether an incoming response merely
 * repeats what this key already recorded.
 *
 * Call order matters and this library does not enforce it: read the stored
 * marker, check {@link alreadyFolded} first, and only when that's false
 * decide whether to emit via `shouldEmitRsvpNote(reply,
 * isNonAcceptance(stored))`. Write the new partstat back with this key ONLY
 * on the path that actually emits a note — never on the suppressed path,
 * and never before deciding whether to emit, or the marker no longer
 * reflects what the event thread carries.
 *
 * Not read from `schedule_contact`: the calendar product's own attendee sync
 * writes that same field from the event roster, so by the time an RSVP email is
 * processed it may already read as accepted and the prior decline is gone. This
 * key records what this connector last folded, which is the actual question.
 *
 * Scoped by `occurrence` as well as `uid`: a reply to one occurrence of a
 * recurring event carries the same series `uid` as every other occurrence,
 * distinguished only by `RECURRENCE-ID`. Without the occurrence in the key, a
 * decline on one occurrence would be read as an outstanding non-acceptance for
 * an unrelated occurrence's later reply. `null` (a series-wide response) maps
 * to the literal `"series"` segment.
 */
export function priorRsvpKey(
  uid: string,
  attendeeEmail: string,
  occurrence: Date | null
): string {
  return `rsvp:${uid}:${occurrence ? occurrence.toISOString() : "series"}:${attendeeEmail.toLowerCase()}`;
}
