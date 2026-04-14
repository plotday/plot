import type { Kysely } from "kysely";

import type { DB } from "../../db-types";

const COUNT_TAG_MIN = 1000;

/**
 * Stub: viewer role is removed in the per-user priority model.
 * Always returns null (no viewer priorities).
 */
async function getViewerPriorityIds(
  _db: Kysely<DB>,
  _userId: string
): Promise<Set<string> | null> {
  return null;
}

/**
 * Get the contact IDs of members on the given priorities, plus the requesting
 * user's own contact ID. Members are a small set; viewers can be very large.
 * Returns a map of priorityId → Set<allowedContactId>.
 */
async function getAllowedActorsByPriority(
  db: Kysely<DB>,
  userId: string,
  viewerPriorityIds: Set<string>
): Promise<Map<string, Set<string>>> {
  const priorityIdArray = [...viewerPriorityIds];

  // Get the requesting user's own contact ID
  const selfContact = await db
    .selectFrom("contact")
    .select("id")
    .where("user_id", "=", userId)
    .where("primary", "=", true)
    .executeTakeFirst();

  const selfContactId = selfContact?.id;

  // In the per-user priority model, all priorities are owned by the user —
  // there are no shared "member" contacts to enumerate.
  const memberContacts: { contact_id: string; priority_id: string }[] = [];

  // Build priorityId → Set<allowedContactId>
  const result = new Map<string, Set<string>>();
  for (const priorityId of priorityIdArray) {
    const allowed = new Set<string>();
    if (selfContactId) allowed.add(selfContactId);
    result.set(priorityId, allowed);
  }
  for (const row of memberContacts) {
    const allowed = result.get(row.priority_id as string);
    if (allowed) allowed.add(row.contact_id);
  }

  return result;
}

/**
 * Strip count tag actor IDs for rows under viewer priorities.
 * Filters to allowed actors (members + self). For apiVersion >= 2,
 * replaces arrays with { c: totalCount, a: filteredActors }.
 * Mutates rows in place.
 */
function stripTags(
  rows: { id: string | null; tags: unknown }[],
  viewerRowIds: Set<string>,
  rowIdToAllowedActors: Map<string, Set<string>>,
  apiVersion: number
): void {
  for (const row of rows) {
    if (!row.id || !row.tags || !viewerRowIds.has(row.id)) continue;

    const allowed = rowIdToAllowedActors.get(row.id);
    if (!allowed) continue;

    const tags = row.tags as Record<string, unknown>;
    for (const [tagId, actorIds] of Object.entries(tags)) {
      if (Number(tagId) >= COUNT_TAG_MIN && Array.isArray(actorIds)) {
        const filtered = actorIds.filter((id: string) => allowed.has(id));
        if (apiVersion >= 2) {
          tags[tagId] = { c: actorIds.length, a: filtered };
        } else {
          tags[tagId] = filtered;
        }
      }
    }
  }
}

/**
 * Strip actor IDs from count tags for thread/note tag rows under viewer priorities.
 * Looks up thread -> priority_id to determine which rows are viewer.
 * Mutates rows in place. No-op if user has no viewer priorities.
 */
export async function stripCountTagActors(
  db: Kysely<DB>,
  userId: string,
  rows: { id: string | null; tags: unknown }[],
  type: "thread" | "note" = "thread",
  apiVersion: number = 0
): Promise<void> {
  if (rows.length === 0) return;

  const viewerPriorityIds = await getViewerPriorityIds(db, userId);
  if (!viewerPriorityIds) return;

  const rowIds = rows.map((r) => r.id).filter((id): id is string => id != null);
  if (rowIds.length === 0) return;

  let idToPriority: Map<string, string>;

  if (type === "thread") {
    const threads = await db
      .selectFrom("thread_priority")
      .select(["thread_id as id", "priority_id"])
      .where("thread_id", "in", rowIds)
      .where("user_id", "=", userId)
      .execute();
    idToPriority = new Map(threads.map((t) => [t.id, t.priority_id]));
  } else {
    // note: look up note -> thread_priority -> priority_id
    const notes = await db
      .selectFrom("note")
      .innerJoin("thread_priority", "thread_priority.thread_id", "note.thread_id")
      .select(["note.id", "thread_priority.priority_id"])
      .where("note.id", "in", rowIds)
      .where("thread_priority.user_id", "=", userId)
      .execute();
    idToPriority = new Map(notes.map((n) => [n.id, n.priority_id]));
  }

  const viewerRowIds = new Set<string>();
  for (const [rowId, priorityId] of idToPriority) {
    if (viewerPriorityIds.has(priorityId)) {
      viewerRowIds.add(rowId);
    }
  }

  if (viewerRowIds.size === 0) return;

  // Look up allowed actor IDs (members + self) per priority
  const allowedByPriority = await getAllowedActorsByPriority(db, userId, viewerPriorityIds);

  // Map row IDs to their allowed actors set
  const rowIdToAllowedActors = new Map<string, Set<string>>();
  for (const rowId of viewerRowIds) {
    const priorityId = idToPriority.get(rowId);
    if (priorityId) {
      const allowed = allowedByPriority.get(priorityId);
      if (allowed) rowIdToAllowedActors.set(rowId, allowed);
    }
  }

  stripTags(rows, viewerRowIds, rowIdToAllowedActors, apiVersion);
}
