/**
 * Presentation for attendee responses folded onto a calendar event's thread.
 *
 * Google's own notification email states the response in one sentence and then
 * repeats the entire event — Meet dial-in, When, Location, Guests — all of
 * which the event thread already shows. Only the response itself and the
 * responder's personal note are new, so that is all these notes carry.
 */
import type { CalendarReply } from "./gmail-api";

const VERBS: Record<CalendarReply["partstat"], string> = {
  DECLINED: "declined",
  ACCEPTED: "accepted",
  TENTATIVE: "tentatively accepted",
};

/**
 * Format an occurrence date the same way the cancellation note does
 * (`calendar/sync.ts`), so the two annotations on a recurring series read
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
export function composeRsvpNote(reply: CalendarReply): string {
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
 * Whether this response should surface the event thread as unread.
 *
 * A decline or a tentative response changes whether the meeting works and
 * deserves attention. An acceptance tells the organizer nothing the event's
 * guest list does not already show, so it must neither raise unread nor clear
 * it — returning false here omits the flag entirely, which the runtime treats
 * as "leave read state alone" (NOT as "mark read").
 *
 * The initial backfill never marks unread: folding a year of historical
 * responses must not resurface old events.
 */
export function shouldMarkUnread(
  reply: CalendarReply,
  initialSync: boolean
): boolean {
  if (initialSync) return false;
  return reply.partstat === "DECLINED" || reply.partstat === "TENTATIVE";
}
