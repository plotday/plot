/**
 * Read an attendee's response to a meeting from an Outlook message's raw
 * MIME source.
 *
 * Both Google- and Microsoft-generated replies carry a
 * `text/calendar; method=REPLY` part with the structured PARTSTAT/COMMENT
 * fields `parseIcsReply` (from `@plotday/rsvp-fold`) needs. Only
 * Google-generated replies ALSO duplicate that part as an `application/ics`
 * attachment — a Microsoft-generated reply has no attachment at all
 * (`hasAttachments` / `X-MS-Has-Attach` is empty). So this reads the
 * message's raw MIME ($value) rather than going through
 * `listAttachments`/`getAttachment`, which would silently miss every
 * Microsoft-generated response.
 */

import { parseIcsReply, type RsvpReply } from "@plotday/rsvp-fold";

/** One leaf (non-multipart) MIME body part: its Content-Type, transfer encoding, and still-encoded text. */
type MimePart = {
  contentType: string;
  transferEncoding: string;
  body: string;
};

/** Split a MIME message (or one of its parts) into its header block and body at the first blank line. */
function splitHeadersAndBody(raw: string): { headers: string; body: string } {
  const m = raw.match(/\r?\n\r?\n/);
  if (!m || m.index === undefined) return { headers: raw, body: "" };
  return {
    headers: raw.slice(0, m.index),
    body: raw.slice(m.index + m[0].length),
  };
}

/** Read one header's value, unfolding continuation lines (CRLF + leading whitespace) first. */
function getHeader(headers: string, name: string): string | null {
  const unfolded = headers.replace(/\r?\n[ \t]+/g, " ");
  const m = unfolded.match(new RegExp(`^${name}:[ \t]*(.*)$`, "im"));
  return m ? m[1].trim() : null;
}

/** The `boundary` parameter off a `Content-Type: multipart/...` header value. */
function boundaryOf(contentType: string): string | null {
  const m = contentType.match(/boundary="?([^";]+)"?/i);
  return m ? m[1] : null;
}

/**
 * Recursively collect every leaf part of a MIME message. Outlook's own
 * replies nest at most one level deep (`multipart/mixed` wrapping
 * `multipart/alternative`), so this only needs to recurse into whatever
 * nesting is actually present — it is not a general-purpose MIME parser.
 */
function collectParts(raw: string): MimePart[] {
  const { headers, body } = splitHeadersAndBody(raw);
  const contentType = getHeader(headers, "Content-Type") ?? "text/plain";
  if (/^multipart\//i.test(contentType)) {
    const boundary = boundaryOf(contentType);
    if (!boundary) return [];
    // Drop the preamble (before the first delimiter) and the epilogue
    // (after the closing `--boundary--`).
    const segments = body.split(`--${boundary}`).slice(1, -1);
    return segments.flatMap((segment) =>
      collectParts(segment.replace(/^\r?\n/, ""))
    );
  }
  return [
    {
      contentType,
      transferEncoding:
        getHeader(headers, "Content-Transfer-Encoding") ?? "7bit",
      body,
    },
  ];
}

/** Decode a part's body per its Content-Transfer-Encoding — only the two encodings this reply shape uses. */
function decodeBody(part: MimePart): string {
  if (part.transferEncoding.toLowerCase() === "base64") {
    return atob(part.body.replace(/[\r\n]/g, ""));
  }
  return part.body;
}

/**
 * Extract an attendee's response from an Outlook message's raw MIME.
 * `text/calendar` is preferred over a duplicate `application/ics`
 * attachment when both are present. Returns `null` when the message carries
 * neither (not a meeting response at all) or when the calendar part itself
 * doesn't parse as a reply (see `parseIcsReply`).
 *
 * `fallback.email` is currently unused — only `.name` reaches
 * `parseIcsReply`, which deliberately has no email fallback (Task 3's
 * `IcsReplyFallback`): an `ATTENDEE` line with no resolvable address is
 * dropped rather than misattributed to whoever merely delivered the
 * notification. `.email` is accepted here anyway so a caller can pass the
 * message's `From` (name + address) straight through without destructuring.
 */
export function extractOutlookReply(
  mime: string,
  fallback: { name: string | null; email: string }
): RsvpReply | null {
  const parts = collectParts(mime);
  const calendarPart =
    parts.find((p) => /text\/calendar/i.test(p.contentType)) ??
    parts.find((p) => /application\/ics/i.test(p.contentType));
  if (!calendarPart) return null;
  return parseIcsReply(decodeBody(calendarPart), { name: fallback.name });
}
