# Groups & Topics — Plan 2: Group Privacy

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give groups a clean **privacy** axis (`open` / `private`) that governs both roster visibility and address permission, replacing the conflated `type`-based gating in `user.group` — while keeping `type`/`join_policy` for client backward-compat.

**Architecture:** Add a `group_privacy` enum + `group.privacy` column (default `open`), backfill from the existing `type` (`announce` → `private`, everything else → `open`), and switch `user.group`'s `member_contact_ids` and posting gates from `type` to `privacy`. Add a `can_address` computed column (who may add the group to a thread/topic) and keep `can_post` as a same-valued alias so older clients keep working. The legacy `type`/`join_policy` columns stay (contract-dropped in a later PR once clients read `privacy`).

**Tech Stack:** PostgreSQL 18 (schema files in `libs/db/schema/`, Atlas migrations), pgTAP (`libs/db/tests/`, `pg_prove`).

**Design doc:** `docs/superpowers/specs/2026-06-05-groups-and-topics-design.md`. This is **Plan 2 of 5**; Plan 1 (topic DB foundation) is already committed on this branch.

## Privacy model & backfill

| privacy | roster visible to | can address (add to thread/topic) | backfilled from `type` |
|---|---|---|---|
| **open** | members + admins | members + admins | `public`, `private`, `team` |
| **private** | admins only | admins only | `announce` |

Admins always bypass. This preserves the existing `can_post` behavior exactly (admins, plus members of any non-`announce` group) and changes `member_contact_ids` only for `public` groups (rare; previously roster-hidden, now roster-visible to members — the intended "open" semantics).

## Execution prerequisites

- Worktree `.claude/worktrees/groups-and-topics`, isolated DB port **54346**. The ambient `$DATABASE_URL` is stale (54322 = MAIN DB). Prefix EVERY DB command:
  ```bash
  cd /Users/kris.braun/code/plot/.claude/worktrees/groups-and-topics && source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres" && echo "Using $DATABASE_URL" && <cmd>
  ```
  Confirm the echoed URL contains `54346` before any migration.
- **Standard DB task loop:** write pgTAP test → run red → edit `libs/db/schema/` → `cd libs/db && pnpm gen-migration -- <name>` → `pnpm apply-migrations` → re-run test green → `pnpm diff-schema-migrations` (no changes) → commit schema + migration + `src/types.ts` + test.
- **Atlas gotcha (Plan 1 lesson):** never let a trigger/function reach its own table through a `LANGUAGE sql` helper. This plan only adds an enum/column and edits the `user.group` VIEW, so it won't hit it; if `gen-migration` ever fails with `modify "<table>": relation does not exist`, STOP and report BLOCKED (do not hand-write the migration).

---

## Task 1: `group_privacy` enum + `group.privacy` column + backfill

**Files:**
- Modify: `libs/db/schema/30-types/group.sql`
- Modify: `libs/db/schema/50-tables/29-group.sql`
- Test: `libs/db/tests/58-group-privacy-column.sql`

- [ ] **Step 1: Write the failing test** — `libs/db/tests/58-group-privacy-column.sql`

```sql
-- group.privacy exists, defaults to 'open', and is backfilled from type
-- (announce -> private, everything else -> open).
BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(4);

SELECT has_column('public'::name, 'group'::name, 'privacy'::name, 'group.privacy exists');

DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    v_open uuid := gen_random_uuid();
    v_announce uuid := gen_random_uuid();
    v_default uuid := gen_random_uuid();
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'gp58@test.local');
    -- explicit types
    INSERT INTO public."group" (id, name, type, created_by) VALUES
        (v_open, 'Open 58', 'private', v_user),
        (v_announce, 'Announce 58', 'announce', v_user);
    -- a row created without specifying privacy gets the default
    INSERT INTO public."group" (id, name, created_by) VALUES (v_default, 'Default 58', v_user);

    CREATE TEMP TABLE _gp58 (open_p group_privacy, announce_p group_privacy, default_p group_privacy);
    INSERT INTO _gp58
    SELECT (SELECT privacy FROM public."group" WHERE id = v_open),
           (SELECT privacy FROM public."group" WHERE id = v_announce),
           (SELECT privacy FROM public."group" WHERE id = v_default);
END $$;

SELECT is((SELECT open_p FROM _gp58)::text, 'open', 'type=private backfills to open');
SELECT is((SELECT announce_p FROM _gp58)::text, 'private', 'type=announce backfills to private');
SELECT is((SELECT default_p FROM _gp58)::text, 'open', 'new group defaults to open');

SELECT * FROM finish();
ROLLBACK;
```

Run: `cd libs/db && pg_prove -d "$DATABASE_URL" tests/58-group-privacy-column.sql`
Expected: FAIL — `type "group_privacy" does not exist` / `column "privacy" does not exist`.

- [ ] **Step 2: Add the enum** — in `libs/db/schema/30-types/group.sql`, append after the existing `group_join_policy` enum:

```sql
CREATE TYPE group_privacy AS ENUM (
    'open',      -- members see the roster and may address the group (add it to a thread/topic)
    'private'    -- only admins see the roster / address it; members merely receive
);
```

- [ ] **Step 3: Add the column** — in `libs/db/schema/50-tables/29-group.sql`, add the column to the `group` table definition (right after the `type` column):

```sql
    -- Single privacy axis (supersedes the conflated `type` gating). Governs
    -- roster visibility and address permission in user.group. Admins bypass.
    -- Legacy `type`/`join_policy` are kept for client back-compat and dropped
    -- in a later contract migration.
    "privacy" group_privacy NOT NULL DEFAULT 'open',
```

- [ ] **Step 4: Generate the migration, then add the backfill to it**

Run: `cd libs/db && pnpm gen-migration -- add_group_privacy`
Then open the generated file in `libs/db/migrations/` and append this backfill at the end (it sets privacy from the existing type; the UPDATE bumps `group.seq` via the existing trigger so synced clients re-pull):

```sql
-- Backfill privacy from the legacy type: announce groups (Everyone, Plot Team)
-- are admin-only/roster-hidden -> private; all others -> open.
UPDATE "public"."group" SET privacy = 'private' WHERE type = 'announce';
```

Because you hand-edited the generated migration, re-hash and apply:

```bash
atlas migrate hash --dir file://migrations
pnpm apply-migrations
```

- [ ] **Step 5: Run the test green**

Run: `cd libs/db && pg_prove -d "$DATABASE_URL" tests/58-group-privacy-column.sql`
Expected: PASS (4/4).

- [ ] **Step 6: Verify sync + commit**

```bash
cd libs/db && pnpm diff-schema-migrations   # expect no changes
git add libs/db/schema/30-types/group.sql libs/db/schema/50-tables/29-group.sql \
        libs/db/tests/58-group-privacy-column.sql libs/db/migrations/ libs/db/src/types.ts
git commit -m "feat(db): group_privacy enum + group.privacy column (backfill from type)"
```

(Use `--no-verify` only if an unrelated pre-commit hook blocks, after diff is clean.)

---

## Task 2: switch `user.group` gating to `privacy` + add `can_address`

**Files:**
- Modify: `libs/db/schema/90-user-schema/35-group.sql`
- Test: `libs/db/tests/59-group-privacy-gating.sql`

- [ ] **Step 1: Write the failing test** — `libs/db/tests/59-group-privacy-gating.sql`

```sql
-- user.group: open group -> members see roster + can_address; private group ->
-- members get empty roster + cannot address; admins always see + can address.
BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(8);

CREATE TEMP TABLE _g59 (admin_u uuid, mem_u uuid, open_g uuid, priv_g uuid);

DO $$
DECLARE
    v_admin uuid := gen_random_uuid();
    v_mem uuid := gen_random_uuid();
    c_admin uuid; c_mem uuid;
    v_open uuid := gen_random_uuid();
    v_priv uuid := gen_random_uuid();
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES
        (v_admin,'ad59@test.local'),(v_mem,'me59@test.local');
    c_admin := public.upsert_user_contact(v_admin,'ad59@test.local','Ad',NULL);
    c_mem   := public.upsert_user_contact(v_mem,'me59@test.local','Me',NULL);

    -- open group: admin + member
    INSERT INTO public."group" (id, name, type, privacy, created_by) VALUES (v_open,'Open59','private','open',v_admin);
    INSERT INTO public.group_admin (group_id, user_id) VALUES (v_open, v_admin);
    INSERT INTO public.group_member (group_id, contact_id) VALUES (v_open, c_admin), (v_open, c_mem);

    -- private group: admin + member
    INSERT INTO public."group" (id, name, type, privacy, created_by) VALUES (v_priv,'Priv59','announce','private',v_admin);
    INSERT INTO public.group_admin (group_id, user_id) VALUES (v_priv, v_admin);
    INSERT INTO public.group_member (group_id, contact_id) VALUES (v_priv, c_admin), (v_priv, c_mem);

    INSERT INTO _g59 VALUES (v_admin, v_mem, v_open, v_priv);
END $$;

-- OPEN group
SELECT ok((SELECT can_address FROM "user".group, _g59 WHERE user_id=_g59.mem_u AND id=_g59.open_g),
    'open: member can_address');
SELECT ok(cardinality((SELECT member_contact_ids FROM "user".group, _g59 WHERE user_id=_g59.mem_u AND id=_g59.open_g)) = 2,
    'open: member sees full roster');
SELECT ok((SELECT can_address FROM "user".group, _g59 WHERE user_id=_g59.admin_u AND id=_g59.open_g),
    'open: admin can_address');

-- PRIVATE group
SELECT ok(NOT (SELECT can_address FROM "user".group, _g59 WHERE user_id=_g59.mem_u AND id=_g59.priv_g),
    'private: member canNOT address');
SELECT ok(cardinality((SELECT member_contact_ids FROM "user".group, _g59 WHERE user_id=_g59.mem_u AND id=_g59.priv_g)) = 0,
    'private: member gets empty roster');
SELECT ok((SELECT can_address FROM "user".group, _g59 WHERE user_id=_g59.admin_u AND id=_g59.priv_g),
    'private: admin can_address');
SELECT ok(cardinality((SELECT member_contact_ids FROM "user".group, _g59 WHERE user_id=_g59.admin_u AND id=_g59.priv_g)) = 2,
    'private: admin sees full roster');

-- can_post stays a same-valued alias of can_address (back-compat)
SELECT ok(
    (SELECT can_post FROM "user".group, _g59 WHERE user_id=_g59.mem_u AND id=_g59.open_g)
    = (SELECT can_address FROM "user".group, _g59 WHERE user_id=_g59.mem_u AND id=_g59.open_g),
    'can_post mirrors can_address');

SELECT * FROM finish();
ROLLBACK;
```

Run: `cd libs/db && pg_prove -d "$DATABASE_URL" tests/59-group-privacy-gating.sql`
Expected: FAIL — `column "can_address" does not exist` (and private-member roster is non-empty under the old type-based gating, since type='announce' currently hides via a different path — confirm it fails).

- [ ] **Step 2: Edit `user.group`** — in `libs/db/schema/90-user-schema/35-group.sql`, make three changes (read the file first to anchor exactly; do NOT change the WHERE-clause group *visibility* — only the computed columns):

(2a) Add `g.privacy,` to the SELECT list, right after the existing `g.type,` line.

(2b) Replace the `can_post` computed column block (the one commented "Whether this user is allowed to send threads to the group" producing `... AS can_post`) with a privacy-based `can_post` PLUS a new `can_address` of the same value:

```sql
    -- can_address: may this user add the group to a thread/topic? Admins always;
    -- members only when the group is `open`. (can_post is kept as a same-valued
    -- alias for older clients that still read it.)
    (
        EXISTS (
            SELECT 1 FROM group_admin ga
            WHERE ga.group_id = g.id AND ga.user_id = u.id
        )
        OR (
            g.privacy = 'open'
            AND EXISTS (
                SELECT 1 FROM group_member gm
                JOIN user_contact uc ON uc.contact_id = gm.contact_id
                    AND uc.linked = TRUE AND uc.archived_at IS NULL
                WHERE gm.group_id = g.id AND uc.user_id = u.id
            )
        )
    ) AS can_post,
    (
        EXISTS (
            SELECT 1 FROM group_admin ga
            WHERE ga.group_id = g.id AND ga.user_id = u.id
        )
        OR (
            g.privacy = 'open'
            AND EXISTS (
                SELECT 1 FROM group_member gm
                JOIN user_contact uc ON uc.contact_id = gm.contact_id
                    AND uc.linked = TRUE AND uc.archived_at IS NULL
                WHERE gm.group_id = g.id AND uc.user_id = u.id
            )
        )
    ) AS can_address,
```

(2c) Replace the `member_contact_ids` CASE block so the member branch keys on `privacy = 'open'` instead of `type IN ('private','team')`:

```sql
    CASE
        WHEN EXISTS (
            SELECT 1 FROM group_admin ga
            WHERE ga.group_id = g.id AND ga.user_id = u.id
        ) THEN (
            SELECT COALESCE(array_agg(gm2.contact_id), ARRAY[]::uuid[])
            FROM group_member gm2 WHERE gm2.group_id = g.id
        )
        WHEN g.privacy = 'open' AND EXISTS (
            SELECT 1 FROM group_member gm
            JOIN user_contact uc ON uc.contact_id = gm.contact_id
                AND uc.linked = TRUE AND uc.archived_at IS NULL
            WHERE gm.group_id = g.id AND uc.user_id = u.id
        ) THEN (
            SELECT COALESCE(array_agg(gm2.contact_id), ARRAY[]::uuid[])
            FROM group_member gm2 WHERE gm2.group_id = g.id
        )
        ELSE ARRAY[]::uuid[]
    END AS member_contact_ids
```

- [ ] **Step 3: Apply migration**

Run: `cd libs/db && pnpm gen-migration -- group_privacy_gating && pnpm apply-migrations`

- [ ] **Step 4: Run the test green + regression**

Run: `cd libs/db && pg_prove -d "$DATABASE_URL" tests/59-group-privacy-gating.sql tests/30-announce-group-contact-isolation.sql`
Expected: 59 PASS (8/8); 30 (announce-group roster isolation) must STILL pass — confirms the announce→private mapping preserves the no-leak behavior.

- [ ] **Step 5: Verify sync + commit**

```bash
cd libs/db && pnpm diff-schema-migrations   # expect no changes
git add libs/db/schema/90-user-schema/35-group.sql \
        libs/db/tests/59-group-privacy-gating.sql libs/db/migrations/ libs/db/src/types.ts
git commit -m "feat(db): gate user.group roster/can_address on privacy; add can_address"
```

---

## Task 3: Full-suite regression + lint

**Files:** none (verification only)

- [ ] **Step 1: Full pgTAP suite**

Run: `cd libs/db && source ../../.worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres" && pg_prove -d "$DATABASE_URL" tests/*.sql`
Expected: ALL pass — especially `30-announce-group-contact-isolation` and any test that reads `user.group` / `member_contact_ids`.

- [ ] **Step 2: Schema sync + types**

```bash
cd libs/db && pnpm diff-schema-migrations            # in sync
pnpm --filter @plotday/db run lint                   # types up to date
```

- [ ] **Step 3: Final commit if anything changed**

```bash
git add -A libs/db && git commit -m "test(db): full suite green for group privacy" || echo "nothing to commit"
```

---

## Self-Review

**Spec coverage (Plan 2 scope):**
- `group_privacy` enum (`open`/`private`) → Task 1. ✅
- `group.privacy` column + backfill from `type` → Task 1. ✅
- `user.group` roster gating switched to `privacy` → Task 2. ✅
- `can_address` computed column → Task 2. ✅
- `can_post` kept as same-valued alias (back-compat) → Task 2. ✅
- Legacy `type`/`join_policy` retained (contract-dropped later) → not touched. ✅
- **Deferred:** API/RPC privacy migration (Plan 3), client `GroupRow.privacy`/`canAddress` (Plan 4), Plot Users rename (Plan 5).

**Placeholder scan:** none — every step has concrete SQL/commands.

**Type/name consistency:** `group_privacy`, `privacy`, `can_address`, `can_post` used consistently across enum, column, view, and tests. Backfill mapping (announce→private, else open) is consistent between the column default (`open`), the migration backfill, and the gating logic.

**Risk note:** the only behavior change vs today is that `public`-typed groups now show their roster to members (they map to `open`); `public` groups are rare and this is the intended "open" semantics. The `announce`→`private` mapping is verified non-leaking by re-running test 30.
