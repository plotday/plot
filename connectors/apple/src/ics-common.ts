/**
 * Low-level iCalendar (RFC 5545) parsing helpers shared by every VCALENDAR
 * component parser in this connector — VEVENT via `calendar/ics-parser.ts`,
 * VTODO via `reminders/ics-todo-parser.ts`. Component-specific field mapping
 * stays in each parser; only generic line/param/date plumbing lives here.
 */

export type ICSDateTimeProp = {
  value: string;
  params: Record<string, string>;
};

/**
 * Unfold ICS lines per RFC 5545 §3.1.
 * Lines that begin with a space or tab are continuations of the previous line.
 */
export function unfoldLines(ics: string): string {
  return ics.replace(/\r\n/g, "\n").replace(/\r/g, "\n").replace(/\n[ \t]/g, "");
}

/**
 * Unescape ICS text values per RFC 5545 §3.3.11.
 */
export function unescapeText(text: string): string {
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
export function parseParams(propName: string): {
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
    const dateStr = d.replace(/T.*$/, "");
    const year = dateStr.slice(0, 4);
    const month = dateStr.slice(4, 6);
    const day = dateStr.slice(6, 8);
    return `${year}-${month}-${day}`;
  }

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

    try {
      const naiveDate = new Date(
        `${year}-${month}-${day}T${hour}:${minute}:${second}`
      );
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
      const parts = formatter.formatToParts(naiveDate);
      const getPart = (type: string) =>
        parts.find((p) => p.type === type)?.value || "0";

      const localYear = parseInt(getPart("year"));
      const localMonth = parseInt(getPart("month"));
      const localDay = parseInt(getPart("day"));
      const localHour = parseInt(getPart("hour")) % 24;
      const localMinute = parseInt(getPart("minute"));

      const utcMs = Date.UTC(
        localYear,
        localMonth - 1,
        localDay,
        localHour,
        localMinute,
        parseInt(getPart("second"))
      );
      const offsetMs = utcMs - naiveDate.getTime();
      return new Date(naiveDate.getTime() - offsetMs);
    } catch {
      return new Date(`${year}-${month}-${day}T${hour}:${minute}:${second}Z`);
    }
  }

  const parsed = new Date(d);
  return isNaN(parsed.getTime()) ? d : parsed;
}
