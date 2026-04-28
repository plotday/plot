# Shareable Groups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `@plot.team` group visible and addressable by all users (so the Using Plot priority's Plot Team chip works for non-team-members), without exposing the group's existing threads to non-members.

**Architecture:** Add a nullable unique `key` column to `public.group` (mirrors `priority.key`). Extend the `user.group` view's visibility predicate to include `key = '@plot.team'`. Replace the type-based admin/member gate in `share_thread_with_groups` with a visibility-driven gate ("anyone who can see the group can address it"), preserving the announce-admin-only carve-out. Seed the key on the auto-maintained Plot Team group via the `auto_create_team_group` / `auto_maintain_team_group_members` triggers and a one-time data backfill.

**Tech Stack:** PostgreSQL (functions, triggers, views), Atlas (schema diff + migrations), `@supabase/postgres-meta` (TypeScript type regen), psql for verification. No app-side Dart changes expected — the existing `Thread()` constructor already seeds `priority.inheritedDefaultSharedGroups` into draft, and `_refreshPinnedChips` already renders any group that `Group.getOne` returns.

**Spec:** `docs/superpowers/specs/2026-04-27-shareable-groups-design.md`

---

## File Map

**Modify:**
- `libs/db/schema/50-tables/29-group.sql` — add `key` column + unique constraint + comment
- `libs/db/schema/90-user-schema/35-group.sql` — extend visibility WHERE clause with `OR g.key = '@plot.team'`
- `libs/db/schema/60-functions/share_thread.sql` — replace type-based gate in `share_thread_with_groups` with visibility-based gate
- `libs/db/schema/95-triggers/24-group_auto_maintain.sql` — set `key = '@plot.team'` on Plot team's auto-maintained group in `auto_create_team_group` and `auto_maintain_team_group_members`

**Create (auto-generated):**
- `libs/db/migrations/<timestamp>_shareable_groups.sql` — Atlas-generated migration including the schema/view/function changes and a hand-added backfill `UPDATE`
- `libs/db/src/types.ts` — regenerated TypeScript types via `pnpm types`

**Verify (no edits expected, but read to confirm assumptions):**
- `apps/plot/lib/store/thread.dart:2105-2155` — Thread constructor seeds `priority.inheritedDefaultSharedGroups`
- `apps/plot/lib/page/new_thread.dart:320-373` — `_refreshPinnedChips` renders chips for groups that `Group.getOne` returns

---

## Task 1: Add `key` column to `group` schema

**Files:**
- Modify: `libs/db/schema/50-tables/29-group.sql:1-14` (table definition) and `:54-55` (comments block)

- [ ] **Step 1: Add the column to the table definition**

In `libs/db/schema/50-tables/29-group.sql`, edit the `CREATE TABLE "public"."group"` block to add `"key" text` after `"auto_publisher_id"`. The new full block:

```sql
CREATE TABLE "public"."group" (
    "id" uuid PRIMARY KEY DEFAULT uuidv7 () NOT NULL,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "archived_at" timestamptz,
    "name" text NOT NULL,
    "type" group_type NOT NULL DEFAULT 'private',
    "join_policy" group_join_policy NOT NULL DEFAULT 'member',
    "team_id" bigint REFERENCES team ON DELETE SET NULL,
    "created_by" uuid NOT NULL REFERENCES public."user" ("id") ON DELETE CASCADE,
    "auto_maintained" boolean NOT NULL DEFAULT FALSE,
    "auto_team_admin_team_id" bigint REFERENCES team ON DELETE CASCADE,
    "auto_publisher_id" bigint REFERENCES publisher ON DELETE CASCADE,
    "key" text,
    CONSTRAINT group_key_unique UNIQUE ("key")
);
```

- [ ] **Step 2: Add a column comment**

After the existing `COMMENT ON COLUMN "public"."group"."auto_maintained"` line (`libs/db/schema/50-tables/29-group.sql:55`), append:

```sql
COMMENT ON COLUMN "public"."group"."key" IS 'Stable identifier for system-managed groups (e.g. ''@plot.team''). Drives special-cased visibility in the user.group view. Nullable; user-created groups have no key.';
```

- [ ] **Step 3: Verify the schema file parses**

Run: `cd libs/db && pnpm diff-schema-migrations 2>&1 | head -20`

Expected: shows the planned diff including `ALTER TABLE "public"."group" ADD COLUMN "key" text` and a unique constraint. (Do NOT generate the migration yet — we want all schema changes in one migration.)

- [ ] **Step 4: Commit**

```bash
git add libs/db/schema/50-tables/29-group.sql
git commit -m "$(cat <<'EOF'
db(schema): add nullable unique key column to group

Mirrors priority.key for stable identification of system-managed
groups. Used in subsequent commits to special-case @plot.team
visibility in user.group.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Set `key = '@plot.team'` on Plot Team in auto-maintain triggers

**Files:**
- Modify: `libs/db/schema/95-triggers/24-group_auto_maintain.sql:20-22` (in `auto_create_team_group`)
- Modify: `libs/db/schema/95-triggers/24-group_auto_maintain.sql:57-60` (in `auto_maintain_team_group_members`)

- [ ] **Step 1: Update `auto_create_team_group` to seed the key for Plot Team**

In `libs/db/schema/95-triggers/24-group_auto_maintain.sql`, locate the `INSERT INTO "group"` inside `auto_create_team_group` (currently at lines 20-22). Replace:

```sql
    INSERT INTO "group" (name, type, team_id, created_by, auto_maintained)
    VALUES (NEW.name || ' Team', 'team', NEW.id, v_first_admin_id, TRUE)
    ON CONFLICT DO NOTHING;
```

With:

```sql
    INSERT INTO "group" (name, type, team_id, created_by, auto_maintained, key)
    VALUES (
        NEW.name || ' Team',
        'team',
        NEW.id,
        v_first_admin_id,
        TRUE,
        CASE WHEN NEW.name = 'Plot' THEN '@plot.team' ELSE NULL END
    )
    ON CONFLICT DO NOTHING;
```

- [ ] **Step 2: Update the create-on-demand fallback in `auto_maintain_team_group_members`**

In the same file, locate the conditional `INSERT INTO "group"` inside `auto_maintain_team_group_members` (currently at lines 57-60). Replace:

```sql
        INSERT INTO "group" (name, type, team_id, created_by, auto_maintained)
        SELECT t.name || ' Team', 'team', t.id, v_user_id, TRUE
        FROM team t WHERE t.id = v_team_id
        ON CONFLICT DO NOTHING
        RETURNING id INTO v_group_id;
```

With:

```sql
        INSERT INTO "group" (name, type, team_id, created_by, auto_maintained, key)
        SELECT
            t.name || ' Team',
            'team',
            t.id,
            v_user_id,
            TRUE,
            CASE WHEN t.name = 'Plot' THEN '@plot.team' ELSE NULL END
        FROM team t WHERE t.id = v_team_id
        ON CONFLICT DO NOTHING
        RETURNING id INTO v_group_id;
```

- [ ] **Step 3: Commit**

```bash
git add libs/db/schema/95-triggers/24-group_auto_maintain.sql
git commit -m "$(cat <<'EOF'
db(schema): seed @plot.team key on Plot team's auto group

Both auto_create_team_group and the create-on-demand fallback in
auto_maintain_team_group_members now set key='@plot.team' when the
team name is 'Plot'.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add `@plot.team` visibility branch to `user.group` view

**Files:**
- Modify: `libs/db/schema/90-user-schema/35-group.sql:46-66` (the WHERE clause)

- [ ] **Step 1: Extend the WHERE clause**

In `libs/db/schema/90-user-schema/35-group.sql`, locate the `WHERE` clause at line 46. Replace:

```sql
WHERE
    g.archived_at IS NULL
    AND (
        g.type IN ('public', 'announce')
        OR (g.type = 'team' AND EXISTS (
            SELECT 1 FROM team_user tu
            WHERE tu.team_id = g.team_id AND tu.user_id = u.id
        ))
        OR (g.type = 'private' AND (
            EXISTS (
                SELECT 1 FROM group_admin ga
                WHERE ga.group_id = g.id AND ga.user_id = u.id
            )
            OR EXISTS (
                SELECT 1 FROM group_member gm
                JOIN user_contact uc ON uc.contact_id = gm.contact_id
                    AND uc.linked = TRUE AND uc.archived_at IS NULL
                WHERE gm.group_id = g.id AND uc.user_id = u.id
            )
        ))
    );
```

With:

```sql
WHERE
    g.archived_at IS NULL
    AND (
        g.type IN ('public', 'announce')
        -- Key-identified broadcast groups: visible to every user so they can
        -- address them as recipients (e.g. submitting feedback to Plot Team).
        -- Membership and thread-receiving semantics are unchanged — non-members
        -- still don't see existing threads sent to the group.
        OR g.key = '@plot.team'
        OR (g.type = 'team' AND EXISTS (
            SELECT 1 FROM team_user tu
            WHERE tu.team_id = g.team_id AND tu.user_id = u.id
        ))
        OR (g.type = 'private' AND (
            EXISTS (
                SELECT 1 FROM group_admin ga
                WHERE ga.group_id = g.id AND ga.user_id = u.id
            )
            OR EXISTS (
                SELECT 1 FROM group_member gm
                JOIN user_contact uc ON uc.contact_id = gm.contact_id
                    AND uc.linked = TRUE AND uc.archived_at IS NULL
                WHERE gm.group_id = g.id AND uc.user_id = u.id
            )
        ))
    );
```

(`is_member` and `member_contact_ids` cases above the WHERE are unchanged: non-members of `@plot.team` will see `is_member = false` and an empty `member_contact_ids` via the existing ELSE branch.)

- [ ] **Step 2: Commit**

```bash
git add libs/db/schema/90-user-schema/35-group.sql
git commit -m "$(cat <<'EOF'
db(schema): add @plot.team visibility branch to user.group

Any user can now see the group with key='@plot.team' in their group
list. Membership semantics unchanged — is_member stays false and
member_contact_ids stays empty for non-members.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Replace type-based gate in `share_thread_with_groups` with visibility-based gate

**Files:**
- Modify: `libs/db/schema/60-functions/share_thread.sql:116-142` (the `FOR v_group IN ... LOOP` block)

- [ ] **Step 1: Replace the permission loop**

In `libs/db/schema/60-functions/share_thread.sql`, locate the loop starting at line 116. Replace:

```sql
    FOR v_group IN
        SELECT g.id, g.type
        FROM unnest(p_add_group_ids) AS arr(id)
        JOIN "group" g ON g.id = arr.id
        WHERE g.archived_at IS NULL
    LOOP
        IF v_group.type = 'announce' THEN
            IF NOT EXISTS (
                SELECT 1 FROM group_admin
                WHERE group_id = v_group.id AND user_id = p_user_id
            ) THEN
                RAISE EXCEPTION 'Only admins can add announce groups to threads';
            END IF;
        ELSIF v_group.type IN ('private', 'team') THEN
            IF NOT EXISTS (
                SELECT 1 FROM group_admin
                WHERE group_id = v_group.id AND user_id = p_user_id
            ) AND NOT EXISTS (
                SELECT 1 FROM group_member gm
                JOIN user_contact uc ON uc.contact_id = gm.contact_id
                    AND uc.linked = TRUE AND uc.archived_at IS NULL
                WHERE gm.group_id = v_group.id AND uc.user_id = p_user_id
            ) THEN
                RAISE EXCEPTION 'User does not have permission to add this group';
            END IF;
        END IF;
    END LOOP;
```

With:

```sql
    FOR v_group IN
        SELECT g.id, g.type
        FROM unnest(p_add_group_ids) AS arr(id)
        JOIN "group" g ON g.id = arr.id
        WHERE g.archived_at IS NULL
    LOOP
        IF v_group.type = 'announce' THEN
            -- Announce groups stay admin-only post (existing inverted role:
            -- everyone receives, only admins broadcast).
            IF NOT EXISTS (
                SELECT 1 FROM group_admin
                WHERE group_id = v_group.id AND user_id = p_user_id
            ) THEN
                RAISE EXCEPTION 'Only admins can add announce groups to threads';
            END IF;
        ELSE
            -- Anyone with picker visibility can address the group. Drives off
            -- the same user.group view that decides whether the chip renders,
            -- so "can see it" and "can post to it" are the same gate. Posting
            -- never grants the poster read access to existing threads — only
            -- members receive what's sent (via file_thread_priority_for_group_members).
            IF NOT EXISTS (
                SELECT 1 FROM "user"."group" ug
                WHERE ug.user_id = p_user_id AND ug.id = v_group.id
            ) THEN
                RAISE EXCEPTION 'User does not have permission to add this group';
            END IF;
        END IF;
    END LOOP;
```

- [ ] **Step 2: Commit**

```bash
git add libs/db/schema/60-functions/share_thread.sql
git commit -m "$(cat <<'EOF'
db(schema): visibility-as-permission in share_thread_with_groups

Non-announce groups: anyone with user.group visibility can add the
group to a thread. Replaces the type-based admin/member gate.
Announce groups still admin-only post.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Generate migration and add backfill UPDATE

**Files:**
- Create: `libs/db/migrations/<timestamp>_shareable_groups.sql` (Atlas-generated)
- Modify: same file, append a backfill `UPDATE` after the auto-generated DDL

- [ ] **Step 1: Generate the migration**

Run: `cd libs/db && pnpm gen-migration -- shareable_groups`

Expected: a new file `libs/db/migrations/<timestamp>_shareable_groups.sql` is created. Open it and confirm it contains roughly:

- `ALTER TABLE "public"."group" ADD COLUMN "key" text` and the unique constraint
- `CREATE OR REPLACE FUNCTION "public"."auto_create_team_group"` (updated body)
- `CREATE OR REPLACE FUNCTION "public"."auto_maintain_team_group_members"` (updated body)
- `CREATE OR REPLACE VIEW "user"."group"` (updated WHERE)
- `CREATE OR REPLACE FUNCTION "public"."share_thread_with_groups"` (updated body)
- The column comment from Task 1

If anything is missing, re-run the schema diff to debug: `cd libs/db && pnpm diff-schema-migrations`. Do not edit the migration file other than the backfill addition described next.

- [ ] **Step 2: Append the backfill UPDATE**

Append to the end of the generated migration file:

```sql
-- Backfill: tag the existing auto-maintained Plot Team group so non-members
-- can see/address it via the new user.group visibility branch.
-- No-op in environments where the Plot team doesn't exist (e.g. local dev
-- with the Plot Publisher fallback).
UPDATE "public"."group" g
SET key = '@plot.team'
WHERE g.auto_maintained = TRUE
  AND g.auto_team_admin_team_id IS NULL
  AND g.team_id = (SELECT id FROM team WHERE name = 'Plot' LIMIT 1)
  AND g.key IS DISTINCT FROM '@plot.team';
```

- [ ] **Step 3: Re-hash the migration directory**

The hash file is recomputed when you edit a migration manually. Run:

```bash
cd libs/db && atlas migrate hash --dir file://migrations
```

Expected: silent success (or confirmation that `atlas.sum` was updated).

- [ ] **Step 4: Apply the migration**

Run: `cd libs/db && pnpm apply-migrations`

Expected: the migration applies cleanly. If it fails, fix the error in the migration file (or upstream schema file), re-hash, and re-run.

- [ ] **Step 5: Confirm schema and migrations are in sync**

Run: `cd libs/db && pnpm diff-schema-migrations 2>&1 | tail -5`

Expected: output ends with `no changes` (or similar) — confirms no further migration is needed.

- [ ] **Step 6: Regenerate TypeScript types**

Run: `cd libs/db && pnpm types`

Expected: `libs/db/src/types.ts` is updated. `key` should appear in the `group` table's Row/Insert/Update types.

- [ ] **Step 7: Commit migration + regenerated types**

```bash
git add libs/db/migrations/ libs/db/src/types.ts
git commit -m "$(cat <<'EOF'
db(migration): shareable groups via key column + visibility gate

Adds group.key column, key='@plot.team' visibility branch in
user.group, and visibility-as-permission in share_thread_with_groups.
Backfills the existing Plot team's auto group with the key.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Verify behavior with psql

These verification queries simulate the three actor classes from the spec's matrix. They are intended to be run against the local database after Task 5.

The local dev DB has no `Plot` team, so we'll create one to drive the verification. After verification we leave it in place — it doesn't affect existing local users.

- [ ] **Step 1: Capture baseline IDs**

Run:

```bash
psql "$DATABASE_URL" -c "SELECT id, email FROM \"user\" ORDER BY created_at LIMIT 3;"
```

Pick two distinct user IDs from the output. In the steps below, substitute:
- `<TEAM_ADMIN_USER>` = first user ID (will be the Plot team admin)
- `<REGULAR_USER>` = second user ID (will NOT be on the Plot team)

If only one user exists locally, sign in to the Flutter app with a second account before continuing.

- [ ] **Step 2: Demonstrate the bug pre-fix is fixed (visibility)**

Create a Plot team — this fires `auto_create_team_group`, which now seeds `key='@plot.team'`:

```bash
psql "$DATABASE_URL" -c "INSERT INTO team (name, created_by) VALUES ('Plot', '<TEAM_ADMIN_USER>') ON CONFLICT DO NOTHING; INSERT INTO team_user (team_id, user_id, role) SELECT id, '<TEAM_ADMIN_USER>', 'admin' FROM team WHERE name = 'Plot' ON CONFLICT DO NOTHING;"
```

Confirm the auto-maintained group has the key:

```bash
psql "$DATABASE_URL" -c "SELECT id, name, type, key FROM \"group\" WHERE key = '@plot.team';"
```

Expected: one row, name `Plot Team`, type `team`, key `@plot.team`.

- [ ] **Step 3: Verify both users see the group via `user.group`**

Run:

```bash
psql "$DATABASE_URL" -c "SELECT user_id, id AS group_id, name, is_member FROM \"user\".\"group\" WHERE key = '@plot.team' AND user_id IN ('<TEAM_ADMIN_USER>', '<REGULAR_USER>');"
```

Expected: two rows. Admin row has `is_member = true`; regular-user row has `is_member = false`. Both rows confirm the chip will render in the picker.

- [ ] **Step 4: Verify a regular user can call `share_thread_with_groups`**

First, find any draft thread the regular user owns (or create one via the app). Then attempt to add the Plot Team group:

```bash
psql "$DATABASE_URL" <<'SQL'
DO $$
DECLARE
    v_user uuid := '<REGULAR_USER>';
    v_group uuid;
    v_thread uuid;
    v_priority uuid;
BEGIN
    SELECT id INTO v_group FROM "group" WHERE key = '@plot.team';
    -- Create a throwaway thread the user has access to
    SELECT id INTO v_priority FROM priority WHERE user_id = v_user LIMIT 1;
    INSERT INTO thread (created_by, priority_id, title)
        VALUES (v_user, v_priority, 'verify share_thread') RETURNING id INTO v_thread;
    -- Will RAISE if the gate rejects it
    PERFORM share_thread_with_groups(v_user, v_thread, ARRAY[v_group]);
    RAISE NOTICE 'OK: regular user added @plot.team to thread %', v_thread;
    -- Cleanup
    DELETE FROM thread WHERE id = v_thread;
END $$;
SQL
```

Expected: `NOTICE: OK: regular user added @plot.team to thread <uuid>`. No EXCEPTION.

- [ ] **Step 5: Verify announce-group restriction still holds**

Create a throwaway announce group (admin only), then attempt to add it as a non-admin:

```bash
psql "$DATABASE_URL" <<'SQL'
DO $$
DECLARE
    v_admin uuid := '<TEAM_ADMIN_USER>';
    v_other uuid := '<REGULAR_USER>';
    v_group uuid;
    v_thread uuid;
    v_priority uuid;
    v_caught boolean := FALSE;
BEGIN
    INSERT INTO "group" (name, type, created_by, auto_maintained)
        VALUES ('test announce', 'announce', v_admin, FALSE) RETURNING id INTO v_group;
    INSERT INTO group_admin (group_id, user_id) VALUES (v_group, v_admin);
    SELECT id INTO v_priority FROM priority WHERE user_id = v_other LIMIT 1;
    INSERT INTO thread (created_by, priority_id, title)
        VALUES (v_other, v_priority, 'verify announce gate') RETURNING id INTO v_thread;
    BEGIN
        PERFORM share_thread_with_groups(v_other, v_thread, ARRAY[v_group]);
    EXCEPTION WHEN OTHERS THEN
        v_caught := TRUE;
        RAISE NOTICE 'OK: rejected non-admin posting to announce group: %', SQLERRM;
    END;
    IF NOT v_caught THEN
        RAISE EXCEPTION 'BUG: non-admin should not be able to add announce group';
    END IF;
    DELETE FROM thread WHERE id = v_thread;
    DELETE FROM "group" WHERE id = v_group;
END $$;
SQL
```

Expected: `NOTICE: OK: rejected non-admin posting to announce group: Only admins can add announce groups to threads`. No EXCEPTION (the inner one is caught and converted to a notice).

- [ ] **Step 6: Verify a non-visible private group is still rejected**

Create a throwaway private group with the admin as the only member, attempt to add it from the regular user (who has no visibility):

```bash
psql "$DATABASE_URL" <<'SQL'
DO $$
DECLARE
    v_admin uuid := '<TEAM_ADMIN_USER>';
    v_other uuid := '<REGULAR_USER>';
    v_group uuid;
    v_thread uuid;
    v_priority uuid;
    v_caught boolean := FALSE;
BEGIN
    INSERT INTO "group" (name, type, created_by) VALUES ('test private', 'private', v_admin) RETURNING id INTO v_group;
    INSERT INTO group_admin (group_id, user_id) VALUES (v_group, v_admin);
    SELECT id INTO v_priority FROM priority WHERE user_id = v_other LIMIT 1;
    INSERT INTO thread (created_by, priority_id, title) VALUES (v_other, v_priority, 'verify private gate') RETURNING id INTO v_thread;
    BEGIN
        PERFORM share_thread_with_groups(v_other, v_thread, ARRAY[v_group]);
    EXCEPTION WHEN OTHERS THEN
        v_caught := TRUE;
        RAISE NOTICE 'OK: rejected non-member posting to private group: %', SQLERRM;
    END;
    IF NOT v_caught THEN
        RAISE EXCEPTION 'BUG: non-member should not be able to add private group';
    END IF;
    DELETE FROM thread WHERE id = v_thread;
    DELETE FROM "group" WHERE id = v_group;
END $$;
SQL
```

Expected: `NOTICE: OK: rejected non-member posting to private group: User does not have permission to add this group`.

---

## Task 7: End-to-end verify via the Flutter app

The Flutter app should require no code changes. This task confirms.

- [ ] **Step 1: Run analyzer to catch any unintended code drift**

Run: `cd apps/plot && flutter analyze 2>&1 | tail -10`

Expected: `No issues found!` (or whatever the unmodified baseline reported — should be unchanged).

- [ ] **Step 2: Hot-reload the running Flutter app and exercise the path**

Hot-reload (the app is running per project conventions). As the regular user:

1. Open the Using Plot priority.
2. Open the new-thread page (e.g. ⌘N or via the new-thread button).
3. Confirm the **Plot Team** chip is present in the "with" row and is selected (filled, not outlined).
4. Type a short note and submit.
5. Switch to the team-admin account.
6. Confirm the new thread appears in the admin's Using Plot priority and is attributed to the regular user.
7. Switch to a third user (any non-admin, non-Plot-team user — sign in via a new account if needed).
8. Confirm the third user does NOT see the thread submitted in step 4 — visibility flows only to actual Plot team members.

If step 3 fails (no chip), check that `priority.default_groups` contains the Plot Team group ID for the regular user's Using Plot priority:

```bash
psql "$DATABASE_URL" -c "SELECT user_id, default_groups FROM priority WHERE user_id = '<REGULAR_USER>' AND key = '@plot.app';"
```

If `default_groups` is empty, the migration `20260421193650_add_priority_default_sharing.sql` needs to have run for that user. It backfills via `WHERE config ? 'group'`, so users created after that migration land with `default_groups` set by `activate_invited_user`. If the regular user's Using Plot priority has empty `default_groups`, manually set it for the test:

```bash
psql "$DATABASE_URL" -c "UPDATE priority SET default_groups = ARRAY[(SELECT id FROM \"group\" WHERE key = '@plot.team')] WHERE user_id = '<REGULAR_USER>' AND key = '@plot.app';"
```

Then force the Flutter sync to pick up the change (toggle the priority away and back, or restart the app).

- [ ] **Step 3: Run finalize**

Run the `/finalize` skill to lint, check backwards compat, error capture, docs.

Expected: clean. There are no API code changes (only schema/SQL), so the API lint should be unchanged. Docs updates: add a one-liner to `docs/updates.md` and (if user-facing semantics changed) `docs/features.md`.

- [ ] **Step 4: Final commit (docs + any cleanup)**

```bash
git add docs/updates.md docs/features.md 2>/dev/null
git diff --cached --stat
git commit -m "$(cat <<'EOF'
docs: shareable groups for @plot.team

Plot Team is now visible to all users so feedback flows from anyone
using the Using Plot priority.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

(Skip if there are no docs changes to commit.)

---

## Self-Review Notes

**Spec coverage:**
- §Schema (key column) → Task 1 ✓
- §user.group view → Task 3 ✓
- §share_thread permission → Task 4 ✓
- §Group seeding (triggers + backfill) → Task 2 + Task 5 step 2 ✓
- §Flutter app (no changes) → Task 7 step 1+2 confirms ✓
- §Migration (single migration with all changes + backfill) → Task 5 ✓
- §Testing (manual psql + Flutter exercise) → Task 6 + Task 7 ✓
- §Visibility/permission matrix → covered by Task 6 steps 3-6 ✓

**Placeholder scan:** none — every task has concrete SQL/commands and exact file:line references.

**Type consistency:** column name `key`, type `text`, key value `'@plot.team'` used consistently across all tasks and matches the spec.

**Ordering note:** Tasks 1-4 are pure schema edits and could be combined into one commit, but separate commits make each change reviewable in isolation. Task 5 generates one Atlas migration that captures the union of Tasks 1-4 (Atlas diffs the whole schema dir at once).
