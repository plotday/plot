# Plot Database

## Schema Change Workflow

**CRITICAL: Always follow this exact process for schema changes. No exceptions.**

### Step-by-Step Process

1. **Modify schema files in `schema/` directory**
   - Schema files are the single source of truth for database structure
   - Organize by type: `40-functions/`, `50-tables/`, `60-functions/`, `70-views/`, `90-user-schema/`, `95-triggers/`, `99-data/`
   - NEVER modify migration files or the database directly

2. **Generate migration**
   ```bash
   pnpm gen-migration -- <descriptive_name>
   ```
   - Uses Atlas to compare schema with existing migrations
   - Creates timestamped migration in `migrations/`
   - Example: `pnpm gen-migration -- add_thread_order_column`

3. **Add data migrations if needed (optional)**
   - Open the generated migration file
   - Add SQL for data transformations after the schema changes
   - Example: `UPDATE thread SET order_value = created_at;`
   - Keep data migrations minimal and focused

4. **Apply migration to LOCAL database**
   ```bash
   pnpm apply-migrations
   ```
   - Uses Atlas to apply all pending migrations to the LOCAL database (uses `$DATABASE_URL`)
   - Atlas tracks applied migrations in its `atlas_schema_revisions` table
   - Use `pnpm diff-schema-migrations` to check if schema changes need new migrations

5. **Handle migration failures**
   - If a migration fails, the database state is unchanged (transaction rollback)
   - Edit the migration file to fix the issue
   - Re-run: `pnpm apply-migrations`
   - Repeat until successful

6. **Make additional schema changes (if needed)**
   - Modify schema files again
   - Generate a new migration: `pnpm gen-migration -- <another_name>`
   - Apply it: `pnpm apply-migrations`
   - This is normal - iterative changes use multiple migrations

7. **Verify schema sync**
   ```bash
   pnpm diff-schema-migrations
   ```
   - Should show no differences if everything is applied
   - If differences exist, you have unapplied schema changes

8. **Regenerate TypeScript types**
   ```bash
   pnpm types
   ```
   - Updates `src/types.ts` to match current database schema
   - Commit these type changes with your schema/migration changes

## Schema Guidelines

- **Schema is the source of truth** - defined in `schema/` directory
- **RLS is disabled on all public schema tables** - Authorization is enforced at the API layer, not via RLS.
- **Primary keys**:
  - Default: `bigint` primary keys for server-created rows
  - UUID primary keys for rows created on the client
- **Migrations are generated** - Never create migration files manually
- **Function directory organization**:
  - Functions in `40-functions/` are loaded before tables in `50-tables/`
  - Functions that reference tables must be in `60-functions/` or later
  - User schema views/functions live in `90-user-schema/` (after public views)
  - If you get "relation does not exist" errors during migration generation, move the function to a later directory

## Database Roles and Permissions

The database uses several roles with different privilege levels:
- **`postgres`**: The owner role used for local development and schema creation.
- **`migrator`**: The role used by CI/CD (GitHub Actions) to apply migrations to production.
- **`api`**: The application role used by workers to read and write data.
- **`readonly`**: A restricted role for internal tools and debugging with SELECT-only access.

### Granting Access to New Tables

To ensure all new tables are accessible to the `api` and `readonly` roles, **`ALTER DEFAULT PRIVILEGES` must be configured for both the `postgres` and `migrator` roles.**

If you add a new schema or a new role that creates objects, you MUST update `libs/db/schema/10-settings/80-grants.sql` and include a migration that applies these grants:

```sql
-- For existing tables
GRANT SELECT ON ALL TABLES IN SCHEMA your_new_schema TO readonly;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA your_new_schema TO api;

-- For future tables
ALTER DEFAULT PRIVILEGES FOR ROLE postgres GRANT SELECT ON TABLES TO readonly;
ALTER DEFAULT PRIVILEGES FOR ROLE migrator GRANT SELECT ON TABLES TO readonly;
-- ... and similar for the api role
```

The `80-grants.sql` file uses global `ALTER DEFAULT PRIVILEGES` (omitting `IN SCHEMA`) to ensure these rules apply across all current and future schemas.

## Timestamp Precision Boundary (JavaScript ↔ PostgreSQL)

JavaScript `Date` has only **millisecond** precision, but PostgreSQL `timestamptz` has **microsecond** precision. When a client-provided timestamp (which passed through JS Date) is compared against a database-stored timestamp using `>=`, `<=`, or `=`, the sub-millisecond digits cause silent mismatches.

**Rule:** Any SQL comparison between a client-provided timestamp and a DB timestamp **MUST** truncate the DB value:

```sql
-- WRONG: fails when DB has sub-millisecond digits
WHERE p_client_timestamp >= db_column

-- CORRECT: truncate DB value to match client precision
WHERE p_client_timestamp >= date_trunc('milliseconds', db_column)
```

This applies to:
- SQL functions that receive timestamps from the API (parameters like `p_read_at`, `p_note_created_at`)
- Sync cursor comparisons (see `updatedSinceCursor()` in `workers/api/src/app/sync/helpers.ts`)
- Any WHERE guard that compares client input against stored timestamps

**Where this is already applied:**
- `updatedSinceCursor()` — sync pagination
- `clear_thread_unread()` — thread read guard
- `upsert_thread_unread()` — race condition guard

## Thread Visibility in Views

Any view or query that joins `thread_unread` (or otherwise decides what a
user can see) must enforce thread visibility. The canonical reference is the
`user.thread` view. In the per-user priority model, visibility is driven
by the `thread_priority` join table plus contact membership:

```sql
JOIN public.thread_priority tp ON tp.thread_id = a.id
LEFT JOIN public.thread_unread tu
    ON tu.user_id = tp.user_id AND tu.thread_id = a.id
WHERE a.archived_at IS NULL
  AND (a.draft = FALSE OR a.created_by = tp.user_id)
  AND a.contacts && "user".user_contact_ids(tp.user_id)
```

- `thread_priority` is populated automatically by the
  `populate_thread_priority_for_author` (author / twist owner) and
  `file_thread_priority_peers` (peers in `contacts`) triggers, so raw
  inserts and RPC-driven upserts both get correct filings for free.
- `thread.contacts` must include every linked contact the thread is
  authored by or shared with. `user_contact_ids(user_id)` returns every
  contact linked to the user (`linked = true`), not only the primary.
- `a.access` / `a.access_contacts` are vestigial columns kept in the
  schema for legacy readers. New code should read `a.contacts` only.

Without the `thread_priority` join + `contacts` intersection, views like
`user.priority_unread` will show unread indicators for threads the user
can't actually see.

**Exception**: Twist callback views (e.g. `twist_instance_thread_read`) are
scoped to threads the twist created — the twist has inherent visibility.

## CRITICAL: Removing Rows from Synced Tables

**Never use `DELETE` on a row that may have been synced to a Flutter client. Set `archived_at = now()` instead.**

The Flutter client pulls incrementally via `seq_since=<last_horizon>` cursors and merges rows by primary key. A bare `DELETE` is invisible to that protocol — the row simply stops being returned, and the local copy stays forever. Setting `archived_at` produces a visible row update (the seq bumps), the client receives the changed row, and per-table archive logic on the client removes it from views.

Applies to every table whose contents flow through `/sync/*` (anything readable from a `user.*` view): `thread`, `note`, `priority`, `schedule`, `link`, `twist_instance`, `group`, `group_member`, `contact`, `user_contact`, etc.

**When this rule applies:**

- Migration data fixes that remove rows
- Trigger functions that clean up after a parent change
- API handlers responding to user actions
- Cron-driven cleanup jobs

**The only safe DELETE on a synced table:** the entity itself is being removed from the schema (table dropped or renamed away). Even then, prefer landing an `archived_at` update one release before the schema change so clients reconcile cleanly. The April 2026 `topic` → `group` rename hit this exact wall — `DELETE FROM topic WHERE auto_personal_twist_user_id IS NOT NULL` followed by `ALTER TABLE topic RENAME TO "group"` left every user with a stranded "Personal Twists" group locally because no per-row sync event ever fired.

**Apparent exceptions that are not actually exceptions:**

- `ON DELETE CASCADE` on a foreign key: still synced if the child table is on a sync endpoint. Either set `archived_at` on the parent first (and let triggers cascade `archived_at` to children), or accept that the cascade will strand client copies of the child rows.
- "It's just internal bookkeeping": if the table is read by any `user.*` view, it is synced. Check.

## Handling Access Loss to Synced Entities

`archived_at` (above) handles the case where a row is *retired* but the user can still see it (e.g. user-initiated archive — reversible). A separate problem is **access loss**: the user is removed server-side from something that granted them visibility (group removal, team-leave, etc.), and the row is now *invisible* to them but their local copy must be cleaned up.

A bare DELETE on the per-user mapping row strands the client (no row in the `user.*` view → seq cursor never re-emits). Setting only `archived_at` doesn't work either: the view's visibility filter (`contacts &&`, `groups &&`, team firewall) excludes the row entirely, so even with seq advanced the view emits nothing for that user.

The pattern: separate access-loss timestamp + parallel "redacted" view + client hard-delete.

### Schema

Per-user mapping rows (e.g. `thread_priority`, future analogs) get a `revoked_at timestamptz` column distinct from `archived_at`:

- `archived_at` — user's explicit archive action. Reversible by the user.
- `revoked_at` — server-side access loss. Not reversible by the user; only by regaining access server-side (e.g. re-added to the group).

The two are independent. A row can be both archived (user dismissed it earlier) and later revoked (user lost access), or revoked without ever being archived.

### Views

Pair the main `user.*` view with a `user.*_redacted` view:

- **`user.thread`** (and analogs): add `AND tp.revoked_at IS NULL` to the WHERE clause. Add a `revoked` column hard-coded to `FALSE` so the schema shape matches across both views.
- **`user.thread_redacted`** (and analogs): same column shape; emit only rows where `tp.revoked_at IS NOT NULL`.

Redacted-view rules:

1. **Frozen identity timestamps**: `archived_at = updated_at = tp.revoked_at`. Do NOT compose `GREATEST(a.updated_at, ...)` — that would leak post-revocation update timestamps.
2. **Frozen seq**: `seq = tp.seq` only. Do NOT compose `a.seq` / `last_note_seq` / `tu.seq`. Once the client first picks up the stub, the seq doesn't advance again, so subsequent thread updates do not re-emit the stub and don't leak. This is the load-bearing leak-prevention mechanism.
3. **Sensitive fields NULL**: `title`, `preview`, `icon`, `topic`, `contacts`, `groups`, `last_note_*`, `bumped_at`, `urgency`, content. `unread=false`, `importance=0`.
4. **`revoked = TRUE`** column — the client flag for hard-delete.
5. **Keep `priority_id`** (with root fallback). The row's about to be hard-deleted client-side, but during the sync→delete window it should sit under its prior priority rather than orphan to root.

Other `user.*` views that join the per-user mapping (e.g. `user.note`, `user.link`, `user.schedule`, `user.thread_association`, `user.priority_unread`) must also add `AND tp.revoked_at IS NULL` so they stop emitting child entities after revocation. The client cascade-deletes children when it hard-deletes the revoked parent.

### Triggers

The trigger that revokes access (e.g. `file_thread_priority_on_group_member_change` DELETE branch, `team_user_archive_priorities`) sets `revoked_at = now() WHERE … AND revoked_at IS NULL`. Do NOT bare-DELETE the mapping row.

The trigger that grants access back (e.g. `file_thread_priority_on_group_member_change` INSERT branch) un-revokes via `ON CONFLICT … DO UPDATE SET revoked_at = NULL WHERE thread_priority.revoked_at IS NOT NULL`. Prior priority filing is preserved — do NOT overwrite `priority_id` / `classify_at`.

### Sync endpoint

Mirror the `/sync/notes` pattern: query both `user.thread` and `user.thread_redacted` on incremental sync, merge, sort by seq/updated_at, slice to the limit. Skip the redacted query on initial sync (epoch / seq=0) — a fresh client has nothing to reconcile.

### Client

The Flutter table gains a `revoked` bool column (default false). On sync merge, rows where `revoked = TRUE` are diverted to a hard-delete path that removes the local row **and** its dependent rows (notes, links, schedules), then are filtered out of the upsert batch. The stub never lands in archives — it can't be unarchived by the user and contains no useful data, so it doesn't belong there.

### Backwards compat

Older clients that don't know about `revoked` see the row as just `archived_at` set and put it in archives. Sub-optimal (empty archived item) but functional — the strand bug is gone.

### Don't lose this again

This pattern was originally present (`user.thread`'s "redacted-stub UNION branch") and was removed in commit `74e42ef2e` (Apr 2026) during the rewrite to per-user `thread_priority`, on the rationale that "no thread_priority row means the thread doesn't exist as far as that user is concerned." That simplification broke the access-loss cleanup path. The leading comment on `user.thread` and the trigger comments now flag this; do not re-remove the redacted view without rebuilding an equivalent cleanup path.

## CRITICAL: Bump Parent `seq` on Child-Table Changes Used by Synced Views

**When a `user.*` view's columns are computed by joining a child table to its parent, every write to the child table MUST bump the parent's `seq` (via an `UPDATE` on the parent that fires the existing `update_seq_and_updated_at` trigger).**

`/sync/*` cursors pull rows where `parent.seq >= last_horizon`. If a child-table write (e.g. adding a `group_admin` row) changes what the view returns for a parent without bumping the parent's `seq`, clients with a stamped `last_horizon` past that seq will never re-pull the parent — the view's computed columns drift permanently out of sync.

Examples in the schema:

- `group_admin` / `group_member` → `group.seq` (drives `user.group.is_admin`, `is_member`, `can_post`, `member_contact_ids`). Triggers in `schema/95-triggers/24-group_auto_maintain.sql`.
- `schedule_contact` → `schedule.updated_at` (drives `user.schedule` RSVP fields). Triggers in `schema/95-triggers/11-schedule-contact-bump.sql`.

**Pattern (statement-level so bulk writes bump each parent once):**

```sql
CREATE OR REPLACE FUNCTION bump_parent_from_new_table () RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    UPDATE parent SET updated_at = now()
    WHERE id IN (SELECT DISTINCT parent_id FROM new_table);
    RETURN NULL;
END;
$$;

CREATE TRIGGER bump_parent_on_child_insert
    AFTER INSERT ON child
    REFERENCING NEW TABLE AS new_table
    FOR EACH STATEMENT
    EXECUTE FUNCTION bump_parent_from_new_table ();

-- Symmetric old_table version for AFTER DELETE.
```

**Also bump on schema changes that add view columns.** When a migration adds a column to a `user.*` view, existing rows still have stale `seq` values. Add a one-shot `UPDATE parent SET updated_at = now();` at the end of the migration so clients re-pull and pick up the new column.

## Database Infrastructure

The local database runs as a Docker container (PostgreSQL 18.1 + pgvector) via `docker-compose.yml`. Key details:

- **Local database port**: 54322 in main repo (Docker maps 54322:5432). **Worktrees use a different port** — prefer `$DATABASE_URL` for psql commands, never hardcode 54322. The worktree port is in `.worktree-db` at the repo root. **Caveat:** `$DATABASE_URL` can be stale mid-session — see "Stale `$DATABASE_URL` after mid-session `worktree-db`" below.
- **Schema management**: Atlas handles diffing, migration generation, and migration application
- **Type generation**: Uses `@supabase/postgres-meta` as a library (via `pnpm types`)
- **Atlas config**: `atlas.hcl` defines the local environment, schema sources, and migration directory

### Stale `$DATABASE_URL` after mid-session `worktree-db`

**If `bash scripts/worktree-db` was run *after* a session started, do not trust the ambient `$DATABASE_URL`.** The script provisions Postgres on a new port and records it in `.worktree-db` (`PORT=`) and `.claude/settings.local.json` (`env.DATABASE_URL`), but a running session's environment is **not reloaded** — `$DATABASE_URL` still holds the session-start value (the main repo's `54322`). Verified symptom: `cat .worktree-db` shows `PORT="54336"` while `echo $DATABASE_URL` shows `...:54322/postgres` in the same shell.

This is silent and data-corrupting: `pnpm apply-migrations`, `gen-migration`, and `diff-schema-migrations` all read `$DATABASE_URL` from the environment, so they would target the **main repo's** database instead of the worktree's.

Either start a fresh session, or override the URL explicitly on every DB command by sourcing the port from `.worktree-db`:

```bash
source .worktree-db
DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres" pnpm apply-migrations
```

Always sanity-check the resolved port before any migration or destructive command:

```bash
psql "$DATABASE_URL" -tAc "show port;"   # must print the worktree PORT, not 54322
```

Hardcoding the worktree's actual port (from `.worktree-db`) when the ambient env is stale is correct; hardcoding `54322` is what's wrong.

## CRITICAL: When Modifying Synced Tables

**When you modify columns in `activity`, `note`, `priority`, `session`, `twist_instance`, or `activity_read` tables, you MUST update TWO additional locations:**

### 1. Database Notification Functions (`schema/60-functions/70-update.sql`)

Each synced table has a corresponding `notify_internal_api_for_<table>()` function that builds JSON payloads. When adding/removing/renaming columns:

- **For `activity` table**: Update `notify_internal_api_for_activity()`
  - Add new fields to the `jsonb_build_object()` call on line ~59 (current item)
  - Add new fields to the `jsonb_build_object()` call on line ~88 (previous item for updates)
  - Example: `'sync_depth', current_item.sync_depth,`

- **For `note` table**: Update `notify_internal_api_for_note()`
  - Add new fields to the `jsonb_build_object()` call on line ~274 (current item)
  - Add new fields to the `jsonb_build_object()` call on line ~295 (previous item for updates)
  - Example: `'key', current_item.key,`

- **For `priority` table**: Update `notify_internal_api_for_priority()`
  - Add new fields to the `jsonb_build_object()` call on line ~160
  - Example: `'sync_depth', current_item.sync_depth,`

- **For `session` table**: Update `notify_internal_api_for_session()`
  - Add new fields to the `jsonb_build_object()` call on line ~202

- **For `twist_instance` table**: Update `notify_internal_api_for_twist_instance()`
  - Add new fields to the `jsonb_build_object()` call on line ~371

- **For `activity_read` table**: Update `notify_internal_api_for_activity_read()`
  - Add new fields to the `jsonb_build_object()` call on line ~413

### 2. API Zod Schemas (`workers/api/src/types.ts`)

Update the corresponding Zod schema to match the database columns:

- **ActivityItemSchema** (line ~3): For `activity` table changes
- **NoteItemSchema** (line ~38): For `note` table changes
- **PriorityItemSchema** (line ~63): For `priority` table changes
- **SessionItemSchema** (line ~76): For `session` table changes
- **TwistInstanceItemSchema** (line ~92): For `twist_instance` table changes
- **ActivityReadItemSchema** (line ~106): For `activity_read` table changes

**Field type mapping**:
- Nullable database columns: Use `.nullable()` in Zod (NOT `.optional()`)
- Non-null database columns: Don't use `.nullable()` or `.optional()`
- Array columns: Use `z.array(...)` and add `.nullable()` if NULL is allowed
- JSONB columns: Use `z.record(z.string(), z.any())` or specific schema

**Why this matters**: The notification functions send database changes to the API, which validates them against these Zod schemas. Missing fields cause validation errors that break real-time sync.

## Available Commands

```bash
# Start the local database (Docker Compose)
pnpm start

# Stop the local database
pnpm stop

# Check if schema changes need a new migration (Atlas)
pnpm diff-schema-migrations

# Generate new EXPAND migration from schema changes (Atlas) -> migrations/
pnpm gen-migration -- <name>

# Generate a CONTRACT (destructive cleanup) migration -> migrations-contract/
# Only after the workers that stopped using the column have shipped.
pnpm gen-contract-migration -- <name>

# Apply pending migrations to LOCAL database (expand + contract dirs)
pnpm apply-migrations

# Regenerate TypeScript types from local database
pnpm types

# Check that schema files match existing migrations (run locally before commit)
pnpm diff-schema-migrations

# Check if types are out of sync (CI lint check)
pnpm lint:pending-types

# Full reset (destroys all data - requires user permission)
pnpm reset
```

## Understanding Diff Commands

### `pnpm diff-schema-migrations` (Schema Files vs Migrations)

- Uses Atlas to compare schema files with existing migration files
- **This is the source of truth** for whether you need to generate migrations
- **Should produce no changes** once all migrations have been generated
- If it shows differences, run `pnpm gen-migration -- <name>`

## Squashing Development Migrations

During development, you may generate multiple migrations while iterating on a solution. Before committing to version control and deploying to production, you should squash them into a single clean migration.

### Reset and Regenerate

```bash
# 1. Delete your development migration files (but keep schema changes)
rm migrations/20260129*_dev_*.sql

# 2. Recalculate the Atlas migration hash
atlas migrate hash --env local

# 3. Remove them from Atlas's tracking table
psql "$DATABASE_URL" -c \
  "DELETE FROM atlas_schema_revisions WHERE version IN ('20260129123456', '20260129123457')"

# 4. Generate one clean migration from your schema files
pnpm gen-migration -- complete_feature_name

# 5. Apply and test
pnpm apply-migrations
```

**Important**: Only squash migrations that haven't been deployed to production or shared with other developers. Never squash migrations that others may have already applied.

## Production Migration Safety

Migrations run in CI before workers deploy. Between "migrations applied" and "new workers deployed," the OLD worker code runs against the NEW schema. Expand migrations must therefore be backward-compatible with the currently-deployed code. Destructive cleanup is deferred to a separate **contract** directory that drains only after the relevant workers have shipped (below).

### Two migration directories

| Directory | Purpose | When applied in prod |
| --- | --- | --- |
| `migrations/` | **Expand** — additive, backward-compatible DDL. The original directory. | Before workers deploy, every deploy. |
| `migrations-contract/` | **Contract** — destructive cleanup (DROP COLUMN/TABLE, etc.). Tracked in a separate Atlas revisions schema (`atlas_contract`), so its history is independent and a pending contract never blocks a future expand. | Drained at the START of a *later* deploy, once it has soaked (see "Contract drain" below). |

When `migrations-contract/` is empty, all tooling behaves exactly as the original single-directory setup.

### Enforcement (CI gate)

The `migration-safety` job in `.github/workflows/lint.yml` runs `atlas migrate lint` on every PR against the expand migrations added since `main`. Atlas's destructive-change analyzers (the `DS*` series) **fail the build** on destructive or backward-incompatible DDL in `migrations/` — dropping a column/table, renaming, narrowing a type, adding a `NOT NULL` column without a default — because those break the OLD workers running against the NEW schema during the deploy window. An `atlas:nolint` directive (which would suppress the check) is also rejected in `migrations/`: destructive changes belong in `migrations-contract/`, not `migrations/`.

### Making a destructive change (expand/contract)

1. **Expand** (one PR): add the new column / stop reading the old one, etc. `pnpm gen-migration -- <name>` → `migrations/`. Ship it. Workers go live not using the old column.
2. **Contract** (a *later* PR, after the expand has deployed): remove the column from `schema/`, then `pnpm gen-contract-migration -- drop_old_thing` → `migrations-contract/`. `pnpm apply-migrations` applies it locally so your dev DB matches.

The contract is committed normally; you do **not** run it against prod yourself.

### Contract drain (automatic, soak-gated)

At the start of each production deploy, `libs/db/scripts/drain-contracts.sh` applies contract migrations that have **soaked** — committed before the *previous* `deploy/<timestamp>` tag, so the workers that stopped using the column have been live since that deploy. Contracts added in the current deploy's batch wait for the next deploy. This preserves a rollback window and never drops a column the currently-live workers still use. It is idempotent and a no-op when nothing has soaked.

### Safe Operations (single expand migration)

- Adding nullable columns or columns with defaults
- Adding tables, indexes, functions, triggers, views
- Adding or modifying RLS policies
- Widening column types (e.g., `int` → `bigint`)

### Requires Expand-Contract (two PRs / two deploys)

- **Renaming columns:** expand (add new column + dual-write trigger; workers read new) → contract (drop old column + trigger).
- **Changing column types (narrowing/incompatible):** expand (add new column + backfill; workers use new) → contract (drop old column).
- **Dropping columns:** expand (workers stop using the column) → contract (drop the column).

### Never in a Single Migration

- ❌ Dropping columns still referenced by running code (use `migrations-contract/`)
- ❌ Renaming columns in-place
- ❌ Changing column types in a way that breaks running queries

## Critical Rules

### NEVER Touch the Remote Database

- ❌ **NEVER**: Modify the remote/production database directly - ALL WORK IS LOCAL ONLY
- ✅ **ONLY**: Work with local database via `$DATABASE_URL` (port 54322 in main repo, different port in worktrees — check `.worktree-db`; verify with `psql "$DATABASE_URL" -tAc "show port;"` since the env can be stale after a mid-session `worktree-db`)

### Local Database Rules

- ✅ **DO**: Modify schema files, generate migrations with Atlas, apply with Atlas
- ✅ **DO**: Fix failed migrations by editing the migration file and re-running `pnpm apply-migrations`
- ✅ **DO**: Create multiple migrations for iterative changes
- ✅ **DO**: Add data migrations to generated migration files when needed
- ✅ **DO**: Regenerate types after schema changes
- ✅ **DO**: Prefer `$DATABASE_URL` for psql commands — never hardcode port 54322 (worktrees use different ports). If `worktree-db` ran mid-session, `$DATABASE_URL` may be stale — override it from `.worktree-db` (see "Stale `$DATABASE_URL` after mid-session `worktree-db`")

- ❌ **NEVER**: Create migration files manually
- ❌ **NEVER**: Edit migration files after they've been successfully applied
- ❌ **NEVER**: Do a database reset (`pnpm reset`) without explicit user permission
- ❌ **NEVER**: Edit `src/types.ts` directly (always regenerate with `pnpm types`)

## Why Migrations Matter

- **Version control**: Complete history of schema evolution
- **Transactions**: Failed migrations rollback completely, no partial state
- **Reproducibility**: Same migrations work across all environments
- **Collaboration**: Team sees exactly what changed and when
- **Safety**: Iterative development with rollback protection

## Database Reset

**NEVER do a database reset without explicit user permission.**

`pnpm reset` destroys all local data and should only be used in exceptional circumstances. In normal development:
- Use migrations for schema changes
- Fix failed migrations by editing and re-running
- Multiple migrations for iterative changes is normal and expected
