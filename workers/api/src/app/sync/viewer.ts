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

// ---------------------------------------------------------------------------
// Hidden-role (BCC) contact filtering
// ---------------------------------------------------------------------------

/** One entry in a thread's `contact_meta` map (keyed by contact id). */
type ContactMetaEntry = {
  role?: string | null;
  addedBy?: string | null;
};

type HiddenRoleThreadRow = {
  id: string | null;
  contacts: string[] | null;
  // jsonb: { "<contactId>": { "role": "<roleId>", "addedBy": "<userId>" }, ... }
  contact_meta: unknown;
};

function parseContactMeta(
  value: unknown,
): Record<string, ContactMetaEntry> | null {
  if (value == null) return null;
  let obj: unknown = value;
  if (typeof value === "string") {
    try {
      obj = JSON.parse(value);
    } catch {
      return null;
    }
  }
  if (!obj || typeof obj !== "object" || Array.isArray(obj)) return null;
  return obj as Record<string, ContactMetaEntry>;
}

function parseLinkTypes(value: unknown): unknown[] {
  if (value == null) return [];
  let v: unknown = value;
  if (typeof value === "string") {
    try {
      v = JSON.parse(value);
    } catch {
      return [];
    }
  }
  return Array.isArray(v) ? v : [];
}

/** Collect `contactRoles[].id` flagged `hidden`, grouped by link type. */
function hiddenRolesByType(linkTypes: unknown[]): Map<string, Set<string>> {
  const out = new Map<string, Set<string>>();
  for (const lt of linkTypes) {
    if (!lt || typeof lt !== "object") continue;
    const type = (lt as { type?: unknown }).type;
    const roles = (lt as { contactRoles?: unknown }).contactRoles;
    if (typeof type !== "string" || !Array.isArray(roles)) continue;
    const hidden = new Set<string>();
    for (const r of roles) {
      if (
        r &&
        typeof r === "object" &&
        (r as { hidden?: unknown }).hidden === true &&
        typeof (r as { id?: unknown }).id === "string"
      ) {
        hidden.add((r as { id: string }).id);
      }
    }
    if (hidden.size > 0) out.set(type, hidden);
  }
  return out;
}

function linkTypesFromPermissions(permissions: unknown): unknown[] {
  if (!permissions || typeof permissions !== "object") return [];
  const providers = (permissions as { _providers?: unknown })._providers;
  if (!Array.isArray(providers)) return [];
  return providers.flatMap((p: unknown) =>
    p && typeof p === "object" && Array.isArray((p as { linkTypes?: unknown }).linkTypes)
      ? ((p as { linkTypes: unknown[] }).linkTypes)
      : [],
  );
}

/**
 * Pure core of the hidden-role filter. Given a thread's `contacts` and parsed
 * `contact_meta`, the set of role ids that are hidden for this thread, the
 * requesting user's own linked contact ids, and the user id, return the
 * contacts/meta with any hidden-role contact stripped — UNLESS the requesting
 * user is allowed to see it (they are the contact themselves, or they added
 * it). Exported for unit testing.
 */
export function computeHiddenRoleStrip(
  contacts: string[],
  meta: Record<string, ContactMetaEntry>,
  hiddenRoleIds: Set<string>,
  ownContacts: Set<string>,
  userId: string,
): { contacts: string[]; meta: Record<string, ContactMetaEntry>; changed: boolean } {
  const toHide = new Set<string>();
  for (const [contactId, entry] of Object.entries(meta)) {
    const role = entry && typeof entry === "object" ? entry.role : null;
    if (typeof role !== "string" || !hiddenRoleIds.has(role)) continue;
    const addedBy = entry.addedBy ?? null;
    // Keep the entry only for the contact themselves (the BCC recipient) or
    // the user who added them (the sender). Everyone else must not learn the
    // hidden recipient exists.
    const allowed = (addedBy != null && addedBy === userId) || ownContacts.has(contactId);
    if (!allowed) toHide.add(contactId);
  }
  if (toHide.size === 0) return { contacts, meta, changed: false };

  const newMeta: Record<string, ContactMetaEntry> = {};
  for (const [k, v] of Object.entries(meta)) {
    if (!toHide.has(k)) newMeta[k] = v;
  }
  const newContacts = contacts.filter((c) => !toHide.has(c));
  return { contacts: newContacts, meta: newMeta, changed: true };
}

/**
 * Strip BCC-style hidden-role recipients from threads for viewers who are not
 * allowed to see them. Mutates rows in place.
 *
 * Email and other `sharingModel: "message"` connectors declare `to`/`cc`/`bcc`
 * roles on their link type, with `bcc` marked `hidden`. A thread's
 * `contact_meta` records each contact's role and the user who added it. The
 * `user.thread` view exposes the shared `contacts`/`contact_meta` to every
 * viewer, so without this filter a BCC recipient would be visible to the other
 * recipients — a privacy leak.
 *
 * For each hidden-role contact on a thread we keep the entry only when the
 * requesting user is either that contact (one of their linked contacts) or the
 * user who added it (the sender). For everyone else the contact is removed from
 * both `contacts` and `contact_meta`.
 *
 * Hidden role ids are resolved from the link type config — channel-level
 * (`channel.link_types`) first, falling back to the twist's
 * `permissions._providers[].linkTypes` — mirroring `link-tags.ts`.
 */
export async function stripHiddenRoleContactsFromThreads(
  db: Kysely<DB>,
  userId: string,
  rows: HiddenRoleThreadRow[],
): Promise<void> {
  if (rows.length === 0) return;

  // Only threads that actually carry a role-bearing contact_meta entry can be
  // affected. The common case (empty `{}`) short-circuits here with no queries.
  const candidates: Array<{
    row: HiddenRoleThreadRow;
    meta: Record<string, ContactMetaEntry>;
  }> = [];
  for (const row of rows) {
    if (!row.id) continue;
    const meta = parseContactMeta(row.contact_meta);
    if (!meta) continue;
    let hasRole = false;
    for (const v of Object.values(meta)) {
      if (v && typeof v === "object" && typeof v.role === "string") {
        hasRole = true;
        break;
      }
    }
    if (hasRole) candidates.push({ row, meta });
  }
  if (candidates.length === 0) return;

  const threadIds = candidates.map((c) => c.row.id as string);

  const links = await db
    .selectFrom("link")
    .select(["thread_id", "type", "channel_id", "created_by"])
    .where("thread_id", "in", threadIds)
    .where("created_by", "is not", null)
    .execute();
  if (links.length === 0) return;

  const tiids = new Set<string>();
  const channelIds = new Set<string>();
  for (const l of links) {
    if (l.created_by) tiids.add(l.created_by);
    if (l.channel_id) channelIds.add(l.channel_id);
  }

  // Channel-level link types: hidden roles keyed by "<tiid>\0<channelId>".
  const channelHidden = new Map<string, Map<string, Set<string>>>();
  if (channelIds.size > 0 && tiids.size > 0) {
    const channels = await db
      .selectFrom("channel")
      .select(["twist_instance_id", "channel_id", "link_types"])
      .where("twist_instance_id", "in", [...tiids])
      .where("channel_id", "in", [...channelIds])
      .execute();
    for (const ch of channels) {
      const map = hiddenRolesByType(parseLinkTypes(ch.link_types));
      if (map.size > 0) {
        channelHidden.set(`${ch.twist_instance_id} ${ch.channel_id}`, map);
      }
    }
  }

  // Twist-level fallback: hidden roles keyed by twist_instance id.
  const twistHidden = new Map<string, Map<string, Set<string>>>();
  if (tiids.size > 0) {
    const twists = await db
      .selectFrom("twist_instance")
      .innerJoin("twist", "twist.id", "twist_instance.twist_id")
      .select(["twist_instance.id as id", "twist.permissions as permissions"])
      .where("twist_instance.id", "in", [...tiids])
      .execute();
    for (const t of twists) {
      const map = hiddenRolesByType(linkTypesFromPermissions(t.permissions));
      if (map.size > 0) twistHidden.set(t.id, map);
    }
  }

  if (channelHidden.size === 0 && twistHidden.size === 0) return;

  // Union hidden role ids across each thread's links.
  const threadHidden = new Map<string, Set<string>>();
  for (const l of links) {
    if (!l.thread_id || !l.type || !l.created_by) continue;
    const perType =
      (l.channel_id
        ? channelHidden.get(`${l.created_by} ${l.channel_id}`)
        : undefined) ?? twistHidden.get(l.created_by);
    const hidden = perType?.get(l.type);
    if (!hidden || hidden.size === 0) continue;
    let set = threadHidden.get(l.thread_id);
    if (!set) {
      set = new Set();
      threadHidden.set(l.thread_id, set);
    }
    for (const id of hidden) set.add(id);
  }
  if (threadHidden.size === 0) return;

  // The requesting user's own linked contacts — always visible to them.
  const ownContacts = new Set<string>();
  const own = await db
    .selectFrom("user_contact")
    .select("contact_id")
    .where("user_id", "=", userId)
    .where("linked", "=", true)
    .where("archived_at", "is", null)
    .execute();
  for (const r of own) ownContacts.add(r.contact_id);

  for (const { row, meta } of candidates) {
    const hidden = threadHidden.get(row.id as string);
    if (!hidden || hidden.size === 0) continue;
    const result = computeHiddenRoleStrip(
      row.contacts ?? [],
      meta,
      hidden,
      ownContacts,
      userId,
    );
    if (!result.changed) continue;
    row.contacts = result.contacts;
    row.contact_meta = result.meta;
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
