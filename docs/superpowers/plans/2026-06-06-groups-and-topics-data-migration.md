# Groups & Topics — Plan 5: Data Migration (Everyone → Plot Users + Plot Updates)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Migrate the global "Everyone" broadcast into a renamed **Plot Users** group + a new **Plot Updates** announce topic over it, and repoint the 7 global onboarding threads onto that topic so every user receives them and can route/leave them.

**Architecture:** A single idempotent, guarded **data migration** (no schema change — created manually + `atlas migrate hash`, like the existing `..._ensure_everyone_group_and_onboarding_filing.sql`). It renames the auto-maintained all-users group, creates the `Plot Updates` topic with `topic_group(plot_updates, plot_users)` (so its membership = all users, maintained automatically by the Plan-1 derivation), repoints the onboarding threads' `topic_id`, and drops the renamed group from their `groups` (visibility now flows through topic membership). Plus any `'Everyone'`-by-name code references → `Plot Users`.

**Tech Stack:** PostgreSQL data migration, pgTAP. **Plan 5 of 5**; Plans 1–4 are pushed.

**Design doc:** `docs/superpowers/specs/2026-06-05-groups-and-topics-design.md`.

## Grounded facts
- All-users group identified by predicate `auto_maintained = TRUE AND team_id IS NULL AND auto_publisher_id IS NULL AND auto_team_admin_team_id IS NULL` (NOT by name — `auto_maintain_everyone_group` in `95-triggers/24-group_auto_maintain.sql` uses the predicate, so renaming `name` is safe). Currently `name='Everyone'`, `privacy='private'` (announce→private from Plan 2). Worktree DB id e.g. `019e99aa-…`.
- 7 global onboarding threads keyed `welcome`,`priorities`,`connections`,`getting-around`,`twists`,`notifications`,`clean-up` carry `groups=[everyone]`, `topic=everyone_id::text` (set by the ensure-everyone migration). The per-user welcome (`key='welcome-user'`, `activate_invited_user`) uses the **Plot Team** group + `topic='onboarding'` — a 1:1 thread, **leave it unchanged** (it must NOT join an all-users topic or every user would see every welcome).
- Triggers that fire during the migration: setting `thread.topic_id` fires `file_thread_priority_for_topic_members` (files Plot Updates members, `ON CONFLICT DO NOTHING` — existing onboarding `thread_priority` rows make it a no-op); removing the group from `thread.groups` fires `file_thread_priority_for_group_members` (only FILES, never revokes) — so existing users keep their rows and now see the threads via the topic path. New users joining Plot Users get filed for the onboarding threads via the transitive group→topic path in `file_thread_priority_on_group_member_change` (Plan 1 Task 6).
- One-shot client re-pull: only threads that GAINED a `topic_id` need a `seq` bump (clients already have `topicId=null` locally for all others via the Plan-4 Drift migration). The repoint UPDATE bumps exactly those — so NO blanket all-threads bump is needed (the Plan-1 "deferred one-shot bump" is satisfied by the repoint).
- Data migration mechanism: no schema diff, so `gen-migration` produces nothing. Create the migration file manually (timestamp `YYYYMMDDHHMMSS_<name>.sql`, format like `migrations/20260417010000_ensure_everyone_group_and_onboarding_filing.sql`), then `atlas migrate hash --dir file://migrations`, then `pnpm apply-migrations`. `diff-schema-migrations` stays clean (no schema change). Commit the migration + `atlas.sum`.

## Execution prerequisites
- Worktree `.claude/worktrees/groups-and-topics`, isolated DB port **54346**. Prefix DB cmds: `source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"` (ambient stale 54322). Confirm `54346` before applying.
- The worktree DB has the seeded Everyone group + onboarding threads (verified: 8 threads reference it), so the migration has real data to act on.

---

## Task 1: The data migration

**Files:**
- Create: `libs/db/migrations/<timestamp>_everyone_to_plot_users_and_updates.sql` (manual data migration)
- Test: `libs/db/tests/62-plot-users-and-updates.sql`

- [ ] **Step 1: Write the failing test** `libs/db/tests/62-plot-users-and-updates.sql` (asserts the post-migration state on the real seeded rows + a fresh-user behavioral check):

```sql
-- After the Everyone→Plot Users + Plot Updates migration: the all-users group
-- is renamed/private, the Plot Updates announce topic exists over it, the global
-- onboarding threads are repointed onto the topic, and a fresh Plot Users member
-- sees an onboarding thread via the topic and can leave it.
BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(7);

-- Plot Users group (the renamed all-users auto-maintained group)
SELECT ok(EXISTS (
    SELECT 1 FROM "group"
    WHERE auto_maintained AND team_id IS NULL AND auto_publisher_id IS NULL
      AND name = 'Plot Users' AND privacy = 'private'
), 'all-users group renamed to Plot Users, private');

-- Plot Updates topic
SELECT ok(EXISTS (SELECT 1 FROM topic WHERE key = '@plot.updates' AND announce AND auto_maintained),
    'Plot Updates announce topic exists');
SELECT ok(EXISTS (
    SELECT 1 FROM topic_group tg
    JOIN topic t ON t.id = tg.topic_id AND t.key = '@plot.updates'
    JOIN "group" g ON g.id = tg.group_id
        AND g.auto_maintained AND g.team_id IS NULL AND g.auto_publisher_id IS NULL
), 'Plot Updates includes the Plot Users group');

-- onboarding threads repointed onto the topic (if any exist in this DB)
SELECT ok(
    NOT EXISTS (SELECT 1 FROM thread WHERE key IN ('welcome','priorities','connections',
        'getting-around','twists','notifications','clean-up'))
    OR EXISTS (
        SELECT 1 FROM thread t JOIN topic tp ON tp.id = t.topic_id AND tp.key = '@plot.updates'
        WHERE t.key IN ('welcome','priorities','connections','getting-around','twists','notifications','clean-up')
    ),
    'onboarding threads (if present) are repointed onto Plot Updates');
SELECT ok(
    NOT EXISTS (SELECT 1 FROM thread WHERE key = 'welcome')
    OR NOT EXISTS (
        SELECT 1 FROM thread t, "group" g
        WHERE t.key = 'welcome' AND g.auto_maintained AND g.team_id IS NULL
          AND g.auto_publisher_id IS NULL AND g.id = ANY(t.groups)
    ),
    'Plot Users group dropped from onboarding thread groups');

-- behavioral: a fresh user added to Plot Users sees an onboarding thread via the
-- topic, and leaving Plot Updates revokes it.
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    v_contact uuid;
    v_plot_users uuid;
    v_onboarding uuid;
BEGIN
    SELECT id INTO v_plot_users FROM "group"
    WHERE auto_maintained AND team_id IS NULL AND auto_publisher_id IS NULL;
    SELECT id INTO v_onboarding FROM thread t JOIN topic tp ON tp.id = t.topic_id AND tp.key='@plot.updates'
    WHERE t.key IN ('welcome','priorities','connections','getting-around','twists','notifications','clean-up')
      AND t.archived_at IS NULL LIMIT 1;

    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'pu62@test.local');
    v_contact := public.upsert_user_contact(v_user, 'pu62@test.local', 'PU', NULL);

    CREATE TEMP TABLE _t62 (user_id uuid, plot_users uuid, onboarding uuid, sees_after_join boolean, sees_after_leave boolean);
    IF v_onboarding IS NULL OR v_plot_users IS NULL THEN
        -- no onboarding/topic seeded in this DB; record nulls so the asserts skip
        INSERT INTO _t62 VALUES (v_user, v_plot_users, v_onboarding, NULL, NULL);
        RETURN;
    END IF;

    -- joining Plot Users (group membership) files the user for the topic's threads
    INSERT INTO group_member (group_id, contact_id) VALUES (v_plot_users, v_contact);
    -- settle the auto-filed row past the classify window
    UPDATE thread_priority SET priority_id = (SELECT id FROM priority WHERE user_id = v_user LIMIT 1), classify_at = NULL
    WHERE thread_id = v_onboarding AND user_id = v_user;

    INSERT INTO _t62 VALUES (
        v_user, v_plot_users, v_onboarding,
        EXISTS (SELECT 1 FROM "user".thread WHERE user_id = v_user AND id = v_onboarding),
        NULL
    );

    -- leave Plot Updates → revoked
    INSERT INTO topic_member_optout (topic_id, user_id)
    SELECT id, v_user FROM topic WHERE key = '@plot.updates';
    UPDATE _t62 SET sees_after_leave = EXISTS (SELECT 1 FROM "user".thread WHERE user_id = v_user AND id = v_onboarding);
END $$;

SELECT ok((SELECT onboarding IS NULL OR sees_after_join FROM _t62),
    'fresh Plot Users member sees an onboarding thread via the topic');
SELECT ok((SELECT onboarding IS NULL OR sees_after_leave = FALSE FROM _t62),
    'leaving Plot Updates revokes the onboarding thread');

SELECT * FROM finish();
ROLLBACK;
```
Run it (before the migration): `cd libs/db && pg_prove -d "$DATABASE_URL" tests/62-plot-users-and-updates.sql` → expect FAIL (no Plot Users / Plot Updates yet).

- [ ] **Step 2: Create the data migration** `libs/db/migrations/<timestamp>_everyone_to_plot_users_and_updates.sql` (use a timestamp later than the newest existing migration; mirror the DO-block/guarded style of `20260417010000_ensure_everyone_group_and_onboarding_filing.sql`):

```sql
-- Migrate the global "Everyone" broadcast into "Plot Users" (group) + a
-- "Plot Updates" announce topic over it, and repoint the 7 global onboarding
-- threads onto that topic. Idempotent + guarded (safe to re-run on prod).
DO $$
DECLARE
    v_plot_users_id uuid;
    v_plot_updates_id uuid;
    v_author_id uuid;
BEGIN
    SELECT id, created_by INTO v_plot_users_id, v_author_id
    FROM "group"
    WHERE auto_maintained = TRUE AND team_id IS NULL AND auto_publisher_id IS NULL
      AND auto_team_admin_team_id IS NULL;
    IF v_plot_users_id IS NULL THEN
        RETURN;  -- no all-users group (e.g. empty test DB) — nothing to migrate
    END IF;

    -- 1. Rename Everyone -> Plot Users, ensure private.
    UPDATE "group"
    SET name = 'Plot Users', privacy = 'private'
    WHERE id = v_plot_users_id AND (name <> 'Plot Users' OR privacy <> 'private');

    -- 2. Create the Plot Updates announce topic (singleton via key) over Plot Users.
    SELECT id INTO v_plot_updates_id FROM topic WHERE key = '@plot.updates';
    IF v_plot_updates_id IS NULL THEN
        INSERT INTO topic (name, announce, auto_maintained, key, created_by)
        VALUES ('Plot Updates', TRUE, TRUE, '@plot.updates', v_author_id)
        RETURNING id INTO v_plot_updates_id;
    END IF;
    INSERT INTO topic_group (topic_id, group_id) VALUES (v_plot_updates_id, v_plot_users_id)
    ON CONFLICT DO NOTHING;
    INSERT INTO topic_admin (topic_id, user_id) VALUES (v_plot_updates_id, v_author_id)
    ON CONFLICT DO NOTHING;

    -- 3. Repoint the global onboarding threads onto the topic. Drop the renamed
    --    group from their groups (visibility now via topic membership = Plot
    --    Users). Setting topic_id bumps these threads' seq so clients re-pull
    --    and pick up the new topic_id column (the Plan-1 deferred one-shot bump,
    --    scoped to exactly the threads that gained a topic_id).
    UPDATE thread
    SET topic_id = v_plot_updates_id,
        topic = 'topic:' || v_plot_updates_id::text,
        groups = array_remove(COALESCE(groups, ARRAY[]::uuid[]), v_plot_users_id)
    WHERE key IN ('welcome','priorities','connections','getting-around',
                  'twists','notifications','clean-up')
      AND archived_at IS NULL
      AND topic_id IS DISTINCT FROM v_plot_updates_id;
END $$;
```

- [ ] **Step 3: Hash + apply** — `cd libs/db && atlas migrate hash --dir file://migrations && pnpm apply-migrations`. (`apply-migrations` regenerates `src/types.ts`; a pure data migration won't change it, but run it to be safe.)

- [ ] **Step 4: Run the test green** — `pg_prove -d "$DATABASE_URL" tests/62-plot-users-and-updates.sql` → 7/7.

- [ ] **Step 5: Verify schema sync + full suite** — `pnpm diff-schema-migrations` → clean (no schema change). `pg_prove -d "$DATABASE_URL" tests/*.sql` → all pass (the rename/repoint must not break tests 30/33/53/55/56 etc.).

- [ ] **Step 6: Commit**
```bash
git add libs/db/migrations/ libs/db/tests/62-plot-users-and-updates.sql libs/db/src/types.ts
git commit -m "feat(db): migrate Everyone -> Plot Users group + Plot Updates topic; repoint onboarding"
```
(`--no-verify` only if an unrelated pre-commit hook blocks, after diff is clean.)

---

## Task 2: `'Everyone'`-by-name code references + full regression

**Files:** TBD by grep (likely client display strings, if any).

- [ ] **Step 1: Find name references** — `grep -rn "Everyone" workers/api/src apps/plot/lib libs/db/schema | grep -iv "everyone_group\|auto_maintain\|//\|comment"`. For each USER-FACING display of the group's name `'Everyone'` (e.g. a hardcoded label), update to `'Plot Users'`. Do NOT touch the predicate-based lookups (auto_maintain_everyone_group, the ensure migration) — those identify by `auto_maintained` predicate, not name, and renaming `name` doesn't affect them. The group's display name now syncs to clients as `Plot Users` via `user.group.name`, so most UI needs no change. If there are none, record that.

- [ ] **Step 2: tsc / analyze** (only if code changed) — `cd workers/api && pnpm tsc --noEmit 2>&1 | grep "error TS" | grep -v twister | grep -v "\.test\." | wc -l` (expect 0 new); `cd apps/plot && flutter analyze 2>&1 | grep -cE "error •"` (expect 0).

- [ ] **Step 3: Full DB regression** — `cd libs/db && source ../../.worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres" && pg_prove -d "$DATABASE_URL" tests/*.sql && pnpm diff-schema-migrations && pnpm --filter @plotday/db run lint`.

- [ ] **Step 4: Commit any changes** — `git commit -m "chore: rename Everyone -> Plot Users in user-facing copy"` (skip if no code changes).

---

## Self-Review

**Spec coverage (Plan 5):** Everyone→Plot Users rename (T1) ✅; Plot Updates announce topic over Plot Users (T1) ✅; onboarding repoint onto the topic (T1) ✅; deferred one-shot seq bump satisfied by the repoint (scoped) ✅; user-facing name refs (T2) ✅. The feature is now end-to-end complete across all 5 plans.

**Decisions made:**
- The **per-user welcome** (`welcome-user`, Plot Team group) is NOT moved to Plot Updates — it's a 1:1 thread; putting it in an all-users topic would expose every user's welcome to everyone.
- The renamed group keeps the `auto_maintained`/predicate identity (auto-maintain trigger unaffected); only `name`/`privacy` change.
- Onboarding threads drop the Plot Users group from `groups` and rely on `topic_id` for visibility — existing `thread_priority` rows persist (no revoke), new users are filed via the transitive group→topic path.
- No blanket all-threads `seq` bump — only the repointed onboarding threads need clients to re-pull (others have `topic_id=null` already locally).

**Placeholder note:** the migration + test are complete SQL. Task 2 is grep-driven (the set of name references isn't known until grepped).

**Risk notes:** (1) Data migration is idempotent + guarded (`RETURN` when no all-users group; `ON CONFLICT`; `IS DISTINCT FROM` guards) — safe to re-run on prod. (2) Manual migration file requires `atlas migrate hash` or CI fails. (3) Setting `topic_id` on the onboarding threads fires the topic peer-filing trigger for all Plot Users members — `ON CONFLICT DO NOTHING` makes it a no-op for existing rows, but it's a one-time O(users×7) pass at deploy; acceptable. (4) This migration must deploy AFTER the Plan-1–3 schema (topic tables, triggers) — it's later in the migration order, so fine.
