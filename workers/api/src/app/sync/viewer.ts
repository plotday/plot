import type { Kysely } from "kysely";

import type { DB } from "../../db-types";

type TagRow = { id: string | null; tags: unknown };
type RowType = "thread" | "note";

/**
 * Filter tag actor IDs for threads with announce topics.
 *
 * For each row whose thread has an announce topic in `thread.topics`, drop
 * any tag actor whose only relationship to the thread is announce-topic
 * membership. An actor is visible iff:
 *   - in `thread.contacts`, or
 *   - a member of any non-announce topic in `thread.topics`, or
 *   - one of the requesting user's linked contacts.
 *
 * For apiVersion >= 2 the original count is preserved by replacing the
 * actor array with `{ c: total, a: visibleIds }`. Older clients lose the
 * count but identities still stay private.
 *
 * Mutates rows in place. Skips rows without an announce topic.
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

  type ThreadInfo = { contacts: string[]; topics: string[] };
  const rowToThread = new Map<string, ThreadInfo>();

  if (type === "thread") {
    const threads = await db
      .selectFrom("thread")
      .select(["id", "contacts", "topics"])
      .where("id", "in", rowIds)
      .execute();
    for (const t of threads) {
      rowToThread.set(t.id, {
        contacts: t.contacts ?? [],
        topics: t.topics ?? [],
      });
    }
  } else {
    const notes = await db
      .selectFrom("note")
      .innerJoin("thread", "thread.id", "note.thread_id")
      .select([
        "note.id",
        "thread.contacts",
        "thread.topics",
      ])
      .where("note.id", "in", rowIds)
      .execute();
    for (const n of notes) {
      rowToThread.set(n.id, {
        contacts: n.contacts ?? [],
        topics: n.topics ?? [],
      });
    }
  }

  const allTopicIds = new Set<string>();
  for (const info of rowToThread.values()) {
    for (const t of info.topics) allTopicIds.add(t);
  }
  if (allTopicIds.size === 0) return;

  const topicTypes = await db
    .selectFrom("topic")
    .select(["id", "type"])
    .where("id", "in", [...allTopicIds])
    .execute();

  const announceTopicIds = new Set<string>();
  for (const t of topicTypes) {
    if (t.type === "announce") announceTopicIds.add(t.id);
  }
  if (announceTopicIds.size === 0) return;

  const affectedRowIds = new Set<string>();
  const nonAnnounceTopicIds = new Set<string>();
  for (const [rowId, info] of rowToThread) {
    let hasAnnounce = false;
    for (const t of info.topics) {
      if (announceTopicIds.has(t)) {
        hasAnnounce = true;
      } else {
        nonAnnounceTopicIds.add(t);
      }
    }
    if (hasAnnounce) affectedRowIds.add(rowId);
  }
  if (affectedRowIds.size === 0) return;

  const topicMembers = new Map<string, Set<string>>();
  if (nonAnnounceTopicIds.size > 0) {
    const members = await db
      .selectFrom("topic_member")
      .select(["topic_id", "contact_id"])
      .where("topic_id", "in", [...nonAnnounceTopicIds])
      .execute();
    for (const m of members) {
      let set = topicMembers.get(m.topic_id);
      if (!set) {
        set = new Set();
        topicMembers.set(m.topic_id, set);
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
    for (const t of info.topics) {
      if (announceTopicIds.has(t)) continue;
      const members = topicMembers.get(t);
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
