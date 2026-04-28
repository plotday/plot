import type { Kysely } from "kysely";

import type { DB } from "../../db-types";

type TagRow = { id: string | null; tags: unknown };
type ThreadRow = {
  id: string | null;
  contacts: string[] | null;
  groups: string[] | null;
};
type RowType = "thread" | "note";

type ThreadVisibility = {
  contacts: string[];
  groups: string[];
  // Actor IDs the requesting user is allowed to see for this thread.
  // Includes: their own linked contacts; thread.contacts minus members of
  // announce groups (where the user is not an admin); members of any
  // non-announce group on the thread.
  visible: Set<string>;
  // True iff the thread has at least one announce group where the user is
  // not an admin — i.e. there is something to filter.
  hasHiddenAnnounce: boolean;
};

/**
 * For a set of thread IDs, load the visibility info needed to filter
 * contacts and tag actors for the requesting user.
 *
 * Returns `null` if no thread has an announce-group restriction for this
 * user; callers can short-circuit and skip filtering entirely.
 */
async function loadThreadVisibility(
  db: Kysely<DB>,
  userId: string,
  threadIds: string[],
): Promise<Map<string, ThreadVisibility> | null> {
  if (threadIds.length === 0) return null;

  const threads = await db
    .selectFrom("thread")
    .select(["id", "contacts", "groups"])
    .where("id", "in", threadIds)
    .execute();
  if (threads.length === 0) return null;

  const allGroupIds = new Set<string>();
  for (const t of threads) {
    for (const g of t.groups ?? []) allGroupIds.add(g);
  }
  if (allGroupIds.size === 0) return null;

  const groupRows = await db
    .selectFrom("group")
    .select(["id", "type"])
    .where("id", "in", [...allGroupIds])
    .execute();
  const groupType = new Map<string, string>();
  for (const g of groupRows) groupType.set(g.id, g.type);

  const announceGroupIds = new Set<string>();
  for (const [id, type] of groupType) {
    if (type === "announce") announceGroupIds.add(id);
  }

  // Exclude announce groups where the user is an admin — admins see full
  // membership, so there's nothing to hide for them on those threads.
  if (announceGroupIds.size > 0) {
    const adminRows = await db
      .selectFrom("group_admin")
      .select("group_id")
      .where("user_id", "=", userId)
      .where("group_id", "in", [...announceGroupIds])
      .execute();
    for (const r of adminRows) announceGroupIds.delete(r.group_id);
  }

  // Build per-thread group membership requirements.
  const nonAnnounceGroupIds = new Set<string>();
  const announceMemberGroupIds = new Set<string>();
  let anyHiddenAnnounce = false;
  for (const t of threads) {
    for (const g of t.groups ?? []) {
      const type = groupType.get(g);
      if (type && type !== "announce") {
        nonAnnounceGroupIds.add(g);
      } else if (announceGroupIds.has(g)) {
        announceMemberGroupIds.add(g);
        anyHiddenAnnounce = true;
      }
    }
  }
  if (!anyHiddenAnnounce && nonAnnounceGroupIds.size === 0) return null;

  // Members of every group we'll need.
  const groupMembers = new Map<string, Set<string>>();
  const memberQueryIds = [
    ...new Set([...announceMemberGroupIds, ...nonAnnounceGroupIds]),
  ];
  if (memberQueryIds.length > 0) {
    const members = await db
      .selectFrom("group_member")
      .select(["group_id", "contact_id"])
      .where("group_id", "in", memberQueryIds)
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

  // The requesting user's own linked contacts — always visible to them.
  const ownContacts = new Set<string>();
  const userContacts = await db
    .selectFrom("user_contact")
    .select("contact_id")
    .where("user_id", "=", userId)
    .where("linked", "=", true)
    .where("archived_at", "is", null)
    .execute();
  for (const c of userContacts) ownContacts.add(c.contact_id);

  const out = new Map<string, ThreadVisibility>();
  for (const t of threads) {
    const contacts = t.contacts ?? [];
    const groups = t.groups ?? [];

    // Hidden contacts: members of any announce group on the thread where
    // the user is not an admin, with the user's own contacts excluded.
    const hidden = new Set<string>();
    let hasHiddenAnnounce = false;
    for (const g of groups) {
      if (!announceGroupIds.has(g)) continue;
      hasHiddenAnnounce = true;
      const members = groupMembers.get(g);
      if (!members) continue;
      for (const m of members) {
        if (!ownContacts.has(m)) hidden.add(m);
      }
    }

    const visible = new Set<string>(ownContacts);
    for (const c of contacts) {
      if (!hidden.has(c)) visible.add(c);
    }
    for (const g of groups) {
      if (announceGroupIds.has(g)) continue;
      const members = groupMembers.get(g);
      if (members) for (const m of members) visible.add(m);
    }

    out.set(t.id, { contacts, groups, visible, hasHiddenAnnounce });
  }
  return out;
}

/**
 * Strip thread.contacts down to the contacts the requesting user is
 * allowed to see, hiding members of any announce group on the thread
 * (unless the user is an admin of that group). Mutates rows in place.
 */
export async function stripAnnounceContactsFromThreads(
  db: Kysely<DB>,
  userId: string,
  rows: ThreadRow[],
): Promise<void> {
  if (rows.length === 0) return;
  const threadIds = rows
    .map((r) => r.id)
    .filter((id): id is string => id != null);
  const visibility = await loadThreadVisibility(db, userId, threadIds);
  if (!visibility) return;

  for (const row of rows) {
    if (!row.id || !row.contacts) continue;
    const info = visibility.get(row.id);
    if (!info || !info.hasHiddenAnnounce) continue;
    row.contacts = row.contacts.filter((c) => info.visible.has(c));
  }
}

/**
 * Filter tag actor IDs for threads with announce groups.
 *
 * For each row whose thread has an announce group in `thread.groups`
 * (and the user isn't an admin of it), drop any tag actor that isn't
 * visible to the requesting user. An actor is visible iff it is one of
 * the user's own linked contacts, a non-hidden contact in
 * `thread.contacts`, or a member of a non-announce group on the thread.
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

  // Map each row id to the underlying thread id.
  const rowToThread = new Map<string, string>();
  if (type === "thread") {
    for (const id of rowIds) rowToThread.set(id, id);
  } else {
    const notes = await db
      .selectFrom("note")
      .select(["id", "thread_id"])
      .where("id", "in", rowIds)
      .execute();
    for (const n of notes) rowToThread.set(n.id, n.thread_id);
  }

  const threadIds = [...new Set(rowToThread.values())];
  const visibility = await loadThreadVisibility(db, userId, threadIds);
  if (!visibility) return;

  for (const row of rows) {
    if (!row.id || !row.tags) continue;
    const threadId = rowToThread.get(row.id);
    if (!threadId) continue;
    const info = visibility.get(threadId);
    if (!info || !info.hasHiddenAnnounce) continue;

    const tags = row.tags as Record<string, unknown>;
    for (const [tagId, actorIds] of Object.entries(tags)) {
      if (!Array.isArray(actorIds)) continue;
      const original = actorIds as string[];
      const filtered = original.filter((id) => info.visible.has(id));
      if (filtered.length === original.length) continue;
      if (apiVersion >= 2) {
        tags[tagId] = { c: original.length, a: filtered };
      } else {
        tags[tagId] = filtered;
      }
    }
  }
}
