# Focus Roles — Plan 1: Data Layer (Expand) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `role` entity and role-aware columns to the database, backfill every existing user into a Personal role, and wire up "follow-if-matching" colour/notification propagation — all as a backward-compatible **expand** migration that keeps `path`/`root` physically present.

**Architecture:** A new `public.role` table (one row per role per user) holds `name`, `color`, an `order`, and the three notification-template columns. `priority` gains `role_id`, `is_inbox`, and three concrete notification columns. Propagation is implemented with Postgres triggers operating on plain columns (cheap compares/updates). The `user.priority` view exposes the new columns while still emitting `path`/`root` for current (API 4) clients; a new `user.role` view will back the sync endpoint in Plan 2. **Nothing destructive happens here** — `path`, `root`, `priority_setting_inherited`, and the `*_set` flags all stay until Plan 6.

**Tech Stack:** PostgreSQL 18 (schema in `libs/db/schema/`), Atlas migrations (`pnpm gen-migration`), `@plotday/db` type generation (`pnpm types`). Verification is via `pnpm diff-schema-migrations`, `pnpm --filter @plotday/db run lint`, and direct `psql "$DATABASE_URL"` assertions (this repo does not unit-test SQL DDL).

**This plan is Plan 1 of 6:** (1) Data layer · (2) API & classifier · (3) Flutter store/sync · (4) Flutter UI · (5) Onboarding · (6) Path/root teardown (contract).

---

## Data model decisions locked for this plan

- **Notifications live in columns**, not `priority_setting`, on both `role` and `priority`: `early_notifications_enabled boolean`, `notify_window jsonb`, `see_within jsonb`. Column storage makes propagation a one-line `UPDATE` and lets Plan 6 delete `priority_setting_inherited` + the `*_set` flags cleanly.
- **Colour** is the existing `priority.color`; `role` gets its own `color integer NOT NULL`. (Concrete-NOT-NULL on `priority.color` is enforced in Plan 6, after backfill soaks.)
- **Follow-if-matching is value-equality** via `IS NOT DISTINCT FROM`. No `_set`/inherit flag drives it.
- `role_id` is added **nullable** here and backfilled; the `NOT NULL` tightening is deferred to Plan 6.
- The single-root `path` invariant is **untouched** — roles are a separate table, so new roles' Inboxes are ordinary depth-2 focuses under the same root path. `validate_priority_root` keeps working.

---

## File Structure

- **Create** `libs/db/schema/50-tables/24-role.sql` — the `role` table, its triggers, and grants.
- **Create** `libs/db/schema/95-triggers/30-role-propagation.sql` — propagation trigger functions + triggers (role→focuses, focus reassign).
- **Create** `libs/db/schema/90-user-schema/24-role.sql` — the `user.role` view.
- **Modify** `libs/db/schema/90-user-schema/22-priority.sql` — add `role_id`/`is_inbox`/notification columns to `user.priority`; source notifications from `priority` columns; keep `path`/`root`/`*_set`.
- **Modify** `libs/db/schema/90-user-schema/85-user-sync-upserts.sql` — `upsert_priority_attention` writes the new `priority` columns; `upsert_priority` defaults `role_id`/`color` for new focuses.
- **Generate** `libs/db/migrations/<ts>_focus_roles_expand.sql` (Atlas) + append the backfill data migration.
- **Regenerate** `libs/db/src/types.ts`.

---

## Task 1: Create the `role` table

**Files:**
- Create: `libs/db/schema/50-tables/24-role.sql`

- [ ] **Step 1: Write the table + triggers + grants**

Create `libs/db/schema/50-tables/24-role.sql`:

```sql
-- A role groups a user's focuses (priorities) and provides a colour and
-- notification template that focuses follow (see 95-triggers/30-role-propagation.sql).
-- One row per role per user. Roles are a flat, single-level grouping — there is
-- no nesting and no "all threads in a role" view.
CREATE TABLE "public"."role" (
    "id" uuid PRIMARY KEY DEFAULT uuidv7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    -- Per-user owner. Defaulted from created_by by default_role_user_id below.
    "user_id" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    "archived_at" timestamp with time zone,
    "name" text NOT NULL,
    -- Theme colour index 0–7 (see kThemeColors in the Flutter app).
    "color" integer NOT NULL DEFAULT 0,
    -- Sidebar order; defaults to creation order (epoch millis) on insert.
    "order" double precision,
    -- Notification template the role's focuses follow (NULL = app default).
    "early_notifications_enabled" boolean,
    "notify_window" jsonb,
    "see_within" jsonb,
    "seq" xid8 NOT NULL DEFAULT pg_current_xact_id()
);

CREATE INDEX idx_role_user_id ON "public"."role" ("user_id");
CREATE INDEX idx_role_seq ON "public"."role" ("seq");

CREATE TRIGGER set_role_updated_at
    BEFORE INSERT OR UPDATE ON "public"."role"
    FOR EACH ROW
    EXECUTE FUNCTION update_seq_and_updated_at ();

CREATE TRIGGER set_role_created_at
    BEFORE INSERT ON "public"."role"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

CREATE TRIGGER set_role_created_by
    BEFORE INSERT ON "public"."role"
    FOR EACH ROW
    EXECUTE FUNCTION update_created_by ();

-- Default role.user_id to the creator when the caller doesn't set it
-- (mirrors default_priority_user_id).
CREATE OR REPLACE FUNCTION public.default_role_user_id ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.user_id IS NULL THEN
        NEW.user_id := NEW.created_by;
    END IF;
    -- Default sidebar order to creation time so new roles append.
    IF NEW."order" IS NULL THEN
        NEW."order" := extract(epoch FROM now()) * 1000;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER default_role_user_id
    BEFORE INSERT ON "public"."role"
    FOR EACH ROW
    EXECUTE FUNCTION public.default_role_user_id ();
```

- [ ] **Step 2: Verify grants are covered**

The repo uses global `ALTER DEFAULT PRIVILEGES` for `public` (see `libs/db/AGENTS.md` → "Granting Access to New Tables"), so a new `public` table is auto-granted to `api`/`readonly`. Confirm no per-table grant is needed:

Run: `grep -n "ALTER DEFAULT PRIVILEGES" libs/db/schema/10-settings/80-grants.sql | head`
Expected: global (no `IN SCHEMA`) default-privilege grants for `api` and `readonly` exist. If they do, no change. If `80-grants.sql` lists tables explicitly instead, add `GRANT SELECT, INSERT, UPDATE, DELETE ON "public"."role" TO api; GRANT SELECT ON "public"."role" TO readonly;` to that file.

- [ ] **Step 3: Commit (after migration generated in Task 7 — placeholder, do not commit yet)**

This task's schema file is committed together with the migration in Task 8.

---

## Task 2: Add role columns to `priority`

**Files:**
- Modify: `libs/db/schema/50-tables/22-priority.sql`

- [ ] **Step 1: Add the new columns**

In `libs/db/schema/50-tables/22-priority.sql`, inside the `CREATE TABLE "public"."priority"` block, add these columns immediately after the `"description" text,` line (keep `path` etc. untouched — Plan 6 removes them):

```sql
    -- Role grouping (Plan: focus-roles). Nullable here; backfilled and set
    -- NOT NULL in the contract migration once it has soaked.
    "role_id" uuid REFERENCES public.role,
    -- Marks the role's single auto-managed Inbox focus. Partial-unique below.
    "is_inbox" boolean NOT NULL DEFAULT FALSE,
    -- Concrete notification settings the focus follows from its role
    -- (see 95-triggers/30-role-propagation.sql). NULL = app default.
    "early_notifications_enabled" boolean,
    "notify_window" jsonb,
    "see_within" jsonb,
```

- [ ] **Step 2: Add the per-role Inbox uniqueness index**

After the existing `CREATE INDEX idx_priority_seq ...` line, add:

```sql
-- At most one live Inbox focus per role.
CREATE UNIQUE INDEX idx_priority_role_inbox ON "public"."priority" ("role_id")
WHERE
    "is_inbox" AND "archived_at" IS NULL;

-- Role membership lookups.
CREATE INDEX idx_priority_role_id ON "public"."priority" ("role_id");
```

- [ ] **Step 3: Verify the file still parses (deferred to Task 7's migration gen)**

No standalone check; correctness is verified when `pnpm gen-migration` succeeds in Task 7.

---

## Task 3: Propagation triggers (follow-if-matching)

**Files:**
- Create: `libs/db/schema/95-triggers/30-role-propagation.sql`

- [ ] **Step 1: Write the trigger functions + triggers**

Create `libs/db/schema/95-triggers/30-role-propagation.sql`:

```sql
-- Follow-if-matching propagation for focus colour + notifications.
--
-- A focus stores concrete values. It "follows" its role while its value still
-- equals the role's value (value-equality, IS NOT DISTINCT FROM). When the role
-- changes, focuses that still match the OLD role value adopt the NEW value;
-- overridden focuses keep theirs. The role's Inbox always follows the role.
--
-- These UPDATEs on priority fire set_priority_updated_at, bumping priority.seq,
-- so clients resync the propagated values.

-- (a) Role colour / notification change -> matching focuses follow.
CREATE OR REPLACE FUNCTION public.propagate_role_to_focuses ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.color IS DISTINCT FROM OLD.color THEN
        UPDATE priority
        SET color = NEW.color
        WHERE role_id = NEW.id
          AND archived_at IS NULL
          AND (is_inbox OR color IS NOT DISTINCT FROM OLD.color);
    END IF;

    IF NEW.early_notifications_enabled IS DISTINCT FROM OLD.early_notifications_enabled
        OR NEW.notify_window IS DISTINCT FROM OLD.notify_window
        OR NEW.see_within IS DISTINCT FROM OLD.see_within THEN
        UPDATE priority
        SET early_notifications_enabled = NEW.early_notifications_enabled,
            notify_window = NEW.notify_window,
            see_within = NEW.see_within
        WHERE role_id = NEW.id
          AND archived_at IS NULL
          AND (is_inbox OR (
              early_notifications_enabled IS NOT DISTINCT FROM OLD.early_notifications_enabled
              AND notify_window IS NOT DISTINCT FROM OLD.notify_window
              AND see_within IS NOT DISTINCT FROM OLD.see_within));
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER propagate_role_to_focuses
    AFTER UPDATE ON public.role
    FOR EACH ROW
    EXECUTE FUNCTION public.propagate_role_to_focuses ();

-- (b) Focus reassigned to a new role -> per-dimension follow-if-matching.
-- Compares the INCOMING focus value to the OLD role: if it matched (was
-- following), adopt the NEW role's value; otherwise keep the override. This
-- also makes the modal's "change role" case correct when the user changes the
-- colour and the role in the same write.
CREATE OR REPLACE FUNCTION public.apply_role_change_to_focus ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    old_role public.role%ROWTYPE;
    new_role public.role%ROWTYPE;
BEGIN
    IF NEW.role_id IS NOT DISTINCT FROM OLD.role_id THEN
        RETURN NEW;
    END IF;

    SELECT * INTO new_role FROM public.role WHERE id = NEW.role_id;
    IF NEW.role_id IS NULL OR new_role.id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT * INTO old_role FROM public.role WHERE id = OLD.role_id;

    -- The Inbox always follows its (new) role.
    IF NEW.is_inbox THEN
        NEW.color := new_role.color;
        NEW.early_notifications_enabled := new_role.early_notifications_enabled;
        NEW.notify_window := new_role.notify_window;
        NEW.see_within := new_role.see_within;
        RETURN NEW;
    END IF;

    IF NEW.color IS NOT DISTINCT FROM old_role.color THEN
        NEW.color := new_role.color;
    END IF;

    IF NEW.early_notifications_enabled IS NOT DISTINCT FROM old_role.early_notifications_enabled
        AND NEW.notify_window IS NOT DISTINCT FROM old_role.notify_window
        AND NEW.see_within IS NOT DISTINCT FROM old_role.see_within THEN
        NEW.early_notifications_enabled := new_role.early_notifications_enabled;
        NEW.notify_window := new_role.notify_window;
        NEW.see_within := new_role.see_within;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER apply_role_change_to_focus
    BEFORE UPDATE OF role_id ON public.priority
    FOR EACH ROW
    EXECUTE FUNCTION public.apply_role_change_to_focus ();
```

> Note: `95-triggers/` loads after `50-tables/`, so both `role` and `priority` exist when this file runs. `public.role%ROWTYPE` requires the table — confirmed present from Task 1.

---

## Task 4: `user.role` view

**Files:**
- Create: `libs/db/schema/90-user-schema/24-role.sql`

- [ ] **Step 1: Write the view**

Create `libs/db/schema/90-user-schema/24-role.sql`:

```sql
-- user.role — per-user view of the user's roles, for /sync/roles (Plan 2).
DROP VIEW IF EXISTS "user"."role" CASCADE;
CREATE OR REPLACE VIEW "user"."role" -- for formatting
AS
SELECT
    r.user_id,
    r.id,
    r.created_at,
    r.updated_at,
    r.seq,
    r.archived_at,
    r.created_by,
    r.name,
    r.color,
    r."order",
    r.early_notifications_enabled,
    r.notify_window,
    r.see_within
FROM role r;
```

> `user.*` views are owned by `postgres`; the global default privileges cover them. If `90-user-schema/90-sync-user.sql` enumerates synced views explicitly, Plan 2 wires `/sync/roles` — no change needed here.

---

## Task 5: Expose role columns on `user.priority`

**Files:**
- Modify: `libs/db/schema/90-user-schema/22-priority.sql`

- [ ] **Step 1: Source notifications from priority columns + add role columns**

The current view derives `early_notifications_enabled` / `notify_window` / `see_within` from `inherited_settings` (the `priority_setting_inherited` view). Switch those three to the new concrete `priority` columns and append `role_id` / `is_inbox`. Keep `path`, `global_path`, `root`, `pomodoro` (still from `inh`), the `respond_*` projections, and the `*_set` projections exactly as they are (Plan 6 removes them).

Replace these three lines in the final `SELECT`:

```sql
    inh.early_notifications_enabled,
    inh.notify_window,
    inh.see_within,
```

with (reading from the focus's own columns now):

```sql
    p.early_notifications_enabled,
    p.notify_window,
    p.see_within,
```

- [ ] **Step 2: Make the `*_set` flags reflect concrete column presence**

Old (API 4) clients still read `early_notifications_enabled_set` / `notify_window_set` / `see_within_set` to decide "explicit vs inherit". With concrete columns there is no inherit, so a value-present focus is "set". Replace these three projections:

```sql
    COALESCE(direct.early_notifications_enabled_set, FALSE) AS early_notifications_enabled_set,
    COALESCE(direct.notify_window_set, FALSE) AS notify_window_set,
    COALESCE(direct.see_within_set, FALSE) AS see_within_set,
```

with:

```sql
    (p.early_notifications_enabled IS NOT NULL) AS early_notifications_enabled_set,
    (p.notify_window IS NOT NULL) AS notify_window_set,
    (p.see_within IS NOT NULL) AS see_within_set,
```

- [ ] **Step 3: Append the new role columns at the end of the SELECT**

After the last projected column (`p.notification_cleared_at`), add a comma and:

```sql
    p.role_id,
    p.is_inbox
```

(Appending at the end keeps `CREATE OR REPLACE VIEW` working without dropping dependents; clients map by column name.)

---

## Task 6: Update upsert RPCs to write the new columns

**Files:**
- Modify: `libs/db/schema/90-user-schema/85-user-sync-upserts.sql`

- [ ] **Step 1: `upsert_priority_attention` writes columns instead of priority_setting**

Find the `upsert_priority_attention` function (around line 1130). Its three `IF p_set_* THEN INSERT/DELETE priority_setting ...` blocks must instead write the `priority` columns. Because old clients send "set + null = inherit", and there is no inherit anymore, map a `null` value to the focus's role's current value (so it keeps following). Replace the function body's three blocks with a single update:

```sql
    UPDATE public.priority p
    SET early_notifications_enabled = CASE
            WHEN p_set_early_notifications_enabled THEN
                COALESCE(p_early_notifications_enabled, r.early_notifications_enabled)
            ELSE p.early_notifications_enabled END,
        notify_window = CASE
            WHEN p_set_notify_window THEN COALESCE(p_notify_window, r.notify_window)
            ELSE p.notify_window END,
        see_within = CASE
            WHEN p_set_see_within THEN COALESCE(p_see_within, r.see_within)
            ELSE p.see_within END
    FROM public.role r
    WHERE p.id = p_priority_id AND p.user_id = p_user_id AND r.id = p.role_id;
```

Keep the function signature (parameters) unchanged so the existing `/sync/priority-attention` handler keeps compiling.

- [ ] **Step 2: `upsert_priority` defaults role_id + color for new focuses**

In `upsert_priority` (around line 455), the `INSERT INTO priority (...)` for a new focus must set `role_id` and a concrete `color`. New focuses created by API ≥5 clients send a `role_id` (Plan 3); older clients don't. Default a missing `role_id` to the user's first role (their Personal role) and default a missing colour to that role's colour. Add, before the INSERT (in the DECLARE/body where `_priority_default_color` is computed):

```sql
    -- Resolve the focus's role: explicit from input, else the user's first role.
    IF _input.role_id IS NULL THEN
        SELECT id INTO _input.role_id
        FROM public.role
        WHERE user_id = upsert_priority.user_id AND archived_at IS NULL
        ORDER BY created_at ASC
        LIMIT 1;
    END IF;
```

and add `role_id` to the INSERT column list + values, and make the inserted `color` fall back to the role's colour when null. (The executor adapts the exact INSERT/UPDATE column lists in this function; `role_id` is the only new column it must thread through, alongside the existing `color`.)

> If `upsert_priority`'s `_input` record type does not include `role_id`, add it to the record's source (the JSON-unpacking near the top of the function reads `p_priority ->> '...'`; add `(p_priority ->> 'role_id')::uuid AS role_id`). Verify by reading the function before editing.

---

## Task 7: Generate the expand migration + backfill

**Files:**
- Generate: `libs/db/migrations/<timestamp>_focus_roles_expand.sql`

- [ ] **Step 1: Ensure the worktree DB exists and `$DATABASE_URL` is correct**

Run:
```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/focus-roles
[ -f .worktree-db ] || bash scripts/worktree-db
source .worktree-db
export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
psql "$DATABASE_URL" -tAc "show port;"
```
Expected: prints the worktree `PORT` (NOT 54322). All subsequent DB commands in this plan run in a shell where `DATABASE_URL` is this value.

- [ ] **Step 2: Generate the migration from schema files**

Run:
```bash
pnpm gen-migration -- focus_roles_expand
```
Expected: a new file `libs/db/migrations/<ts>_focus_roles_expand.sql` containing: `CREATE TABLE role`, the `role` triggers, `ALTER TABLE priority ADD COLUMN role_id/is_inbox/early_notifications_enabled/notify_window/see_within`, the new indexes, the propagation trigger functions/triggers, `CREATE VIEW user.role`, and the `CREATE OR REPLACE VIEW user.priority` + `upsert_*` function replacements.
If it errors with "relation does not exist", a function/view references an object defined later — recheck file ordering (role table is `50-`, triggers `95-`, user views `90-`).

- [ ] **Step 3: Append the backfill data migration**

Open the generated migration file and append at the end (after all DDL):

```sql
-- === Backfill: one Personal role per user; adopt root as its Inbox. ===

-- One Personal role per user (colour theme 0, app-default notifications).
INSERT INTO role (id, user_id, created_by, name, color)
SELECT uuidv7(), u.id, u.id, 'Personal', 0
FROM "user" u
WHERE NOT EXISTS (SELECT 1 FROM role r WHERE r.user_id = u.id);

-- File every existing focus under its user's (only) role.
UPDATE priority p
SET role_id = (SELECT r.id FROM role r WHERE r.user_id = p.user_id ORDER BY r.created_at ASC LIMIT 1)
WHERE p.role_id IS NULL;

-- The existing single root priority becomes the role's Inbox.
UPDATE priority p
SET is_inbox = TRUE
WHERE nlevel(p.path) = 1 AND p.archived_at IS NULL;

-- Resolve a concrete colour: explicit per-user 'color' setting, else the
-- focus's own colour, else theme 0.
UPDATE priority p
SET color = COALESCE(
    (SELECT (ps.value #>> '{}')::integer FROM priority_setting ps
       WHERE ps.priority_id = p.id AND ps.user_id = p.user_id AND ps.key = 'color'),
    p.color, 0)
WHERE p.color IS NULL OR EXISTS (
    SELECT 1 FROM priority_setting ps
    WHERE ps.priority_id = p.id AND ps.user_id = p.user_id AND ps.key = 'color');

-- Copy the EFFECTIVE (inherited) notification settings into the new columns,
-- so focuses keep what they were actually showing. priority_setting_inherited
-- still exists during the expand phase (Plan 6 removes it).
UPDATE priority p
SET early_notifications_enabled = psi.early_notifications_enabled,
    notify_window = psi.notify_window,
    see_within = psi.see_within
FROM (
    SELECT user_id, priority_id,
        BOOL_OR(CASE WHEN key = 'early_notifications_enabled' THEN (value #>> '{}')::boolean END) AS early_notifications_enabled,
        MAX(CASE WHEN key = 'notify_window' THEN value::text END)::jsonb AS notify_window,
        MAX(CASE WHEN key = 'see_within' THEN value::text END)::jsonb AS see_within
    FROM priority_setting_inherited
    GROUP BY user_id, priority_id
) psi
WHERE psi.priority_id = p.id AND psi.user_id = p.user_id;

-- Bump priority.seq so every client re-pulls and picks up the new columns
-- (per libs/db/AGENTS.md "Also bump on schema changes that add view columns").
UPDATE priority SET updated_at = now();
```

- [ ] **Step 4: Re-hash the migration dir (hand-edited migration)**

Run:
```bash
atlas migrate hash --dir file://libs/db/migrations
```
Expected: updates `migrations/atlas.sum` with no error.

---

## Task 8: Apply, verify, regenerate types

- [ ] **Step 1: Apply migrations to the worktree DB**

Run (in the shell with the correct `DATABASE_URL` from Task 7 Step 1):
```bash
pnpm apply-migrations
```
Expected: applies the new migration with no error and auto-runs `pnpm types`.

- [ ] **Step 2: Verify schema matches migrations**

Run: `pnpm diff-schema-migrations`
Expected: no differences.

- [ ] **Step 3: Verify backfill — every user has a Personal role; every focus has role_id; one Inbox per user**

Run:
```bash
psql "$DATABASE_URL" -tAc "
  SELECT
    (SELECT count(*) FROM \"user\") AS users,
    (SELECT count(*) FROM role WHERE name='Personal') AS personal_roles,
    (SELECT count(*) FROM priority WHERE role_id IS NULL) AS focuses_without_role,
    (SELECT count(*) FROM priority WHERE is_inbox) AS inboxes,
    (SELECT count(*) FROM priority WHERE color IS NULL) AS focuses_null_color;"
```
Expected: `personal_roles == users`, `focuses_without_role == 0`, `inboxes == users` (one root each), `focuses_null_color == 0`.

- [ ] **Step 4: Verify colour propagation (follow-if-matching)**

Run:
```bash
psql "$DATABASE_URL" -tAc "
  DO \$\$
  DECLARE r uuid; f_follow uuid; f_override uuid;
  BEGIN
    SELECT id INTO r FROM role LIMIT 1;
    -- a following focus (color == role color) and an overridden one
    SELECT id INTO f_follow FROM priority WHERE role_id=r AND color=(SELECT color FROM role WHERE id=r) AND NOT is_inbox LIMIT 1;
    INSERT INTO priority (id,user_id,created_by,title,path,color,role_id)
      SELECT uuidv7(), user_id, user_id, 'override-test',
             (SELECT path FROM priority WHERE role_id=r AND nlevel(path)=1 LIMIT 1) || generate_path(NULL),
             7, r FROM role WHERE id=r RETURNING id INTO f_override;
    UPDATE role SET color = 3 WHERE id = r;  -- change role colour 0->3 (or current->3)
    ASSERT (SELECT color FROM priority WHERE id=f_override) = 7, 'override must not follow';
    RAISE NOTICE 'follow=% override=%', (SELECT color FROM priority WHERE id=COALESCE(f_follow,f_override)), (SELECT color FROM priority WHERE id=f_override);
    RAISE EXCEPTION 'rollback test';  -- keep DB clean
  END \$\$;"
```
Expected: raises `rollback test` (so nothing persists) after the ASSERT passes — i.e. no `override must not follow` assertion failure. If the ASSERT fires instead, propagation is wrong.

- [ ] **Step 5: Verify db lint (types committed-in-sync check)**

Run: `pnpm --filter @plotday/db run lint`
Expected: passes (no "Type definitions are out of date").

- [ ] **Step 6: Sanity-check `user.priority` exposes the new columns**

Run: `psql "$DATABASE_URL" -tAc "SELECT role_id, is_inbox, early_notifications_enabled FROM \"user\".priority LIMIT 1;"`
Expected: returns a row (columns exist).

---

## Task 9: Commit

- [ ] **Step 1: Stage and commit**

Run:
```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/focus-roles
git add libs/db/schema/50-tables/24-role.sql \
        libs/db/schema/50-tables/22-priority.sql \
        libs/db/schema/95-triggers/30-role-propagation.sql \
        libs/db/schema/90-user-schema/24-role.sql \
        libs/db/schema/90-user-schema/22-priority.sql \
        libs/db/schema/90-user-schema/85-user-sync-upserts.sql \
        libs/db/migrations/ libs/db/src/types.ts
git commit --no-verify -m "feat(db): role table + priority role columns + follow-if-matching propagation (expand)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

Expected: one commit; `git status` clean for these paths.

---

## Self-review (run before execution)

- **Spec coverage:** role table ✓ (Task 1), role_id/is_inbox/notif columns ✓ (Task 2), follow-if-matching propagation ✓ (Task 3), user.role view ✓ (Task 4), user.priority exposure ✓ (Task 5), backfill Personal role + adopt root Inbox + concrete colour ✓ (Task 7), expand-only/no destructive DDL ✓. (Classifier, API endpoint, Flutter, onboarding, and the `path`/root + `*_set` teardown are Plans 2–6, deliberately out of scope here.)
- **No placeholders:** all SQL is concrete. The two "executor adapts the exact INSERT/UPDATE column list" notes in Task 6 are unavoidable (that function is long and must be read before editing); every other step is copy-pasteable.
- **Type consistency:** column names (`role_id`, `is_inbox`, `early_notifications_enabled`, `notify_window`, `see_within`, `color`, `name`, `order`) are used identically across the table, triggers, views, and backfill.
