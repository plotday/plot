import {
  type Activity,
  type ActivityLink,
  type ActivityMeta,
  ActivityType,
  type ActorId,
  ActorType,
} from "@plotday/twister/plot";

import { type ActivityItem } from "../../../types";

/**
 * Parses the start date/time from range fields in database records.
 */
export function parseRangeStart(
  rangeOn: string | null,
  rangeAt: string | null
): Date | string | null {
  // Priority: if there's a timestamp range (rangeAt), use it
  if (rangeAt) {
    const rangeStr = rangeAt.toString();
    const match = rangeStr.match(/^\[([^,\]]+)/);
    if (match) {
      return new Date(match[1]);
    }
  }

  // Otherwise, try date range (rangeOn)
  if (rangeOn) {
    const rangeStr = rangeOn.toString();
    const match = rangeStr.match(/^\[([^,\]]+)/);
    if (match) {
      return match[1]; // Return as date string in YYYY-MM-DD format
    }
  }

  return null;
}

/**
 * Parses the end date/time from range fields in database records.
 */
export function parseRangeEnd(
  rangeOn: string | null,
  rangeAt: string | null
): Date | string | null {
  // Priority: if there's a timestamp range (rangeAt), use it
  if (rangeAt) {
    const rangeStr = rangeAt.toString();
    const match = rangeStr.match(/,([^)\]]+)[)\]]/);
    if (match) {
      return new Date(match[1]);
    }
    // Check for unbounded end (ends with comma and closing bracket/paren)
    if (rangeStr.match(/,[)\]]$/)) {
      return null;
    }
  }

  // Otherwise, try date range (rangeOn)
  if (rangeOn) {
    const rangeStr = rangeOn.toString();
    const match = rangeStr.match(/,([^)\]]+)[)\]]/);
    if (match) {
      return match[1]; // Return as date string in YYYY-MM-DD format
    }
    // Check for unbounded end (ends with comma and closing bracket/paren)
    if (rangeStr.match(/,[)\]]$/)) {
      return null;
    }
  }

  return null;
}

/**
 * Calculates which tags were added between two tag states.
 */
export function calculateTagsAdded(
  currentTags: Record<string, string[]> | null,
  previousTags: Record<string, string[]> | null
): Record<number, string[]> {
  if (!currentTags) return {};
  if (!previousTags) return currentTags;

  const added: Record<number, string[]> = {};
  for (const [tagId, actorIds] of Object.entries(
    currentTags as Record<string, string[]>
  )) {
    const prevActorIds = previousTags[tagId] || [];
    const newActorIds = actorIds.filter((id) => !prevActorIds.includes(id));
    if (newActorIds.length > 0) {
      added[Number(tagId)] = newActorIds;
    }
  }
  return added;
}

/**
 * Calculates which tags were removed between two tag states.
 */
export function calculateTagsRemoved(
  currentTags: Record<string, string[]> | null,
  previousTags: Record<string, string[]> | null
): Record<number, string[]> {
  if (!previousTags) return {};
  if (!currentTags) return previousTags;

  const removed: Record<number, string[]> = {};
  for (const [tagId, actorIds] of Object.entries(
    previousTags as Record<string, string[]>
  )) {
    const currActorIds = currentTags[tagId] || [];
    const removedActorIds = actorIds.filter((id) => !currActorIds.includes(id));
    if (removedActorIds.length > 0) {
      removed[Number(tagId)] = removedActorIds;
    }
  }
  return removed;
}

/**
 * Converts a database activity record into an Activity object.
 */
export function buildActivityFromDbRecord(
  activityRecord: ActivityItem
): Activity {
  // Convert string activity type to ActivityType enum
  let activityType: ActivityType;
  switch (activityRecord.type) {
    case "action":
      activityType = ActivityType.Action;
      break;
    case "event":
      activityType = ActivityType.Event;
      break;
    default:
      activityType = ActivityType.Note;
  }

  // Build thread root from database record if present
  const threadRoot = activityRecord.thread_root
    ? buildActivityFromDbRecord(activityRecord.thread_root)
    : undefined;

  return {
    id: activityRecord.id,
    type: activityType,
    author: {
      id: (activityRecord.author_id ?? activityRecord.created_by) as ActorId,
      name: activityRecord.author_name,
      type:
        activityRecord.author_type === "user"
          ? ActorType.User
          : activityRecord.author_type === "priority_twist"
          ? ActorType.Twist
          : ActorType.Contact,
    },
    priority: {
      id: activityRecord.priority_id,
      title: activityRecord.priority_title,
    },
    start: parseRangeStart(activityRecord.on, activityRecord.at),
    end: parseRangeEnd(activityRecord.on, activityRecord.at),
    recurrenceUntil: null,
    recurrenceCount: null,
    doneAt: activityRecord.done_at ? new Date(activityRecord.done_at) : null,
    note: activityRecord.note,
    title: activityRecord.title,
    parent: null,
    ...(threadRoot && { threadRoot }),
    links: activityRecord.links as ActivityLink[] | null,
    recurrenceRule: activityRecord.recurrence_rule,
    recurrenceExdates: activityRecord.recurrence_exdates
      ? activityRecord.recurrence_exdates.map((date: string) => new Date(date))
      : null,
    recurrenceDates: activityRecord.recurrence_dates
      ? activityRecord.recurrence_dates.map((date: string) => new Date(date))
      : null,
    recurrence: null,
    occurrence: null,
    meta: activityRecord.meta as ActivityMeta | null,
    tags: activityRecord.tags as Partial<Record<number, ActorId[]>> | null,
    mentions: (activityRecord.mentions as ActorId[]) || null,
  };
}
