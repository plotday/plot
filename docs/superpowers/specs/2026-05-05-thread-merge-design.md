# Thread Merge — Design

## Goal

Extend Plot's existing `MergeThreadInto` / `SplitThread` so that merging an
event thread into a discussion thread produces a single thread that:

1. Keeps the event link and its scheduling on the merged thread.
2. Adds the source's notes (and links, tags, schedules) onto the target.
3. Survives connector re-sync of the merged event without silently
   creating a duplicate thread.
4. Can be split back later by reading the source thread directly,
   without snapshotting fields onto the target. Multiple sources can
   merge into a single target.

The current implementation lives in `apps/plot/lib/command/thread.dart`
(`_ExecuteMerge` / `_ExecuteSplit`). It already moves notes, links, tags,
and schedules; this design fills in the remaining gaps and replaces the
"snapshot on target" idea with a reference column on the source.

## Model: source-row-as-snapshot

Add `thread.merged_into_thread_id` (nullable, references `thread.id`,
`ON DELETE SET NULL`). When set on a thread, that thread is a merge
*source*: it is archived but its identity columns are preserved on its
own row. The target it merged into is found by following the reference.

Many sources can point at one target. The target itself does not store a
list of its sources — they are discovered by reverse-lookup
(`WHERE merged_into_thread_id = target.id`).

Source content (notes, links, schedules, tags, `thread_association`
rows) is moved to the target at merge time so existing per-thread
queries, views, visibility checks, and sort orders keep working without
join-time aggregation. The source row is preserved purely for split-time
restoration of *its* identity.

## Per-field behavior

| Field / table | Merge behavior | Split behavior |
|---|---|---|
| `thread.title`, `thread.icon`, `thread.topic` | Target wins (unchanged). | Source's original is on source row; target untouched. |
| `thread.created_at`, `thread.created_by` | Target wins. | Source's original on source row; target untouched. |
| `thread.readAt`, `thread.unread` | Target wins. | Untouched. |
| `thread.contacts`, `thread.groups` | **Union** source ∪ target. | `target.contacts -= (source.contacts \ otherActiveSources.contacts)`, same for `groups`. Removes contacts/groups that only this source contributed; keeps any that another still-merged source carries. Lossy only in the rare case where a contact was in both the pre-merge target and source (the overlap is dropped from target on split). |
| `thread.importance` | `max(source, target)`. | Target untouched. (Lossy — accepted.) |
| `thread.urgency` | More urgent of the two by `_urgencyRank` (`interrupt < inform-requests < inform-updates < passive < null`). | Target untouched. (Lossy — accepted.) |
| `thread.twist_id`, `thread.key` | **Server-side trigger** copies from source to target when target's are unset. If target already has its own different `(twist_id, key)`, trigger leaves both rows unchanged (rare; behavior matches today's connector-duplicate bug — no regression, just no fix in this case). Source row keeps its values either way. Client never reads or writes these — they're not synced to clients. | Server-side trigger: when `merged_into_thread_id` transitions back to NULL on source, if `target.(twist_id, key) == source.(twist_id, key)`, clear them on target so source can reclaim the active slot. |
| `thread.preview`, `bumpedAt`, `lastNoteCreatedAt`, `embedding` | Recomputed server-side from notes; no explicit handling. | Same. |
| `thread.merged_into_thread_id` | On source: set to target.id. On target: never set by merge. | On source being split: set to NULL. |
| `thread.archived_at` (on source) | Set to `now()`. | Set to NULL. |
| `note` rows (non-draft) | Move to target with `mergedFromThreadId = source.id`. For each source note with non-null `key`, if target already has any note with the same key, null out the moved note's `key`. | Move back to source as today. |
| `note` rows (draft) | Skip (existing behavior). | N/A. |
| `link` rows | Move to target with `mergedFromThreadId = source.id`. | Move back as today. |
| `schedule` rows | Fill-gaps on `(userId, occurrence)` (existing). Conflicts drop source's. | Move source-owned schedules back. |
| `thread_tag` (per occurrence) | Union actors per tag (existing). | Existing reverse logic. |
| `thread_association` (source as child) | Repoint `child_thread_id` to target only if target has no active parent; otherwise archive source's row. | **Not restored.** (Lossy — accepted.) |
| `thread_association` (source as parent) | Bulk repoint active children's `parent_thread_id` to target. | Not restored. |
| `schedule_contact` | Follows schedules naturally — `schedule.id` is unchanged at move, only `thread_id`/`link_id` change. | Same. |

## Connector upsert resolution

`upsert_thread()` (`libs/db/schema/90-user-schema/80-upsert_thread.sql`)
already resolves `(twist_id, key)` against active rows only:

```sql
SELECT t.id INTO v_id
FROM thread t
WHERE t.twist_id = v_twist_id
  AND t.key = (p_thread ->> 'key')
  AND t.archived_at IS NULL;
```

Because the merge trigger archives source and copies its `(twist_id, key)`
onto target, this lookup naturally lands on target. **No change needed
to `upsert_thread()`.**

The `merged_into_thread_id` column is used for split-time discovery on
the client (and for the trigger to know which target to copy
`(twist_id, key)` onto), not as a runtime indirection for connector
ingestion.

## Server-side trigger: `transfer_twist_key_on_merge`

Because `thread.twist_id` and `thread.key` are not synced to clients,
the migration of those fields between source and target happens
server-side via an `AFTER UPDATE` trigger on `thread`. The trigger
fires on transitions of `merged_into_thread_id`:

- **NULL → set (merge)**: source must also be archived in the same
  update (precondition). If source has `(twist_id, key)` and target
  has none, copy them onto target. If target already has different
  `(twist_id, key)`, leave both rows unchanged.
- **set → NULL (split)**: if `target.(twist_id, key) == source.(twist_id, key)`,
  clear them on target. Then source's unarchive (also in the same
  update) restores it to the active key slot.

The order of operations within the trigger ensures the partial unique
index `thread_twist_key_unique` is satisfied at every intermediate
state.

## UI

Entry point unchanged: from the source thread, "Merge" picks a target.
No new entry point on the target side.

After merge, navigate to the target thread (existing behavior).

## Multi-source semantics

- `merged_into_thread_id` is many-to-one. Any number of sources can
  point at one target.
- `SplitThread` lists all sources by reverse-lookup and lets the user
  pick which to split out (existing UX, broader source set).
- `(twist_id, key)` is capped at one per target by the merge-time
  conflict check; this prevents the upsert chain from diverging across
  multiple twist-owned sources.
- Audience union and importance/urgency max are commutative across
  multiple merges, so the target's stored fields converge naturally as
  more sources are absorbed.

## Implementation surface

### Schema

`libs/db/schema/50-tables/24-thread.sql`:

```sql
ALTER TABLE "public"."thread"
    ADD COLUMN "merged_into_thread_id" uuid
    REFERENCES public.thread (id) ON DELETE SET NULL;

CREATE INDEX idx_thread_merged_into ON "public"."thread" ("merged_into_thread_id")
WHERE merged_into_thread_id IS NOT NULL;
```

### Drift mirror

`apps/plot/lib/store/thread.dart` — add the column, bump
`Store.schemaVersion`, add an `addColumn` migration step.

### Sync wiring

The thread sync push/pull must include `merged_into_thread_id`.
Concretely: include the column in the `user.thread` view projection,
in the sync POST payload mapping, and in the Drift→server upsert
shape used by `SyncOrchestrator.thread`.

### Client-side merge logic

`apps/plot/lib/command/thread.dart`, `_ExecuteMerge.run`. New steps,
ordered:

1. **Note key collision pre-pass**: build a `Set<NoteId>` of
   moved-source-note ids whose `key` collides with an existing target
   note's `key`. Apply `key: null` for those during the move loop.
2. **Audience union onto target**: `target.contacts = target.contacts ∪
   source.contacts`, same for `groups`.
3. **Importance/urgency onto target**: `target.importance =
   max(target.importance, source.importance)`; `target.urgency =
   urgencyByLowerRank(target.urgency, source.urgency)`.
4. **Single target write** combining steps 2 and 3 (one row write to
   minimize sync pushes).
5. **Archive source and set back-reference**: write
   `source.merged_into_thread_id = target.id` and
   `archived_at = now()`. The server trigger fires on this update and
   handles the `(twist_id, key)` migration. `(twist_id, key)` is not
   readable from the client, so we don't surface conflict errors;
   the trigger silently skips the copy when target already has its own
   different key.
6. **Existing note move**, with the collision set applied.
7. **Existing link move.**
8. **Existing tag union.**
9. **Existing schedule fill-gaps.**
10. **`thread_association` move**:
    - Active row where `child_thread_id == source.id`: if target has no
      active parent association, set `child_thread_id = target.id`.
      Else archive source's association.
    - Active rows where `parent_thread_id == source.id`: bulk update
      `parent_thread_id = target.id`.
11. Existing sync push for note + thread; navigate to target.

### Client-side split logic

`_ExecuteSplit.run`:

1. Replace `SplitThread.hasMergedContent` and the source-id discovery
   in `SplitThread.run` to query `thread WHERE merged_into_thread_id
   == target.id AND archived_at IS NOT NULL`. (Falls back to the
   existing notes/links scan only for legacy data without the new
   column populated.)
2. After existing note/link/schedule restore for the chosen source:
   - **Audience subtract**: collect `otherActiveSources` for this
     target via the same reverse-lookup, excluding the source being
     split. Compute `removeContacts = source.contacts \ ⋃
     otherActiveSources.contacts`. Apply
     `target.contacts -= removeContacts`. Same for `groups`.
   - Set `source.merged_into_thread_id = NULL`, `archived_at = NULL`.
     The server trigger fires on this transition and handles
     `(twist_id, key)` reverse-migration (clears them from target if
     they match source's).
3. `thread_association` rows are not restored.
4. Target's `importance`/`urgency` are not modified (no clean inverse
   of `max`).

### Server-side sync surface

Sync uses the seq-cursor protocol via the `user.thread` view, not the
old `notify_internal_api_for_*` functions (`libs/db/AGENTS.md` is
stale on that point). To get `merged_into_thread_id` to clients:

- Add the column to the `user.thread` view projection
  (`libs/db/schema/90-user-schema/` thread view file — exact path to
  pin during plan).
- Run `pnpm types` to regenerate `workers/api/src/db-types.ts`
  (auto-generated; do not edit by hand).
- Confirm any thread-shape Zod validators in
  `workers/api/src/app/sync/threads.ts` accept the new optional
  field — extend if needed.

## Failure modes & errors

- `(twist_id, key)` conflict between source and target: the server
  trigger silently skips the key migration. Merge content (notes,
  links, etc.) still moves correctly. The connector continues
  upserting against source's (twist_id, key), which is now archived;
  the upsert lookup finds no active row and creates a fresh thread on
  next sync. This is the existing connector-duplicate bug — no
  regression vs today, just no fix in this rare conflict case.
- Merge aborts if either thread is already a merge source
  (`merged_into_thread_id IS NOT NULL`) — a source can't be re-merged
  while alive, and you can't merge into an archived source. (Listing
  filter in the picker covers most cases; the runtime check is a
  guardrail.)

## Migration

No data migration needed. Existing merges archived their sources via
`source.delete()` (which sets `archived_at`); those rows have
`merged_into_thread_id = NULL`, so they look like ordinary archived
threads. `SplitThread` falls back to the notes/links scan for them, so
existing merged content remains splittable. New merges set
`merged_into_thread_id`, and the new path is preferred.

## Out of scope

- Three-way merge or interactive conflict resolution UI.
- Restoring target's `importance`/`urgency` on split (no clean
  inverse for `max`).
- Restoring `thread_association` on split.
- Per-merge audit log of which fields were absorbed.
- Adding a "absorb…" entry point on the target thread.
