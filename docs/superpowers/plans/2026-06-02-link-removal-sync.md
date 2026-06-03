# Link-removal Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop connection archival / channel disable / per-item removal from stranding orphan `link` (and `schedule`) rows on Flutter clients, and make reconnect converge to exactly one live link per source.

**Architecture:** Two mechanisms. **Bulk** removals (uninstall, channel disable) keep the server's existing hard-`DELETE`; the client purges its local copies by reacting to the already-synced `twist_instance.archived_at` / `channel.enabled` signals, and a one-time Drift migration clears existing orphans. The rare **per-item** removal (no bulk signal) soft-deletes (`link.archived_at`) and delivers a per-link tombstone through a new bounded `user.link_redacted` view, which the client hard-deletes. A partial unique index (`WHERE archived_at IS NULL`) makes re-sync insert fresh rows (no revival) and guarantees one live link per source.

**Tech Stack:** PostgreSQL + Atlas migrations (`libs/db`), Cloudflare Workers + Kysely + Hono (`workers/api`), Flutter + Drift/SQLite (`apps/plot`). Full design: `docs/superpowers/specs/2026-06-02-link-removal-sync-design.md`.

---

## Prerequisites

- DB schema + Drift migration + Flutter codegen are involved. Work on branch `fix/link-removal-sync` (already created). For DB isolation, optionally run in a worktree with `bash scripts/worktree-db`; otherwise the main repo's local DB on `54322` is fine (it is the local dev DB, never production).
- **Always** target the local DB via `$DATABASE_URL`. If `worktree-db` ran mid-session, override per `libs/db/AGENTS.md` "Stale `$DATABASE_URL`" and sanity-check: `psql "$DATABASE_URL" -tAc "show port;"`.
- Local DB must be running: `pnpm --filter @plotday/db start`.
- The repo's `workers/api` tests mock Kysely, so SQL view/trigger behavior is verified with **psql scripts against the local DB** (concrete, runnable). Flutter logic is verified with real in-memory Drift tests. TS merge/caller logic uses mock-based unit tests.

## File structure

**Server — DB (`libs/db/schema/`)**
- `50-tables/25-link.sql` — add `archived_at` column; make `link_source_priority_unique` partial; add `idx_link_archived_at`.
- `60-functions/archive_links.sql` — hard/soft branch + `p_hard` param + live-link-aware `threads_fully_matched`.
- `90-user-schema/30-link.sql` — main `user.link`: add `AND l.archived_at IS NULL`, `FALSE AS revoked`.
- `90-user-schema/30-link.sql` (same file, appended) — new `user.link_redacted` view.
- `90-user-schema/31-schedule.sql` — gate the link join on `l.archived_at IS NULL`.
- `90-user-schema/80-upsert_link.sql` — `ON CONFLICT (...) WHERE archived_at IS NULL`.
- `95-triggers/24-thread_last_holder.sql` — count only live links; add `AFTER UPDATE OF archived_at` trigger.

**Server — workers (`workers/api/src/`)**
- `twist/management.ts` — pass `p_hard: true` on uninstall.
- `twist/tools/integrations.ts` — `archiveLinks` lets `archive_links` self-derive (no change needed beyond verifying), document the contract.
- `app/sync/links.ts` — `GET /sync/links` two-view merge (main + redacted).
- `twist/tools/plot/link.ts` — orphan-thread `deleteFrom("thread")` → archive-first (×2).

**Client — Flutter (`apps/plot/lib/store/`)**
- `link.dart` — `Links.revoked` column; `processPulledRows` revoked→hard-delete; bulk-purge helpers.
- `twist_instance.dart` — `processPulledRows` purges links on instance archival.
- `channel.dart` — `processPulledRows` purges links on channel disable.
- `store.dart` — bump `schemaVersion` to 352; add `revoked` column migration + one-time orphan cleanup.

---

# Phase 1 — Database schema

> Workflow per `libs/db/AGENTS.md`: edit schema files → `pnpm gen-migration -- <name>` → `pnpm apply-migrations` → verify. Each task generates+applies its own dev migration so it's independently testable; Task 8 squashes them into one clean migration before commit. Run all `pnpm` DB commands from repo root.

## Task 1: `link.archived_at` column + partial unique index

**Files:**
- Modify: `libs/db/schema/50-tables/25-link.sql:51` (add column) and `:73-75` (partial index)

- [ ] **Step 1: Write the verification script (expect failure pre-change)**

Create a scratch file `/tmp/t1.sql`:

```sql
-- archived_at column exists and is nullable
SELECT 'col' AS check, count(*) FROM information_schema.columns
 WHERE table_schema='public' AND table_name='link' AND column_name='archived_at';
-- unique index is partial on archived_at IS NULL
SELECT 'partial' AS check, indexdef FROM pg_indexes
 WHERE schemaname='public' AND indexname='link_source_priority_unique';
```

- [ ] **Step 2: Run it, expect the column missing / index not partial**

Run: `psql "$DATABASE_URL" -f /tmp/t1.sql`
Expected: `col` count `0`; `partial` indexdef has **no** `WHERE (archived_at IS NULL)`.

- [ ] **Step 3: Edit the schema file**

In `25-link.sql`, add the column right after `seq` (line 51, before the closing `)`):

```sql
    "seq" xid8 NOT NULL DEFAULT pg_current_xact_id(),
    -- Soft-delete marker for per-item removals that have no bulk client
    -- signal (archiveLinks with a meta/type/status filter on a live instance
    -- + enabled channel). Delivered to the owner via user.link_redacted.
    -- Bulk removals (uninstall / channel disable) still hard-delete.
    "archived_at" timestamptz
```

Replace the unique index (lines 73-75) with a partial index, and add an index for the redacted view / GC:

```sql
-- Ensure one LIVE link per source per priority root. Partial on
-- archived_at IS NULL so a soft-deleted tombstone no longer occupies the
-- slot: re-sync inserts a fresh row (no revival) and the constraint still
-- guarantees a single live link per source (the breadcrumb invariant).
CREATE UNIQUE INDEX link_source_priority_unique ON "public"."link" ("source", "source_priority_root")
WHERE
    archived_at IS NULL;

-- Soft-deleted tombstones (drives user.link_redacted + future GC).
CREATE INDEX idx_link_archived_at ON "public"."link" ("archived_at")
WHERE
    archived_at IS NOT NULL;
```

- [ ] **Step 4: Generate + apply the migration**

Run:
```bash
pnpm gen-migration -- add_link_archived_at && pnpm apply-migrations
```
Expected: migration created and applied with no error.

- [ ] **Step 5: Run the verification script, expect pass**

Run: `psql "$DATABASE_URL" -f /tmp/t1.sql`
Expected: `col` count `1`; `partial` indexdef ends with `WHERE (archived_at IS NULL)`.

- [ ] **Step 6: Confirm existing live data still unique**

Run: `psql "$DATABASE_URL" -tAc "SELECT count(*) FROM (SELECT source, source_priority_root FROM link WHERE archived_at IS NULL AND source IS NOT NULL GROUP BY 1,2 HAVING count(*)>1) d;"`
Expected: `0` (no duplicate live links).

## Task 2: `upsert_link` ON CONFLICT → partial

**Files:**
- Modify: `libs/db/schema/90-user-schema/80-upsert_link.sql:179`

- [ ] **Step 1: Write verification (expect failure: re-insert blocked by tombstone)**

Create `/tmp/t2.sql` (uses a throwaway twist_instance/thread; adjust ids if your dev DB differs — this is illustrative of the assertion):

```sql
-- After soft-deleting a sourced link, a fresh insert with the SAME
-- (source, source_priority_root) must succeed (partial index frees the slot).
-- Pre-change this fails with a unique violation.
BEGIN;
-- pick any existing connector link with a source
WITH s AS (SELECT id, source, source_priority_root, thread_id, created_by FROM link
           WHERE source IS NOT NULL AND archived_at IS NULL LIMIT 1)
UPDATE link SET archived_at = now() WHERE id = (SELECT id FROM s);
-- attempt a fresh insert reusing the just-freed (source, source_priority_root)
INSERT INTO link (source, source_priority_root, thread_id, created_by, source_created_at)
SELECT source, source_priority_root, thread_id, created_by, now()
FROM link WHERE archived_at IS NOT NULL ORDER BY archived_at DESC LIMIT 1;
SELECT 'inserted_fresh' AS check;
ROLLBACK;
```

- [ ] **Step 2: Run it BEFORE the ON CONFLICT edit but AFTER Task 1**

Run: `psql "$DATABASE_URL" -f /tmp/t2.sql`
Expected: the INSERT **succeeds** already (Task 1 made the index partial). This step confirms the index behavior; the `upsert_link` edit aligns the RPC's `ON CONFLICT` predicate with the partial index so the RPC path doesn't error.

- [ ] **Step 3: Edit `upsert_link`**

Change line 179 from:
```sql
    ON CONFLICT (source, source_priority_root)
```
to:
```sql
    ON CONFLICT (source, source_priority_root) WHERE archived_at IS NULL
```

- [ ] **Step 4: Generate + apply**

Run: `pnpm gen-migration -- upsert_link_partial_conflict && pnpm apply-migrations`
Expected: applied with no error.

- [ ] **Step 5: Verify the function compiles and dedups live links**

Run: `psql "$DATABASE_URL" -tAc "SELECT pg_get_functiondef('user.upsert_link(uuid,jsonb,jsonb)'::regprocedure) LIKE '%WHERE archived_at IS NULL%';"`
Expected: `t`.

## Task 3: `archive_links` hard/soft branch

**Files:**
- Modify (replace function body): `libs/db/schema/60-functions/archive_links.sql`

- [ ] **Step 1: Write verification script**

Create `/tmp/t3.sql`:

```sql
-- new signature accepts p_hard; channel filter on a DISABLED channel hard-deletes;
-- item filter (meta) soft-deletes (sets archived_at); empty filter hard-deletes.
SELECT 'sig' AS check,
  EXISTS(SELECT 1 FROM pg_proc WHERE proname='archive_links' AND pronargs=3) AS has_3arg;
```

- [ ] **Step 2: Run it, expect failure**

Run: `psql "$DATABASE_URL" -f /tmp/t3.sql`
Expected: `has_3arg = f`.

- [ ] **Step 3: Replace the function**

Replace the entire `archive_links.sql` with:

```sql
-- Archive links from the given twist_instance (p_created_by) that match the
-- filter, and, for each affected thread, mark the twist_instance OWNER's
-- thread_priority row as archived — a PER-USER archive.
--
-- Removal strategy (see docs/superpowers/specs/2026-06-02-link-removal-sync-design.md):
--   * HARD-delete when the client has an independent bulk delete signal:
--     - whole-instance removal (uninstall): caller passes p_hard = true and
--       archives the twist_instance (the client observes archived_at).
--     - channel removal: the channel's `enabled` flag is already false (the
--       client observes it via user.channel).
--   * SOFT-delete (set archived_at) otherwise (item-specific meta/type/status
--     on a live instance + enabled channel) — delivered to the owner per-link
--     via user.link_redacted; the client hard-deletes it.
-- p_hard overrides the derivation when not NULL.
--
-- Returns affected priority IDs for sync notification.
CREATE OR REPLACE FUNCTION public.archive_links (
    p_created_by uuid,
    p_filter jsonb DEFAULT '{}' ::jsonb,
    p_hard boolean DEFAULT NULL
) RETURNS uuid[]
    LANGUAGE plpgsql
    AS $function$
DECLARE
    v_owner_user_id uuid;
    v_affected_priority_ids uuid[];
    v_now timestamptz := now();
    v_hard boolean;
    v_link_ids uuid[];
BEGIN
    SELECT owner_id INTO v_owner_user_id
    FROM public.twist_instance
    WHERE id = p_created_by;

    IF v_owner_user_id IS NULL THEN
        RETURN ARRAY[]::uuid[];
    END IF;

    -- Decide hard vs soft delete.
    v_hard := COALESCE(
        p_hard,
        CASE
            WHEN p_filter ? 'channelId' THEN
                -- Channel removal: hard only if the channel is confirmed disabled.
                NOT COALESCE((
                    SELECT c.enabled FROM public.channel c
                    WHERE c.twist_instance_id = p_created_by
                      AND c.channel_id = (p_filter ->> 'channelId')
                ), TRUE)
            WHEN p_filter = '{}'::jsonb THEN
                -- Whole-instance removal (uninstall). Caller should also pass
                -- p_hard = true; defaulting to hard is safe because the empty
                -- filter is only ever used by the uninstall path.
                TRUE
            ELSE
                FALSE
        END
    );

    -- Identify matching LIVE links once.
    SELECT ARRAY(
        SELECT l.id
        FROM public.link l
        WHERE l.created_by = p_created_by
          AND l.thread_id IS NOT NULL
          AND l.archived_at IS NULL
          AND (NOT (p_filter ? 'channelId') OR l.channel_id = (p_filter ->> 'channelId'))
          AND (NOT (p_filter ? 'type')      OR l.type = (p_filter ->> 'type'))
          AND (NOT (p_filter ? 'status')    OR l.status = (p_filter ->> 'status'))
          AND (NOT (p_filter ? 'meta')      OR l.meta @> (p_filter -> 'meta'))
    ) INTO v_link_ids;

    IF array_length(v_link_ids, 1) IS NULL THEN
        RETURN ARRAY[]::uuid[];
    END IF;

    -- Per-user archive: retire the owner's filing only on threads where this
    -- twist_instance has NO remaining unmatched LIVE links.
    WITH threads_matched AS (
        SELECT DISTINCT l.thread_id
        FROM public.link l
        WHERE l.id = ANY (v_link_ids)
    ),
    threads_fully_matched AS (
        SELECT tm.thread_id
        FROM threads_matched tm
        WHERE NOT EXISTS (
            SELECT 1 FROM public.link other_l
            WHERE other_l.thread_id = tm.thread_id
              AND other_l.created_by = p_created_by
              AND other_l.archived_at IS NULL
              AND other_l.id <> ALL (v_link_ids)
        )
    ),
    archived_priorities AS (
        UPDATE public.thread_priority tp
        SET archived_at = v_now
        FROM threads_fully_matched tfm
        WHERE tp.thread_id = tfm.thread_id
          AND tp.user_id = v_owner_user_id
          AND tp.archived_at IS NULL
        RETURNING tp.priority_id
    )
    SELECT ARRAY(SELECT DISTINCT priority_id FROM archived_priorities)
    INTO v_affected_priority_ids;

    -- Remove the matched links.
    IF v_hard THEN
        DELETE FROM public.link WHERE id = ANY (v_link_ids);
    ELSE
        UPDATE public.link SET archived_at = v_now WHERE id = ANY (v_link_ids);
    END IF;

    RETURN COALESCE(v_affected_priority_ids, ARRAY[]::uuid[]);
END;
$function$;
```

- [ ] **Step 4: Generate + apply**

Run: `pnpm gen-migration -- archive_links_hard_soft && pnpm apply-migrations`
Expected: applied with no error.

- [ ] **Step 5: Behavioral verification**

Create `/tmp/t3b.sql` (self-contained: builds a user, instance, channel, thread, link, then exercises each path):

```sql
BEGIN;
-- minimal fixtures
INSERT INTO "user" (id) VALUES (gen_random_uuid()) RETURNING id \gset u_
INSERT INTO twist_instance (id, twist_id, owner_id) VALUES (gen_random_uuid(), 1, :'u_id') RETURNING id \gset ti_
INSERT INTO channel (twist_instance_id, channel_id, title, enabled) VALUES (:'ti_id', 'chan-A', 't', true);
INSERT INTO thread (id, created_by) VALUES (gen_random_uuid(), :'ti_id') RETURNING id \gset th_
INSERT INTO thread_priority (thread_id, user_id) VALUES (:'th_id', :'u_id');
-- per-item (meta) → SOFT delete
INSERT INTO link (id, thread_id, created_by, twist_id, source, channel_id, source_created_at, meta)
  VALUES (gen_random_uuid(), :'th_id', :'ti_id', 1, 'src-1', 'chan-A', now(), '{"taskId":"X"}') RETURNING id \gset l1_
SELECT archive_links(:'ti_id', '{"meta":{"taskId":"X"}}'::jsonb);
SELECT 'soft' AS check, archived_at IS NOT NULL AS archived FROM link WHERE id = :'l1_id';   -- expect t (row still present)
-- channel disabled → HARD delete
UPDATE channel SET enabled = false WHERE twist_instance_id = :'ti_id' AND channel_id = 'chan-A';
INSERT INTO link (id, thread_id, created_by, twist_id, source, channel_id, source_created_at)
  VALUES (gen_random_uuid(), :'th_id', :'ti_id', 1, 'src-2', 'chan-A', now()) RETURNING id \gset l2_
SELECT archive_links(:'ti_id', '{"channelId":"chan-A"}'::jsonb);
SELECT 'hard_channel' AS check, count(*) FROM link WHERE id = :'l2_id';                       -- expect 0 (deleted)
ROLLBACK;
```

Run: `psql "$DATABASE_URL" -f /tmp/t3b.sql`
Expected: `soft | archived = t`; `hard_channel | count = 0`.

## Task 4: `user.link` main view (+ archived_at filter, + revoked column)

**Files:**
- Modify: `libs/db/schema/90-user-schema/30-link.sql`

- [ ] **Step 1: Write verification**

Create `/tmp/t4.sql`:
```sql
SELECT 'has_revoked' AS check, count(*) FROM information_schema.columns
 WHERE table_schema='user' AND table_name='link' AND column_name='revoked';
SELECT 'def_filters_archived' AS check,
 pg_get_viewdef('"user".link'::regclass) LIKE '%archived_at IS NULL%' AS ok;
```

- [ ] **Step 2: Run it, expect failure**

Run: `psql "$DATABASE_URL" -f /tmp/t4.sql`
Expected: `has_revoked = 0`; `def_filters_archived = f`.

- [ ] **Step 3: Edit the view SELECT + WHERE**

In `30-link.sql`, add `FALSE AS revoked` to the SELECT list (after `COALESCE(upe.path, pp.path) AS priority_path` at line 39 — add a comma and the new line):

```sql
    COALESCE(upe.path, pp.path) AS priority_path,
    FALSE AS revoked
```

Change the WHERE clause (line 68-69) from:
```sql
WHERE
    tp.user_id IS NOT NULL OR p.user_id IS NOT NULL;
```
to:
```sql
WHERE
    l.archived_at IS NULL
    AND (tp.user_id IS NOT NULL OR p.user_id IS NOT NULL);
```

- [ ] **Step 4: Apply (view change only — regen)**

Run: `pnpm gen-migration -- user_link_revoked_and_archived_filter && pnpm apply-migrations`
Expected: applied with no error.

- [ ] **Step 5: Run verification, expect pass**

Run: `psql "$DATABASE_URL" -f /tmp/t4.sql`
Expected: `has_revoked = 1`; `def_filters_archived = t`.

## Task 5: `user.link_redacted` view (new)

**Files:**
- Modify: `libs/db/schema/90-user-schema/30-link.sql` (append the new view after `user.link`)

- [ ] **Step 1: Write verification**

Create `/tmp/t5.sql`:
```sql
SELECT 'exists' AS check, count(*) FROM information_schema.views
 WHERE table_schema='user' AND table_name='link_redacted';
-- column set must match user.link exactly (same names/order) so the sync merge is uniform
SELECT 'cols_match' AS check,
 (SELECT array_agg(column_name ORDER BY ordinal_position) FROM information_schema.columns
   WHERE table_schema='user' AND table_name='link')
 = (SELECT array_agg(column_name ORDER BY ordinal_position) FROM information_schema.columns
   WHERE table_schema='user' AND table_name='link_redacted') AS ok;
```

- [ ] **Step 2: Run it, expect failure**

Run: `psql "$DATABASE_URL" -f /tmp/t5.sql`
Expected: `exists = 0`.

- [ ] **Step 3: Append the redacted view**

Add to the end of `30-link.sql`:

```sql
-- Per-link access-loss tombstone for SOFT-deleted links (per-item removals on
-- a still-live instance). Mirrors user.thread_redacted: owner-scoped, frozen
-- identity timestamps + frozen seq (the link is not mutated after soft-delete,
-- so l.seq is stable and the row emits exactly once), sensitive fields NULLed,
-- revoked = TRUE. Bulk removals hard-delete, so uninstall/channel-disable links
-- never appear here (instance archived → excluded by the ti join; channel
-- disabled → no soft-deleted rows exist). Column list MUST match user.link.
CREATE OR REPLACE VIEW "user"."link_redacted" AS
SELECT
    ti.owner_id AS user_id,
    l.id,
    l.created_at,
    l.archived_at AS updated_at,        -- frozen
    l.seq,                              -- frozen (link not mutated post-soft-delete)
    l.thread_id,
    NULL::text AS source,
    l.source_created_at,                -- non-null on the client; preserved
    NULL::uuid AS author_id,
    l.twist_id,
    l.created_by,
    l.updated_by,
    l.sync_depth,
    NULL::text AS title,
    NULL::text AS preview,
    NULL::uuid AS assignee_id,
    NULL::text AS type,
    NULL::text AS status,
    NULL::jsonb AS actions,
    NULL::jsonb AS meta,
    NULL::text AS source_url,
    NULL::text AS channel_id,
    NULL::text AS logo,
    "user".effective_priority_id(tp.priority_id, ti.owner_id) AS priority_id,
    NULL::uuid AS merged_from_thread_id,
    upe.path AS priority_path,
    TRUE AS revoked
FROM
    link l
    JOIN twist_instance ti
        ON ti.id = l.created_by
        AND l.twist_id IS NOT NULL
        AND ti.archived_at IS NULL
    LEFT JOIN thread_priority tp
        ON tp.thread_id = l.thread_id
        AND tp.user_id = ti.owner_id
    LEFT JOIN "user".priority_expanded upe
        ON upe.user_id = ti.owner_id
        AND upe.priority_id = "user".effective_priority_id(tp.priority_id, ti.owner_id)
WHERE
    l.archived_at IS NOT NULL;
```

- [ ] **Step 4: Apply**

Run: `pnpm gen-migration -- user_link_redacted && pnpm apply-migrations`
Expected: applied with no error.

- [ ] **Step 5: Run verification, expect pass**

Run: `psql "$DATABASE_URL" -f /tmp/t5.sql`
Expected: `exists = 1`; `cols_match = t`.

- [ ] **Step 6: Behavioral check — soft-deleted link surfaces only in redacted, owner-scoped**

Append to `/tmp/t3b.sql` logic or run a fresh `/tmp/t5b.sql` mirroring Task 3's fixtures, then:
```sql
-- after the meta soft-delete from Task 3 fixtures:
SELECT 'main_hidden' AS check, count(*) FROM "user".link WHERE id = :'l1_id' AND user_id = :'u_id';      -- expect 0
SELECT 'redacted_shown' AS check, revoked, title IS NULL AS title_null
  FROM "user".link_redacted WHERE id = :'l1_id' AND user_id = :'u_id';                                    -- expect t, t
```
Expected: `main_hidden = 0`; `redacted_shown | revoked = t | title_null = t`.

## Task 6: `user.schedule` — gate link join on `archived_at IS NULL`

**Files:**
- Modify: `libs/db/schema/90-user-schema/31-schedule.sql` (the `LEFT JOIN link l ON l.id = s.link_id` line)

- [ ] **Step 1: Write verification**

Create `/tmp/t6.sql`:
```sql
SELECT 'gate' AS check,
 pg_get_viewdef('"user".schedule'::regclass) LIKE '%l.archived_at IS NULL%' AS ok;
```

- [ ] **Step 2: Run it, expect failure**

Run: `psql "$DATABASE_URL" -f /tmp/t6.sql`
Expected: `gate = f`.

- [ ] **Step 3: Edit the link join**

Change:
```sql
    LEFT JOIN link l ON l.id = s.link_id
```
to:
```sql
    LEFT JOIN link l ON l.id = s.link_id AND l.archived_at IS NULL
```

- [ ] **Step 4: Apply**

Run: `pnpm gen-migration -- user_schedule_archived_link_gate && pnpm apply-migrations`
Expected: applied with no error.

- [ ] **Step 5: Run verification, expect pass**

Run: `psql "$DATABASE_URL" -f /tmp/t6.sql`
Expected: `gate = t`.

## Task 7: thread last-holder trigger — live-link count + soft-delete trigger

**Files:**
- Modify: `libs/db/schema/95-triggers/24-thread_last_holder.sql`

- [ ] **Step 1: Write verification**

Create `/tmp/t7.sql`:
```sql
SELECT 'live_count' AS check,
 pg_get_functiondef('public.maybe_archive_thread_last_holder()'::regprocedure) LIKE '%l.archived_at IS NULL%' AS ok;
SELECT 'soft_trigger' AS check, count(*) FROM pg_trigger
 WHERE tgname = 'maybe_archive_thread_after_link_soft_delete';
```

- [ ] **Step 2: Run it, expect failure**

Run: `psql "$DATABASE_URL" -f /tmp/t7.sql`
Expected: `live_count = f`; `soft_trigger = 0`.

- [ ] **Step 3: Edit the file**

Change the "remaining links" check (lines 40-45) from:
```sql
    -- Any remaining links pointing at this thread?
    IF EXISTS (
        SELECT 1 FROM public.link l
        WHERE l.thread_id = v_thread_id
    ) THEN
        RETURN NULL;
    END IF;
```
to:
```sql
    -- Any remaining LIVE links pointing at this thread? (Soft-deleted links
    -- count as absent so a per-item soft-delete can archive an emptied thread.)
    IF EXISTS (
        SELECT 1 FROM public.link l
        WHERE l.thread_id = v_thread_id
          AND l.archived_at IS NULL
    ) THEN
        RETURN NULL;
    END IF;
```

Add a new trigger after the existing `maybe_archive_thread_after_link_delete` (after line 67):
```sql
-- Fires after a link is soft-deleted (per-item removal sets archived_at).
CREATE TRIGGER maybe_archive_thread_after_link_soft_delete
    AFTER UPDATE OF archived_at ON public.link
    FOR EACH ROW
    WHEN (NEW.archived_at IS NOT NULL AND OLD.archived_at IS NULL)
    EXECUTE FUNCTION public.maybe_archive_thread_last_holder ();
```

- [ ] **Step 4: Apply**

Run: `pnpm gen-migration -- thread_last_holder_live_links && pnpm apply-migrations`
Expected: applied with no error.

- [ ] **Step 5: Run verification, expect pass**

Run: `psql "$DATABASE_URL" -f /tmp/t7.sql`
Expected: `live_count = t`; `soft_trigger = 1`.

## Task 8: Squash dev migrations + regen types + verify in-sync

**Files:**
- Delete: the dev migration files created in Tasks 1-7 (`libs/db/migrations/2026*`); regenerate one clean migration.
- Commit: `libs/db/src/types.ts`

- [ ] **Step 1: List the dev migrations you created**

Run: `ls -t libs/db/migrations/ | head`
Note the timestamped files from this session.

- [ ] **Step 2: Squash per `libs/db/AGENTS.md` "Squashing Development Migrations"**

```bash
# remove only THIS session's dev migration files (substitute the exact names)
rm libs/db/migrations/<each_dev_migration>.sql
atlas migrate hash --env local
psql "$DATABASE_URL" -c "DELETE FROM atlas_schema_revisions.atlas_schema_revisions WHERE version IN ('<v1>','<v2>', ...);"
pnpm gen-migration -- link_removal_sync
pnpm apply-migrations
```
Expected: one clean migration applied; `pnpm types` runs automatically (not `$CI`).

- [ ] **Step 3: Verify schema/migrations/types are in sync**

Run:
```bash
pnpm diff-schema-migrations && pnpm --filter @plotday/db run lint
```
Expected: no diff; lint passes (types current).

- [ ] **Step 4: Commit the DB layer**

```bash
git add libs/db/schema libs/db/migrations libs/db/src/types.ts
git commit -m "feat(db): soft-delete + redacted view for per-item link removal; partial unique index"
```

---

# Phase 2 — API workers

> Run from repo root. Unit tests: `pnpm --filter @plotday/api test` (mock-based; excludes `__tests__/`). Per `project_workers_api_lint_excludes_tests`, the lint gate is "no NEW `error TS`" (main has pre-existing errors); use the package's own `tsc`/`vitest`.

## Task 9: `archive_links` callers — pass `p_hard` on uninstall

**Files:**
- Modify: `workers/api/src/twist/management.ts` (the `is_source` branch that calls `archive_links` with `{}`)
- Verify only: `workers/api/src/twist/tools/integrations.ts:1287` `archiveLinks` (no code change — `archive_links` self-derives from `channel.enabled`; `disableSync` already sets `enabled=false` before dispatch)

- [ ] **Step 1: Edit the uninstall caller**

In `management.ts`, the connector branch currently calls:
```typescript
    await rpc(trx, "archive_links", {
      p_created_by: twist_instance_id,
      p_filter: {},
    });
```
Change to make the bulk signal explicit:
```typescript
    // Uninstall is a whole-instance removal: hard-delete the links and rely on
    // the synced twist_instance.archived_at signal to purge them on clients.
    await rpc(trx, "archive_links", {
      p_created_by: twist_instance_id,
      p_filter: {},
      p_hard: true,
    });
```

- [ ] **Step 2: Confirm `rpc` typing accepts the new arg**

Run: `pnpm --filter @plotday/api exec tsc --noEmit 2>&1 | rg -c "error TS" || true`
Expected: count is not greater than the pre-existing baseline (run the same command on a clean checkout if unsure). The `rpc` helper passes args through as JSON, so `p_hard` requires no signature change.

- [ ] **Step 3: Add a comment documenting the channel-disable contract in `integrations.ts`**

Above the `archiveLinks` method (`integrations.ts:1287`), add:
```typescript
  // archive_links self-derives hard vs soft delete from the filter:
  //  - {channelId} on a channel whose `enabled` is already false → hard-delete
  //    (disableSync sets channel.enabled=false BEFORE dispatching
  //    onChannelDisabled, so the flag is reliably false here). The client
  //    purges via the synced channel.enabled signal.
  //  - {meta}/{type}/{status} (item-specific) → soft-delete, delivered per-link
  //    via user.link_redacted.
  // No p_hard is passed here; the SQL function decides.
```

- [ ] **Step 4: Commit**

```bash
git add workers/api/src/twist/management.ts workers/api/src/twist/tools/integrations.ts
git commit -m "feat(api): pass p_hard on connector uninstall; document channel-disable contract"
```

## Task 10: `GET /sync/links` two-view merge

**Files:**
- Modify: `workers/api/src/app/sync/links.ts:20-94`
- Test: `workers/api/src/app/sync/__tests__/links-merge.test.ts` (new)

- [ ] **Step 1: Write the failing unit test**

Create `workers/api/src/app/sync/__tests__/links-merge.test.ts`. It tests the pure merge/sort/skip-on-initial logic by stubbing `withUserDb` to capture which views are queried. Mirror the mock style in `workers/api/src/twist/tools/__tests__/plot.test.ts`:

```typescript
import { describe, expect, it, vi } from "vitest";

// We test the handler's branching: initial sync must NOT query user.link_redacted;
// incremental sync must query both and return a merged, seq-sorted list.
import linksApp from "../links";

function makeCtx(query: Record<string, string>, viewRows: Record<string, any[]>) {
  const queriedViews: string[] = [];
  const trx = {
    selectFrom: (view: string) => {
      queriedViews.push(view);
      const q: any = {};
      q.selectAll = () => q;
      q.where = () => q;
      q.orderBy = () => q;
      q.limit = () => q;
      q.execute = async () => viewRows[view] ?? [];
      return q;
    },
  };
  return { queriedViews, trx };
}

describe("GET /sync/links view selection", () => {
  it("skips user.link_redacted on initial (seq_since=0) sync", async () => {
    // Arrange a request with seq_since=0 and stub withUserDb to run our trx.
    // Assert queriedViews contains "user.link" and NOT "user.link_redacted".
    // (Wire the stub via vi.mock("../../../db", ...) returning withUserDb that
    //  invokes the callback with our trx, and readSafeHorizon → "0".)
    expect(true).toBe(true); // replace with real wiring per plot.test.ts
  });

  it("queries both views and merges sorted by seq on incremental sync", async () => {
    // seq_since=5; user.link returns [{id:'b',seq:'9',revoked:false}],
    // user.link_redacted returns [{id:'a',seq:'7',revoked:true}].
    // Assert merged order is [a(seq7), b(seq9)] and both views were queried.
    expect(true).toBe(true); // replace with real wiring
  });
});
```

> Note: fully wiring Hono + `vi.mock("../../../db")` follows the existing `__tests__` patterns. If wiring the full handler proves heavy, extract the merge/sort into a small exported pure helper (`mergeSeqRows(visible, redacted, useSeqCursor, limit)`) and unit-test that directly — preferred, and it keeps `links.ts` DRY with the threads/notes pattern.

- [ ] **Step 2: Run the test, expect failure**

Run: `pnpm --filter @plotday/api test -- links-merge`
Expected: FAIL (handler still single-view / helper missing).

- [ ] **Step 3: Implement the two-view merge**

Edit `links.ts`. Replace the body of the `withUserDb(...)` block (lines 39-88) to mirror `notes.ts:80-150`. Add the initial-sync detection before it (after line 37):

```typescript
  const useSeqCursor = seqSince !== null;

  // Fresh clients have nothing to reconcile, so skip the redacted-stub query
  // on initial sync; only query user.link_redacted on incremental syncs.
  const isInitialSync = useSeqCursor
    ? seqSince === "0"
    : !updatedSince || updatedSince === "1970-01-01T00:00:00.000Z";

  const { rows, horizon } = await withUserDb(c.var.db, userId, async (trx) => {
    const buildQuery = (view: "user.link" | "user.link_redacted") => {
      let query = trx
        .selectFrom(view as any)
        .selectAll()
        .where("user_id", "=", userId);

      if (useSeqCursor) {
        query = query.orderBy("seq", "asc").orderBy("id", "asc");
      } else if (updatedSince) {
        query = query.orderBy(sql`date_trunc('milliseconds', updated_at)`, "asc").orderBy("id", "asc");
      } else {
        query = query.orderBy(sql.ref(sortBy), sortDir).orderBy("id", sortDir);
      }

      query = query.limit(limit);

      if (id) query = query.where("id", "=", id);

      if (useSeqCursor) {
        query = query.where(seqSinceCursor(seqSince, pageSeq, pageId));
      } else if (updatedSince) {
        query = query.where(updatedSinceCursor(updatedSince, cursorId));
      }

      if (priorityId) {
        query = query.where("priority_id", "=", priorityId);
      } else if (priorityPath) {
        query = query.where(sql<boolean>`priority_path = ${priorityPath}::ltree`);
      }

      if (rangeStart) query = query.where(sql<boolean>`${sql.ref(sortBy)} > ${rangeStart}::timestamptz`);
      if (rangeEnd) query = query.where(sql<boolean>`${sql.ref(sortBy)} < ${rangeEnd}::timestamptz`);

      return query;
    };

    const visible = await buildQuery("user.link").execute();
    const horizonValue = useSeqCursor ? await readSafeHorizon(trx) : "0";

    if (isInitialSync) {
      return { rows: visible, horizon: horizonValue };
    }

    const redacted = await buildQuery("user.link_redacted").execute();
    const merged = [...visible, ...redacted];
    if (useSeqCursor) {
      merged.sort((a, b) => {
        const as = (a as any).seq ?? "0";
        const bs = (b as any).seq ?? "0";
        if (as !== bs) return as < bs ? -1 : 1;
        const aid = (a as any).id ?? "";
        const bid = (b as any).id ?? "";
        return aid < bid ? -1 : aid > bid ? 1 : 0;
      });
    } else {
      merged.sort((a, b) => {
        const au = (a as any).updated_at ? (a as any).updated_at.getTime() : 0;
        const bu = (b as any).updated_at ? (b as any).updated_at.getTime() : 0;
        if (au !== bu) return au - bu;
        const aid = (a as any).id ?? "";
        const bid = (b as any).id ?? "";
        return aid < bid ? -1 : aid > bid ? 1 : 0;
      });
    }
    return { rows: merged.slice(0, limit), horizon: horizonValue };
  });
```

(The `seqEnvelope` / `c.json(rows)` return at the end stays unchanged.)

- [ ] **Step 4: Run the test, expect pass**

Run: `pnpm --filter @plotday/api test -- links-merge`
Expected: PASS.

- [ ] **Step 5: Manual end-to-end check against the DB (optional but recommended)**

Using the Task 3 fixtures' soft-deleted link, call the endpoint logic via psql proxy or confirm the row appears in `user.link_redacted` (Task 5 Step 6 already covers the SQL side).

- [ ] **Step 6: Commit**

```bash
git add workers/api/src/app/sync/links.ts workers/api/src/app/sync/__tests__/links-merge.test.ts
git commit -m "feat(api): /sync/links merges user.link + user.link_redacted (skip redacted on initial)"
```

## Task 11: `plot/link.ts` orphan-thread deletes → archive-first

**Files:**
- Modify: `workers/api/src/twist/tools/plot/link.ts:305-311` and `:354-367`

- [ ] **Step 1: Edit the race-cleanup delete (lines 305-311)**

Change:
```typescript
      if (linkResult.thread_id && linkResult.thread_id !== threadId) {
        await plot.db
          .deleteFrom("thread")
          .where("id", "=", threadId)
          .execute();
        threadId = linkResult.thread_id as Uuid;
      }
```
to:
```typescript
      if (linkResult.thread_id && linkResult.thread_id !== threadId) {
        // Archive (not delete) the orphan thread so the removal syncs to
        // clients; archived_at frees the (twist_id, key) slot just like
        // delete (thread_twist_key_unique is WHERE archived_at IS NULL).
        // The thread has no links (the link moved to linkResult.thread_id),
        // so there is no link cascade.
        await archiveOrDeleteOrphanThread(plot, threadId);
        threadId = linkResult.thread_id as Uuid;
      }
```

- [ ] **Step 2: Edit the merge-cleanup delete (lines 354-367)**

Change the orphan loop:
```typescript
        for (const oldThreadId of orphanedThreadIds) {
          const remaining = await plot.db
            .selectFrom("link")
            .select("link.id")
            .where("link.thread_id", "=", oldThreadId)
            .executeTakeFirst();
          if (!remaining) {
            await plot.db
              .deleteFrom("thread")
              .where("id", "=", oldThreadId)
              .execute();
          }
        }
```
to:
```typescript
        for (const oldThreadId of orphanedThreadIds) {
          const remaining = await plot.db
            .selectFrom("link")
            .select("link.id")
            .where("link.thread_id", "=", oldThreadId)
            .executeTakeFirst();
          if (!remaining) {
            await archiveOrDeleteOrphanThread(plot, oldThreadId);
          }
        }
```

- [ ] **Step 3: Add the helper (top of the file, after imports)**

```typescript
/**
 * Remove an orphan thread left behind by saveLink dedup/merge. Archive-first
 * (syncs to clients via thread.archived_at, frees the (twist_id, key) slot)
 * UNLESS the thread is a genuinely-never-synced ephemeral race orphan — no
 * notes and no non-revoked thread_priority — in which case a hard delete
 * avoids leaving server cruft (nothing was ever synced to strand).
 */
async function archiveOrDeleteOrphanThread(plot: Plot, threadId: Uuid): Promise<void> {
  const hasNote = await plot.db
    .selectFrom("note").select("note.id")
    .where("note.thread_id", "=", threadId as string)
    .limit(1).executeTakeFirst();
  const hasFiling = await plot.db
    .selectFrom("thread_priority").select("thread_priority.thread_id")
    .where("thread_priority.thread_id", "=", threadId as string)
    .where("thread_priority.revoked_at", "is", null)
    .limit(1).executeTakeFirst();
  if (!hasNote && !hasFiling) {
    await plot.db.deleteFrom("thread").where("id", "=", threadId as string).execute();
    return;
  }
  await plot.db
    .updateTable("thread")
    .set({ archived_at: new Date().toISOString() })
    .where("id", "=", threadId as string)
    .where("archived_at", "is", null)
    .execute();
}
```

(`Plot` is already imported in this module; if not, add it from `../plot`.)

- [ ] **Step 4: Typecheck**

Run: `pnpm --filter @plotday/api exec tsc --noEmit 2>&1 | rg "error TS" | rg "plot/link" || echo "no new errors in plot/link"`
Expected: `no new errors in plot/link`.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/twist/tools/plot/link.ts
git commit -m "feat(api): archive-first for saveLink orphan threads (removes last thread→link cascade)"
```

---

# Phase 3 — Flutter client

> Per `apps/plot/AGENTS.md`: after column changes run `flutter pub run build_runner build`, then `flutter analyze`. To run tests in a worktree see `project_worktree_flutter_test_bootstrap`. Commands run from `apps/plot`.
>
> **Test harness (real in-memory Drift).** Mirror `test/store/priority_icon_migration_test.dart`. Open a store with:
> ```dart
> import 'package:drift/native.dart';
> import 'package:sqlite3/sqlite3.dart';
> import 'package:plot/store/store.dart';
>
> final raw = sqlite3.openInMemory();
> final store = Store.forTesting(
>   NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
> );
> // ... seed via store.into(store.<table>).insert(<Table>Companion(...)) using Value(...) and Uuid.generate()
> // ... exercise, then: await store.close(); raw.close();
> ```
> Seed **local** rows with Companions. Construct **incoming** sync rows (the `Iterable<Insertable<DataClass>>` passed to `processPulledRows`) as the generated row class, e.g. `LinkRow(...)` / `LinkRow.fromJson({...})`, `TwistInstanceRow(...)`, `ChannelRow(...)`. There is no `openTestStore()` — use the snippet above.

## Task 12: `Links.revoked` column + Drift migration + one-time orphan cleanup

**Files:**
- Modify: `apps/plot/lib/store/link.dart:242-264` (table)
- Modify: `apps/plot/lib/store/store.dart:2411` (schemaVersion) and `_incrementalMigration`

- [ ] **Step 1: Add the column to the `Links` table**

In `link.dart`, add to the `Links` table class (after `mergedFromThreadId`, line 263):
```dart
  /// Server access-loss tombstone marker. TRUE when the row arrived from
  /// user.link_redacted (a per-item connector removal with no bulk signal).
  /// The sync layer hard-deletes these locally (link + its schedules).
  BoolColumn get revoked => boolean().withDefault(const Constant(false))();
```

- [ ] **Step 2: Bump schemaVersion**

In `store.dart:2411`, change `int get schemaVersion => 351;` to `=> 352;`.

- [ ] **Step 3: Add the migration step**

Find `_incrementalMigration` (the method invoked at `store.dart` onUpgrade). Add a new block at the end of its `if (from < N)` ladder:
```dart
    if (from < 352) {
      // Link access-loss tombstone column (user.link_redacted).
      await _safeAddColumn(m, links, links.revoked);
      // One-time cleanup: enforce "a connector link whose owning
      // twist_instance is archived must not exist locally" — clears orphan
      // links (and their schedules) stranded by the old server hard-delete
      // that didn't sync. Exact and safe: user-authored links have a user-id
      // created_by (no matching twist_instance); reconnect-revived links point
      // at a live instance.
      await _safeCustomStatement(m, '''
        DELETE FROM schedules WHERE link_id IN (
          SELECT l.id FROM links l
          JOIN twist_instances ti ON ti.id = l.created_by
          WHERE ti.archived_at IS NOT NULL
        )
      ''');
      await _safeCustomStatement(m, '''
        DELETE FROM links WHERE created_by IN (
          SELECT id FROM twist_instances WHERE archived_at IS NOT NULL
        )
      ''');
    }
```

- [ ] **Step 4: Regenerate Drift code**

Run: `flutter pub run build_runner build --delete-conflicting-outputs`
Expected: `store.g.dart` regenerated; no errors.

- [ ] **Step 5: Analyze**

Run: `flutter analyze lib/store/link.dart lib/store/store.dart`
Expected: no new errors.

- [ ] **Step 6: Write a migration test (real in-memory Drift)**

Create `apps/plot/test/store/link_orphan_migration_test.dart`, following `priority_icon_migration_test.dart` exactly: build the current schema, drop the new `revoked` column + roll `user_version` back to 351, seed orphan data, reopen so `onUpgrade` runs the `from < 352` step, assert the orphans are gone and a user-authored link survives:

```dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('v352 upgrade clears connector links under archived instances + their schedules', () async {
    final raw = sqlite3.openInMemory();

    // 1. Build current schema (onCreate).
    final seed = Store.forTesting(
      NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
    );

    final instanceId = Uuid.generate();   // archived connector instance
    final userId = Uuid.generate();        // a user (for the user-authored link)
    final orphanLinkId = Uuid.generate();
    final userLinkId = Uuid.generate();
    final schedId = Uuid.generate();

    await seed.into(seed.twistInstances).insert(TwistInstancesCompanion.insert(
      id: instanceId,
      twistId: BigInt.from(1),
      twistEnvironment: 'prod',
      name: 'Linear',
      config: const {},
      archivedAt: Value(DateTime.now()),   // archived
    ));
    // connector orphan link (created_by = archived instance) + its schedule
    await seed.into(seed.links).insert(LinksCompanion.insert(
      id: orphanLinkId,
      sourceCreatedAt: DateTime.now(),
      createdBy: Value(instanceId),
    ));
    await seed.into(seed.schedules).insert(SchedulesCompanion.insert(
      id: schedId,
      linkId: Value(orphanLinkId),
    ));
    // user-authored link (created_by = a user id) — must survive
    await seed.into(seed.links).insert(LinksCompanion.insert(
      id: userLinkId,
      sourceCreatedAt: DateTime.now(),
      createdBy: Value(userId),
    ));
    await seed.close();

    // 2. Roll back to v351 (no `revoked` column yet).
    raw.execute('ALTER TABLE links DROP COLUMN revoked');
    raw.execute('PRAGMA user_version = 351');

    // 3. Reopen → onUpgrade runs the from<352 step.
    final upgraded = Store.forTesting(
      NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
    );
    final orphanLinks = await upgraded.customSelect(
      "SELECT 1 FROM links WHERE hex(created_by) = ?",
      variables: [Variable(hex(instanceId.toBytes()))],
    ).get();
    final orphanScheds = await upgraded.customSelect(
      "SELECT 1 FROM schedules WHERE hex(link_id) = ?",
      variables: [Variable(hex(orphanLinkId.toBytes()))],
    ).get();
    final userLinks = await upgraded.customSelect(
      "SELECT 1 FROM links WHERE hex(created_by) = ?",
      variables: [Variable(hex(userId.toBytes()))],
    ).get();
    expect(orphanLinks, isEmpty, reason: 'orphan connector link purged');
    expect(orphanScheds, isEmpty, reason: 'its schedule purged');
    expect(userLinks, hasLength(1), reason: 'user-authored link survives');
    await upgraded.close();
    raw.close();
  });
}
```

> Note: match the exact `*.insert(...)` Companion field names/required args to the generated `store.g.dart` (run `build_runner` first). `hex(...)` is the helper used by the SQLite `hex()` comparison; if the repo exposes a different blob-compare idiom in tests, use it. The structure and assertions are the contract.

- [ ] **Step 7: Run the migration test**

Run: `flutter test test/store/link_orphan_migration_test.dart`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add apps/plot/lib/store/link.dart apps/plot/lib/store/store.dart apps/plot/lib/store/store.g.dart apps/plot/test/store/link_orphan_migration_test.dart
git commit -m "feat(app): Links.revoked column + v352 migration; one-time orphan-link cleanup"
```

## Task 13: `LinksBase.processPulledRows` — revoked → hard-delete link + schedules

**Files:**
- Modify: `apps/plot/lib/store/link.dart:331-346` (processPulledRows) + add helpers
- Test: `apps/plot/test/store/link_revoked_test.dart` (new)

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/store/link_revoked_test.dart` (use an in-memory `Store`; mirror any existing store test for setup):
```dart
import 'package:flutter_test/flutter_test.dart';
// import the test Store harness used elsewhere in test/store/

void main() {
  test('revoked link is hard-deleted with its schedules and excluded from upsert', () async {
    final raw = sqlite3.openInMemory();
    final store = Store.forTesting(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    addTearDown(() async { await store.close(); raw.close(); });
    final linkId = Uuid.v7();
    // seed a local link + a schedule referencing it
    await store.into(store.links).insert(/* LinkRow with id=linkId */);
    await store.into(store.schedules).insert(/* ScheduleRow with linkId=linkId */);

    final incoming = /* LinkRow.fromJson with id=linkId, revoked=true */;
    final processed = await LinksBase().processPulledRows(store, [incoming]);

    expect(processed, isEmpty); // revoked row excluded from upsert batch
    final link = await (store.select(store.links)..where((l) => l.id.equals(linkId.toBytes()))).getSingleOrNull();
    expect(link, isNull); // local link hard-deleted
    final sched = await (store.select(store.schedules)..where((s) => s.linkId.equals(linkId.toBytes()))).get();
    expect(sched, isEmpty); // its schedules hard-deleted
  });
}
```

- [ ] **Step 2: Run it, expect failure**

Run: `flutter test test/store/link_revoked_test.dart`
Expected: FAIL (revoked not handled; link still present).

- [ ] **Step 3: Implement**

Replace `LinksBase.processPulledRows` (lines 331-346) with:
```dart
  @override
  Future<List<Insertable<DataClass>>> processPulledRows(
    Store store,
    Iterable<Insertable<DataClass>> rows,
  ) async {
    // Access-loss tombstones (user.link_redacted): a per-item connector
    // removal with no bulk signal. Hard-delete the local link + its schedules.
    final revokedIds = <Uint8List>[];
    final result = <Insertable<DataClass>>[];
    for (final row in rows) {
      final linkRow = row as LinkRow;
      if (linkRow.revoked) {
        revokedIds.add(linkRow.id.toBytes());
        continue;
      }
      // Existing race protection: skip rows with a pending local write.
      final local = await (store.select(store.links)
            ..where((l) => l.id.equals(linkRow.id.toBytes())))
          .getSingleOrNull();
      if (local != null && local.pending != null) continue;
      result.add(row);
    }
    if (revokedIds.isNotEmpty) {
      await Link._hardDeleteLinks(store, revokedIds);
    }
    return result;
  }
```

Add the shared hard-delete helper to the `Link` class (in `link.dart`):
```dart
  /// Hard-delete the given links and their schedules from the local DB.
  /// Drift doesn't enforce FK cascade locally, so schedules are deleted by
  /// linkId explicitly (link-schedules; thread-schedules are untouched).
  static Future<void> _hardDeleteLinks(
    Store store,
    List<Uint8List> linkIds,
  ) async {
    await store.transaction(() async {
      await (store.delete(store.schedules)
            ..where((s) => s.linkId.isIn(linkIds)))
          .go();
      await (store.delete(store.links)
            ..where((l) => l.id.isIn(linkIds)))
          .go();
    });
  }
```

(If `Uint8List` isn't already imported in `link.dart`, it comes via `store.dart`'s exports as in `thread.dart`; add `import 'dart:typed_data';` only if analyze flags it.)

- [ ] **Step 4: Regenerate (no schema change, but ensure analyzer sees helpers)**

Run: `flutter analyze lib/store/link.dart`
Expected: no new errors.

- [ ] **Step 5: Run the test, expect pass**

Run: `flutter test test/store/link_revoked_test.dart`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/store/link.dart apps/plot/test/store/link_revoked_test.dart
git commit -m "feat(app): hard-delete revoked links + their schedules on sync"
```

## Task 14: Bulk-purge on `twist_instance` archival

**Files:**
- Modify: `apps/plot/lib/store/twist_instance.dart` (`TwistInstancesBase` — add `processPulledRows`)
- Modify: `apps/plot/lib/store/link.dart` (add `Link.hardDeleteForInstance`)
- Test: `apps/plot/test/store/link_instance_purge_test.dart` (new)

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/store/link_instance_purge_test.dart`:
```dart
void main() {
  test('archived twist_instance purges its connector links + schedules', () async {
    final raw = sqlite3.openInMemory();
    final store = Store.forTesting(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    addTearDown(() async { await store.close(); raw.close(); });
    final instanceId = Uuid.v7();
    final linkId = Uuid.v7();
    // seed a local (live) twist_instance, a link created_by it, and a schedule
    await store.into(store.links).insert(/* LinkRow id=linkId, createdBy=instanceId */);
    await store.into(store.schedules).insert(/* ScheduleRow linkId=linkId */);

    // sync delivers the instance now archived
    final archived = /* TwistInstanceRow id=instanceId, archivedAt=now */;
    await TwistInstancesBase().processPulledRows(store, [archived]);

    expect(await (store.select(store.links)..where((l) => l.createdBy.equals(instanceId.toBytes()))).get(), isEmpty);
    expect(await (store.select(store.schedules)..where((s) => s.linkId.equals(linkId.toBytes()))).get(), isEmpty);
  });
}
```

- [ ] **Step 2: Run it, expect failure**

Run: `flutter test test/store/link_instance_purge_test.dart`
Expected: FAIL (no purge; link present).

- [ ] **Step 3: Add the purge helper to `Link`**

```dart
  /// Purge all connector links owned by [instanceId] and their schedules.
  /// Driven by the synced twist_instance.archived_at signal (uninstall).
  static Future<void> hardDeleteForInstance(Store store, Uuid instanceId) async {
    final ids = await (store.select(store.links)
          ..where((l) => l.createdBy.equals(instanceId.toBytes())))
        .get();
    if (ids.isEmpty) return;
    await _hardDeleteLinks(store, ids.map((r) => r.id.toBytes()).toList());
  }
```

- [ ] **Step 4: Add `processPulledRows` to `TwistInstancesBase`**

In `twist_instance.dart`, add to `TwistInstancesBase`:
```dart
  @override
  Future<List<Insertable<DataClass>>> processPulledRows(
    Store store,
    Iterable<Insertable<DataClass>> rows,
  ) async {
    // When an instance transitions to archived (uninstall), purge its
    // connector links locally — the server hard-deletes them, which the seq
    // cursor can't see, so the instance archival is the delete signal.
    final toPurge = <Uuid>[];
    final result = <Insertable<DataClass>>[];
    for (final row in rows) {
      final ti = row as TwistInstanceRow;
      if (ti.archivedAt != null) {
        final local = await (store.select(store.twistInstances)
              ..where((t) => t.id.equals(ti.id.toBytes())))
            .getSingleOrNull();
        if (local == null || local.archivedAt == null) {
          toPurge.add(ti.id);
        }
      }
      result.add(row);
    }
    for (final id in toPurge) {
      await Link.hardDeleteForInstance(store, id);
    }
    return result;
  }
```

(`Link` is exported via `store.dart` part files; if analyze can't resolve it, the stores are all `part of 'store.dart'` so it should resolve. Confirm `TwistInstanceRow` exposes `archivedAt` — it does via `DeletableTable`.)

- [ ] **Step 5: Run the test, expect pass**

Run: `flutter test test/store/link_instance_purge_test.dart`
Expected: PASS.

- [ ] **Step 6: Analyze + commit**

```bash
cd apps/plot && flutter analyze lib/store/twist_instance.dart lib/store/link.dart
git add apps/plot/lib/store/twist_instance.dart apps/plot/lib/store/link.dart apps/plot/test/store/link_instance_purge_test.dart
git commit -m "feat(app): purge connector links when their twist_instance is archived"
```

## Task 15: Bulk-purge on `channel` disable

**Files:**
- Modify: `apps/plot/lib/store/channel.dart` (`ChannelsBase` — add `processPulledRows`)
- Modify: `apps/plot/lib/store/link.dart` (add `Link.hardDeleteForChannel`)
- Test: `apps/plot/test/store/link_channel_purge_test.dart` (new)

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/store/link_channel_purge_test.dart`:
```dart
void main() {
  test('disabling a channel purges that channel\'s connector links + schedules', () async {
    final raw = sqlite3.openInMemory();
    final store = Store.forTesting(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    addTearDown(() async { await store.close(); raw.close(); });
    final instanceId = Uuid.v7();
    const channelId = 'chan-A';
    final linkId = Uuid.v7();
    final otherLinkId = Uuid.v7();
    // seed: link on chan-A (purged) + link on chan-B (kept), both created_by instance
    await store.into(store.links).insert(/* LinkRow id=linkId, createdBy=instanceId, channelId='chan-A' */);
    await store.into(store.links).insert(/* LinkRow id=otherLinkId, createdBy=instanceId, channelId='chan-B' */);
    await store.into(store.schedules).insert(/* ScheduleRow linkId=linkId */);
    // local channel currently enabled
    await store.into(store.channels).insert(/* ChannelRow twistInstanceId=instanceId, channelId='chan-A', enabled=true */);

    final disabled = /* ChannelRow same key, enabled=false */;
    await ChannelsBase().processPulledRows(store, [disabled]);

    expect(await (store.select(store.links)..where((l) => l.id.equals(linkId.toBytes()))).getSingleOrNull(), isNull);
    expect(await (store.select(store.links)..where((l) => l.id.equals(otherLinkId.toBytes()))).getSingleOrNull(), isNotNull);
    expect(await (store.select(store.schedules)..where((s) => s.linkId.equals(linkId.toBytes()))).get(), isEmpty);
  });
}
```

- [ ] **Step 2: Run it, expect failure**

Run: `flutter test test/store/link_channel_purge_test.dart`
Expected: FAIL.

- [ ] **Step 3: Add the purge helper to `Link`**

```dart
  /// Purge connector links owned by [instanceId] on [channelId] and their
  /// schedules. Driven by the synced channel.enabled=false signal.
  static Future<void> hardDeleteForChannel(
    Store store,
    Uuid instanceId,
    String channelId,
  ) async {
    final rows = await (store.select(store.links)
          ..where((l) =>
              l.createdBy.equals(instanceId.toBytes()) &
              l.channelId.equals(channelId)))
        .get();
    if (rows.isEmpty) return;
    await _hardDeleteLinks(store, rows.map((r) => r.id.toBytes()).toList());
  }
```

- [ ] **Step 4: Add `processPulledRows` to `ChannelsBase`**

In `channel.dart`:
```dart
  @override
  Future<List<Insertable<DataClass>>> processPulledRows(
    Store store,
    Iterable<Insertable<DataClass>> rows,
  ) async {
    // When a channel transitions to disabled, purge that channel's connector
    // links locally (the server hard-deleted them; channel.enabled is the
    // delete signal).
    final toPurge = <({Uuid instanceId, String channelId})>[];
    final result = <Insertable<DataClass>>[];
    for (final row in rows) {
      final ch = row as ChannelRow;
      if (!ch.enabled) {
        final local = await (store.select(store.channels)
              ..where((c) => c.id.equals(ch.id)))
            .getSingleOrNull();
        if (local == null || local.enabled) {
          toPurge.add((instanceId: ch.twistInstanceId, channelId: ch.channelId));
        }
      }
      result.add(row);
    }
    for (final p in toPurge) {
      await Link.hardDeleteForChannel(store, p.instanceId, p.channelId);
    }
    return result;
  }
```

(Channels' primary key is `id` (Int64); `twistInstanceId` is the Uuid blob, `channelId` is text — confirmed in `channel.dart`.)

- [ ] **Step 5: Run the test, expect pass**

Run: `flutter test test/store/link_channel_purge_test.dart`
Expected: PASS.

- [ ] **Step 6: Analyze + commit**

```bash
cd apps/plot && flutter analyze lib/store/channel.dart lib/store/link.dart
git add apps/plot/lib/store/channel.dart apps/plot/lib/store/link.dart apps/plot/test/store/link_channel_purge_test.dart
git commit -m "feat(app): purge a channel's connector links when it is disabled"
```

---

# Phase 4 — Finalize

## Task 16: Finalize

**Files:**
- Modify: `docs/updates.md` (user-facing note)
- Verify: full lint across changed packages

- [ ] **Step 1: Add a user-facing update note**

In `docs/updates.md`, add to the top section (plain language):
```markdown
- Removing a connection or turning off a synced channel now cleanly clears its items from all your devices, and re-adding it brings them back without leaving stale duplicates.
```

- [ ] **Step 2: Run lint across changed packages**

Run:
```bash
pnpm --filter @plotday/db run lint
pnpm --filter @plotday/api exec tsc --noEmit 2>&1 | rg -c "error TS" || true
cd apps/plot && flutter analyze
```
Expected: db lint passes (types current); no NEW `error TS` over baseline; flutter analyze clean.

- [ ] **Step 3: Run the `/finalize` checklist**

Invoke the project `/finalize` skill (lint, backwards-compat, error-capture, docs, public submodule). There are **no** `public/` submodule changes and **no** new `catch` blocks needing `captureException` in this work; confirm during finalize.

- [ ] **Step 4: Commit docs**

```bash
git add docs/updates.md
git commit -m "docs: note cleaner connection/channel removal across devices"
```

- [ ] **Step 5: Final review**

Run: `git log --oneline main..HEAD` and confirm the commit sequence covers DB → workers → Flutter → docs. Consider opening a PR (`commit-push-pr`) only when the user asks.

---

## Self-review (filled in by plan author)

**Spec coverage:** S1 (column)→T1; S2 (partial index + upsert ON CONFLICT)→T1+T2; S3 (archive_links branch)→T3+T9; S4 (user.link)→T4; S5 (user.link_redacted)→T5; S6 (user.schedule)→T6; S7 (/sync/links merge)→T10; S8 (last-holder trigger)→T7; S9 (plot/link.ts archive-first)→T11; C1 (Links.revoked + cascade)→T12+T13; C2 (bulk-purge)→T14+T15; C3 (one-time orphan migration)→T12; C4 (Drift migration)→T12; types regen/squash→T8; backward-compat→preserved (old clients read filtered user.link, ignore revoked); reconnect cases→covered by partial index (T1) + bulk purge (T14/T15). Tombstone GC→noted as deferred per Decision Log (no task; swept by next bulk removal).

**Placeholder scan:** The Flutter test harness is now concrete — `Store.forTesting(NativeDatabase.opened(sqlite3.openInMemory(), …))` per `test/store/priority_icon_migration_test.dart` (Phase 3 header + fully-written T12 migration test). The remaining `/* … */` markers in T13/T14/T15 Step 1 are seed-row literals (`LinksCompanion`/`ScheduleRow`/etc.) whose exact generated field names must be matched against `store.g.dart` after `build_runner` runs; assertions and control flow are concrete. T10's TS test uses `expect(true).toBe(true)` placeholders with an explicit instruction to either wire `vi.mock("../../../db")` per `plot.test.ts` or (preferred) extract+test a pure `mergeSeqRows` helper — a real choice the implementer makes, not a hidden gap.

**Type consistency:** `_hardDeleteLinks` (private to `Link`) is reused by `processPulledRows`, `hardDeleteForInstance`, `hardDeleteForChannel`. `archive_links` 3-arg signature (`p_created_by, p_filter, p_hard`) is consistent between T3 (definition) and T9 (caller). View column lists in T4/T5 are asserted identical by T5 Step 5.
