import {
  type Thread,
  type Action,
  type ActorId,
  ActorType,
  type Note,
  type Uuid,
} from "@plotday/twister/plot";

import type { EnrichedThread, EnrichedNote } from "../../view-types";

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
 * Converts a database thread record into a Thread object.
 */
export function buildThreadFromDbRecord(
  threadRecord: EnrichedThread
): Thread {
  return {
    // @ts-ignore - threadRecord.id is a string from DB, but Uuid is a branded type
    id: threadRecord.id as any,
    created: threadRecord.created_at ? new Date(threadRecord.created_at) : new Date(),
    priority: {
      id: threadRecord.priority_id as Uuid,
      title: threadRecord.priority_title ?? "",
      archived: false,
      key: null,
      color: null,
    },
    title: threadRecord.title || "",
    private: threadRecord.private ?? false,
    archived: threadRecord.archived_at !== null,
    tags: (threadRecord.tags as Partial<Record<number, ActorId[]>>) || {},
    mentions: (threadRecord.mentions as ActorId[]) || [],
  };
}

/** @deprecated Use buildThreadFromDbRecord */
export const buildActivityFromDbRecord = buildThreadFromDbRecord;

/**
 * Converts a database note record into a Note object.
 * Note: The thread field only contains minimal data (id and priority) since the full thread
 * is not included in enriched note views. This is sufficient for intent handlers.
 */
export function buildNoteFromDbRecord(noteRecord: EnrichedNote): Note {
  return {
    // @ts-ignore - noteRecord.id is a string from DB, but Uuid is a branded type
    id: noteRecord.id as any,
    created: noteRecord.created_at ? new Date(noteRecord.created_at) : new Date(),
    // @ts-ignore - Partial Thread data from NoteItem payload
    thread: {
      id: noteRecord.thread_id,
      priority: {
        id: noteRecord.priority_id,
      },
      // Include meta if available in payload (for note.created callbacks)
      ...(noteRecord.thread_meta && { meta: noteRecord.thread_meta }),
    } as unknown as Thread,
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
    actions: noteRecord.actions as Array<Action> | null,
  };
}
