# Thread & Note Visibility Redesign

## Context

Thread and note visibility currently uses a `private` boolean on both tables, combined with a `mentions` uuid[] array on notes that conflates user visibility with twist/connector dispatch routing. This has several problems:

- No way to set visibility on a thread with only a link and no notes
- Checking thread visibility requires querying notes (via `mentioned_in_thread()`)
- User visibility and twist/connector mentions are mixed in one field
- The `private` boolean is too coarse — can't specify exactly who should have access

This redesign replaces the boolean with a structured access model and separates user visibility from twist mentions.

## Database Schema

### Thread table

Remove:

- `private boolean NOT NULL DEFAULT FALSE`

Add:

- `access text NOT NULL DEFAULT 'members'` — values: `'public'`, `'members'`, `'restricted'`
- `access_contacts uuid[]` — contact_ids of additional users granted access

Access semantics:

| access     | access_contacts | who can see                   |
| ---------- | --------------- | ----------------------------- |
| public     | (ignored)       | everyone in priority          |
| members    | NULL/[]         | author + all priority members |
| members    | [A, B]          | author + all members + A, B   |
| restricted | []              | author only                   |
| restricted | [A, B]          | author + A + B                |

Notes:

- `members` is the default for all priorities. In non-viewer priorities this is equivalent to `public`.
- `restricted` is not used in priorities with viewers — `members` + `access_contacts` covers all cases there.
- The author always has access regardless of access level.

### Note table

Remove:

- `private boolean NOT NULL DEFAULT FALSE`
- `mentions uuid[]` (old field mixing users and twists)

Add:

- `access_contacts uuid[]` — restricts note visibility within thread viewers. NULL = all thread viewers, [] = author only, [ids] = author + listed contacts.
- `mentions uuid[]` — now contains only `priority_twist_id` values (twists and connectors) for dispatch routing. No user contact_ids.

Note access is always a restriction on top of thread access — it cannot widen visibility beyond the thread.

| note access_contacts | who can see (within thread viewers) |
| -------------------- | ----------------------------------- |
| NULL                 | all thread viewers                  |
| []                   | author only                         |
| [A, B]               | author + A + B                      |

### Functions and views to remove

- `get_thread_mentions()` — aggregated user mentions from notes to thread level; no longer needed
- `mentioned_in_thread()` — checked if user was mentioned in any note; replaced by `access`/`access_contacts` on thread
- `mentions` column from `thread_x` view

### Updated visibility logic

**Thread visibility** (replaces private-based checks in `user.thread`, `user.priority_unread`, etc.):

```sql
CASE
  WHEN t.access = 'public' THEN TRUE
  WHEN t.created_by = user_id THEN TRUE
  WHEN t.access = 'members' AND upe.role = 'member' THEN TRUE
  WHEN "user".user_contact_id(user_id) = ANY(t.access_contacts) THEN TRUE
  ELSE FALSE
END
```

**Note visibility** (applied after thread visibility passes):

```sql
n.access_contacts IS NULL  -- all thread viewers
OR n.created_by = user_id
OR "user".user_contact_id(user_id) = ANY(n.access_contacts)
```

**Redaction** continues as before — threads/notes the user can't see return with content NULLed but metadata preserved.

### Updated RPC functions

**`upsert_thread()`:**

- Add `p_access text` parameter (default 'members')
- Add `p_access_contacts uuid[]` parameter
- Remove `p_private` parameter (handled by API translation layer for old clients)
- Viewer enforcement: viewers always get `access = 'members'`, cannot change access level

**`upsert_note()`:**

- Add `p_access_contacts uuid[]` parameter
- Change `p_mentions uuid[]` to only accept priority_twist_ids
- Remove `p_private` parameter (handled by API translation layer for old clients)
- Viewer enforcement: viewers in public threads get `access_contacts = ARRAY[]::uuid[]`

### Data migration

Migration is context-dependent based on whether the priority has viewers:

**Priorities with viewers** (identified by having viewer-role `priority_user` entries):

- `private = true` → `access = 'members'`
- `private = false` → `access = 'public'`

**All other priorities:**

- `private = true` → `access = 'restricted'`
- `private = false` → `access = 'members'` (new default, equivalent to public)

**Note mentions migration (all priorities):**

- Old `mentions` entries that are user contact_ids → move to `access_contacts`
- Old `mentions` entries that are priority_twist_ids → keep in new `mentions`
- Distinguish by joining against `contact` and `priority_twist` tables

**Thread access_contacts computation:**

- For threads migrated to `restricted`: aggregate user contact_ids from note mentions to populate thread-level `access_contacts`

## API Versioning

### X-Plot-API-Version header

Introduce `X-Plot-API-Version` header — a strictly increasing integer, independent of app version. This works with Shorebird patch releases which can bump the API version without changing the app version.

- Version 0 (default, old clients that don't send the header): current `private`/`mentions` format
- Version 1: new `access`/`access_contacts`/`mentions` format

### Sync endpoint translation

**Old clients (version 0):**

Request translation:

- `private: true` → `access: 'members'` (in viewer priorities) or `access: 'restricted'` (otherwise)
- `private: false` → `access: 'public'` (in viewer priorities) or `access: 'members'` (otherwise)
- `mentions` with user contacts → split into `access_contacts` (users) and `mentions` (twists)

Response translation:

- `access != 'public'` → `private: true`
- `access == 'public'` → `private: false`
- Merge `access_contacts` (users) + `mentions` (twists) → `mentions`

**New clients (version 1):**

- Request/response uses `access`, `access_contacts`, `mentions` directly
- No `private` field

## Twister SDK Type Changes

### Thread type

```typescript
type Thread = {
  id: Uuid;
  created: Date;
  access: "public" | "members" | "restricted"; // replaces private
  accessContacts: ActorId[]; // new
  archived: boolean;
  tags: Tags;
  // mentions removed from Thread
  title: string;
  priority: Priority;
  type: ThreadType | null;
  schedule?: Schedule;
  meta?: ThreadMeta;
};
```

### Note type

```typescript
type Note = {
  id: Uuid;
  created: Date;
  accessContacts: ActorId[] | null; // replaces private; null = all thread viewers
  archived: boolean;
  tags: Tags;
  mentions: ActorId[]; // now twist/connector only
  author: Actor;
  key: string | null;
  thread: Thread;
  content: string | null;
  actions: Array<Action> | null;
  reNote: { id: Uuid } | null;
};
```

### NewThread / NewNote

Updated similarly — `private` replaced by `access`/`accessContacts`.

This is a minor version bump for Twister (breaking change, pre-1.0). Requires a changeset.

## Flutter App UI Changes

### NoteEditor bottom bar (note mode)

```
[Task] [Assign(count)] [Lock(count)] [Connector] [Twist] [Attach] [Photo] [Save]
```

Remove the twist/connector mention chips from above the editor. All mention controls move to the bottom bar.

### Lock icon behavior

**Non-viewer priorities:**

- Shown in bottom bar but not accented by default (`members` = everyone can see)
- Tap → switch to `restricted` (author only), icon accents
- Tap when restricted → open selection modal
- Modal: "Make public" (= back to `members`) at top, then contacts to add to `access_contacts`
- Count badge: total people with access (author + access_contacts), shown only when > 1
- When restricted with `access_contacts`: show names list below icon (same pattern as assigned tags)

**Viewer priorities:**

- Shown and accented by default in NoteEditor (`members` = hidden from viewers)
- Tap → open selection modal (never a direct toggle, since making public is a publishing action)
- Modal: "Make public" at top, then viewer-role contacts to add via `access_contacts`
- Count badge: number of viewers in `access_contacts` (not members), shown starting at 1
- When viewers are added to `access_contacts`: show names list below icon (same pattern as assigned tags)
- On saved/rendered notes: when thread is public, lock icon shown only on hover

**Viewers (any priority):**

- Lock not shown in NoteEditor (viewers cannot toggle access)

### Note-level lock

**In public threads:**

- Members: accented by default (`access_contacts = []`, author only). Tap → modal to add viewers or "Make public" (`access_contacts = NULL`).
- Viewers: forced private, not interactive.

**In private threads (members/restricted):**

- Default off (`access_contacts = NULL`, all thread viewers can see)
- Members can tap to restrict (`access_contacts = []`), then add specific members via modal

### Connector icon (plug)

- Only shown when thread was created by a connector with `handleReplies = true`
- Accented by default (connector is in mentions)
- Tap toggles off/on (removes/adds connector from note `mentions`)
- Toggling off skips connector processing for that note

### Twist icon

- Shown when priority has twists
- Tap when off → show twist picker (single select), accent icon on selection
- Tap when on → toggle off (remove twist from `mentions`)
- Default: on if last note in thread mentioned a twist or is from a twist; otherwise off. If user toggles off, next note defaults to off too.

### Assigned icon

- Count badge: number of assignees, shown only when > 1

### Selection modal layout

```
┌─────────────────────────────┐
│  Thread access              │
│                             │
│  Make public                │
│  ─────────────────────────  │
│  ☑ You            (locked)  │
│  ☐ Alice                    │
│  ☐ Bob                      │
│  ☐ Charlie                  │
└─────────────────────────────┘
```

- "Make public" first (list may be long)
- Current user always shown, can't deselect
- Selecting contacts adds to `access_contacts`
- Changes apply immediately (no save button, matching assignment modal pattern)
- For `members` access: member contacts shown as checked but not toggleable; only viewer contacts are selectable

### Default behaviors

**New thread creation:**

| Creator role | Priority type | Default access | Lock shown?        | Lock interactive?  |
| ------------ | ------------- | -------------- | ------------------ | ------------------ |
| Member       | Non-viewer    | members        | Yes (not accented) | Yes (can restrict) |
| Member       | Viewer        | members        | Yes (accented)     | Yes (modal)        |
| Viewer       | Viewer        | members        | Yes (accented)     | No                 |

**New note creation:**

| Thread type    | Creator | Default access_contacts   | Lock interactive? |
| -------------- | ------- | ------------------------- | ----------------- |
| Public thread  | Member  | [] (author only)          | Yes               |
| Public thread  | Viewer  | [] (author only)          | No                |
| Private thread | Member  | NULL (all thread viewers) | Yes               |
| Private thread | Viewer  | NULL (all thread viewers) | No                |

## Inline @mentions

Inline @user mentions in the editor (the `@` popover) continue to work as styled text in markdown. They are NOT stored in the `mentions` field — that field is twist/connector only. User visibility is handled entirely through `access`/`access_contacts`.

The @user popover still shows users for inline text styling. The `mentions` field popover/controls only show twists and connectors.

## Verification

1. **Database**: Run `pnpm gen-migration`, `pnpm apply-migrations`, `pnpm diff-schema-migrations`, `pnpm types`
2. **API**: Test sync endpoints with both version 0 and version 1 clients; verify old clients get translated responses
3. **Migration**: Verify "Using Plot" priority threads migrate to `members`, other priorities' private threads migrate to `restricted`
4. **Flutter**: Test lock icon behavior in viewer vs non-viewer priorities, test note-level restriction in public vs private threads, test connector/twist toggles
5. **Twister**: `cd public/twister && pnpm build`, verify existing sources compile with updated types
6. **Lint**: `pnpm lint` across all affected packages

## Key files to modify

### Database schema

- `libs/db/schema/50-tables/24-thread.sql` — add access, access_contacts; remove private
- `libs/db/schema/50-tables/25-note.sql` — add access_contacts, new mentions; remove private, old mentions
- `libs/db/schema/60-functions/get_thread_mentions.sql` — remove
- `libs/db/schema/70-views/25-thread.sql` — update thread_x, remove mentions
- `libs/db/schema/90-user-schema/06-user_mentioned_in_thread.sql` — remove
- `libs/db/schema/90-user-schema/30-thread.sql` — update user.thread visibility logic
- `libs/db/schema/90-user-schema/31-note.sql` — update user.note visibility logic
- `libs/db/schema/90-user-schema/80-upsert_thread.sql` — new params, viewer enforcement
- `libs/db/schema/90-user-schema/85-user-sync-upserts.sql` — upsert_note new params

### API

- `workers/api/src/middleware/client-version.ts` — add X-Plot-API-Version parsing
- `workers/api/src/app/sync/threads.ts` — version-branched request/response
- `workers/api/src/app/sync/notes.ts` — version-branched request/response
- `workers/api/src/twist/tools/plot/thread.ts` — use access/access_contacts
- `workers/api/src/twist/tools/plot/note.ts` — use access_contacts, twist-only mentions
- `workers/api/src/twist/tools/plot/converters.ts` — new field mapping
- `workers/api/src/twist/tools/integrations.ts` — update saveThread/saveLink

### Twister SDK

- `public/twister/src/plot.ts` — Thread/Note type changes
- `public/.changeset/` — changeset file for minor bump

### Flutter app

- `apps/plot/lib/store/thread.dart` — access, access_contacts columns
- `apps/plot/lib/store/note.dart` — access_contacts column, mentions column
- `apps/plot/lib/store/tag.dart` — update Tag.private mapping
- `apps/plot/lib/widget/note_editor.dart` — bottom bar: lock, connector, twist icons; remove twist chips
- `apps/plot/lib/command/note.dart` — update private commands to access commands
- New: selection modal widget for access_contacts
- `apps/plot/lib/store/sync.dart` — sync with new fields, API version header
