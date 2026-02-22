import {
  type Activity,
  type Link,
  type ActivityMeta,
  ActivityType,
  type ActivityKind,
  type ActorId,
  ActorType,
  type Note,
  type Uuid,
} from "@plotday/twister/plot";

import type { EnrichedActivity, EnrichedNote } from "../../view-types";

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
  activityRecord: EnrichedActivity
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

  return {
    // @ts-ignore - activityRecord.id is a string from DB, but Uuid is a branded type
    id: activityRecord.id as any,
    type: activityType,
    kind: (activityRecord as any).kind as ActivityKind | null ?? null,
    created: activityRecord.created_at ? new Date(activityRecord.created_at) : new Date(),
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
      id: activityRecord.priority_id as Uuid,
      title: activityRecord.priority_title ?? "",
      archived: false,
      key: null,
      color: null,
    },
    start: parseRangeStart(activityRecord.on as string | null, activityRecord.at as string | null),
    end: parseRangeEnd(activityRecord.on as string | null, activityRecord.at as string | null),
    recurrenceUntil: null,
    recurrenceCount: null,
    done: activityRecord.done_at ? new Date(activityRecord.done_at) : null,
    title: activityRecord.title || "",
    assignee: activityRecord.assignee_id
      ? {
          id: activityRecord.assignee_id as ActorId,
          name: null, // Not enriched in database view
          type: ActorType.User, // Default type, not enriched in database view
        }
      : null,
    private: activityRecord.private ?? false,
    archived: activityRecord.archived_at !== null,
    recurrenceRule: activityRecord.recurrence_rule,
    recurrenceExdates: activityRecord.recurrence_exdates
      ? activityRecord.recurrence_exdates.map((date: string) => new Date(date))
      : null,
    meta: activityRecord.meta as ActivityMeta | null,
    order: (activityRecord as any).order ?? 0,
    links: (activityRecord as any).links as Link[] | null ?? null,
    source: activityRecord.source || null,
    tags: (activityRecord.tags as Partial<Record<number, ActorId[]>>) || {},
    mentions: (activityRecord.mentions as ActorId[]) || [],
  };
}

/**
 * Converts a database note record into a Note object.
 * Note: The activity field only contains minimal data (id and priority) since the full activity
 * is not included in enriched note views. This is sufficient for intent handlers.
 */
export function buildNoteFromDbRecord(noteRecord: EnrichedNote): Note {
  return {
    // @ts-ignore - noteRecord.id is a string from DB, but Uuid is a branded type
    id: noteRecord.id as any,
    created: noteRecord.created_at ? new Date(noteRecord.created_at) : new Date(),
    // @ts-ignore - Partial Activity data from NoteItem payload
    activity: {
      id: noteRecord.activity_id,
      priority: {
        id: noteRecord.priority_id,
      },
      // Include meta if available in payload (for note.created callbacks)
      ...(noteRecord.activity_meta && { meta: noteRecord.activity_meta }),
    } as unknown as Activity,
    author: {
      id: (noteRecord.author_id ?? noteRecord.created_by) as ActorId,
      name: noteRecord.author_name,
      type:
        noteRecord.author_type === "user"
          ? ActorType.User
          : noteRecord.author_type === "priority_twist"
          ? ActorType.Twist
          : ActorType.Contact,
    },
    content: noteRecord.content,
    key: noteRecord.key || null,
    reNote: noteRecord.re_note_id ? { id: noteRecord.re_note_id as Uuid } : null,
    mentions: (noteRecord.mentions as ActorId[]) || [],
    tags: (noteRecord.tags as Partial<Record<number, ActorId[]>>) || {},
    private: noteRecord.private ?? false,
    archived: noteRecord.archived_at !== null,
    links: noteRecord.links as Array<Link> | null,
  };
}
