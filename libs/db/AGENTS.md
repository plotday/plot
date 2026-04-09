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
   - Example: `pnpm gen-migration -- add_activity_order_column`

3. **Add data migrations if needed (optional)**
   - Open the generated migration file
   - Add SQL for data transformations after the schema changes
   - Example: `UPDATE activity SET order_value = created_at;`
   - Keep data migrations minimal and focused

4. **Apply migration to LOCAL database**
   ```bash
   pnpm apply-migrations
   ```
   - Uses Atlas to apply all pending migrations to the LOCAL database (localhost:54322)
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

Any view or query that joins `thread_unread` to determine what a user can see must enforce thread visibility. The canonical reference is the `user.thread` view. Required filters when joining thread (aliased as `a`) with `thread_unread`:

```sql
AND a.archived_at IS NULL
AND (a.draft = FALSE OR a.created_by = user_id)
AND (a.private = FALSE OR a.created_by = user_id
     OR "user".mentioned_in_thread(user_id, a.id))
```

Without these, views like `user.priority_unread` will show false unread indicators for threads the user can't actually see (private threads from other users, archived threads, other users' drafts).

**Exception**: Twist callback views (e.g. `priority_twist_thread_read`) are scoped to threads the twist created — the twist has inherent visibility.

## Database Infrastructure

The local database runs as a Docker container (PostgreSQL 18.1 + pgvector) via `docker-compose.yml`. Key details:

- **Local database port**: 54322 (Docker maps 54322:5432)
- **Schema management**: Atlas handles diffing, migration generation, and migration application
- **Type generation**: Uses `@supabase/postgres-meta` as a library (via `pnpm types`)
- **Atlas config**: `atlas.hcl` defines the local environment, schema sources, and migration directory

## Available Commands

```bash
# Start the local database (Docker Compose)
pnpm start

# Stop the local database
pnpm stop

# Check if schema changes need a new migration (Atlas)
pnpm diff-schema-migrations

# Generate new migration from schema changes (Atlas)
pnpm gen-migration -- <name>

# Apply pending migrations to LOCAL database (Atlas)
pnpm apply-migrations

# Regenerate TypeScript types from local database
pnpm types

# Check for unapplied migrations (CI lint check)
pnpm lint:pending-migrations

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
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -c \
  "DELETE FROM atlas_schema_revisions WHERE version IN ('20260129123456', '20260129123457')"

# 4. Generate one clean migration from your schema files
pnpm gen-migration -- complete_feature_name

# 5. Apply and test
pnpm apply-migrations
```

**Important**: Only squash migrations that haven't been deployed to production or shared with other developers. Never squash migrations that others may have already applied.

## Production Migration Safety

Migrations run in CI before workers deploy. Between "migrations applied" and "new workers deployed," the OLD worker code runs against the NEW schema. Migrations must be backward-compatible with the currently-deployed code.

### Safe Operations (single migration)

- Adding nullable columns or columns with defaults
- Adding tables, indexes, functions, triggers, views
- Adding or modifying RLS policies
- Widening column types (e.g., `int` → `bigint`)

### Requires Two-Phase Expand-Contract

**Renaming columns:**
1. Migration 1: Add new column + dual-write trigger
2. Deploy workers that read from new column
3. Migration 2: Drop old column and trigger

**Changing column types (narrowing or incompatible):**
1. Migration 1: Add new column with new type + backfill trigger
2. Deploy workers that use new column
3. Migration 2: Drop old column and trigger

**Dropping columns:**
1. Deploy workers that stop using the column
2. Migration: Drop the column

### Never in a Single Migration

- ❌ Dropping columns still referenced by running code
- ❌ Renaming columns in-place
- ❌ Changing column types in a way that breaks running queries

## Critical Rules

### NEVER Touch the Remote Database

- ❌ **NEVER**: Modify the remote/production database directly - ALL WORK IS LOCAL ONLY
- ✅ **ONLY**: Work with local database at localhost:54322

### Local Database Rules

- ✅ **DO**: Modify schema files, generate migrations with Atlas, apply with Atlas
- ✅ **DO**: Fix failed migrations by editing the migration file and re-running `pnpm apply-migrations`
- ✅ **DO**: Create multiple migrations for iterative changes
- ✅ **DO**: Add data migrations to generated migration files when needed
- ✅ **DO**: Regenerate types after schema changes
- ✅ **DO**: Always verify you're targeting localhost:54322

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
