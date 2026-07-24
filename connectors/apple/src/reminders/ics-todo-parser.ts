/**
 * Lightweight ICS (iCalendar RFC 5545) parser for VTODO components —
 * iCloud Reminders. Mirrors calendar/ics-parser.ts's VEVENT parser; shares
 * its low-level line/param helpers via ics-common.ts.
 */
import {
  type ICSDateTimeProp,
  parseParams,
  unescapeText,
  unfoldLines,
} from "../ics-common";

export type ICSTodo = {
  uid: string;
  summary: string;
  description: string | null;
  due: ICSDateTimeProp | null;
  completed: ICSDateTimeProp | null;
  /** NEEDS-ACTION | IN-PROCESS | COMPLETED | CANCELLED | null (absent means NEEDS-ACTION per RFC 5545 §3.8.1.11). */
  status: string | null;
  priority: number | null;
  /**
   * Parent VTODO's UID, from RELATED-TO. UNVERIFIED whether iCloud's
   * Reminders subtask feature actually populates this — see the design
   * spec's flagged assumption; confirm during live verification (Task 9).
   */
  relatedTo: string | null;
  rrule: string | null;
  sequence: number;
  created: string | null;
  lastModified: string | null;
  url: string | null;
};

/** Parse all VTODO blocks from an ICS string into ICSTodo objects. */
export function parseICSTodos(icsData: string): ICSTodo[] {
  const unfolded = unfoldLines(icsData);
  const lines = unfolded.split("\n");
  const todos: ICSTodo[] = [];

  let inTodo = false;
  let todoLines: string[] = [];

  for (const line of lines) {
    if (line.trim() === "BEGIN:VTODO") {
      inTodo = true;
      todoLines = [];
      continue;
    }
    if (line.trim() === "END:VTODO") {
      inTodo = false;
      const todo = parseVTodo(todoLines);
      if (todo) todos.push(todo);
      continue;
    }
    if (inTodo) {
      todoLines.push(line);
    }
  }

  return todos;
}

/** Parse a single VTODO block's lines into an ICSTodo. */
function parseVTodo(lines: string[]): ICSTodo | null {
  let uid = "";
  let summary = "";
  let description: string | null = null;
  let due: ICSDateTimeProp | null = null;
  let completed: ICSDateTimeProp | null = null;
  let status: string | null = null;
  let priority: number | null = null;
  let relatedTo: string | null = null;
  let rrule: string | null = null;
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
      case "DUE":
        due = { value: valuePart.trim(), params };
        break;
      case "COMPLETED":
        completed = { value: valuePart.trim(), params };
        break;
      case "STATUS":
        status = valuePart.trim().toUpperCase();
        break;
      case "PRIORITY": {
        const parsed = parseInt(valuePart.trim());
        priority = isNaN(parsed) ? null : parsed;
        break;
      }
      case "RELATED-TO":
        relatedTo = valuePart.trim();
        break;
      case "RRULE":
        rrule = valuePart.trim();
        break;
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

  if (!uid) return null;

  return {
    uid,
    summary,
    description,
    due,
    completed,
    status,
    priority,
    relatedTo,
    rrule,
    sequence,
    created,
    lastModified,
    url,
  };
}
