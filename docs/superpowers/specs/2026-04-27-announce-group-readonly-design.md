# Read-only thread access via announce groups — design

## Goal

A user whose access to a thread is exclusively via membership in an
announce-typed group should not be able to write to the thread or its
notes, except for adding *private* notes that they author. Their
"archive" action becomes per-user, leaving the thread visible for other
members.

The trigger for this work is the onboarding "Welcome" thread, which is
shared with the workspace "Everyone" announce group. Any team member
viewing it could overwrite the title, icon, or notes for everybody.

## Definitions

A user has **write access** to a thread iff *any* of:

1. One of their linked contacts is in `thread.contacts`.
2. They are a member (via any linked contact) of any non-announce group
   in `thread.groups`.
3. They are an admin of any announce group in `thread.groups`.

If none apply, they are a **read-only viewer**.

The DB function `public.user_has_thread_write_access(user_id, thread_id)`
is the single source of truth.

## Server changes

### `public.user_has_thread_write_access` (new helper)

Returns `boolean`. Lives in `libs/db/schema/60-functions/`.

### `user.upsert_thread` (modified)

After resolving `v_existing` on the UPDATE path (i.e. the row already
exists), evaluate write access. If the caller lacks write access:

* If the only mutated field is `archived_at` (or `archived_at` together
  with no-op fields equal to existing values), route to per-user
  archive: update `thread_priority.archived_at` for `(user_id,
  thread_id)`. Do not mutate `thread.*`. Return the unchanged thread row.
* Otherwise, raise: `User does not have write access to thread`.

The INSERT path is unchanged — the creator is always trusted.

### `user.upsert_note` (modified)

When the caller is a user (not a twist) and lacks write access to
`p_thread_id`:

* Reject if updating an existing note authored by someone else.
* Force `p_access_contacts IS NOT NULL`. If NULL, raise.
* Reject if `p_access_contacts` contains contacts that are not in
  `thread.contacts ∪ members of non-announce groups in thread.groups`,
  the user's own linked contacts excepted.

Note tag and group-share validation already enforce ownership at the
trigger level (count tags, etc.) — no change needed for those paths.

## Client changes (Flutter, local-first)

### `Thread.isReadOnly` getter

Computed from cached state:

```
bool get isReadOnly {
  final selfIds = Actor.getCurrentUserActorIds().toUuids();
  if (contacts.any(selfIds.contains)) return false;
  for (final groupId in groups ?? const []) {
    final g = Group.fromCache(groupId);
    if (g == null) continue;
    if (g.type == 'announce') {
      if (g.isAdmin) return false;
    } else if (g.isMember) {
      return false;
    }
  }
  return true;
}
```

### Command and UI gating

When `thread.isReadOnly`, hide / suppress:

* Edit thread (title/icon/sub-type), in header and menu
* Rename, change icon, set sub-type
* Add to group / share thread
* Edit/delete other users' notes

Keep available:

* Per-user filing (move to priority)
* Mark read/unread, RSVP, todo/done count tags (server already filters
  identities)
* Pin

### Archive

`ArchiveThread` calls `thread.copyWith(archivedAt: ...).save()` as
today; the existing wire path (`POST /sync/threads`) is reused. The
server detects read-only and routes the archive to per-user
(`thread_priority.archived_at`). The local optimistic update is the
combined `archivedAt` value (already what the local schema stores), so
no client-side branching is required for archive.

### NoteEditor

Pass `viewerMode: thread.isReadOnly || thread.priority.isViewer` so the
toolbar collapses and notes default to private.

The default `accessContacts` for a read-only-viewer note must be
`thread.contacts ∪ members of non-announce groups in thread.groups`
(plus the user's own linked contacts), not self-only as today.

### Share-target picker for notes

When `thread.isReadOnly`, hide announce groups from the picker. The
user cannot share a note with the announce group they're a member of.
Their default selection includes all `thread.contacts` and all
non-announce groups in `thread.groups`, but they may explicitly narrow
that subset.

## Edge cases

* User in `thread.contacts` AND member of an announce group → write
  access (rule 1).
* Announce group admin → write access (matches existing
  `share_thread.sql` policy).
* Self-archive then later added to `thread.contacts` → per-user
  `thread_priority.archived_at` persists; user must un-archive
  manually. Acceptable.
* Twists/connectors writing to the thread (created_by != user_id) are
  unaffected — they have their own permission model.
* Existing notes by read-only viewers (predating this change) are not
  retroactively touched; only new writes are validated.

## Out of scope

* Announce-group admin moderating viewers' notes
* Notification-digest changes for read-only viewers
* Bulk un-archive / migration of existing threads
