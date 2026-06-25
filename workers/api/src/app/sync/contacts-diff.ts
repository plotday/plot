// Pure diff over a thread's contact membership, used to dispatch the
// connector `onContactsChanged` callback. Both the `/sync/threads` upsert and
// the `/thread/:id/share` endpoint snapshot the persisted thread before and
// after their mutation and run this over the two snapshots, so the diff is
// correct regardless of which endpoint made the change and regardless of
// partial (additively-merged) `contact_meta` payloads.

export type ContactsSnapshot = {
  /** thread.contacts — every contact on the thread. */
  contacts: string[];
  /**
   * thread.dropped_contacts — message-mode soft-removed contacts. Always a
   * subset of `contacts`; excluded from the active recipient set.
   */
  droppedContacts: string[];
  /** thread.contact_meta — `{ "<contactId>": { role?, addedBy? } }`. */
  contactMeta: Record<string, unknown>;
};

export type ContactsDiff = {
  added: Array<{ contactId: string; role: string | null }>;
  removed: Array<{ contactId: string; role: string | null }>;
  changed: Array<{ contactId: string; from: string | null; to: string | null }>;
};

/** Resolve a contact's role from contact_meta, or null when absent/malformed. */
function roleOf(meta: Record<string, unknown>, id: string): string | null {
  const entry = meta[id];
  if (entry && typeof entry === "object" && !Array.isArray(entry)) {
    const role = (entry as { role?: unknown }).role;
    if (typeof role === "string") return role;
  }
  return null;
}

/** The contacts a connector treats as active members: contacts − dropped. */
function effectiveMembers(s: ContactsSnapshot): Set<string> {
  const dropped = new Set(s.droppedContacts);
  const members = new Set<string>();
  for (const id of s.contacts) {
    if (!dropped.has(id)) members.add(id);
  }
  return members;
}

/**
 * Compute the membership/role diff between two thread snapshots. Ordering is
 * deterministic: additions/role-changes follow `next.contacts` order, removals
 * follow `prev.contacts` order.
 */
export function computeContactsDiff(
  prev: ContactsSnapshot,
  next: ContactsSnapshot,
): ContactsDiff {
  const prevMembers = effectiveMembers(prev);
  const nextMembers = effectiveMembers(next);

  const added: ContactsDiff["added"] = [];
  const seenAdded = new Set<string>();
  for (const id of next.contacts) {
    if (nextMembers.has(id) && !prevMembers.has(id) && !seenAdded.has(id)) {
      seenAdded.add(id);
      added.push({ contactId: id, role: roleOf(next.contactMeta, id) });
    }
  }

  const removed: ContactsDiff["removed"] = [];
  const seenRemoved = new Set<string>();
  for (const id of prev.contacts) {
    if (prevMembers.has(id) && !nextMembers.has(id) && !seenRemoved.has(id)) {
      seenRemoved.add(id);
      removed.push({ contactId: id, role: roleOf(prev.contactMeta, id) });
    }
  }

  const changed: ContactsDiff["changed"] = [];
  const seenChanged = new Set<string>();
  for (const id of next.contacts) {
    if (prevMembers.has(id) && nextMembers.has(id) && !seenChanged.has(id)) {
      const from = roleOf(prev.contactMeta, id);
      const to = roleOf(next.contactMeta, id);
      if (from !== to) {
        seenChanged.add(id);
        changed.push({ contactId: id, from, to });
      }
    }
  }

  return { added, removed, changed };
}

/**
 * The contactIds that became active members in `next` and were not active
 * members before — the candidates for an invitation email.
 *
 * A `null` `prev` means a brand-new thread (no server-side row existed before
 * this save), so every active member of `next` is newly added. Re-saving a
 * thread with unchanged membership yields an empty list, which is what keeps
 * routine saves (title edits, priority moves, marking read) from re-inviting
 * contacts already on the thread.
 *
 * Membership-only (role changes and removals are ignored); ordering follows
 * `next.contacts`. Self/linked/non-inviteable filtering is the caller's job —
 * this is a pure set diff over effective membership.
 */
export function newlyAddedMemberIds(
  prev: ContactsSnapshot | null,
  next: ContactsSnapshot,
): string[] {
  if (!prev) {
    return [...effectiveMembers(next)];
  }
  return computeContactsDiff(prev, next).added.map((a) => a.contactId);
}
