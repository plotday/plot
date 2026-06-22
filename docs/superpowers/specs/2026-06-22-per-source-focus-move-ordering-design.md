# Per-source-focus Move ordering (cross-device)

**Date:** 2026-06-22
**Status:** Approved design, ready for implementation plan
**Scope:** Flutter app (`apps/plot`) Move modal ordering + recording, plus a new
synced field on `user_settings` (server schema + sync endpoint + Drift).
**Supersedes:** [`2026-06-17-move-modal-ordering-design.md`](./2026-06-17-move-modal-ordering-design.md),
which built the current ordering and explicitly deferred persistence and any
server/Drift/sync change. This spec lifts those two exclusions.

## Problem

When moving a thread to another focus, the Move modal ranks candidate focuses with
`orderMoveTargets` (`apps/plot/lib/state/move_recency.dart`) in three tiers:

1. **Tier 0** — focuses recently moved into *this session* (`MoveRecency`, newest
   first).
2. **Tier 1** — focuses sharing the moved thread's current role.
3. **Tier 2** — base order (visit-recency, then alphabetical).

The recency tier is **global**: `MoveRecency.record(focusId)` stores only the
*destination*, ignoring which focus the thread came *from*. So "I just moved
something to X" floats X to the top no matter where the next thread lives. The
better predictor of where a thread should go is **where threads from its current
focus usually go**. Recency should be scoped to the source focus.

It is also session-only and in-memory, so the signal evaporates on restart and
never crosses devices.

## Goals

1. **Scope recency to the source focus.** Tier 0 becomes "destinations I've recently
   moved threads into *from the current focus*," newest first.
2. **Persist across devices.** The per-source affinity survives restarts and syncs,
   so the pattern accumulates into a genuine "from this focus, threads usually go
   here" signal.
3. **Never fail offline.** Reads come from the local store and never touch the
   network; writes are best-effort and degrade silently when offline.

## Decisions (from brainstorming)

- **Tier structure: per-source recency → same-role → base.** Tiers 1 and 2 are
  unchanged. The global session-recency tier is **removed** (not kept as a deeper
  fallback). `orderMoveTargets` itself is already source-agnostic — only the *list*
  it is fed changes.
- **Persistence: reuse the synced `user_settings` row.** Add a `move_affinity` JSON
  map rather than a new synced table. `user_settings` already syncs cross-device and
  already has a precedent for custom merge (`dismissed_focus_suggestions` is
  union-merged in its upsert).
- **Per-source cap: 8 destinations.** On write, each source focus keeps only its 8
  most-recent destinations. Ordering relevance drops off fast and this keeps the blob
  small.
- **Affinity is a separate concern from the classifier signal.** The existing
  `POST /sync/priority-moves` learning signal (which records destination-only and
  feeds the classifier) is left untouched. Affinity is a client-owned UX ranking
  store.
- **Move-modal only.** Compose / file-into-focus pickers are unchanged (as before).

## The tiers (new)

For a move whose **source focus** is `S` (the thread's current focus) with role
`roleId(S)`:

1. **Tier 0 — recently moved into from `S`**: destinations in
   `move_affinity[S]`, ordered by recorded timestamp, newest first.
2. **Tier 1 — same role**: `roleId == roleId(S)`, excluding Tier-0 focuses. `roleId`
   is nullable in the model; when `roleId(S)` is null this tier is empty.
3. **Tier 2 — everything else**, in the incoming base order from
   `Priority.getRaw(order: PriorityOrder.recent)` (visit-recency, then alphabetical).

The thread's current focus is filtered out before sorting (unchanged). Inbox/FYI
focuses participate normally.

## Data model

A new `move_affinity` field on the existing per-user `user_settings` row:

```jsonc
// move_affinity
{
  "<sourceFocusId>": { "<destFocusId>": <epochMillis>, ... },
  ...
}
```

- **Stored as** `jsonb NOT NULL DEFAULT '{}'` server-side; JSON `TEXT` (default
  `'{}'`) in Drift locally.
- **Bounds.** The client caps each source map to its 8 highest-timestamp entries on
  every write. The whole structure is naturally bounded by the number of focuses a
  user has (≤ `#focuses` sources × ≤ `#focuses` dests), so it stays KB-scale.
- **Staleness is harmless.** The merge never deletes cells, so deleted/archived
  focuses can linger in the map; the modal only renders focuses that still exist, so
  stale entries simply never match a candidate. No pruning needed (bounded by
  `#focuses`).

## Components

### 1. `MoveAffinity` — pure, testable parse / record / serialize

Replaces the `MoveRecency` singleton (deleted — the local Drift `user_settings` row
is now the persistent, offline-capable store). Lives in
`apps/plot/lib/state/move_recency.dart` (or a renamed `move_affinity.dart`).

```dart
class MoveAffinity {
  MoveAffinity(this._bySource); // { sourceId: { destId: epochMillis } }
  final Map<Uuid, Map<Uuid, int>> _bySource;

  static const maxPerSource = 8;

  /// Tolerant parse: null / empty / malformed JSON → empty map (never throws).
  factory MoveAffinity.fromJson(String? raw) { ... }

  /// Destinations recently moved into from [source], newest first.
  List<Uuid> destsFor(Uuid source) { ... } // sort by epoch desc

  /// Return an updated copy recording source→dest at [at], re-capped to
  /// [maxPerSource] for that source (drops the oldest beyond the cap).
  MoveAffinity recordMove(Uuid source, Uuid dest, DateTime at) { ... }

  String toJson() { ... } // stable JSON for the user_settings column
}
```

Pure: no `BuildContext`, Drift, or network — unit-testable like `orderMoveTargets`.

### 2. `orderMoveTargets(...)` — unchanged logic, new input

Keep the existing stable tiered sort. The only change is the caller: feed it the
per-source dest list instead of the global MRU. Signature stays
`{ focuses, recentMoves, currentRoleId }`; `recentMoves` now carries
`affinity.destsFor(sourceFocusId)`.

### 3. `sharedSourceFocusId(threads)` — bulk helper

Mirrors the existing `sharedRoleId`. Returns the single source focus id shared by an
entire bulk selection, or `null` when the selection spans more than one source focus
(or is empty). Tier 0 applies to a bulk move only when one source is shared;
otherwise `recentMoves` is empty and ordering falls to the role tier.

## Data flow — Flutter

### Read (modal builders)

In `MoveThreadToPriority._getMoveCommands` and `BulkMove._getBulkMoveCommands`
(`apps/plot/lib/command/thread.dart`): load the current settings
(`UserSettingsEntity.get()` — a local Drift read, always available offline; null →
empty affinity), build the per-source list, and pass it through:

```dart
final affinity = MoveAffinity.fromJson((await UserSettingsEntity.get())?.moveAffinity);
final sourceId = thread.priority.id;                 // bulk: sharedSourceFocusId(threads)
final ordered = orderMoveTargets(
  focuses: focuses,
  recentMoves: affinity.destsFor(sourceId),          // bulk: [] when source not shared
  currentRoleId: thread.priority.roleId,             // bulk: sharedRoleId(...)
);
```

### Record (command level, coalesced)

Move recording is lifted **out of** `_applyPriorityMove` up to the command `run`
methods, and coalesced to the distinct `(source → dest)` pairs of the operation:

- `MoveToPriority`: record one pair `(thread.priority.id → dest)`.
- `_BulkMoveToPriority`: record one pair per *distinct* source in the selection
  (a 50-thread same-source bulk writes once, not 50 times).

Recording = read current `move_affinity` → `recordMove(...)` for each pair →
`UserSettingsEntity.save(...)` (local Drift) → best-effort sync `push()`. Wrapped in
`try/catch` + `unawaited` exactly like the existing best-effort
`_persistPriorityMove` POST, so a move never blocks on or throws from the affinity
write. `thread.priority.id` (the source) is available before the optimistic
`copyWith(priority: dest)`, as it is today.

## Server / sync

### Schema (`libs/db/schema`)

- Add `move_affinity jsonb NOT NULL DEFAULT '{}'` to `public.user_settings`
  (`50-tables/99-user-settings.sql`). Its existing `set_user_settings_updated_at`
  trigger already bumps `seq`/`updated_at`, so sync picks the change up for free.
- Generate the migration with `pnpm gen-migration -- add_user_settings_move_affinity`,
  `pnpm apply-migrations`, and **commit the regenerated `libs/db/src/types.ts`**.

### Merge in the upsert (`90-user-schema/85-user-sync-upserts.sql`)

Add a nullable `p_move_affinity jsonb DEFAULT NULL` parameter to
`user.upsert_user_settings`:

- **`NULL` = "no change"** — preserves the stored value. This is the
  backwards-compatibility guarantee: existing app versions POST `user_settings`
  without the field, so they must never wipe it.
- **Non-null = deep merge, keeping the max timestamp per `(source, dest)` cell**, so
  two devices' concurrent offline moves both survive (neither clobbers the other).

Merge semantics (helper sketch; final mechanics may differ):

```sql
-- merge two {source:{dest:epoch_ms}} maps, max epoch per (source,dest)
CREATE OR REPLACE FUNCTION "user".merge_move_affinity(existing jsonb, incoming jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(jsonb_object_agg(src, dests), '{}'::jsonb)
  FROM (
    SELECT src, jsonb_object_agg(dest, ms) AS dests
    FROM (
      SELECT s.key AS src, d.key AS dest, max((d.value)::numeric) AS ms
      FROM (
        SELECT key, value FROM jsonb_each(coalesce(existing, '{}'::jsonb))
        UNION ALL
        SELECT key, value FROM jsonb_each(coalesce(incoming, '{}'::jsonb))
      ) s, LATERAL jsonb_each(s.value) d
      GROUP BY s.key, d.key
    ) m
    GROUP BY src
  ) per_source;
$$;
```

In `upsert_user_settings`: on INSERT set `coalesce(p_move_affinity, '{}')`; on
CONFLICT set
`CASE WHEN p_move_affinity IS NULL THEN user_settings.move_affinity ELSE "user".merge_move_affinity(user_settings.move_affinity, p_move_affinity) END`.

### Endpoint (`workers/api/src/app/sync/user-settings.ts`)

- **GET** `/sync/user-settings`: include `move_affinity` in the returned row.
- **POST** `/sync/user-settings`: forward `move_affinity` (when present) to
  `rpcUser(trx, "upsert_user_settings", { ...,  p_move_affinity })`.

### Drift (`apps/plot/lib/store/user_settings.dart`)

- Add a `moveAffinity` `TextColumn` (JSON, default `'{}'`) to the `UserSettings`
  table.
- Bump `Store.schemaVersion` and add an incremental
  `m.addColumn(userSettings, userSettings.moveAffinity)` migration step (per
  `apps/plot/AGENTS.md`); run `flutter pub run build_runner build`.
- Ensure `UserSettingsEntity` push/pull serialization carries `move_affinity`
  (read it on pull, send it on push). The `userSettings` `SyncEntity` registration in
  `sync_orchestrator.dart` is otherwise unchanged.

## Offline behavior (explicit requirement)

- **Read / ordering**: a local Drift read of `user_settings`; works offline; a
  null/empty/malformed value yields an empty `MoveAffinity` so ordering falls cleanly
  to the role and base tiers. Never awaits the network, never throws.
- **Write / recording**: local Drift write first; `push()` is best-effort and
  retried by the existing sync orchestrator. A failed push (offline / transient) is
  swallowed and never surfaces to the move.

## Edge cases

- **Fresh install / no history**: Tier 0 empty → role affinity leads, then base order
  (same as today between sessions).
- **Source focus has null `roleId`**: Tiers 0 and 1 may both be empty → pure base
  order. No crash.
- **A focus that is both recently-moved-from-`S` and same-role**: appears once, in
  Tier 0.
- **Bulk across multiple source focuses**: `sharedSourceFocusId` → null → Tier 0
  empty; falls to `sharedRoleId` behavior (unchanged).
- **Bulk across multiple roles**: `sharedRoleId` → null (unchanged), Tier 1 empty.
- **Deleted/archived destination in the map**: never matches a rendered focus; inert.
- **Old client writes user_settings**: omits `move_affinity` → server preserves it
  (no wipe).

## Testing (TDD)

Pure units (no `BuildContext`/Drift/network):

- **`MoveAffinity`**: `fromJson` tolerates null/empty/garbage → empty; `recordMove`
  prepends/updates a cell and re-caps to 8 (oldest dropped); `destsFor` returns
  newest-first; `toJson`↔`fromJson` round-trips.
- **`orderMoveTargets`**: existing tests hold; add cases proving Tier 0 is driven by
  the per-source list (different sources yield different orders); empty list →
  role/base only.
- **`sharedSourceFocusId`**: single shared source → that id; mixed → null; empty →
  null.

Command / integration:

- Single move records `(source → dest)` into `user_settings.move_affinity`.
- Same-source bulk coalesces to one recorded pair; mixed-source bulk records one pair
  per distinct source and produces no Tier 0 in the modal.
- Offline (push throws): the move still completes and the local affinity is updated.

Server:

- `merge_move_affinity` keeps the max timestamp per `(source, dest)`; disjoint maps
  union; overlapping cells take the newer.
- `upsert_user_settings` with `p_move_affinity = NULL` leaves the stored map intact
  (backwards-compat no-wipe); with a value, merges.

Run `cd apps/plot && flutter analyze`, `pnpm --filter @plotday/db run lint`, and the
api test suite before completion.

## Out of scope

- Time-decay or count-weighted ranking (recency-only, capped at 8).
- Applying the signal to compose / file-into-focus pickers.
- Pruning stale (deleted-focus) cells server-side.
- Reusing or changing the `POST /sync/priority-moves` classifier signal.
