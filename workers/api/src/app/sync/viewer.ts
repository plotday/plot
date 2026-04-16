import type { Kysely } from "kysely";

import type { DB } from "../../db-types";

type TagRow = { id: string | null; tags: unknown };
type RowType = "thread" | "note";

/**
 * Filter tag actor IDs for threads with announce groups.
 *
 * For each row whose thread has an announce group in `thread.groups`, drop
 * any tag actor whose only relationship to the thread is announce-group
 * membership. An actor is visible iff:
 *   - in `thread.contacts`, or
 *   - a member of any non-announce group in `thread.groups`, or
 *   - one of the requesting user's linked contacts.
 *
 * For apiVersion >= 2 the original count is preserved by replacing the
 * actor array with `{ c: total, a: visibleIds }`. Older clients lose the
 * count but identities still stay private.
 *
 * Mutates rows in place. Skips rows without an announce group.
 */
export async function stripAnnounceTagActors(
  db: Kysely<DB>,
  userId: string,
  rows: TagRow[],
  type: RowType = "thread",
  apiVersion: number = 0,
): Promise<void> {
  if (rows.length === 0) return;

  const rowIds = rows.map((r) => r.id).filter((id): id is string => id != null);
  if (rowIds.length === 0) return;

  type ThreadInfo = { contacts: string[]; groups: string[] };
  const rowToThread = new Map<string, ThreadInfo>();

  if (type === "thread") {
    const threads = await db
      .selectFrom("thread")
      .select(["id", "contacts", "groups"])
      .where("id", "in", rowIds)
      .execute();
    for (const t of threads) {
      rowToThread.set(t.id, {
        contacts: t.contacts ?? [],
        groups: t.groups ?? [],
      });
    }
  } else {
    const notes = await db
      .selectFrom("note")
      .innerJoin("thread", "thread.id", "note.thread_id")
      .select([
        "note.id",
        "thread.contacts",
        "thread.groups",
      ])
      .where("note.id", "in", rowIds)
      .execute();
    for (const n of notes) {
      rowToThread.set(n.id, {
        contacts: n.contacts ?? [],
        groups: n.groups ?? [],
      });
    }
  }

  const allGroupIds = new Set<string>();
  for (const info of rowToThread.values()) {
    for (const g of info.groups) allGroupIds.add(g);
  }
  if (allGroupIds.size === 0) return;

  const groupTypes = await db
    .selectFrom("group")
    .select(["id", "type"])
    .where("id", "in", [...allGroupIds])
    .execute();

  const announceGroupIds = new Set<string>();
  for (const g of groupTypes) {
    if (g.type === "announce") announceGroupIds.add(g.id);
  }
  if (announceGroupIds.size === 0) return;

  const affectedRowIds = new Set<string>();
  const nonAnnounceGroupIds = new Set<string>();
  for (const [rowId, info] of rowToThread) {
    let hasAnnounce = false;
    for (const g of info.groups) {
      if (announceGroupIds.has(g)) {
        hasAnnounce = true;
      } else {
        nonAnnounceGroupIds.add(g);
      }
    }
    if (hasAnnounce) affectedRowIds.add(rowId);
  }
  if (affectedRowIds.size === 0) return;

  const groupMembers = new Map<string, Set<string>>();
  if (nonAnnounceGroupIds.size > 0) {
    const members = await db
      .selectFrom("group_member")
      .select(["group_id", "contact_id"])
      .where("group_id", "in", [...nonAnnounceGroupIds])
      .execute();
    for (const m of members) {
      let set = groupMembers.get(m.group_id);
      if (!set) {
        set = new Set();
        groupMembers.set(m.group_id, set);
      }
      set.add(m.contact_id);
    }
  }

  const ownContacts = new Set<string>();
  const userContacts = await db
    .selectFrom("user_contact")
    .select("contact_id")
    .where("user_id", "=", userId)
    .where("linked", "=", true)
    .where("archived_at", "is", null)
    .execute();
  for (const c of userContacts) ownContacts.add(c.contact_id);

  for (const row of rows) {
    if (!row.id || !row.tags || !affectedRowIds.has(row.id)) continue;
    const info = rowToThread.get(row.id);
    if (!info) continue;

    const visible = new Set<string>(ownContacts);
    for (const c of info.contacts) visible.add(c);
    for (const g of info.groups) {
      if (announceGroupIds.has(g)) continue;
      const members = groupMembers.get(g);
      if (members) for (const m of members) visible.add(m);
    }

    const tags = row.tags as Record<string, unknown>;
    for (const [tagId, actorIds] of Object.entries(tags)) {
      if (!Array.isArray(actorIds)) continue;
      const original = actorIds as string[];
      const filtered = original.filter((id) => visible.has(id));
      if (filtered.length === original.length) continue;
      if (apiVersion >= 2) {
        tags[tagId] = { c: original.length, a: filtered };
      } else {
        tags[tagId] = filtered;
      }
    }
  }
}
