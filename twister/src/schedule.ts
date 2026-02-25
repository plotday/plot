import { type Tag } from "./tag";
import {
  type Actor,
  type ActorId,
  type NewActor,
  type NewTags,
  type Tags,
} from "./plot";
import { Uuid } from "./utils/uuid";

export { Uuid } from "./utils/uuid";

/**
 * Represents a schedule entry for a thread.
 *
 * Schedules define when a thread occurs in time. A thread may have zero or more schedules:
 * - Shared schedules (userId is null): visible to all members of the thread's priority
 * - Per-user schedules (userId set): private ordering/scheduling for a specific user
 *
 * For recurring events, start/end represent the first occurrence, with recurrenceRule
 * defining the pattern.
 */
export type Schedule = {
  /** When this schedule was created */
  created: Date;
  /** Whether this schedule has been archived */
  archived: boolean;
  /** If set, this is a per-user schedule visible only to this user */
  userId: ActorId | null;
  /** Per-user ordering within a day (only set for per-user schedules) */
  order: number | null;
  /**
   * Start time of the schedule.
   * Date object for timed events, date string in "YYYY-MM-DD" format for all-day events.
   */
  start: Date | string | null;
  /**
   * End time of the schedule.
   * Date object for timed events, date string in "YYYY-MM-DD" format for all-day events.
   */
  end: Date | string | null;
  /** Recurrence rule in RFC 5545 RRULE format (e.g., "FREQ=WEEKLY;BYDAY=MO,WE,FR") */
  recurrenceRule: string | null;
  /** Duration of each occurrence in milliseconds (required for recurring schedules) */
  duration: number | null;
  /** Array of dates to exclude from the recurrence pattern */
  recurrenceExdates: Date[] | null;
  /**
   * For occurrence exceptions: the original date/time of this occurrence in the series.
   * Format: Date object or "YYYY-MM-DD" for all-day events.
   */
  occurrence: Date | string | null;
  /** Contacts invited to this schedule (attendees/participants) */
  contacts: ScheduleContact[];
};

export type ScheduleContactStatus = "attend" | "skip";
export type ScheduleContactRole = "organizer" | "required" | "optional";

export type ScheduleContact = {
  contact: Actor;
  status: ScheduleContactStatus | null;
  role: ScheduleContactRole;
  archived: boolean;
};

export type NewScheduleContact = {
  contact: NewActor;
  status?: ScheduleContactStatus | null;
  role?: ScheduleContactRole | null;
  archived?: boolean;
};

/**
 * Type for creating new schedules.
 *
 * Requires `threadId` and `start`. All other fields are optional.
 *
 * @example
 * ```typescript
 * // Simple timed event
 * const schedule: NewSchedule = {
 *   threadId: threadId,
 *   start: new Date("2025-03-15T10:00:00Z"),
 *   end: new Date("2025-03-15T11:00:00Z")
 * };
 *
 * // All-day event
 * const allDay: NewSchedule = {
 *   threadId: threadId,
 *   start: "2025-03-15",
 *   end: "2025-03-16"
 * };
 *
 * // Recurring weekly event
 * const recurring: NewSchedule = {
 *   threadId: threadId,
 *   start: new Date("2025-01-20T14:00:00Z"),
 *   end: new Date("2025-01-20T15:00:00Z"),
 *   recurrenceRule: "FREQ=WEEKLY;BYDAY=MO",
 *   recurrenceUntil: new Date("2025-06-30")
 * };
 * ```
 */
export type NewSchedule = {
  /** The thread this schedule belongs to */
  threadId: Uuid;
  /**
   * Start time. Date for timed events, "YYYY-MM-DD" for all-day.
   * Determines whether the schedule uses `at` (timed) or `on` (all-day) storage.
   */
  start: Date | string;
  /** End time. Date for timed events, "YYYY-MM-DD" for all-day. */
  end?: Date | string | null;
  /** Recurrence rule in RFC 5545 RRULE format */
  recurrenceRule?: string | null;
  /**
   * For recurring schedules, the last occurrence date (inclusive).
   * When both recurrenceCount and recurrenceUntil are provided, recurrenceCount takes precedence.
   */
  recurrenceUntil?: Date | string | null;
  /**
   * For recurring schedules, the number of occurrences to generate.
   * Takes precedence over recurrenceUntil if both are provided.
   */
  recurrenceCount?: number | null;
  /** Array of dates to exclude from the recurrence pattern */
  recurrenceExdates?: Date[] | null;
  /**
   * For occurrence exceptions: the original date/time of this occurrence.
   */
  occurrence?: Date | string | null;
  /** If set, this is a per-user schedule for the specified user */
  userId?: ActorId | null;
  /** Per-user ordering (only valid with userId) */
  order?: number | null;
  /** Whether to archive this schedule */
  archived?: boolean;
  /** Contacts to upsert on this schedule. Upserted by contact identity. */
  contacts?: NewScheduleContact[];
};

/** @deprecated Schedules are updated via Thread. Use NewSchedule instead. */
export type ScheduleUpdate = Partial<Omit<NewSchedule, "threadId">>;

/**
 * Represents a specific instance of a recurring schedule.
 * All field values are computed by merging the recurring schedule's
 * defaults with any occurrence-specific overrides.
 */
export type ScheduleOccurrence = {
  /**
   * Original date/datetime of this occurrence.
   * Use start for the occurrence's current start time.
   */
  occurrence: Date | string;

  /** The recurring schedule of which this is an occurrence */
  schedule: Schedule;

  /** Effective start for this occurrence (series default + override) */
  start: Date | string;
  /** Effective end for this occurrence */
  end: Date | string | null;

  /** Tags for this occurrence */
  tags: Tags;

  /** True if the occurrence is archived */
  archived: boolean;
};

/**
 * Type for creating or updating schedule occurrences.
 */
export type NewScheduleOccurrence = Pick<
  ScheduleOccurrence,
  "occurrence" | "start"
> &
  Partial<
    Omit<ScheduleOccurrence, "occurrence" | "start" | "schedule" | "tags">
  > & {
    /** Tags for this occurrence */
    tags?: NewTags;

    /** Add or remove the twist's tags on this occurrence */
    twistTags?: Partial<Record<Tag, boolean>>;

    /** Whether this occurrence should be marked as unread */
    unread?: boolean;

    /** Contacts to upsert on this occurrence's schedule */
    contacts?: NewScheduleContact[];
  };

/**
 * Type for updating schedule occurrences inline.
 */
export type ScheduleOccurrenceUpdate = Pick<
  NewScheduleOccurrence,
  "occurrence"
> &
  Partial<Omit<NewScheduleOccurrence, "occurrence" | "schedule">>;
