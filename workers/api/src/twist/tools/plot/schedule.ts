import type { Json } from "@plotday/db";
import type {
  NewSchedule,
  NewScheduleOccurrence,
  Schedule,
  ScheduleContact,
} from "@plotday/twister/schedule";
import type { ActorId } from "@plotday/twister/plot";

import { rpcUser } from "../../../rpc";
import { calculateDbEndFromRecurrenceUntil, formatInterval } from "./datetime";
import { processScheduleContacts } from "./schedule-contacts";
import type { Plot } from "./index";

/**
 * Converts start/end to the appropriate DB range field (at or on).
 *
 * - Date objects → timed event → tstzrange `at`
 * - String dates (YYYY-MM-DD) → all-day event → daterange `on`
 */
function convertTimeRange(
  start: Date | string,
  end?: Date | string | null
): { at?: string; on?: string } {
  if (typeof start === "string") {
    // All-day event: daterange
    if (end) {
      return { on: `[${start},${end as string})` };
    }
    return { on: `[${start},)` };
  } else {
    // Timed event: tstzrange
    const startIso = start.toISOString();
    if (end) {
      return { at: `[${startIso},${(end as Date).toISOString()})` };
    }
    return { at: `[${startIso},)` };
  }
}

/**
 * Converts a NewSchedule (without threadId) to the DB JSON format for upsert_schedule.
 *
 * @param schedule - The schedule to convert
 * @param target - Either { link_id } or { thread_id } to assign the schedule to
 */
export function convertScheduleToDb(
  schedule: Omit<NewSchedule, "threadId">,
  target: { link_id: string } | { thread_id: string }
): Record<string, unknown> {
  const dbSchedule: Record<string, unknown> = { ...target };

  // Time range (at or on) and duration.
  // For recurring schedules, expand the range to cover all occurrences so that
  // overlap queries against the agenda window find them. The `duration` column
  // stores the per-occurrence duration.
  if (schedule.recurrenceRule) {
    const { dbEnd, duration } = calculateDbEndFromRecurrenceUntil(
      schedule.start,
      schedule.end ?? null,
      schedule.recurrenceUntil ?? null,
      schedule.recurrenceCount ?? undefined,
      schedule.recurrenceRule
    );
    const range = convertTimeRange(schedule.start, dbEnd);
    Object.assign(dbSchedule, range);
    if (duration != null) {
      dbSchedule.duration = formatInterval(duration);
    }
  } else {
    const range = convertTimeRange(schedule.start, schedule.end);
    Object.assign(dbSchedule, range);
  }

  // Recurrence rule with UNTIL/COUNT appended
  if (schedule.recurrenceRule !== undefined) {
    let rule = schedule.recurrenceRule;
    if (rule) {
      if (schedule.recurrenceCount != null) {
        rule += `;COUNT=${schedule.recurrenceCount}`;
      } else if (schedule.recurrenceUntil != null) {
        const until =
          schedule.recurrenceUntil instanceof Date
            ? schedule.recurrenceUntil
                .toISOString()
                .replace(/[-:]/g, "")
                .replace(/\.\d{3}/, "")
            : schedule.recurrenceUntil.replace(/-/g, "");
        rule += `;UNTIL=${until}`;
      }
    }
    dbSchedule.recurrence_rule = rule;
  }

  // Recurrence exdates
  if (schedule.recurrenceExdates !== undefined) {
    dbSchedule.recurrence_exdates = schedule.recurrenceExdates
      ? schedule.recurrenceExdates.map((d) =>
          d instanceof Date ? d.toISOString() : String(d)
        )
      : null;
  }

  // Occurrence (for exception instances)
  if (schedule.occurrence !== undefined && schedule.occurrence !== null) {
    dbSchedule.occurrence =
      schedule.occurrence instanceof Date
        ? schedule.occurrence.toISOString()
        : schedule.occurrence;
  }

  // Per-user fields
  if (schedule.userId !== undefined) {
    dbSchedule.user_id = schedule.userId;
  }
  if (schedule.order !== undefined) {
    dbSchedule.order = schedule.order;
  }

  // Archived
  if (schedule.archived !== undefined) {
    dbSchedule.archived_at = schedule.archived
      ? new Date().toISOString()
      : null;
  }

  return dbSchedule;
}

/**
 * Converts a NewScheduleOccurrence to the DB JSON format for upsert_schedule.
 *
 * @param occ - The occurrence override to convert
 * @param target - Either { link_id } or { thread_id }
 */
function convertOccurrenceToDb(
  occ: NewScheduleOccurrence,
  target: { link_id: string } | { thread_id: string }
): Record<string, unknown> {
  const dbSchedule: Record<string, unknown> = { ...target };

  // Time range
  const range = convertTimeRange(occ.start, occ.end);
  Object.assign(dbSchedule, range);

  // Occurrence identifier (required)
  dbSchedule.occurrence =
    occ.occurrence instanceof Date
      ? occ.occurrence.toISOString()
      : occ.occurrence;

  // Archived
  if (occ.archived !== undefined) {
    dbSchedule.archived_at = occ.archived ? new Date().toISOString() : null;
  }

  return dbSchedule;
}

/**
 * Creates schedule rows for a link.
 *
 * Calls upsert_schedule for each schedule and occurrence, then processes
 * contacts for schedules that have them.
 *
 * @param plot - The Plot instance
 * @param linkId - The link ID to attach schedules to
 * @param priorityId - The priority ID for contact resolution
 * @param schedules - Array of schedules to create
 * @param scheduleOccurrences - Array of occurrence overrides to create
 * @returns Array of created schedule IDs
 */
export async function createLinkSchedules(
  plot: Plot,
  linkId: string,
  priorityId: string,
  schedules?: Array<Omit<NewSchedule, "threadId">>,
  scheduleOccurrences?: NewScheduleOccurrence[]
): Promise<string[]> {
  const userId = await plot.getUserId();
  const scheduleIds: string[] = [];
  const target = { link_id: linkId };

  // Create schedules
  if (schedules?.length) {
    for (const schedule of schedules) {
      const dbSchedule = convertScheduleToDb(schedule, target);
      const result = await rpcUser(plot.db, "upsert_schedule", {
        user_id: userId,
        p_schedule: dbSchedule as Json,
      });

      if (result?.id) {
        scheduleIds.push(result.id);

        // Process contacts if present
        if (schedule.contacts?.length) {
          await processScheduleContacts(
            plot,
            result.id,
            schedule.contacts,
            priorityId
          );
        }
      }
    }
  }

  // Create occurrence overrides
  if (scheduleOccurrences?.length) {
    for (const occ of scheduleOccurrences) {
      const dbSchedule = convertOccurrenceToDb(occ, target);
      const result = await rpcUser(plot.db, "upsert_schedule", {
        user_id: userId,
        p_schedule: dbSchedule as Json,
      });

      if (result?.id) {
        scheduleIds.push(result.id);

        // Process contacts if present
        if (occ.contacts?.length) {
          await processScheduleContacts(
            plot,
            result.id,
            occ.contacts,
            priorityId
          );
        }
      }
    }
  }

  return scheduleIds;
}

/**
 * Parses a PostgreSQL range string into start and end components.
 * Handles both tstzrange (e.g., `["2025-03-15 10:00:00+00","2025-03-15 11:00:00+00")`)
 * and daterange (e.g., `[2025-03-15,2025-03-16)`) formats.
 */
function parseRange(range: string | null): {
  start: string | null;
  end: string | null;
} {
  if (!range) return { start: null, end: null };
  const match = range.match(/[\[(]"?([^",]*)"?,\s*"?([^")\]]*)"?[\])]/);
  if (!match) return { start: null, end: null };
  return {
    start: match[1]?.trim() || null,
    end: match[2]?.trim() || null,
  };
}

/**
 * Converts a PostgreSQL interval value to milliseconds.
 * Handles both string format ("HH:MM:SS") and object format from pg driver.
 */
function intervalToMs(interval: unknown): number | null {
  if (interval == null) return null;
  if (typeof interval === "string") {
    // Try "HH:MM:SS" or "HH:MM:SS.mmm" format
    const match = interval.match(/(\d+):(\d+):(\d+)/);
    if (match) {
      return (
        (parseInt(match[1]!) * 3600 +
          parseInt(match[2]!) * 60 +
          parseInt(match[3]!)) *
        1000
      );
    }
    return null;
  }
  if (typeof interval === "object") {
    const iv = interval as Record<string, number>;
    let ms = 0;
    if (iv.days) ms += iv.days * 24 * 3600 * 1000;
    if (iv.hours) ms += iv.hours * 3600 * 1000;
    if (iv.minutes) ms += iv.minutes * 60 * 1000;
    if (iv.seconds) ms += iv.seconds * 1000;
    if (iv.milliseconds) ms += iv.milliseconds;
    return ms || null;
  }
  return null;
}

/**
 * Converts a DB schedule row to the SDK Schedule type.
 */
export function convertDbToSchedule(
  row: Record<string, unknown>
): Schedule {
  // Parse at (tstzrange) or on (daterange)
  let start: Date | string | null = null;
  let end: Date | string | null = null;

  const atRange = parseRange(row.at as string | null);
  const onRange = parseRange(row.on as string | null);

  if (atRange.start) {
    // Timed event
    start = new Date(atRange.start);
    end = atRange.end ? new Date(atRange.end) : null;
  } else if (onRange.start) {
    // All-day event
    start = onRange.start;
    end = onRange.end || null;
  }

  return {
    created: new Date(row.created_at as string),
    archived: row.archived_at !== null,
    userId: (row.user_id as ActorId) ?? null,
    order: (row.order as number) ?? null,
    start,
    end,
    recurrenceRule: (row.recurrence_rule as string) ?? null,
    duration: intervalToMs(row.duration),
    recurrenceExdates: row.recurrence_exdates
      ? (row.recurrence_exdates as string[]).map((d) => new Date(d))
      : null,
    occurrence:
      row.occurrence != null
        ? typeof row.occurrence === "string" &&
          /^\d{4}-\d{2}-\d{2}$/.test(row.occurrence)
          ? row.occurrence
          : new Date(row.occurrence as string)
        : null,
    contacts: [] as ScheduleContact[], // Contacts are fetched separately if needed
  };
}
