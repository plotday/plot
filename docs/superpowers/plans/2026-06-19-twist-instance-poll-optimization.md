# Twist callback-delivery poll (`twist_instance_*`) optimization — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **Phases 1 and 2 are gated on a re-measurement (Phase 0) and a scope decision — do not start them blind.**

**Goal:** Cut the production DB cost of the twist runtime's callback-delivery polls (the `twist_instance_*` views), which are the #1 steady-state aggregate cost (~64%).

**Architecture:** The `TwistSync` Durable Object (`workers/api/src/state/twist-sync.ts`) polls 10 `twist_instance_*` views per alarm with a per-(twist, entity) seq cursor. The views route each row to a twist via a JOIN/STABLE-function, so `WHERE twist_instance_id = $1` is a post-filter, never an index condition; `seq` is global, so each poll scans the entity's entire global churn in the cursor window and discards rows not owned by the twist. **L1 (already shipped on this branch) makes the cursor windows narrow.** This plan covers the two follow-ups that remove the residual: **L1′** (stop polling entities with nothing pending) and **L2** (denormalize the routing key so polls index-prune to a twist's own rows).

**Tech Stack:** TypeScript (Cloudflare Workers / Kysely), PostgreSQL 18 (Atlas migrations, pgTAP), vitest.

## Global Constraints

- **Local only. NEVER deploy.** Workers and DB changes run locally only.
- **Worktree with isolated DB** for any schema work: `bash scripts/worktree-db`; verify with `psql "$DATABASE_URL" -tAc "show port;"` (env can be stale mid-session — override `DATABASE_URL` from `.worktree-db`). Do NOT run `pnpm test` (its `test:setup` hits the main docker DB) — run `pg_prove -d "$DATABASE_URL" libs/db/tests/<file>.sql` directly.
- **Schema workflow only:** edit `libs/db/schema/`, then `pnpm gen-migration`, `pnpm apply-migrations`, `pnpm diff-schema-migrations` (must be clean), commit regenerated `libs/db/src/types.ts`. Migrations EXPAND-safe (nullable cols / indexes / CREATE OR REPLACE / triggers; no drops/renames/not-null-adds — Squawk gate). Destructive cleanup → `migrations-contract/`.
- **Lock order:** `schedule_contact`/`thread_state` are children of `schedule`/`thread`. Any writer that UPDATEs a bump-triggering child column must lock the parent first (see libs/db/AGENTS.md "Bump Parent `seq`… deadlock warning"). Wrap re-route transactions in `retryOnTxnConflict`.
- **`workers/api/src/twist/entrypoint.ts` is a template literal — escape all backticks** (only relevant if that file is touched; this plan does not).

---

## Measurements (the driver — already collected 2026-06-19, prod readonly)

Post-15:34-UTC pgss window. `track_planning` is **OFF** (planning unmeasured; same-session EXPLAIN warming proved it's cold-relcache, warm ~35-54 ms — secondary). All top views return **`rows = 0`** — the polling does ~70 min of execution per window to deliver **zero** callbacks.

| view | calls | total exec | mean/call | % of twist_instance cost | blks/call | rows |
|---|---|---|---|---|---|---|
| `twist_instance_schedule_contact` | 1,574 | 35.4 min | 1,349 ms | **48.4%** | 9,246 | 0 |
| `twist_instance_note_create` | 2,312 | 15.0 min | 390 ms | 20.6% | 538 | 0 |
| `twist_instance_note_reaction_change` | 5,608 | 8.6 min | 92 ms | 11.8% | 454 | 0 |
| `twist_instance_thread_read` | 1,335 | 5.3 min | 237 ms | 7.2% | 4,470 | 0 |
| `twist_instance_thread_schedule` | 1,201 | 1.6 min | 81 ms | 2.2% | 851 | 0 |

EXPLAIN (busy twist, prod): a **wide** install-floor `schedule_contact` poll = 2,564 ms / 10,495 buffers / 0 rows (`idx_schedule_contact_seq` finds 1,021 rows in the window → 1,021 schedule PK + 1,021 link PK lookups → `twist_instance_for_actor` evaluated on all 1,021 → all removed by the join filter). The **same query caught-up** (9-row window) = 271 ms / 316 buffers.

Topology: 120 active twist_instances, 17 connectors (**89 non-calendar, 31 calendar**). schedule_contact = 11,817 rows / 3.7 MB; note_reaction = 212 rows; note = 115k / 440 MB; thread_state = 34k. Steady-state schedule_contact churn ≈ 9 rows / 100k xacts.

Root cause (shared by every view): routing is a JOIN/function → `twist_instance_id = $1` is a post-filter; `seq` is global → cost is **O(twists × global_churn × join)** when it should be **O(twists × own_churn)**.

---

## Status

- **L1 — SHIPPED on this branch** (commit `a967a7dc1`). `selectCursorsToAdvance()` seeds a `twist_instance_sync` cursor at the horizon on 0-item polls instead of skipping it, so cursorless entities stop re-scanning their full global history every alarm. Schema-free, 7 unit tests. Expected effect: every poll moves from the wide regime (9,246 blks) to the caught-up regime (≈300 blks) after one catch-up poll per entity per twist. **L1 narrows windows but still runs all 10 polls every alarm, and caught-up polls still scan global churn during bursts.**

---

## Phase 0 — Deploy L1, re-measure, decide L2 scope (GATE — do this first)

**Rationale:** L1 should remove most of the 48.4% (schedule_contact) and a large share of thread_read/thread_schedule by keeping windows narrow. The residual determines whether L1′/L2 are worth their cost and which entities to target. Building L2 before measuring the post-L1 residual risks denormalizing tables that L1 already made cheap.

- [ ] **Step 1:** Merge + deploy L1 (PR for commit `a967a7dc1`). *(Kris — normal deploy flow.)*
- [ ] **Step 2:** After ~1–2 h of traffic, re-run the pgss apportionment admin query (below) and compare per-view `total_exec`, `mean/call`, `blks/call` to the table above.

```sql
-- Admin (readonly cannot see pgss text). Run after L1 has soaked.
SELECT substring(query from 'twist_instance_[a-z_]+') AS view, calls,
  round(total_exec_time::numeric,0) AS total_exec_ms, round(mean_exec_time::numeric,2) AS mean_ms,
  round(((shared_blks_hit+shared_blks_read)::numeric/NULLIF(calls,0)),0) AS blks_per_call, rows
FROM extensions.pg_stat_statements WHERE query LIKE '%twist_instance_%'
ORDER BY total_exec_time DESC LIMIT 30;
```

- [ ] **Step 3:** Decide scope:
  - If schedule_contact mean/call dropped to the caught-up regime (~300 blks) and total cost is acceptable → **stop; L1 was sufficient.** Skip Phases 1–2.
  - If polls are cheap-per-call but **sheer volume** still dominates (all 10 entities polled every alarm) → do **Phase 1 (L1′)**.
  - If specific entities are still expensive **per call** during churn bursts (schedule_contact / note_create / note_reaction) → do **Phase 2 (L2)** for those entities only.

---

## Phase 1 — L1′: stop polling entities with nothing pending

**Goal:** The alarm should poll an entity only when there is pending data for this twist, instead of running all 10 view queries every alarm.

**Approach:** Reuse the existing pending signal. The `twist_instance_sync` row already carries `last_update_seq` (bumped by write-path triggers when routed data arrives) and `last_sync_seq` (the cursor). `SyncRecovery.get_stale_twist_syncs` already trusts `last_update_seq > last_sync_seq` as "has pending data." The alarm can use the same predicate to skip a view query whose cursor shows nothing pending.

**Blocker:** This predicate is only complete for entities that have a `sync_twist_for_*` write-path trigger: `link, note, note_reaction, note_tag, thread, thread_tag`. **`schedule_contact` and `thread_state` have NO such trigger** (verified) — their `last_update_seq` is only ever set by the alarm itself, so skipping on `last_update_seq <= last_sync_seq` would make them never re-poll → missed RSVP / read dispatches. So Phase 1 must first add the two missing triggers.

**File Structure:**
- `libs/db/schema/60-functions/73-twist-sync.sql` — add `sync_twist_for_schedule_contact()` and `sync_twist_for_thread_state()` (mirror the routing of `twist_instance_schedule_contact` / `twist_instance_thread_read` + `_thread_schedule` views exactly, as the existing trigger fns mirror their views).
- `libs/db/schema/95-triggers/11-twist-sync.sql` — `AFTER INSERT OR UPDATE ... REFERENCING NEW TABLE` statement-level triggers calling them.
- `libs/db/tests/<n>-twist-sync-pending-signal.sql` — pgTAP: a routed change bumps `last_update_seq` for the correct twist only.
- `workers/api/src/state/twist-sync-cursor.ts` — add `selectEntitiesToPoll(cursorInfos, horizon)` returning the entity set with `last_update_seq > last_sync_seq` (or no row → must still poll until first seed... see Interfaces).
- `workers/api/src/state/twist-sync.ts` — gate each of the 10 `Promise.allSettled` queries on `selectEntitiesToPoll`.

> ⚠️ **Open decision for review:** the safety trade-off. Today's blind poll is a belt-and-suspenders net that catches anything the triggers miss. Phase 1 trusts the triggers (same trust `SyncRecovery` already places). Mitigation options to choose: (a) keep a low-frequency full poll (e.g. 1/hour) as a net; (b) accept trigger-trust fully. Recommend (a).

### Task 1.1: `sync_twist_for_schedule_contact` write-path trigger

**Files:**
- Modify: `libs/db/schema/60-functions/73-twist-sync.sql` (add function)
- Modify: `libs/db/schema/95-triggers/11-twist-sync.sql` (add triggers)
- Test: `libs/db/tests/74-twist-sync-schedule-contact-signal.sql` (new pgTAP file)

**Interfaces:**
- Produces: a `twist_instance_sync (twist_instance_id, 'schedule_contact', 'update')` row with `last_update_seq = MAX(sc.seq)` for each twist the changed `schedule_contact` rows route to — routing identical to `twist_instance_schedule_contact` (`twist_instance_for_actor(sc.contact_id, l.created_by)`, non-null only).

- [ ] **Step 1: Write the failing pgTAP test.** Insert a `schedule_contact` on a link owned by a connector, where the contact links to a user who has a matching active twist instance. Assert that instance's `('schedule_contact','update')` `last_update_seq` advanced, and a non-matching instance's did not.

```sql
-- libs/db/tests/74-twist-sync-schedule-contact-signal.sql (sketch — fill seed per existing pgTAP fixtures)
BEGIN;
SELECT plan(2);
-- ... seed: user U, contact C linked to U, connector twist T, instance PT (owner U, twist T),
--     thread A (draft=false), link L (created_by = some connector instance of twist T),
--     schedule S on L. Then:
INSERT INTO schedule_contact (id, schedule_id, contact_id, status, seq)
  VALUES (gen_random_uuid(), :'S', :'C', 'attend', pg_current_xact_id());
SELECT isnt(
  (SELECT last_update_seq FROM twist_instance_sync
     WHERE twist_instance_id = :'PT' AND entity='schedule_contact' AND operation='update'),
  NULL, 'routed twist got a pending signal');
SELECT is(
  (SELECT count(*)::int FROM twist_instance_sync
     WHERE twist_instance_id = :'OTHER_PT' AND entity='schedule_contact'),
  0, 'non-routed twist got no signal');
SELECT * FROM finish();
ROLLBACK;
```

- [ ] **Step 2: Run, verify it fails.** `pg_prove -d "$DATABASE_URL" libs/db/tests/74-twist-sync-schedule-contact-signal.sql` → FAIL (function/trigger absent → no row).

- [ ] **Step 3: Add the function** (mirror `sync_twist_for_note_reaction`'s structure: a statement trigger over `new_table`, compute `MAX(seq)`, loop distinct routed twist ids, UPSERT `last_update_seq = GREATEST(...)`). Route via `twist_instance_for_actor(sc.contact_id, l.created_by)` joining `schedule_contact → schedule → link`, filtering `thread.draft = false` and non-null route.

- [ ] **Step 4: Add the triggers** in `95-triggers/11-twist-sync.sql`:

```sql
CREATE OR REPLACE TRIGGER sync_twist_schedule_contact_insert
  AFTER INSERT ON schedule_contact REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT EXECUTE FUNCTION sync_twist_for_schedule_contact();
CREATE OR REPLACE TRIGGER sync_twist_schedule_contact_update
  AFTER UPDATE ON schedule_contact REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT EXECUTE FUNCTION sync_twist_for_schedule_contact();
```

- [ ] **Step 5:** `pnpm gen-migration -- twist_sync_schedule_contact_signal` && `pnpm apply-migrations` && `pnpm diff-schema-migrations` (clean). Commit regenerated `types.ts`.
- [ ] **Step 6:** Run the pgTAP file → PASS. Run the full pgTAP suite via `pg_prove` to confirm no regression.
- [ ] **Step 7: Commit.**

### Task 1.2: `sync_twist_for_thread_state` write-path trigger

Same shape as 1.1, for `thread_state`. **Note:** `thread_state` feeds **two** views — `twist_instance_thread_read` (routes via `thread.created_by`) and `twist_instance_thread_schedule` (same driving table). The trigger must bump the pending signal for **both** `('thread_read','update')` and `('thread_schedule','update')`. Routing = `thread.created_by` (the creating twist), filtered `thread.draft = false AND twist_instance.archived_at IS NULL`. Follow the same Steps 1–7. Test file: `libs/db/tests/75-twist-sync-thread-state-signal.sql`.

### Task 1.3: `selectEntitiesToPoll` + gate the alarm queries

**Files:**
- Modify: `workers/api/src/state/twist-sync-cursor.ts`
- Test: `workers/api/src/state/twist-sync-cursor.test.ts`
- Modify: `workers/api/src/state/twist-sync.ts`

**Interfaces:**
- Consumes: `syncInfos` extended to also select `last_update_seq::text` (currently only `last_sync_seq::text`).
- Produces: `selectEntitiesToPoll(cursorInfos, lowFrequencyFullPoll: boolean): Set<string>` keyed `"${entity}:${operation}"`. An entity is polled when: it has a row with `last_update_seq > last_sync_seq`, OR it has **no** row yet (until L1 seeds one — so first poll still happens), OR `lowFrequencyFullPoll` is true (the hourly safety net).

- [ ] **Step 1: Write failing unit tests** for `selectEntitiesToPoll` — covering: pending row (poll), caught-up row (skip), no row (poll), full-poll override (poll all). [Include the actual test bodies when executing — mirror the `selectCursorsToAdvance` tests.]
- [ ] **Step 2:** Run → fail (function absent).
- [ ] **Step 3:** Implement `selectEntitiesToPoll`.
- [ ] **Step 4:** Run → pass.
- [ ] **Step 5:** In `twist-sync.ts`: add `last_update_seq::text` to the `syncInfos` select; compute `const toPoll = selectEntitiesToPoll(syncInfos, isHourlyFullPoll)`; wrap each of the 10 `db.selectFrom("twist_instance_*")` queries so a skipped entity resolves to `[]` without issuing SQL. Keep the existing cursor-advance (L1) unchanged.
- [ ] **Step 6:** `pnpm exec tsc --noEmit` + `pnpm exec eslint` + the unit tests → green.
- [ ] **Step 7: Commit.**

---

## Phase 2 — L2: denormalize the routing key (per-entity, only where Phase 0 says it's needed)

**Goal:** Make `twist_instance_id = $1` an index condition so even churn-heavy windows scan only a twist's own rows — the complete fix for the global-churn amplification.

**Worked example: `schedule_contact` (the 48% leader).** Routing `twist_instance_for_actor(sc.contact_id, l.created_by)` is single-valued (0 or 1 twist per row, given the row's link). Denormalize it.

**File Structure:**
- `libs/db/schema/50-tables/<schedule_contact>.sql` — add nullable `routed_twist_instance_id uuid`.
- `libs/db/schema/95-triggers/` — maintenance triggers (below).
- `libs/db/schema/70-views/77-twist-instance-schedule-contact.sql` — `SELECT sc.routed_twist_instance_id AS twist_instance_id` and drop the `twist_instance pt` join used purely for routing (keep schedule/link/thread joins for enrichment, now driven from the indexed small row set).
- Index: `CREATE INDEX idx_schedule_contact_routed_seq ON schedule_contact (routed_twist_instance_id, seq);`
- Backfill: data migration setting `routed_twist_instance_id` for existing rows (seq-suppressed — no client resync needed; `schedule_contact` is not a `user.*` synced entity, so no `archived_at` concern).

**Maintenance triggers (the subtle part — REVIEW BEFORE BUILDING):**
1. On `schedule_contact` INSERT/UPDATE of `contact_id`: set `routed_twist_instance_id = twist_instance_for_actor(contact_id, <link.created_by>)`.
2. On `twist_instance` INSERT (user connects a matching connector): re-route that user's `schedule_contact` rows of the matching connector type where currently NULL/stale → set to the new instance.
3. On `twist_instance` archive: re-route its rows to the user's other matching active instance, else NULL.
4. On `user_contact` link/unlink: re-route rows for that contact.

> ⚠️ **Open decisions for review:**
> - **Lock order / deadlock.** Triggers 2–4 UPDATE `schedule_contact` (a child of `schedule`), and the existing `schedule-contact-bump` trigger bumps `schedule.updated_at` (child→parent). Writers starting from `schedule`/`link` take the opposite order. Re-route batch UPDATEs must lock parents first or run in `retryOnTxnConflict`. **Verify the lock graph before building.**
> - **View-rewrite vs two-phase.** Unlike feed PR #356 (whose COALESCE + visibility joins defeated the index, forcing a two-phase query), here `twist_instance_id` maps directly to a plain indexed column with no COALESCE, so a **view rewrite alone should let the planner push `= $1` into `idx_schedule_contact_routed_seq`.** Confirm with `EXPLAIN` on the worktree DB; only add a two-phase API path if the planner still won't use the index through the view.
> - **Scope.** Apply the same pattern to `note_reaction` (same routing function, 11.8%) if Phase 0 shows it's still hot. `note_create` (20.6%) is a **different** problem — `$1 = ANY(n.mentions)` isn't pushed into the GIN index because `pt.id` is a join variable; its fix is to make the API filter `mentions @> ARRAY[$1]` directly (or denormalize), evaluated separately. `thread_read`/`thread_schedule` denormalization (creator onto the large, churny `thread_state`) is the most invasive — only pursue if L1 + Phase 1 leave them hot.

**Task outline (per entity chosen; full TDD steps to be written once scope + the two open decisions are settled in review):**
- [ ] 2.a Add nullable column + index (EXPAND migration); `EXPLAIN` the rewritten view query to confirm index pruning (before/after buffers).
- [ ] 2.b pgTAP: backfill correctness (every row's `routed_twist_instance_id` equals `twist_instance_for_actor(...)`).
- [ ] 2.c pgTAP: each maintenance trigger (insert routing, reconnect re-route, archive re-route, contact relink re-route) — assert routing stays correct and dispatch isn't duplicated/dropped.
- [ ] 2.d Rewrite the view; confirm `TwistSync` still type-checks (the API query is unchanged — same `WHERE twist_instance_id = $1`).
- [ ] 2.e Backfill data migration (seq-suppressed). `diff-schema-migrations` clean; commit `types.ts`.
- [ ] 2.f Re-measure on prod after deploy.

---

## Risks & rollout

- **L1 (shipped):** lowest risk — schema-free, only changes which `twist_instance_sync` rows get an UPSERT; delivery paths untouched (verified RSVP notify is independent of the cursor floor).
- **Phase 1:** moderate — trusts write-path triggers as the complete pending signal. Mitigate with the hourly full-poll net. New triggers add a small write-path cost on `schedule_contact`/`thread_state` writes (statement-level, batched).
- **Phase 2:** highest — re-routing maintenance + lock-order. Gate on review of the two open decisions. EXPAND-only; no `user.*` sync impact (`schedule_contact` isn't client-synced).

## Verification (all phases)

- pgTAP via `pg_prove -d "$DATABASE_URL" libs/db/tests/<file>.sql` (NOT `pnpm test`).
- `pnpm exec tsc --noEmit` + `pnpm exec eslint` in `workers/api` (build `public/twister` first if module-resolution errors appear).
- `pnpm diff-schema-migrations` clean; `libs/db/src/types.ts` committed.
- Before/after `EXPLAIN (ANALYZE, BUFFERS)` on the worktree DB for each rewritten view, plus prod pgss re-measurement after deploy.
