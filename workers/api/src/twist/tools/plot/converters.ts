import type { Database, Json } from "@plotday/db";
import {
  type Activity,
  type ActivityMeta,
  ActivityType,
  type Actor,
  type ActorId,
  ActorType,
  type Priority,
  type Tags,
} from "@plotday/twister/plot";

import {
  calculateRecurrenceUntil,
  parseInterval,
  parseRangeEnd,
  parseRangeStart,
} from "./datetime";

export function fromDbActivity(
  dbActivity: Database["public"]["Tables"]["activity"]["Row"] & {
    author: {
      id: string | null;
      name: string | null;
      type: string | null;
      email?: string | null;
    };
    assignee?: {
      id: string | null;
      name: string | null;
      type: string | null;
      email?: string | null;
    } | null;
    tags?: Json | null;
    mentions?: string[] | null;
    source?: string | null;
    source_created_at?: string | null;
  },
  includeAuthorEmail: boolean = false
): Activity {
  // Map database activity_type to ActivityType enum
  let activityType: number;
  switch (dbActivity.type) {
    case "action":
      activityType = ActivityType.Action;
      break;
    case "event":
      activityType = ActivityType.Event;
      break;
    default:
    case "note":
      activityType = ActivityType.Note;
      break;
  }

  // Map actor type to ActorType enum
  let authorType: number = ActorType.User; // Default to User
  if (dbActivity.author.type) {
    switch (dbActivity.author.type) {
      case "user":
        authorType = ActorType.User;
        break;
      case "contact":
        authorType = ActorType.Contact;
        break;
      case "priority_twist":
        authorType = ActorType.Twist;
        break;
    }
  }

  const start = parseRangeStart(dbActivity.on, dbActivity.at);
  const dbEnd = parseRangeEnd(dbActivity.on, dbActivity.at);

  // Calculate recurrenceUntil from database end and duration
  const recurrenceUntil = calculateRecurrenceUntil(
    start,
    dbEnd,
    dbActivity.duration,
    dbActivity.recurrence_rule
  );

  // For SDK, end is always the end of the first occurrence
  // If this is recurring, we need to calculate the first occurrence end from start and duration
  let sdkEnd = dbEnd;
  if (dbActivity.recurrence_rule && start && dbActivity.duration) {
    const durationSeconds = parseInterval(dbActivity.duration);
    if (durationSeconds !== undefined) {
      if (typeof start === "string") {
        // Date-based: add duration in days
        const startDate = new Date(start);
        const durationDays = Math.floor(durationSeconds / (24 * 60 * 60));
        const endDate = new Date(
          startDate.getTime() + durationDays * 24 * 60 * 60 * 1000
        );
        sdkEnd = endDate.toISOString().split("T")[0];
      } else if (start instanceof Date) {
        // DateTime-based: add duration in seconds
        sdkEnd = new Date(start.getTime() + durationSeconds * 1000);
      }
    }
  }

  // Build author object with conditional email inclusion
  const author: Actor = {
    id: (dbActivity.author.id || dbActivity.author_id) as ActorId,
    name: dbActivity.author.name || null,
    type: authorType,
    ...(includeAuthorEmail && dbActivity.author.email
      ? { email: dbActivity.author.email }
      : {}),
  };

  // Build assignee object if available
  let assignee: Actor | null = null;
  if (dbActivity.assignee) {
    // Map assignee type to ActorType enum
    let assigneeType: number = ActorType.User; // Default to User
    if (dbActivity.assignee.type) {
      switch (dbActivity.assignee.type) {
        case "user":
          assigneeType = ActorType.User;
          break;
        case "contact":
          assigneeType = ActorType.Contact;
          break;
        case "priority_twist":
          assigneeType = ActorType.Twist;
          break;
      }
    }

    assignee = {
      id: (dbActivity.assignee.id || dbActivity.assignee_id) as ActorId,
      name: dbActivity.assignee.name || null,
      type: assigneeType,
      ...(includeAuthorEmail && dbActivity.assignee.email
        ? { email: dbActivity.assignee.email }
        : {}),
    };
  }

  return {
    id: dbActivity.id,
    type: activityType,
    createdAt: dbActivity.source_created_at
      ? new Date(dbActivity.source_created_at)
      : null,
    author,
    start,
    end: sdkEnd,
    recurrenceUntil,
    recurrenceCount: null, // Not stored separately in database
    doneAt: dbActivity.done_at ? new Date(dbActivity.done_at) : null,
    title: dbActivity.title || null,
    assignee,
    draft: dbActivity.draft ?? false,
    private: dbActivity.private ?? false,
    archived: dbActivity.archived_at !== null,
    priority: {
      id: dbActivity.priority_id,
      title: dbActivity.title ?? "Untitled",
    },
    recurrenceRule: dbActivity.recurrence_rule || null,
    recurrenceExdates:
      dbActivity.recurrence_exdates?.map((d) => new Date(d)) || null,
    recurrenceDates:
      dbActivity.recurrence_dates?.map((d) => new Date(d)) || null,
    recurrence: null,
    occurrence: null,
    source: dbActivity.source ?? null,
    meta: dbActivity.meta as ActivityMeta | null,
    tags: (dbActivity.tags as Tags) || null,
    mentions: (dbActivity.mentions as ActorId[]) || null,
  };
}

export function fromDbPriority(
  dbPriority: Database["public"]["Tables"]["priority"]["Row"]
): Priority {
  return {
    id: dbPriority.id,
    title: dbPriority.title,
  };
}
