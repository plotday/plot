# Focus Roles — Plan 7: `path` / `root` Teardown (HELD follow-up) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development / superpowers:executing-plans. Steps use checkbox (`- [ ]`).
>
> **STATUS: NOT YET EXECUTED — deliberately held.** This is the destructive contract that removes `priority.path` (ltree) and `priority.root` server-side, after the role model (Plans 1–6) has shipped. Execute it as its **own PR**, after Plans 1–6 have merged and **soaked in production** (so the expand has deployed and old workers are gone), and after a live run-app verification of the role feature. Do not bundle it with the feature PR.

**Goal:** Remove `priority.path` and `priority.root` from the database and stop the API depending on them, completing the move to the pure role/`is_inbox` model. The Flutter client is already path-independent and on **API v5** (Plan 6), so the server can drop `path`/`root` for v5+ clients while synthesizing a minimal legacy shape for any remaining v<5 clients.

**Architecture:** Two sub-phases per the project's expand/contract discipline (`libs/db/AGENTS.md`). **Expand:** rewrite every view/function to stop *using* `path`/`root` (synthesize a `priority_path` string from `role_id`/`is_inbox` so thread/link/schedule views keep their column shape; route fallbacks through `fallback_inbox_id`; `projectPriority` synthesizes `path`/`root` for v<5) — `path`/`root` columns stay physically present so in-flight old workers don't break. **Contract** (`migrations-contract/`, a later deploy): drop the `path`/`root` columns, ltree indexes, `validate_priority_root`, `generate_path`/`parent_path`/`move_priority`, `priority_setting_inherited`, the dead `*_set` columns, `link.source_priority_root`; set `priority.role_id`/`color` NOT NULL.

**Tech Stack:** Postgres schema + Atlas expand/contract migrations (`libs/db/`), the API worker (`workers/api/src/app/sync/priorities.ts`). No Flutter change (already path-independent). `pnpm diff-schema-migrations`, db lint, and the Squawk migration-safety gate apply.

**Prereqs:** Plans 1–6 merged + deployed + soaked (the contract's `migrations-contract/` drains one deploy after the expand). Confirm no v<4 clients remain in the wild before relying solely on the v5 path; keep the v<5 synthesis until they're gone.

---

## Full dependency map (from Plan 6 research — every `path`/`root`/`root_priority_id`/`priority_setting_inherited`/`*_set` site)

**Schema (`libs/db/schema/`):**
- `50-tables/22-priority.sql` — `path ltree NOT NULL`, `root` (computed in view), `idx_priority_user_path_unique`, `idx_priority_path_gist`, `idx_priority_key_per_root` (`subltree(path,0,1)`), `validate_priority_root` trigger.
- `50-tables/25-link.sql` — `source_priority_root ltree` column.
- `40-functions/10-priority.sql` — `generate_path()`, `parent_path()`.
- `60-functions/15-move-priority.sql` — `move_priority()`.
- `60-functions/activate_invited_user.sql` — `generate_path(NULL)` for the root insert.
- `60-functions/apply_mute.sql` — `root_priority_id()` calls.
- `70-views/15-priority.sql` — `priority_setting_inherited` (ltree `<@` joins, `nlevel` distance).
- `70-views/26-link.sql` — `pp.path AS priority_path`.
- `90-user-schema/04-root_priority_id.sql` — `nlevel(path)=1`.
- `90-user-schema/20-priority_expanded.sql` — projects `p.path`.
- `90-user-schema/22-priority.sql` — `user_root` CTE (`nlevel=1`), `root`, `path`/`global_path`, `priority_setting_inherited`, `respond_*`/`*_set`.
- `90-user-schema/30-thread.sql`, `30-link.sql`, `31-schedule.sql` — `upe.path AS priority_path` via `priority_expanded`.
- `90-user-schema/80-upsert_thread.sql` — `nlevel(p.path)` check.
- `90-user-schema/85-user-sync-upserts.sql` — `upsert_priority` path-synth block (`_root_path`, `generate_path`, `move_priority`, `nlevel`).

**API (`workers/api/`):** `app/sync/priorities.ts` `projectPriority` (uses `row.root`). Thread/link/schedule sync endpoints `selectAll()` the views (so a synthetic `priority_path` in the views needs no endpoint code change). The server already filters by `priority_id`.

**Flutter:** none — Plan 6 made the client path-independent and bumped to API v5. (Client `root` decoupling is the one remaining item; see "Also" below.)

---

## Synthetic `priority_path` (the key trick)

Thread/link/schedule views project `priority_path` (a `filterName`/legacy field; v5 clients ignore it, v<5 clients still receive it). To drop `priority.path` without touching those client entities, synthesize it from role identity wherever a view emitted `upe.path`/`pp.path`:
```sql
CASE WHEN p.is_inbox THEN p.role_id::text || ':inbox' ELSE p.id::text END AS priority_path
```
Opaque, unique per focus, satisfies old clients' not-null expectation. `priority_expanded` keeps a `path text` column emitting this synthetic value (its consumers join on it).

---

# PHASE A — Expand (one PR): stop using path/root; columns stay

## Task A1: `fallback_inbox_id` everywhere `root_priority_id` was used
- [ ] Retire `root_priority_id` consumers: `apply_mute.sql` → `fallback_inbox_id(p_user_id)` (already added in Plan 2). `upsert_thread.sql` `nlevel(p.path) > 1` check → `NOT p.is_inbox` (a non-Inbox focus). Leave `root_priority_id` defined for now (dropped in Phase B) but unreferenced.

## Task A2: `priority_expanded` → synthetic path
- [ ] Rewrite `90-user-schema/20-priority_expanded.sql` to emit the synthetic `priority_path` (above) as its `path` column instead of `p.path`. Keep the column name so downstream joins are unchanged.

## Task A3: thread/link/schedule + public link views → synthetic priority_path
- [ ] `90-user-schema/30-thread.sql`, `30-link.sql`, `31-schedule.sql`, `70-views/26-link.sql`: replace `upe.path`/`pp.path` projections with the synthetic value (via `priority_expanded.path` or inline). The join key (`upe.priority_id = effective_priority_id(...)`) is unchanged. Verify the `user.*_redacted` variants too.

## Task A4: `user.priority` stops using path/root + inherited view
- [ ] `90-user-schema/22-priority.sql`: drop the `user_root` CTE (`nlevel=1`); project `root` as `p.is_inbox` (back-compat alias for v<5 — the value differs from the old "single root" but is the closest analog) or synthesize per `projectPriority`; project `path`/`global_path` as the synthetic value; stop sourcing notifications from `priority_setting_inherited` (Plan 1 already moved them to columns — confirm none remain); drop the dead `respond_*`/`*_set` projections. Keep the column shape v<5 clients expect.

## Task A5: `priority_setting_inherited` — drop ltree, role-based or remove
- [ ] `70-views/15-priority.sql`: with notifications now concrete columns (Plan 1), this view is only for `color`/`pomodoro`. Replace its ltree `<@`/`nlevel` joins with either direct per-priority reads (no inheritance) or role-based reads, or remove it if nothing consumes it after A4. Confirm consumers.

## Task A6: `activate_invited_user` + `upsert_priority` stop generating paths
- [ ] `activate_invited_user.sql`: insert the root/Inbox priority WITHOUT `path` (and without `generate_path`); it already sets `role_id`/`is_inbox` (Plan 5). (During expand, `path` is still NOT NULL — temporarily default it to the synthetic value or keep generating until Phase B makes it nullable. Sequence carefully: either make `path` nullable at the START of Phase A, or keep one `generate_path` call here until B.)
- [ ] `upsert_priority` (`85-user-sync-upserts.sql`): remove the path-synthesis block, `move_priority`, `nlevel`. New focuses no longer get a path (client doesn't send one; server stops generating). (Same `path` NOT NULL sequencing note.)

> **Sequencing:** the cleanest is to make `priority.path` **nullable** as the first step of Phase A (a safe widening), so A6 can stop generating paths. The actual `DROP COLUMN` is Phase B.

## Task A7: `projectPriority` v5 gate
- [ ] `workers/api/src/app/sync/priorities.ts`: for `apiVersion >= 5`, emit `role_id`/`is_inbox`, drop `path`/`root`/`global_path` from the wire. For `apiVersion < 5`, synthesize `path`/`root` (minimal no-crash: `root = is_inbox` for the oldest Inbox, `path` = the synthetic string) so old clients don't crash. Title relabel for the Inbox stays.

## Task A8: generate + apply the expand migration; verify
- [ ] `pnpm gen-migration -- focus_roles_stop_using_path` → applies the rewritten views/functions + (if chosen) `path` nullable. `pnpm apply-migrations`, `pnpm diff-schema-migrations` (synced), db lint. Squawk must pass (no destructive DDL in `migrations/`). Worker lint + classifier tests green.

---

# PHASE B — Contract (`migrations-contract/`, a later deploy): drop it

## Task B1: remove from schema files, then gen-contract-migration
- [ ] Delete from `schema/`: `priority.path`, `priority.root` (if a real column — it's view-computed, so just the view alias), `link.source_priority_root`, the dead `*_set` columns; the ltree indexes; `validate_priority_root` (trigger + function); `generate_path`/`parent_path` (`40-functions/10-priority.sql`); `move_priority` (`60-functions/15-move-priority.sql`); `root_priority_id` (`90-user-schema/04`); `priority_setting_inherited` if A5 removed its consumers. Replace `idx_priority_key_per_root` with a per-user `(user_id, key) WHERE key IS NOT NULL` unique index.
- [ ] Set `priority.role_id` NOT NULL and `priority.color` NOT NULL (backfill guaranteed them; safe after soak).
- [ ] `pnpm gen-contract-migration -- drop_priority_path_root_ltree` → `migrations-contract/`. `pnpm apply-migrations` (applies locally). `atlas migrate hash`.

## Task B2: verify
- [ ] `pnpm diff-schema-migrations` synced; db lint; worker lint; classifier tests. Confirm `migrations-contract/` is the only place the drops live (Squawk would reject them in `migrations/`).

---

## Also (small, related): client `root` decoupling
Plan 6 made the client path-independent but left `priority.root` in use (Everything tile `ChangeCurrentPriority(root, …)`, `hasNonRoot`, `getDefault`, the `!p.root || p.isInbox` sidebar filter). Before the server drops `root` for v5+, decouple the client from `root` too (switch those to `is_inbox`/role-based, keep the Everything anchor as a designated focus id), and confirm v5's `projectPriority` no longer needs to emit `root`. Small Flutter follow-up; can ride with Phase A or its own change.

---

## Risks / verification
- **Highest risk:** the synthetic `priority_path` must keep thread/link/schedule sync working for any v<5 clients (and the v5 client ignores it). Run-app verify the feed for both client versions if any v<5 remain.
- **Soak discipline:** the contract drains one deploy after the expand; never drop a column the currently-live workers still read (Phase A must ship and deploy first).
- **Backfill guarantees** (Plan 1/5) underwrite the NOT NULL tightenings — verify `0` NULL `role_id`/`color` in prod before B1's NOT NULL.

## Self-review checklist (run when executing)
- Every map entry above has a task. No destructive DDL in `migrations/` (Phase A) — only in `migrations-contract/` (Phase B). `projectPriority` v5/<5 both produce valid client shapes. `pnpm diff-schema-migrations` synced after each phase. Client unaffected in Phase A (already path-independent).
