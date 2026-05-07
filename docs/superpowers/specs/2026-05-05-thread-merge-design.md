# Thread Merge — Design

## Goal

Extend Plot's existing `MergeThreadInto` / `SplitThread` so that merging an
event thread into a discussion thread produces a single thread that:

1. Keeps the event link and its scheduling on the merged thread.
2. Adds the source's notes (and links, tags, schedules) onto the target.
3. Survives connector re-sync of the merged event without silently
   creating a duplicate thread — even when many connector-keyed sources
   merge into one target, or when targets have their own different
   connector identity.
4. Can be split back later by reading the source thread directly,
   without snapshotting fields onto the target. Multiple sources can
   merge into a single target.

The current implementation lives in `apps/plot/lib/command/thread.dart`
(`_ExecuteMerge` / `_ExecuteSplit`). It already moves notes, links, tags,
and schedules; this design fills in the remaining gaps and replaces the
"snapshot on target" idea with a reference column on the source plus a
chain-follow lookup for connector resyncs.

## Model: source-row-as-snapshot + connector chain-follow

Add `thread.merged_into_thread_id` (nullable, references `thread.id`,
`ON DELETE SET NULL`). When set on a thread, that thread is a merge
*source*: it is archived but its identity columns — including its
connector `(twist_id, key)` — are preserved on its own row. The target
it merged into is found by following the reference.

Many sources can point at one target. The target itself does not store a
list of its sources — they are discovered by reverse-lookup
(`WHERE merged_into_thread_id = target.id`).

Source content (notes, links, schedules, tags, `thread_association`
rows) is moved to the target at merge time so existing per-thread
queries, views, visibility checks, and sort orders keep working without
join-time aggregation. The source row is preserved purely for split-time
restoration of *its* identity and to keep its `(twist_id, key)` reachable
through the connector lookup.

## Per-field behavior

| Field / table | Merge behavior | Split behavior |
|---|---|---|
| `thread.title`, `thread.icon`, `thread.topic` | Target wins (unchanged). | Source's original is on source row; target untouched. |
| `thread.created_at`, `thread.created_by` | Target wins. | Source's original on source row; target untouched. |
| `thread.readAt`, `thread.unread` | Target wins. | Untouched. |
| `thread.contacts`, `thread.groups` | **Union** source ∪ target. | `target.contacts -= (source.contacts \ otherActiveSources.contacts)`, same for `groups`. Removes contacts/groups that only this source contributed; keeps any that another still-merged source carries. Lossy only in the rare case where a contact was in both the pre-merge target and source (the overlap is dropped from target on split). |
| `thread.importance` | `max(source, target)`. | Target untouched. (Lossy on target — accepted; source is restored fully via its preserved row.) |
| `thread.urgency` | More urgent of the two by `_urgencyRank` (`interrupt < inform-requests < inform-updates < passive < null`). | Target untouched. (Lossy on target — accepted; source is restored fully via its preserved row.) |
| `thread.twist_id`, `thread.key` | **Stay on source forever.** Not modified on merge or split. The connector lookup follows `merged_into_thread_id` on resync (see below). Client never reads or writes these — they're not synced to clients. | Untouched on either row. Source's key becomes findable as an active row again automatically when source unarchives. |
| `thread.preview`, `bumpedAt`, `lastNoteCreatedAt`, `embedding` | Recomputed server-side from notes; no explicit handling. | Same. |
| `thread.merged_into_thread_id` | On source: set to target.id. On target: never set by merge. | On source being split: set to NULL. |
| `thread.archived_at` (on source) | Set to `now()`. | Set to NULL. |
| `note` rows (non-draft) | Move to target with `mergedFromThreadId = source.id`. The `note_thread_link_key_unique` partial index on `(thread_id, link_id, key) WHERE key IS NOT NULL` accommodates this — different `link_id` rows don't collide, and NULL `link_id` rows are treated as distinct. No client-side key handling needed. | Move back to source. |
| `note` rows (draft) | Skip (existing behavior). | N/A. |
| `link` rows | Move to target with `mergedFromThreadId = source.id`. | Move back. |
| `schedule` rows | Fill-gaps on `(userId, occurrence)` (existing). Conflicts drop source's. | Fill-gaps inverse: move source-owned schedules back. |
| `thread_tag` (per occurrence) | Union actors per tag (existing). Target's tag rows absorb source's actors; source's tag rows on source.id are untouched. | Set-subtract on target per `(tag, occurrence, actor)` — drop actors that source contributed unless another still-merged source carries them. Source's tag rows reactivate naturally when source unarchives. |
| `thread_association` (source as child) | Repoint `child_thread_id` to target only if target has no active parent; otherwise archive source's row. | **Not restored.** (Lossy — accepted.) |
| `thread_association` (source as parent) | Bulk repoint active children's `parent_thread_id` to target. | Not restored. |
| `schedule_contact` | Follows schedules naturally — `schedule.id` is unchanged at move, only `thread_id`/`link_id` change. | Same. |

## Connector upsert resolution: chain-follow

`upsert_thread()` (`libs/db/schema/90-user-schema/80-upsert_thread.sql`)
resolves `(twist_id, key)` to a thread on every connector sync. The new
behavior:

1. Drop the `archived_at IS NULL` filter from the lookup. Archived
   sources that retain their key are eligible matches.
2. `ORDER BY archived_at ASC NULLS FIRST LIMIT 1` so an active row wins
   when one exists (the normal case for unmerged threads).
3. If the matched row's `merged_into_thread_id` is non-null, follow the
   chain. Loop with a 10-hop safeguard against pathological cycles.

```sql
SELECT t.id, t.merged_into_thread_id
INTO v_id, v_chain_next
FROM thread t
WHERE t.twist_id = v_twist_id AND t.key = (p_thread ->> 'key')
ORDER BY t.archived_at ASC NULLS FIRST
LIMIT 1;

WHILE v_chain_next IS NOT NULL AND v_chain_hops < 10 LOOP
    v_id := v_chain_next;
    SELECT merged_into_thread_id INTO v_chain_next
      FROM thread WHERE id = v_id;
    v_chain_hops := v_chain_hops + 1;
END LOOP;
```

This routes any external item's resync to its currently-merged target,
no matter how many sources have collapsed into it or how deep the
merge chain runs:

- **Source merged into target.** Source archived with its key. Lookup
  for source's external key finds source → follows to target. Target
  receives the upsert.
- **Source merged into target, target has its own different
  `(twist_id, key)`.** Source still holds its key; target still holds
  its own. Lookups for either key route to target.
- **N twist-keyed sources merged into one target.** Each source retains
  its own `(twist_id, key)` on its archived row. All lookups route to
  target. Target effectively holds many connector identities, no
  separate "alt keys" structure required.
- **Chained merges (A → B → C).** A and B both archived with their own
  keys; chain-follow walks A → B → C in two hops.

## Server-side trigger: `thread_merge_preconditions`

A `BEFORE UPDATE OF merged_into_thread_id` trigger enforces the caller
invariant:

- **NULL → set (merge)**: `archived_at` must also be set in the same
  UPDATE. If not, raise an exception (caller bug — Flutter merge always
  archives source in the same write).
- **set → NULL (split)**: `archived_at` must also be cleared. If not,
  raise an exception.

No row-level migration logic. No row locks needed. The trigger exists
purely as a guardrail; nothing in the merge/split workflow depends on
it for correctness, but a bug that violates the invariant would create
inconsistent state without it.

## UI

Entry point unchanged: from the source thread, "Merge" picks a target.
No new entry point on the target side.

After merge, navigate to the target thread (existing behavior).

## Multi-source semantics

- `merged_into_thread_id` is many-to-one. Any number of sources can
  point at one target.
- `SplitThread` lists all sources by reverse-lookup and lets the user
  pick which to split out (existing UX, broader source set).
- Targets can have any number of associated `(twist_id, key)` keys —
  one per source, plus optionally target's own. The chain-follow
  upsert routes them all to target without merging or coordinating
  the keys.
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

1. **Audience union onto target**: `target.contacts = target.contacts ∪
   source.contacts`, same for `groups`.
2. **Importance/urgency onto target**: `target.importance =
   max(target.importance, source.importance)`; `target.urgency =
   urgencyByLowerRank(target.urgency, source.urgency)`.
3. **Single target write** combining steps 1 and 2 (one row write to
   minimize sync pushes).
4. **Archive source and set back-reference**: write
   `source.merged_into_thread_id = target.id` and
   `archived_at = now()`. The precondition trigger validates this.
   The server-side `upsert_thread()` chain-follow handles connector
   routing automatically — no row-level key migration.
5. **Existing note move.** No client-side key handling — `note_thread_link_key_unique` 
   accommodates the moves under main's `(thread_id, link_id, key)` scoping.
6. **Existing link move.**
7. **Existing tag union.**
8. **Existing schedule fill-gaps.**
9. **`thread_association` move**:
    - Active row where `child_thread_id == source.id`: if target has no
      active parent association, set `child_thread_id = target.id`.
      Else archive source's association.
    - Active rows where `parent_thread_id == source.id`: bulk update
      `parent_thread_id = target.id`.
10. Existing sync push for note + thread; navigate to target.

### Client-side split logic

`_ExecuteSplit.run`:

1. Find source threads via `thread WHERE merged_into_thread_id =
   current.id AND archived_at IS NOT NULL`. Fall back to the existing
   notes/links scan for legacy merges (pre-`merged_into_thread_id`).
2. Move notes back, links back, schedules back (fill-gaps inverse).
3. **Tag set-subtract on current**: per `(tag, occurrence)`, drop
   actors that source contributed unless another still-merged source
   carries them.
4. **Audience subtract on current**: same set-subtract logic for
   `contacts` and `groups`.
5. Single current write combining steps 3 and 4.
6. Set `source.merged_into_thread_id = NULL`, `archived_at = NULL`.
   The precondition trigger validates this. Source's preserved
   `(twist_id, key)` becomes findable as an active row again.
7. `thread_association` rows are not restored.
8. Target's `importance`/`urgency` are not modified (no clean inverse
   of `max`); source's are correctly restored via its own preserved row.

### Server-side sync surface

Sync uses the seq-cursor protocol via the `user.thread` view, not the
old `notify_internal_api_for_*` functions (`libs/db/AGENTS.md` is
stale on that point). To get `merged_into_thread_id` to clients:

- Add the column to the `user.thread` view projection.
- Run `pnpm types` to regenerate `workers/api/src/db-types.ts`
  (auto-generated; do not edit by hand).

## Failure modes & errors

- **Merge aborts via trigger** if `archived_at` isn't set in the same
  UPDATE that sets `merged_into_thread_id`. The Flutter command always
  sets both; the trigger catches caller bugs.
- **Split aborts via trigger** if `archived_at` isn't cleared in the
  same UPDATE that clears `merged_into_thread_id`. Same rationale.
- Merge aborts if either thread is already a merge source
  (`merged_into_thread_id IS NOT NULL`) — a source can't be re-merged
  while alive, and you can't merge into an archived source. (Listing
  filter in the picker covers most cases; the runtime check is a
  guardrail.)
- Connector lookups follow up to 10 hops of `merged_into_thread_id`
  chain. Beyond that, the lookup falls back to whatever id was reached
  at the cap. In practice merge depth is small; this is a defense
  against pathological cycles.

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
  inverse for `max`); source's are restored via its own preserved row.
- Restoring `thread_association` on split.
- Per-merge audit log of which fields were absorbed.
- Adding a "absorb…" entry point on the target thread.
