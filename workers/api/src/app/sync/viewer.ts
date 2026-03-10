import type { Kysely } from "kysely";

import type { DB } from "../../db-types";

const COUNT_TAG_MIN = 1000;

/**
 * Get the set of viewer priority IDs for a user, or null if the user has none.
 * Uses early exit on priority_user before querying priority_expanded.
 */
async function getViewerPriorityIds(
  db: Kysely<DB>,
  userId: string
): Promise<Set<string> | null> {
  const hasViewer = await db
    .selectFrom("priority_user")
    .select("priority_id")
    .where("user_id", "=", userId)
    .where("role", "=", "viewer")
    .where("archived_at", "is", null)
    .limit(1)
    .executeTakeFirst();

  if (!hasViewer) return null;

  // Get effective viewer priority IDs (most-permissive-wins already computed)
  const viewerPriorities = await db
    .selectFrom("user.priority_expanded" as any)
    .select("priority_id")
    .where("user_id", "=", userId)
    .where("role", "=", "viewer")
    .where("archived_at", "is", null)
    .execute();

  if (viewerPriorities.length === 0) return null;

  return new Set(viewerPriorities.map((r: any) => r.priority_id).filter((id: any): id is string => id != null));
}

/**
 * Strip count tag actor IDs for rows under viewer priorities.
 * Replaces actor UUID arrays with null arrays (preserves count, hides identity).
 * Mutates rows in place.
 */
function stripTags(
  rows: { id: string | null; tags: unknown }[],
  viewerRowIds: Set<string>
): void {
  for (const row of rows) {
    if (!row.id || !row.tags || !viewerRowIds.has(row.id)) continue;

    const tags = row.tags as Record<string, unknown>;
    for (const [tagId, actorIds] of Object.entries(tags)) {
      if (Number(tagId) >= COUNT_TAG_MIN && Array.isArray(actorIds)) {
        tags[tagId] = actorIds.map(() => null);
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
  type: "thread" | "note" = "thread"
): Promise<void> {
  if (rows.length === 0) return;

  const viewerPriorityIds = await getViewerPriorityIds(db, userId);
  if (!viewerPriorityIds) return;

  const rowIds = rows.map((r) => r.id).filter((id): id is string => id != null);
  if (rowIds.length === 0) return;

  let idToPriority: Map<string, string>;

  if (type === "thread") {
    const threads = await db
      .selectFrom("thread")
      .select(["id", "priority_id"])
      .where("id", "in", rowIds)
      .execute();
    idToPriority = new Map(threads.map((t) => [t.id, t.priority_id]));
  } else {
    // note: look up note -> thread -> priority_id
    const notes = await db
      .selectFrom("note")
      .innerJoin("thread", "thread.id", "note.thread_id")
      .select(["note.id", "thread.priority_id"])
      .where("note.id", "in", rowIds)
      .execute();
    idToPriority = new Map(notes.map((n) => [n.id, n.priority_id]));
  }

  const viewerRowIds = new Set<string>();
  for (const [rowId, priorityId] of idToPriority) {
    if (viewerPriorityIds.has(priorityId)) {
      viewerRowIds.add(rowId);
    }
  }

  if (viewerRowIds.size > 0) {
    stripTags(rows, viewerRowIds);
  }
}
