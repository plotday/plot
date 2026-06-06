# Groups & Topics — Plan 3: API + Sync

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Expose topics and group-privacy to clients: topic-management RPCs + version-gated `/topic` routes, a version-gated `/sync/topics` feed, `thread.topic_id` passthrough on thread create, a group→contact snapshot-expansion helper for connector sends, and switching group creation to set `privacy` directly (retiring the transitional derive trigger).

**Architecture:** New DB RPCs mirror the existing `create_group`/`add_group_members` shape. The `/topic` and `/sync/topics` routes are **version-gated** (`apiVersion >= 3` → new topic entity; `< 3` → existing legacy group-compat, unchanged). The sync feed mirrors the `user.note` + `user.note_redacted` merge pattern. Group creation moves the `privacy` source-of-truth from the `type`-derive trigger to the API.

**Tech Stack:** PostgreSQL (Atlas migrations, pgTAP), TypeScript Cloudflare Worker (`workers/api`, Hono + Kysely), vitest integration tests.

**Design doc:** `docs/superpowers/specs/2026-06-05-groups-and-topics-design.md`. **Plan 3 of 5**; Plans 1 (topic DB foundation) & 2 (group privacy) are committed on this branch.

## Grounded references (read these patterns before mirroring)
- Group RPCs: `libs/db/schema/60-functions/group.sql` (`create_group`, `add_group_members`, `remove_group_members`).
- Group routes: `workers/api/src/app/group.ts`. Legacy compat: `workers/api/src/app/topic.ts` (`/topic/*` → group RPCs, apiVersion<3) and `workers/api/src/app/sync/topics.ts` (`/sync/topics` → `user.group`, apiVersion<3).
- Sync redacted-merge: `workers/api/src/app/sync/notes.ts` / `sync/threads.ts` (query `user.X` + `user.X_redacted`, skip redacted on initial sync, merge+sort+slice, `seqEnvelope`). Helpers: `workers/api/src/app/sync/helpers.ts`.
- Route mounting: `workers/api/src/index.ts` (`appSection.route("/", groupRoutes)` etc.), `workers/api/src/app/sync/index.ts` (`sync.route("/", groups)` etc.).
- RPC helpers: `workers/api/src/rpc.ts` — `rpc(db, fn, args)` (public schema), `rpcUser(db, fn, args)` (user schema). `withUserDb(db, userId, fn)` = txn wrapper (`workers/api/src/db.ts`).
- apiVersion: `c.var.apiVersion ?? 0` (set by `middleware/client-version.ts` from `X-Plot-API-Version`). Gate pattern: `app/sync/threads.ts:238` (`if (apiVersion < 3) {...}`).
- Thread create: `workers/api/src/app/sync/threads.ts` `POST /sync/threads` — builds `threadData`, calls `rpcUser(trx, "upsert_thread", { user_id, p_thread, p_defaults })`. `topic_id` is NOT stripped, so it passes through once clients send it.
- Error/validation: `captureServerError(c, err, msg, ctx)` (`utils/error-capture.ts`), `handleValidationError(zodErr)` (`utils/validation.ts`).
- Integration tests: `src/**/__tests__/**/*.test.ts`, `createDb({DATABASE_URL})` + `db.transaction()` + `Rollback` sentinel + `SET LOCAL session_replication_role = replica` while seeding. Config `vitest.integration.config.ts`. Example: `workers/api/src/state/email-digest-query.test.ts`.

## Execution prerequisites
- Worktree `.claude/worktrees/groups-and-topics`, isolated DB port **54346**. Prefix DB commands: `source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"` (ambient is stale 54322). Confirm `54346` before any migration.
- **Atlas gotcha:** topic RPCs that read topic tables are fine (they're plpgsql, opaque). If `gen-migration` fails with `modify "<table>": relation does not exist`, a trigger/sql-function is cycling — STOP, report BLOCKED (see `reference_atlas_trigger_self_ref_cycle` in memory; never hand-write the migration).
- Worker TS checks: `cd workers/api && pnpm tsc --noEmit` (note: 2 pre-existing errors on main — the gate is "no NEW `error TS`"). Integration tests: `DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:54346/postgres pnpm vitest run --config vitest.integration.config.ts <file>` (the workers pool can wedge the shell on exit — wrap in `timeout 180`).

---

## DEFERRED (flagged for a decision): topic-entity access-loss (`user.topic_redacted`)

The spec listed `user.topic_redacted` + topic-entity access-loss for Plan 3. Unlike threads (which have a per-user `thread_priority` row to stamp `revoked_at` on), **the `user.topic` view is computed (CROSS JOIN user × topic)** — there is no per-user mapping row to revoke. So the thread-style redacted-stub pattern doesn't directly apply.

When a user loses topic membership (removed from the only group/contact that made them a member — note: *opt-out keeps the topic visible*, so the lossy path is force-removal only), their `user.topic` row silently vanishes and the client's local copy strands.

Options (decide before building this piece):
1. **Materialize per-user topic membership** into a `topic_member_state(user_id, topic_id, revoked_at)` table maintained by the same membership triggers, then apply the standard redacted-stub pattern. Robust, but adds a table + trigger maintenance.
2. **Client full-reconcile**: on a periodic full `/sync/topics` (no cursor), the client diffs and drops local topics absent from the set. Cheap server-side; relies on the client.
3. **Defer entirely** until force-removal UX exists (opt-out — the common "leave" — already keeps the topic visible, so the strand is an edge case).

**This plan implements Tasks 1–6 (the functional path) and leaves topic-entity access-loss as a follow-up (Task 7, design-gated).** Surface options 1–3 to the user.

---

## Task 1: Topic management RPCs (DB)

**Files:**
- Create: `libs/db/schema/60-functions/topic.sql`
- Test: `libs/db/tests/60-topic-rpcs.sql`

RPCs (all `SET search_path TO 'public'`, mirroring `group.sql`):
- `create_topic(p_user_id uuid, p_name text, p_announce boolean DEFAULT false, p_team_id bigint DEFAULT NULL, p_contact_ids uuid[] DEFAULT '{}', p_group_ids uuid[] DEFAULT '{}') RETURNS uuid` — validates team membership if `p_team_id` set; inserts `topic`; adds creator to `topic_admin`; inserts `topic_contact`/`topic_group` rows.
- `add_topic_contacts(p_user_id, p_topic_id, p_contact_ids)` / `remove_topic_contacts(...)` — guard: topic not `auto_maintained`; caller is admin OR (`join_policy='open'` AND effective member). INSERT/DELETE `topic_contact`.
- `add_topic_groups(...)` / `remove_topic_groups(...)` — same guard; INSERT/DELETE `topic_group`.
- `join_topic(p_user_id, p_topic_id)` — DELETE the caller's `topic_member_optout` row if present; if the caller is still not an effective member, INSERT their primary contact into `topic_contact`. Allowed even for `auto_maintained` topics (rejoin).
- `leave_topic(p_user_id, p_topic_id)` — INSERT `topic_member_optout (p_topic_id, p_user_id)` `ON CONFLICT DO NOTHING`. Allowed for any topic (the universal leave).

Each follows the group-RPC error idioms (`RAISE EXCEPTION 'Topic not found'`, `'Cannot modify auto-maintained topic'`, `'Insufficient permission'`).

pgTAP (`60-topic-rpcs.sql`): create_topic sets creator admin + members; add/remove contact & group; non-member cannot add to an `open=false`/announce-style topic; leave inserts opt-out (and revokes via the Plan-1 trigger); join clears opt-out; auto_maintained rejects add but allows leave/join.

Standard DB loop + commit `feat(db): topic management RPCs`.

---

## Task 2: Group creation sets privacy directly; retire the transitional trigger (DB + TS)

**Files:**
- Modify: `libs/db/schema/60-functions/group.sql` (`create_group` gains `p_privacy group_privacy DEFAULT NULL`; when provided, set it; else fall back to type-derivation so old callers still work)
- Remove: `libs/db/schema/95-triggers/24-group_privacy_derive.sql` (the transitional trigger — now the RPC/API owns privacy) — generate via `pnpm gen-migration` (Atlas emits the DROP TRIGGER + DROP FUNCTION).
- Modify: `workers/api/src/app/group.ts` (and the version-gated topic.ts in Task 3) — `CreateGroupSchema` gains `privacy: z.enum(["open","private"]).optional()`; pass `p_privacy`.
- Test: extend `libs/db/tests/58-group-privacy-column.sql` (or a new test) to assert `create_group` with explicit `p_privacy='private'` on a `type='public'` group yields `privacy='private'` (proving privacy is now independent of type once the trigger is gone), and that omitting `p_privacy` still defaults sanely.

⚠️ Removing the derive trigger means existing creators that set only `type` (the auto-maintain triggers for Everyone/Plot Team/team groups) no longer get privacy auto-derived. Mitigate: in `create_group` keep a fallback (`p_privacy` → if NULL, derive from `p_type`), and update the auto-maintain group-creation triggers (`95-triggers/24-group_auto_maintain.sql`) to set `privacy='private'` for the announce groups they create (Everyone, Plot Team). Verify the existing Everyone/Plot-Team-creation paths still yield `privacy='private'`. Re-run test 30 + 58 + 59.

Standard DB loop; `cd workers/api && pnpm tsc --noEmit`; commit `feat(db,api): create_group sets privacy directly; drop transitional derive trigger`.

---

## Task 3: Version-gated `/topic` entity routes (TS)

**Files:**
- Modify: `workers/api/src/app/topic.ts` — for each handler, branch on `const apiVersion = c.var.apiVersion ?? 0;`. `apiVersion < 3` → keep the existing legacy group-compat body (unchanged). `apiVersion >= 3` → the new topic-entity behavior:
  - `POST /topic` → `rpc(trx, "create_topic", { p_user_id, p_name, p_announce, p_team_id?, p_contact_ids, p_group_ids })`. New `CreateTopicSchemaV3 = { name, announce?: boolean, teamId?, contactIds?: uuid[], groupIds?: uuid[] }`.
  - `POST/DELETE /topic/:id/contacts` → `add_topic_contacts`/`remove_topic_contacts`.
  - `POST/DELETE /topic/:id/groups` → `add_topic_groups`/`remove_topic_groups`.
  - `POST/DELETE /topic/:id/admins` → insert/delete `topic_admin` (mirror group.ts admin handlers, admin-gated).
  - `POST /topic/:id/join` → `join_topic`; `POST /topic/:id/leave` → `leave_topic`.
  - Note: the legacy `/topic/:id/members` path stays apiVersion<3-only (the new entity uses `/contacts`+`/groups`).
- Test: `workers/api/src/app/__tests__/topic-routes.test.ts` — integration test hitting the handlers (or the RPCs directly via the same txn harness) for create/add/remove/join/leave at apiVersion>=3, and that apiVersion<3 still routes to group behavior.

`pnpm tsc --noEmit`; integration test; commit `feat(api): version-gated /topic entity routes`.

---

## Task 4: Version-gated `/sync/topics` (TS)

**Files:**
- Modify: `workers/api/src/app/sync/topics.ts` — branch on apiVersion. `< 3` → existing `user.group` body (unchanged). `>= 3` → the new entity feed: mirror `sync/notes.ts` exactly but `selectFrom("user.topic")` + `user.topic_redacted` (the redacted view ships in Task 7; until then, query only `user.topic` and add a `TODO(Task 7)` note — DO NOT invent a redacted view here). Support seq + updatedSince cursors and `seqEnvelope` like `sync/groups.ts`.
- Test: `workers/api/src/app/sync/__tests__/sync-topics.test.ts` — seed a user + topic + membership, assert `GET /sync/topics` at apiVersion>=3 returns the `user.topic` row with `is_member`/`can_post`; at apiVersion<3 returns `user.group` shape.

`pnpm tsc --noEmit`; integration test; commit `feat(api): version-gated /sync/topics feed`.

---

## Task 5: `thread.topic_id` passthrough on thread create (TS)

**Files:**
- Modify: `workers/api/src/app/sync/threads.ts` `POST /sync/threads` — confirm `topic_id` survives into `threadData` (it is not stripped). Add it to any explicit allow-list if one exists, and add a camelCase alias (`if (threadData.topic_id === undefined && threadData.topicId !== undefined) threadData.topic_id = threadData.topicId; delete threadData.topicId;`) mirroring the `teamId` handling. The DB `upsert_thread` already derives the routing string from `topic_id` (Plan 1 Task 2).
- Test: `workers/api/src/app/sync/__tests__/thread-topic-id.test.ts` — POST a thread with `topic_id`, assert the stored thread has `topic_id` set and `topic = 'topic:'||topic_id`.

`pnpm tsc --noEmit`; integration test; commit `feat(api): forward topic_id on thread create`.

---

## Task 6: Group→contact snapshot-expansion helper (DB + TS)

**Files:**
- Create: `libs/db/schema/60-functions/expand_group_contacts.sql` — `expand_group_contacts(p_user_id uuid, p_group_id uuid) RETURNS uuid[]`: returns the group's member contact_ids, but ONLY if the user may address the group (admin OR `privacy='open'` member — mirror `user.group.can_address`); else RAISE EXCEPTION 'Insufficient permission to use this group'. plpgsql (opaque to Atlas).
- (API usage of the expansion at connector-send time is wired where connector threads are composed; this task delivers the DB helper + a thin `POST /group/:id/expand` or internal use — keep minimal: deliver the helper + pgTAP, and a `GET /group/:id/contacts` route returning the expanded list for the compose UI.)
- Test: `libs/db/tests/61-expand-group-contacts.sql` — open group: member gets contacts; private group: non-admin member gets exception; admin gets contacts.

Standard DB loop; `pnpm tsc --noEmit`; commit `feat(db,api): group→contact snapshot expansion helper`.

---

## Task 7 (DESIGN-GATED — do NOT start without the access-loss decision): topic-entity access-loss

Implement the chosen option from the "DEFERRED" section (materialized `topic_member_state` + redacted view, OR client full-reconcile, OR keep deferred). If option 1: add the table + maintenance triggers + `user.topic_redacted` + the `/sync/topics` redacted merge (finishing Task 4's TODO). Full pgTAP + integration coverage.

---

## Task 8: Full regression + lint

- pgTAP: `pg_prove -d "$DATABASE_URL" tests/*.sql` — all pass.
- DB: `pnpm diff-schema-migrations` (clean), `pnpm --filter @plotday/db run lint` (types current).
- API: `cd workers/api && pnpm tsc --noEmit` (no NEW errors vs the 2 pre-existing) + the new integration tests green.
- Commit any final fixes.

---

## Self-Review

**Spec coverage (Plan 3 scope):** topic RPCs (T1) ✅; group privacy via API + retire trigger (T2) ✅; `/topic` entity routes version-gated (T3) ✅; `/sync/topics` version-gated (T4) ✅; thread `topic_id` passthrough (T5) ✅; snapshot-expansion helper (T6) ✅. **`user.topic_redacted` + topic-entity access-loss (T7) is design-gated and deferred** — flagged for a user decision. Client store (Plan 4) and data migration (Plan 5) remain.

**Placeholder note:** Tasks 1–2 and 6 (DB) have concrete SQL specs; Tasks 3–5 (TS) are specified as precise edits against fully-referenced existing files (the executor mirrors `group.ts`/`notes.ts`/`threads.ts` patterns cited above) rather than reproducing hundreds of lines of boilerplate — this is deliberate given the strong existing patterns. The executor should read the referenced files and mirror them.

**Risk notes:** (1) Retiring the derive trigger (T2) requires the auto-maintain group creators to set privacy — verify Everyone/Plot Team stay `private`. (2) Version-gating must not change apiVersion<3 behavior — keep the legacy bodies byte-identical. (3) Topic-entity access-loss (T7) genuinely needs a design decision before building.
