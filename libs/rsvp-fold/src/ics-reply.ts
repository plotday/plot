/**
 * Parses the `METHOD:REPLY` iCalendar body a calendar system sends when an
 * attendee accepts, declines, or tentatively accepts an invitation.
 *
 * Both Google Calendar and Microsoft Exchange emit this shape — they differ
 * only in where the responder's personal note lives (a `COMMENT` property vs.
 * an `X-RESPONSE-COMMENT` parameter on the `ATTENDEE` line) and this parser
 * reads both. A connector resolves the raw ICS text itself (it may arrive
 * inline or as an attachment) and supplies a fallback display name for when
 * the `ATTENDEE` line omits a `CN` of its own.
 */

import type { RsvpReply } from "./rsvp-note";

/**
 * Unfold RFC 5545 lines (CRLF + leading space/tab is a continuation) and
 * match one property line: group 1 is its parameter section (leading `;`
 * included, or `""` when there are none), group 2 is its value. Shared by
 * `icsProp` (value only) and `icsPropLine` (params + value), so the
 * unfolding rule and line regex exist exactly once.
 */
function matchIcsLine(ics: string, name: string): RegExpMatchArray | null {
  const unfolded = ics.replace(/\r?\n[ \t]/g, "");
  const re = new RegExp(`^${name}((?:;[^:\\r\\n]*)?):(.*)$`, "im");
  return unfolded.match(re);
}

/**
 * Unfold RFC 5545 lines (CRLF + leading space/tab is a continuation) and read
 * a property's value. General-purpose enough that connectors also use it
 * directly for lookups that have nothing to do with a reply (e.g. reading
 * `METHOD`/`UID`/`SEQUENCE` to classify a calendar message), so it's exported
 * alongside `parseIcsReply` rather than kept private.
 */
export function icsProp(ics: string, name: string): string | null {
  const m = matchIcsLine(ics, name);
  return m ? m[2].trim() : null;
}

/**
 * Read a property's raw line (parameters included) from an ICS body. Shares
 * `icsProp`'s unfolding and line regex via `matchIcsLine`, but returns
 * everything after the property name so parameters can be parsed.
 */
function icsPropLine(ics: string, name: string): string | null {
  const m = matchIcsLine(ics, name);
  return m ? `${m[1]}:${m[2]}` : null;
}

/**
 * Split an ICS property's parameter section into a map. Values may be quoted
 * (`X-RESPONSE-COMMENT="a, b"`), and a quoted value may contain the `;` and
 * `:` that otherwise delimit parameters — so scan rather than split.
 */
function parseIcsParams(paramSection: string): Record<string, string> {
  const params: Record<string, string> = {};
  const re = /;([A-Za-z0-9-]+)=("([^"]*)"|[^;:]*)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(paramSection)) !== null) {
    params[m[1].toUpperCase()] = m[3] !== undefined ? m[3] : m[2];
  }
  return params;
}

/**
 * Parse an ICS date-time into a UTC instant. Handles `20260804T140000Z`
 * (UTC), `20260804T100000` (floating or TZID-qualified — read as UTC, since
 * resolving a TZID needs a tz database the caller doesn't carry), and
 * `20260804` (VALUE=DATE).
 */
function parseIcsDate(value: string): Date | null {
  const m = value
    .trim()
    .match(/^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$/);
  if (!m) return null;
  const [, y, mo, d, h = "00", mi = "00", s = "00"] = m;
  const ms = Date.UTC(+y, +mo - 1, +d, +h, +mi, +s);
  return Number.isNaN(ms) ? null : new Date(ms);
}

/**
 * RFC 5545 text un-escaping: `\n`/`\N` → newline, `\,` `\;` `\\` → the
 * literal character. Single-pass so an escaped backslash immediately
 * followed by a literal `n` (`\\n`) isn't misread as a newline escape — a
 * two-pass `\n`-then-`\\` replacement would consume the second backslash of
 * `\\` as if it started its own `\n` escape.
 *
 * Exported because connectors read escaped text out of properties this module
 * does not parse for them (e.g. an invitation's `COMMENT`), and a second copy
 * of this rule would undo the deduplication `matchIcsLine` established.
 */
export function unescapeIcsText(value: string): string {
  return value.replace(/\\([nN,;\\])/g, (_, ch: string) =>
    ch === "n" || ch === "N" ? "\n" : ch
  );
}

/**
 * The display name to fall back on when the `ATTENDEE` line itself omits a
 * `CN`. Connectors typically parse this from the message's own From header.
 * There is deliberately no email fallback: an `ATTENDEE` line with no
 * resolvable address is not a response from anyone in particular, so it is
 * dropped rather than attributed to whoever merely delivered the
 * notification (e.g. a calendar system's own notification address).
 */
export type IcsReplyFallback = {
  name: string | null;
};

/**
 * Parse one attendee response from a `METHOD:REPLY` iCalendar body.
 *
 * Returns `null` when the body isn't a reply, carries no usable `ATTENDEE`
 * (no resolvable address on the line itself), or carries a `PARTSTAT` other
 * than `ACCEPTED`/`DECLINED`/`TENTATIVE` (`NEEDS-ACTION` means there is no
 * response yet, so it yields nothing).
 */
export function parseIcsReply(
  ics: string,
  fallback: IcsReplyFallback
): RsvpReply | null {
  if ((icsProp(ics, "METHOD") ?? "").toUpperCase() !== "REPLY") return null;

  const attendeeLine = icsPropLine(ics, "ATTENDEE");
  if (!attendeeLine) return null;
  const sep = attendeeLine.lastIndexOf(":");
  const params = parseIcsParams(attendeeLine.slice(0, sep));
  const attendeeEmail = attendeeLine
    .slice(sep + 1)
    .trim()
    .replace(/^mailto:/i, "");
  if (!attendeeEmail) return null;

  const partstat = (params.PARTSTAT ?? "").toUpperCase();
  if (
    partstat !== "DECLINED" &&
    partstat !== "ACCEPTED" &&
    partstat !== "TENTATIVE"
  ) {
    return null;
  }

  const recurrenceLine = icsPropLine(ics, "RECURRENCE-ID");
  let occurrence: Date | null = null;
  let allDay = false;
  if (recurrenceLine) {
    const rSep = recurrenceLine.lastIndexOf(":");
    const rParams = parseIcsParams(recurrenceLine.slice(0, rSep));
    allDay = (rParams.VALUE ?? "").toUpperCase() === "DATE";
    occurrence = parseIcsDate(recurrenceLine.slice(rSep + 1));
  }

  const icsComment = icsProp(ics, "COMMENT");
  const comment =
    (icsComment ? unescapeIcsText(icsComment).trim() : "") ||
    (params["X-RESPONSE-COMMENT"]
      ? unescapeIcsText(params["X-RESPONSE-COMMENT"]).trim()
      : "") ||
    null;

  return {
    partstat: partstat as RsvpReply["partstat"],
    attendeeName: params.CN?.trim() || fallback.name || null,
    attendeeEmail,
    occurrence,
    allDay,
    comment,
  };
}
