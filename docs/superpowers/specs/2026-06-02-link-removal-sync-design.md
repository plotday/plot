# Link-removal sync — design

- **Date:** 2026-06-02
- **Status:** Approved (pre-implementation)
- **Area:** core sync (server `archive_links` / `user.link` + Flutter Drift client)
- **Branch:** TBD (`fix/link-removal-sync` suggested)

## Problem

Plot is local-first: the Flutter client pulls incrementally via `GET /sync/<entity>?seq_since=<horizon>` (rows where `seq >= horizon`, merged by primary key). A bare `DELETE` on a synced table is **invisible** to this protocol — the row simply stops being returned, so any client that already synced it keeps its local copy forever (see `libs/db/AGENTS.md` → "CRITICAL: Removing Rows from Synced Tables").

`public.archive_links` (`libs/db/schema/60-functions/archive_links.sql:76-81`) hard-`DELETE`s `link` rows when a connection's channel is disabled or the connection is archived/uninstalled. The `link` table is synced (read via `user.link`), so every client that previously synced those links is left with **permanent orphans**.

The same `DELETE` cascades to `schedule` rows (`schedule.link_id → link(id) ON DELETE CASCADE`, `libs/db/schema/50-tables/28-schedule.sql:18`), so calendar-event schedules strand on clients too.

### How it surfaced

The channel breadcrumb on a thread is derived from the thread's **primary** link = earliest-created link (`Thread.resolveSharingModel` / `resolvePrimaryAssignmentLink` in `apps/plot/lib/store/thread.dart`). Re-adding an archived connection (e.g. Linear) creates a **new** `twist_instance` that re-syncs the same external items as **new** link rows (new ids, `created_by` = new instance). The old instance's links were `DELETE`d server-side but persist on already-synced clients, so a thread ends up with two links for the same source; the earliest belongs to the archived instance, and primary-link resolution picks the stale one → channel-scoped UI breaks.

Verified evidence (one user's dev data): client had 13 orphan issue links under archived instance `019e89d5`; server had 0 rows for that instance (13 live under instance `019e89e9`). That user's orphans were cleaned manually and the connector-side `sharingModel` issue was fixed separately — **both out of scope here**. This spec is purely the server/client mechanism by which connection archival removes links without stranding clients.

### Why the naive fix fails

The obvious remedy ("set `archived_at` instead of `DELETE`, expose it, hard-delete on the client") fails at the view layer. `user.link` (`libs/db/schema/90-user-schema/30-link.sql:45-61`) only emits a connector link while its owning instance is non-archived:

```sql
LEFT JOIN twist_instance ti
    ON ti.id = l.created_by
    AND l.twist_id IS NOT NULL
    AND ti.archived_at IS NULL          -- gate
...
AND (l.twist_id IS NULL OR ti.owner_id = tp.user_id)   -- NULL → row excluded
```

The instant the connection is archived, the view stops emitting that link entirely — an `archived_at` tombstone would be filtered out by the very archival that created it. This is the same shape as the thread access-loss problem already solved by the `user.thread` / `user.thread_redacted` pattern (`libs/db/AGENTS.md` → "Handling Access Loss to Synced Entities").

## Goals / non-goals

**Goals**

- No connection archival, channel disable, or per-item removal ever strands a `link` (or its `schedule`s) on a client.
- Re-adding a connection / re-enabling a channel converges cleanly — exactly **one live link per source** so the breadcrumb resolves correctly.
- Clean up orphans already sitting on deployed clients.
- Convert the remaining silent thread→link cascade-delete path (`plot/link.ts`) to archive-first (general-mechanism scope).
- No regression for old clients.

**Non-goals**

- The breadcrumb feature itself and the connector-side `sharingModel` fix (already done).
- Broader thread-stranding beyond the `plot/link.ts` orphan-thread conversion.
- Preserving thread/note history across disable→enable (we deliberately chose fresh re-sync; see Decision Log).

## Key invariant

> **A connector link whose owning `twist_instance` is archived must not exist on the client.**

User-authored links (`twist_id IS NULL`) have a user-id `created_by`, never a `twist_instance` id, so they are never affected. Reconnect re-points `created_by` to the live instance via fresh rows, so revived data never matches the archived-instance predicate. This invariant is enforced both reactively (on the synced archival signal) and as a one-time migration (existing orphans).

## Design overview — two mechanisms

Removals fall into two classes by whether a **bulk client signal** is reliably available. The signal is a row the client already syncs (`twist_instance.archived_at`, `channel.enabled`), so bulk removals need **zero per-link sync traffic**.

| Removal | Caller | Server | Client delete signal | Re-appearance |
|---|---|---|---|---|
| **Uninstall** | `management.ts` → `archive_links(i,{})` then archives the instance | hard-delete (**unchanged**) | `twist_instance.archived_at` set | fresh re-sync under new instance |
| **Channel disable** | connector `onChannelDisabled` → `integrations.archiveLinks({channelId})` → `archive_links(i,{channelId})` | hard-delete (**unchanged**) | `channel.enabled → false` | fresh re-sync on re-enable |
| **Per-item** | connector → `integrations.archiveLinks({meta/type/status})` → `archive_links(i,{…})` | **soft-delete** (`archived_at`) | `user.link_redacted` row (`revoked = true`) | fresh (partial unique index) |

`archive_links`' hard-vs-soft choice is **signal-verified, not blindly filter-sniffed**:

- Empty filter (`{}`) → uninstall: caller (`management.ts`) passes an explicit "hard" flag; the instance archival is the guaranteed signal.
- Channel filter (`{channelId}` only) → hard-delete **only if `channel.enabled = false` is confirmed** for that channel (the guaranteed signal); otherwise fall back to soft-delete.
- Any item-specific filter (`meta` / `type` / `status`) → soft-delete.

This makes it impossible for `archive_links` to hard-delete without a client-visible signal, even if a future connector calls `archiveLinks({channelId})` outside a disable.

Re-sync always **inserts fresh rows** (it does not revive tombstones), so there is **no un-archive logic anywhere** — re-sync produces a fresh thread + fresh link, exactly as today, and the partial unique index guarantees one live link per source.

## Server changes

### S1. `link.archived_at` column

`libs/db/schema/50-tables/25-link.sql`: add `archived_at timestamptz` (nullable). `link.seq` (xid8) and the existing `set_link_updated_at` trigger (`update_seq_and_updated_at`) already bump `seq`/`updated_at` on UPDATE, so soft-deletes are seq-visible.

### S2. Partial unique index + `upsert_link` ON CONFLICT

- Change `link_source_priority_unique` (`25-link.sql:75`) to **partial**: `... (source, source_priority_root) WHERE archived_at IS NULL`.
- `upsert_link` (`libs/db/schema/90-user-schema/80-upsert_link.sql:179`): change to `ON CONFLICT (source, source_priority_root) WHERE archived_at IS NULL`.

Effects: live-link dedup is unchanged (all current rows have `archived_at = NULL`); a tombstone no longer occupies the `(source, source_priority_root)` slot, so re-sync **inserts a fresh row** rather than reviving; uniqueness still guarantees **one live link per source**. No `archived_at`-clearing / revival path is introduced.

> Implementation note: PostgreSQL requires the `ON CONFLICT` inference predicate to match the partial index predicate exactly. Grep for any other `ON CONFLICT (source, source_priority_root)` references before landing (none expected outside `upsert_link`; the plain-insert branch at `plot/link.ts:371` uses no `ON CONFLICT`).

### S3. `archive_links` — hard/soft decision

`libs/db/schema/60-functions/archive_links.sql`:

- Keep the existing per-user `thread_priority` archive (lines 66-74) and the `threads_fully_matched` logic (56-65) unchanged.
- Replace the `DELETE FROM public.link` CTE (76-81) with a branch:
  - **Hard path** (bulk signal verified): `DELETE` as today.
  - **Soft path** (per-item): `UPDATE public.link SET archived_at = now() WHERE id IN (matched_links)`.
- Signal verification: add a parameter (e.g. `p_hard boolean DEFAULT NULL`). When `NULL`, derive: hard iff filter is `{}` **and** caller asserts instance archival, **or** filter targets a `channelId` whose `channel.enabled = false`. The two callers set/derive this:
  - `workers/api/src/twist/management.ts:378` (uninstall, `{}`) → pass `p_hard = true`.
  - `workers/api/src/twist/tools/integrations.ts` `archiveLinks` impl (~`:1287`) → resolve `p_hard` from whether the `channelId` is disabled; `meta`/`type`/`status` filters → `p_hard = false`.

### S4. `user.link` view

`libs/db/schema/90-user-schema/30-link.sql`: add `AND l.archived_at IS NULL` to the `WHERE`, and a hard-coded `FALSE AS revoked` column (so both views share a shape). Keep the existing `ti.archived_at IS NULL` gate.

### S5. `user.link_redacted` view (new)

Mirror `user.thread_redacted` (`libs/db/schema/90-user-schema/30-thread.sql:255-299`):

```sql
CREATE OR REPLACE VIEW "user"."link_redacted" AS
SELECT
    ti.owner_id        AS user_id,           -- owner-scoped; never leaks to others
    l.id,
    l.created_at,
    l.archived_at      AS updated_at,        -- frozen identity timestamps
    l.seq,                                   -- frozen seq (see note)
    l.thread_id,
    NULL::text         AS source,            -- sensitive fields NULLed
    l.source_created_at,
    NULL::uuid         AS author_id,
    l.twist_id,
    l.created_by,
    ...                                      -- title/preview/meta/etc. NULLed
    TRUE               AS revoked
FROM link l
JOIN twist_instance ti
    ON ti.id = l.created_by
    AND l.twist_id IS NOT NULL
    AND ti.archived_at IS NULL               -- live instance only → excludes uninstall (bulk-signal handled)
WHERE l.archived_at IS NOT NULL;
```

- **Owner-scoped** via `ti.owner_id` — a connector link is only ever the owner's, so no cross-user leak.
- **Bounded**: bulk-removed links are hard-deleted, so only per-item tombstones on live instances appear here. Channel-disabled links are hard-deleted too, so they never appear (no explicit `channel.enabled` check needed in the view).
- **Frozen seq** is the load-bearing leak/re-emission guard (`libs/db/AGENTS.md` → redacted-view rules). For links the natural frozen value is `l.seq` as of the soft-delete UPDATE: the per-item path never mutates a soft-deleted link again, so `l.seq` is stable and the redacted row emits **once**. **Decision (see Decision Log):** reuse `l.seq` and add `WHERE archived_at IS NULL` guards to any writer that could otherwise touch a soft-deleted link; a dedicated `redacted_seq xid8` column captured at archival is the fallback if a stray writer is found.
- Keep `thread_id` / `priority_id` resolution so the stub sits under its prior priority during the sync→delete window.

### S6. `user.schedule` view

`libs/db/schema/90-user-schema/31-schedule.sql`: add `AND l.archived_at IS NULL` on the `link` join so a soft-deleted link's calendar schedules stop emitting. (Hard-deleted links' schedules are gone server-side via FK cascade and purged client-side by the bulk signal; soft-deleted links' schedules are purged client-side by the redacted-link cascade.)

### S7. `GET /sync/links` — query both views

`workers/api/src/app/sync/links.ts:20`: mirror `GET /sync/threads` (`workers/api/src/app/sync/threads.ts:87-224`) and `/sync/notes` (`notes.ts:54-195`):

- Detect initial sync (`seqSince === "0"` / epoch `updatedSince`).
- Query `user.link`; on **incremental** sync also query `user.link_redacted`, merge, sort by `seq` (then `id`), slice to `limit`.
- **Skip** the redacted query on initial sync (fresh client has nothing to reconcile).

### S8. Thread last-holder trigger

`libs/db/schema/95-triggers/24-thread_last_holder.sql`:

- In `maybe_archive_thread_last_holder`, change the "remaining links" check (lines 39-45) to `... WHERE l.thread_id = v_thread_id AND l.archived_at IS NULL` so soft-deleted links count as absent.
- Add `CREATE TRIGGER maybe_archive_thread_after_link_soft_delete AFTER UPDATE OF archived_at ON public.link FOR EACH ROW WHEN (NEW.archived_at IS NOT NULL AND OLD.archived_at IS NULL) EXECUTE FUNCTION public.maybe_archive_thread_last_holder ();`
- Keep the existing `AFTER DELETE ON public.link` trigger (covers bulk hard-deletes).

### S9. `plot/link.ts` orphan-thread deletes → archive-first

`workers/api/src/twist/tools/plot/link.ts:307` and `:363` (both delete an orphan thread after its links were moved away): convert `deleteFrom("thread")` → `UPDATE thread SET archived_at = now()`. `thread_twist_key_unique WHERE archived_at IS NULL` means archiving frees the `(twist_id, key)` slot just like delete did (dedup unaffected). Guard: a genuinely-never-synced race orphan (no notes, no non-revoked `thread_priority`, just created) may still be hard-deleted to avoid server cruft; otherwise archive. This removes the last thread→link cascade path.

### S10. Types regen

After all schema changes: `pnpm apply-migrations` (auto-runs `pnpm types`), commit `libs/db/src/types.ts`. Verify `pnpm diff-schema-migrations` is clean and `pnpm --filter @plotday/db run lint` passes. No `notify_internal_api_for_*` function changes are needed — `link` syncs via direct `user.link` reads, not a notify payload.

## Client changes (Flutter)

### C1. `Links.revoked` column + processPulledRows cascade

`apps/plot/lib/store/link.dart`:

- Add `BoolColumn get revoked => boolean().withDefault(const Constant(false))();` to the `Links` table (`:242`), mirroring `Threads.revoked` (`thread.dart:132-140`).
- `LinksBase.fromBase` (`:318`): keep `revoked` (do not strip it; it is never pushed back).
- `LinksBase.processPulledRows` (`:331`): divert `revoked == true` rows to a hard-delete that removes the local link **and its schedules by `linkId`** (the client `Schedules` table has both `threadId` and `linkId`, `thread.dart:194-195`), then filter them out of the upsert batch — mirroring `ThreadsBase.processPulledRows` / `_hardDeleteRevokedThreads` (`thread.dart:420-521`).

### C2. Bulk-purge on synced signals

- **Instance archived:** when a `twist_instance` row transitions to `archived_at != null` during sync merge, hard-delete local links where `createdBy == instance.id` + their schedules (by `linkId`). Implement in the twist-instance `BaseTable.processPulledRows` (or its post-merge hook), analogous to C1.
- **Channel disabled:** when a `channel` row transitions to `enabled == false`, hard-delete local links where `createdBy == channel.twistInstanceId AND channelId == channel.channelId` + their schedules. `user.channel` (`libs/db/schema/90-user-schema/32-channel.sql`) syncs `enabled`, `twist_instance_id`, `channel_id`, `seq` to the owner.

> Implementation note: verify the client twist_instance and channel stores expose `archivedAt` / `enabled` and that a transition (not just presence) can be detected on merge. If the stores don't currently retain prior state, compare against the local row before upsert (as C1 does for `pending`).

### C3. One-time migration for existing orphans

Add a Drift `onUpgrade` step (new `schemaVersion`, per `apps/plot/AGENTS.md` "Drift schema changes") that enforces the key invariant once: delete local links whose `createdBy` matches a locally-archived `twist_instance`, plus their schedules. This clears the deployed-client breadcrumb bug. Exact and safe (user-authored links never match; reconnect-revived links point at a live instance).

### C4. Drift migration for `revoked`

Same `onUpgrade` bump: `_safeAddColumn(m, links, links.revoked)` (mirror the thread `revoked` migration). Run `flutter pub run build_runner build`; `flutter analyze`.

## Reconnect walkthrough

**Re-enable a disabled channel:** disable → `channel.enabled=false` (synced) + `archive_links({channelId})` hard-deletes the channel's links; client purges them + schedules; fully-matched threads auto-archive and sync to the client's archive. Re-enable → `channel.enabled=true` → `onChannelEnabled` (`integrations.ts`; `enableSync` dispatches it; owner's client drives refresh) → connector full re-sync → `upsert_link` finds no live row → **inserts fresh** link on a fresh thread → client pulls it. One live link per source; breadcrumb correct. Old empty threads linger in archive (unchanged from today).

**Re-add an archived connection:** uninstall → `twist_instance.archived_at` set (synced) + `archive_links({})` hard-deletes all of the instance's links; client purges by `created_by` + schedules. Re-add → new instance → full re-sync → fresh threads + fresh links under the new instance. Breadcrumb resolves to the single live link, owned by the live instance — strictly better than today (no duplicate, no strand).

Load-bearing property: any re-sync bumps `seq` to a fresh high value (`pg_current_xact_id()`), so the client's cursor always picks up the new rows; the bulk signal is a single synced row, so high-volume removals cost zero per-link traffic.

## Tombstone lifecycle / GC

Per-item soft-deleted rows are few (single deleted source items) and are swept up by the next bulk removal for that instance/channel (uninstall / channel-disable hard-deletes everything for that scope, tombstones included). Frozen seq means the redacted view emits each tombstone once and never re-emits. No dedicated GC job is required; an optional periodic sweep (`DELETE FROM link WHERE archived_at < now() - interval` whose owning instance is archived) is noted as a future option if per-item volume grows.

## Backward compatibility

- Old clients query only `user.link` (now filtered to `archived_at IS NULL`) and do not process `revoked` or the bulk signals. On any removal they simply stop seeing the link — exactly as today. No regression, no new strand.
- New `revoked` column on `user.link` / `user.link_redacted` is additive; old client row parsing ignores unknown fields.
- Production migration safety (`libs/db/AGENTS.md` → "Production Migration Safety"): adding a nullable column, a new view, a new trigger, and converting an index to partial are all single-migration-safe. The `upsert_link` `ON CONFLICT` predicate and the partial index change ship in the **same migration/function** (the worker only calls the RPC), so there is no worker↔DB skew.

## Testing strategy

- **DB / integration (`workers/api` integration config, `__tests__/`):** uninstall hard-deletes links + cascades schedules; channel-disable hard-deletes only that channel's links; per-item `{meta}` soft-deletes (sets `archived_at`), `user.link` hides it, `user.link_redacted` emits it once for the owner with `revoked=true` and a frozen seq; re-sync after each path inserts a fresh single live link (partial-index dedup); `user.schedule` stops emitting a soft-deleted link's schedules; `maybe_archive_thread_last_holder` archives a thread when its last live link is soft-deleted.
- **`/sync/links`:** initial sync omits redacted rows; incremental sync merges both views, sorted by seq; a soft-deleted link surfaces exactly once.
- **Flutter:** `processPulledRows` hard-deletes a `revoked` link + its schedules and excludes it from upsert; instance-archived and channel-disabled merges purge the right links + schedules; the one-time migration clears seeded orphans; `flutter analyze` clean. (Worktree test bootstrap per `apps/plot/AGENTS.md`.)

## Build sequence

1. Schema: `link.archived_at`, partial unique index, `archive_links` branch, `user.link` + `user.link_redacted`, `user.schedule`, last-holder trigger, `upsert_link` ON CONFLICT → `pnpm gen-migration` / `apply-migrations` / commit `types.ts`.
2. Workers: `archive_links` callers (`management.ts`, `integrations.ts` signal resolution), `GET /sync/links` two-view merge, `plot/link.ts` archive-first.
3. Flutter: `Links.revoked` + Drift migration, `processPulledRows` cascade, bulk-purge on instance/channel signals, one-time orphan migration.
4. `/finalize` (lint, error-capture, docs/updates.md note).

## Decision log

- **Scope: general mechanism.** Includes the `plot/link.ts` thread-delete conversion, not only `archive_links`.
- **Bulk = hard-delete + client signal.** The client gets an independent delete signal (archived instance / disabled channel) and only ever re-syncs fresh, never un-deletes — so the server keeps its current hard-delete; no soft-delete/tombstone for bulk cases.
- **Bulk channel signal: yes.** `channel.enabled` drives a client purge so disabling a busy channel doesn't sync thousands of per-link rows.
- **Fresh re-sync, not revival.** Partial unique index → re-sync inserts fresh rows; old links/threads remain archived tombstones. Avoids fragile un-archive coupling to `createThread` / orphan-reconciliation; matches current behavior and the "full re-sync" expectation.
- **Per-item: build minimal soft-delete + bounded `user.link_redacted`.** The only path without a bulk signal; keeps active bundled threads strand-free.
- **Existing orphans: one-time client migration** enforcing the key invariant (same predicate as the reactive purge).

## References

- `libs/db/AGENTS.md` → "Removing Rows from Synced Tables", "Handling Access Loss to Synced Entities", "Bump Parent `seq` on Child-Table Changes".
- Precedent: `user.thread` / `user.thread_redacted` (`libs/db/schema/90-user-schema/30-thread.sql`), `thread_priority.revoked_at` (`50-tables/27-thread_priority.sql`), client `thread.dart:420-521`, sync merge `threads.ts:87-224` / `notes.ts:54-195`, Drift `revoked` migration in `store.dart`.
- Bug surface: `archive_links.sql:76-81`, `user.link` gate `30-link.sql:45-61`, `upsert_link.sql:179`, `plot/link.ts:307,363`, `management.ts:378`, `integrations.ts` `archiveLinks`/`disableSync`/`onChannelEnabled`, last-holder trigger `24-thread_last_holder.sql:39-67`, schedule FK `28-schedule.sql:18`.
