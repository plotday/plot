/**
 * Lightweight ICS (iCalendar RFC 5545) parser for Cloudflare Workers.
 * Parses VCALENDAR/VEVENT data into structured event objects.
 */

export type ICSDateTimeProp = {
  value: string;
  params: Record<string, string>;
};

export type ICSEvent = {
  uid: string;
  summary: string;
  description: string | null;
  dtstart: ICSDateTimeProp;
  dtend: ICSDateTimeProp | null;
  duration: string | null;
  rrule: string | null;
  exdates: Date[];
  rdates: Date[];
  recurrenceId: ICSDateTimeProp | null;
  status: string | null;
  location: string | null;
  organizer: { email: string; name: string | null } | null;
  attendees: Array<{
    email: string;
    name: string | null;
    partstat: string | null;
    role: string | null;
  }>;
  sequence: number;
  created: string | null;
  lastModified: string | null;
  url: string | null;
};

/**
 * Unfold ICS lines per RFC 5545 §3.1.
 * Lines that begin with a space or tab are continuations of the previous line.
 */
function unfoldLines(ics: string): string {
  // Normalize line endings to \n
  return ics.replace(/\r\n/g, "\n").replace(/\r/g, "\n").replace(/\n[ \t]/g, "");
}

/**
 * Unescape ICS text values per RFC 5545 §3.3.11.
 */
function unescapeText(text: string): string {
  return text
    .replace(/\\n/gi, "\n")
    .replace(/\\,/g, ",")
    .replace(/\\;/g, ";")
    .replace(/\\\\/g, "\\");
}

/**
 * Parse property parameters from a property name string.
 * e.g., "DTSTART;TZID=America/New_York;VALUE=DATE" → { TZID: "America/New_York", VALUE: "DATE" }
 */
function parseParams(propName: string): {
  name: string;
  params: Record<string, string>;
} {
  const parts = propName.split(";");
  const name = parts[0].toUpperCase();
  const params: Record<string, string> = {};

  for (let i = 1; i < parts.length; i++) {
    const eqIdx = parts[i].indexOf("=");
    if (eqIdx >= 0) {
      const key = parts[i].substring(0, eqIdx).toUpperCase();
      let val = parts[i].substring(eqIdx + 1);
      // Remove quotes
      if (val.startsWith('"') && val.endsWith('"')) {
        val = val.slice(1, -1);
      }
      params[key] = val;
    }
  }

  return { name, params };
}

/**
 * Parse an ICS date/datetime string into a Date object or date string.
 *
 * - "YYYYMMDD" (VALUE=DATE) → "YYYY-MM-DD" string (all-day event)
 * - "YYYYMMDDTHHMMSSZ" → Date object (UTC)
 * - "YYYYMMDDTHHMMSS" with TZID → Date object
 */
export function parseICSDateTime(prop: ICSDateTimeProp): Date | string {
  const d = prop.value.trim();
  const isDateOnly = prop.params.VALUE === "DATE" || /^\d{8}$/.test(d);

  if (isDateOnly) {
    // All-day date: YYYYMMDD → "YYYY-MM-DD"
    const dateStr = d.replace(/T.*$/, ""); // Strip time if present
    const year = dateStr.slice(0, 4);
    const month = dateStr.slice(4, 6);
    const day = dateStr.slice(6, 8);
    return `${year}-${month}-${day}`;
  }

  // DateTime: YYYYMMDDTHHMMSS or YYYYMMDDTHHMMSSZ
  if (/^\d{8}T\d{6}Z?$/.test(d)) {
    const year = d.slice(0, 4);
    const month = d.slice(4, 6);
    const day = d.slice(6, 8);
    const hour = d.slice(9, 11);
    const minute = d.slice(11, 13);
    const second = d.slice(13, 15);
    const isUtc = d.endsWith("Z");

    if (isUtc || !prop.params.TZID) {
      return new Date(`${year}-${month}-${day}T${hour}:${minute}:${second}Z`);
    }

    // With TZID — attempt conversion. Workers support Intl with timezone.
    try {
      // Create a Date assuming UTC, then adjust would be complex.
      // Instead, use the TZID directly with Intl to compute the UTC offset.
      const naiveDate = new Date(
        `${year}-${month}-${day}T${hour}:${minute}:${second}`
      );

      // Use Intl to find the offset for this timezone at this date
      const formatter = new Intl.DateTimeFormat("en-US", {
        timeZone: prop.params.TZID,
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
        hour12: false,
      });

      // Parse the formatted local time and compare to get offset
      const parts = formatter.formatToParts(naiveDate);
      const getPart = (type: string) =>
        parts.find((p) => p.type === type)?.value || "0";

      const localYear = parseInt(getPart("year"));
      const localMonth = parseInt(getPart("month"));
      const localDay = parseInt(getPart("day"));
      const localHour = parseInt(getPart("hour")) % 24;
      const localMinute = parseInt(getPart("minute"));

      // If the formatter returns the same values as our input, the naive date is correct for that TZ
      // Compute delta between what JS thinks is the time and what TZ says it is
      const utcMs = Date.UTC(
        localYear,
        localMonth - 1,
        localDay,
        localHour,
        localMinute,
        parseInt(getPart("second"))
      );
      const offsetMs = utcMs - naiveDate.getTime();

      // The actual UTC time is the naive time minus the offset
      return new Date(naiveDate.getTime() - offsetMs);
    } catch {
      // Fallback: treat as UTC
      return new Date(`${year}-${month}-${day}T${hour}:${minute}:${second}Z`);
    }
  }

  // Fallback: try native parsing
  const parsed = new Date(d);
  return isNaN(parsed.getTime())
    ? d // Return raw string if unparseable
    : parsed;
}

/**
 * Parse an ATTENDEE or ORGANIZER line to extract email and parameters.
 */
function parseMailtoLine(
  line: string
): { email: string; params: Record<string, string> } | null {
  const colonIdx = line.indexOf(":");
  if (colonIdx < 0) return null;

  const propPart = line.substring(0, colonIdx);
  const valuePart = line.substring(colonIdx + 1).trim();

  // Extract email from mailto: URI
  const emailMatch = valuePart.match(/^mailto:(.+)$/i);
  if (!emailMatch) return null;

  const { params } = parseParams(propPart);
  return { email: emailMatch[1].toLowerCase(), params };
}

/**
 * Parse all VEVENT blocks from an ICS string into ICSEvent objects.
 */
export function parseICSEvents(icsData: string): ICSEvent[] {
  const unfolded = unfoldLines(icsData);
  const lines = unfolded.split("\n");
  const events: ICSEvent[] = [];

  let inEvent = false;
  let eventLines: string[] = [];

  for (const line of lines) {
    if (line.trim() === "BEGIN:VEVENT") {
      inEvent = true;
      eventLines = [];
      continue;
    }
    if (line.trim() === "END:VEVENT") {
      inEvent = false;
      const event = parseVEvent(eventLines);
      if (event) events.push(event);
      continue;
    }
    if (inEvent) {
      eventLines.push(line);
    }
  }

  return events;
}

/**
 * Parse a single VEVENT block's lines into an ICSEvent.
 */
function parseVEvent(lines: string[]): ICSEvent | null {
  let uid = "";
  let summary = "";
  let description: string | null = null;
  let dtstart: ICSDateTimeProp | null = null;
  let dtend: ICSDateTimeProp | null = null;
  let duration: string | null = null;
  let rrule: string | null = null;
  const exdateStrings: string[] = [];
  const rdateStrings: string[] = [];
  let recurrenceId: ICSDateTimeProp | null = null;
  let status: string | null = null;
  let location: string | null = null;
  let organizer: { email: string; name: string | null } | null = null;
  const attendees: ICSEvent["attendees"] = [];
  let sequence = 0;
  let created: string | null = null;
  let lastModified: string | null = null;
  let url: string | null = null;

  for (const line of lines) {
    const colonIdx = line.indexOf(":");
    if (colonIdx < 0) continue;

    const propPart = line.substring(0, colonIdx);
    const valuePart = line.substring(colonIdx + 1);
    const { name, params } = parseParams(propPart);

    switch (name) {
      case "UID":
        uid = valuePart.trim();
        break;
      case "SUMMARY":
        summary = unescapeText(valuePart.trim());
        break;
      case "DESCRIPTION":
        description = unescapeText(valuePart.trim());
        break;
      case "DTSTART":
        dtstart = { value: valuePart.trim(), params };
        break;
      case "DTEND":
        dtend = { value: valuePart.trim(), params };
        break;
      case "DURATION":
        duration = valuePart.trim();
        break;
      case "RRULE":
        rrule = valuePart.trim();
        break;
      case "EXDATE":
        exdateStrings.push(valuePart.trim());
        break;
      case "RDATE":
        rdateStrings.push(valuePart.trim());
        break;
      case "RECURRENCE-ID":
        recurrenceId = { value: valuePart.trim(), params };
        break;
      case "STATUS":
        status = valuePart.trim().toUpperCase();
        break;
      case "LOCATION":
        location = unescapeText(valuePart.trim());
        break;
      case "ORGANIZER": {
        const parsed = parseMailtoLine(line);
        if (parsed) {
          organizer = {
            email: parsed.email,
            name: parsed.params.CN || null,
          };
        }
        break;
      }
      case "ATTENDEE": {
        const parsed = parseMailtoLine(line);
        if (parsed) {
          attendees.push({
            email: parsed.email,
            name: parsed.params.CN || null,
            partstat: parsed.params.PARTSTAT || null,
            role: parsed.params.ROLE || null,
          });
        }
        break;
      }
      case "SEQUENCE":
        sequence = parseInt(valuePart.trim()) || 0;
        break;
      case "CREATED":
        created = valuePart.trim();
        break;
      case "LAST-MODIFIED":
        lastModified = valuePart.trim();
        break;
      case "URL":
        url = valuePart.trim();
        break;
    }
  }

  if (!uid || !dtstart) return null;

  return {
    uid,
    summary,
    description,
    dtstart,
    dtend,
    duration,
    rrule,
    exdates: parseMultiDateValues(exdateStrings),
    rdates: parseMultiDateValues(rdateStrings),
    recurrenceId,
    status,
    location,
    organizer,
    attendees,
    sequence,
    created,
    lastModified,
    url,
  };
}

/**
 * Parse multiple EXDATE/RDATE value strings into Date arrays.
 * Each value can contain comma-separated dates.
 */
function parseMultiDateValues(values: string[]): Date[] {
  const dates: Date[] = [];

  for (const value of values) {
    const parts = value.split(",");
    for (const part of parts) {
      const d = part.trim();
      if (!d) continue;
      const parsed = parseICalDate(d);
      if (parsed) dates.push(parsed);
    }
  }

  return dates;
}

/**
 * Parse an iCalendar date string into a Date.
 * Handles: YYYYMMDD, YYYYMMDDTHHMMSS, YYYYMMDDTHHMMSSZ
 */
function parseICalDate(dateStr: string): Date | null {
  const d = dateStr.trim();

  // All-day: YYYYMMDD
  if (/^\d{8}$/.test(d)) {
    const year = d.slice(0, 4);
    const month = d.slice(4, 6);
    const day = d.slice(6, 8);
    return new Date(`${year}-${month}-${day}`);
  }

  // DateTime: YYYYMMDDTHHMMSS or YYYYMMDDTHHMMSSZ
  if (/^\d{8}T\d{6}Z?$/.test(d)) {
    const year = d.slice(0, 4);
    const month = d.slice(4, 6);
    const day = d.slice(6, 8);
    const hour = d.slice(9, 11);
    const minute = d.slice(11, 13);
    const second = d.slice(13, 15);
    const isUtc = d.endsWith("Z");
    return new Date(
      `${year}-${month}-${day}T${hour}:${minute}:${second}${isUtc ? "Z" : ""}`
    );
  }

  // Fallback
  const parsed = new Date(d);
  return isNaN(parsed.getTime()) ? null : parsed;
}

/**
 * Parse RRULE recurrence end (UNTIL) from an RRULE string.
 */
export function parseRRuleEnd(rrule: string | null): Date | string | null {
  if (!rrule) return null;

  const untilMatch = rrule.match(/UNTIL=([^;]+)/);
  if (!untilMatch) return null;

  const untilValue = untilMatch[1];
  if (untilValue.includes("T")) {
    const year = untilValue.slice(0, 4);
    const month = untilValue.slice(4, 6);
    const day = untilValue.slice(6, 8);
    const hour = untilValue.slice(9, 11);
    const minute = untilValue.slice(11, 13);
    const second = untilValue.slice(13, 15);
    return new Date(`${year}-${month}-${day}T${hour}:${minute}:${second}Z`);
  } else if (/^\d{8}$/.test(untilValue)) {
    const year = untilValue.slice(0, 4);
    const month = untilValue.slice(4, 6);
    const day = untilValue.slice(6, 8);
    return `${year}-${month}-${day}`;
  }

  return null;
}

/**
 * Parse RRULE recurrence count (COUNT) from an RRULE string.
 */
export function parseRRuleCount(rrule: string | null): number | null {
  if (!rrule) return null;

  const countMatch = rrule.match(/COUNT=(\d+)/);
  if (!countMatch) return null;

  const count = parseInt(countMatch[1]);
  return isNaN(count) ? null : count;
}

/**
 * Update an attendee's PARTSTAT in raw ICS data.
 * Finds the ATTENDEE line matching the given email and updates its PARTSTAT parameter.
 *
 * @param icsData - The full ICS text (VCALENDAR with VEVENT)
 * @param email - The attendee email to update
 * @param partstat - The new PARTSTAT value (ACCEPTED, DECLINED, TENTATIVE, NEEDS-ACTION)
 * @returns The modified ICS data, or null if the attendee was not found
 */
export function updateAttendeePartstat(
  icsData: string,
  email: string,
  partstat: string
): string | null {
  // Unfold lines first to handle multi-line ATTENDEE properties
  const unfolded = icsData
    .replace(/\r\n/g, "\n")
    .replace(/\r/g, "\n")
    .replace(/\n[ \t]/g, "");

  const lines = unfolded.split("\n");
  let found = false;

  const updatedLines = lines.map((line) => {
    // Match ATTENDEE lines containing this email
    if (
      line.toUpperCase().startsWith("ATTENDEE") &&
      line.toLowerCase().includes(`mailto:${email.toLowerCase()}`)
    ) {
      found = true;

      // Replace or add PARTSTAT parameter
      if (/PARTSTAT=[^;:]+/i.test(line)) {
        // Replace existing PARTSTAT
        return line.replace(/PARTSTAT=[^;:]+/i, `PARTSTAT=${partstat}`);
      } else {
        // Add PARTSTAT before the colon (value separator)
        const colonIdx = line.indexOf(":");
        if (colonIdx >= 0) {
          return (
            line.substring(0, colonIdx) +
            `;PARTSTAT=${partstat}` +
            line.substring(colonIdx)
          );
        }
      }
    }
    return line;
  });

  if (!found) return null;
  return updatedLines.join("\r\n");
}
