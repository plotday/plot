# Plot Database

## Schema Change Workflow

**CRITICAL: Always follow this exact process for schema changes. No exceptions.**

### Step-by-Step Process

1. **Modify schema files in `schema/` directory**
   - Schema files are the single source of truth for database structure
   - Organize by type: `50-tables/`, `60-views/`, `70-rls/`, `80-triggers/`, etc.
   - NEVER modify migration files or the database directly

2. **Generate migration**
   ```bash
   pnpm gen-migration <descriptive_name>
   ```
   - Compares schema with existing migrations
   - Creates timestamped migration in `supabase/migrations/`
   - Example: `pnpm gen-migration add_activity_order_column`

3. **Add data migrations if needed (optional)**
   - Open the generated migration file
   - Add SQL for data transformations after the schema changes
   - Example: `UPDATE activity SET order_value = created_at;`
   - Keep data migrations minimal and focused

4. **Apply migration to LOCAL database**
   ```bash
   psql postgresql://postgres:postgres@localhost:54322/postgres < supabase/migrations/YOUR_MIGRATION.sql
   ```
   - This applies the migration to the LOCAL database only (localhost:54322)
   - Automatically wrapped in a transaction by PostgreSQL
   - If migration fails, transaction rolls back - no partial state
   - Fix the migration file and re-run the psql command

5. **Handle migration failures**
   - If a migration fails, the database state is unchanged (transaction rollback)
   - Edit the migration file to fix the issue
   - Re-run: `psql postgresql://postgres:postgres@localhost:54322/postgres < supabase/migrations/YOUR_MIGRATION.sql`
   - Repeat until successful

6. **Make additional schema changes (if needed)**
   - Modify schema files again
   - Generate a new migration: `pnpm gen-migration <another_name>`
   - Apply it with psql: `psql postgresql://postgres:postgres@localhost:54322/postgres < supabase/migrations/NEW_MIGRATION.sql`
   - This is normal - iterative changes use multiple migrations

7. **Verify schema sync**
   ```bash
   pnpm diff-schema-db
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
- **All tables must have RLS enabled** - Tables not synced to the app should have no RLS rules (keeping them private)
- **Primary keys**:
  - Default: `bigint` primary keys for server-created rows
  - UUID primary keys for rows created on the client
- **Migrations are generated** - Never create migration files manually
- **Function directory organization**:
  - Functions in `40-functions/` are loaded before tables in `50-tables/`
  - Functions that reference tables must be in `50-functions/` or later (e.g., `65-functions/`)
  - If you get "relation does not exist" errors during migration generation, move the function to a later directory

## CRITICAL: When Modifying Synced Tables

**When you modify columns in `activity`, `note`, `priority`, `session`, `priority_twist`, or `activity_read` tables, you MUST update TWO additional locations:**

### 1. Database Notification Functions (`schema/30-functions/70-update.sql`)

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

- **For `priority_twist` table**: Update `notify_internal_api_for_priority_twist()`
  - Add new fields to the `jsonb_build_object()` call on line ~371

- **For `activity_read` table**: Update `notify_internal_api_for_activity_read()`
  - Add new fields to the `jsonb_build_object()` call on line ~413

### 2. API Zod Schemas (`workers/api/src/types.ts`)

Update the corresponding Zod schema to match the database columns:

- **ActivityItemSchema** (line ~3): For `activity` table changes
- **NoteItemSchema** (line ~38): For `note` table changes
- **PriorityItemSchema** (line ~63): For `priority` table changes
- **SessionItemSchema** (line ~76): For `session` table changes
- **PriorityTwistItemSchema** (line ~92): For `priority_twist` table changes
- **ActivityReadItemSchema** (line ~106): For `activity_read` table changes

**Field type mapping**:
- Nullable database columns: Use `.nullable()` in Zod (NOT `.optional()`)
- Non-null database columns: Don't use `.nullable()` or `.optional()`
- Array columns: Use `z.array(...)` and add `.nullable()` if NULL is allowed
- JSONB columns: Use `z.record(z.string(), z.any())` or specific schema

**Why this matters**: The notification functions send database changes to the API, which validates them against these Zod schemas. Missing fields cause validation errors that break real-time sync.

## Available Commands

```bash
# View difference between schema and local database
pnpm diff-schema-db

# Generate new migration from schema changes
pnpm gen-migration <name>

# Apply a migration to LOCAL database (uses transactions)
psql postgresql://postgres:postgres@localhost:54322/postgres < supabase/migrations/MIGRATION_FILE.sql

# Regenerate TypeScript types from local database
pnpm types

# Check for unapplied migrations (CI lint check)
pnpm lint:pending-migrations

# Check if types are out of sync (CI lint check)
pnpm lint:pending-types
```

## Understanding Diff Commands

### `pnpm diff-schema-db` (Schema vs Database)

- Compares schema files with the running local database
- **Often shows false-positive function changes** even when already applied
- If a function or extension already exists in migration files, **ignore it** in the diff output
- Use this for general awareness, but don't trust it completely
- The migration generator is smarter about filtering out already-applied changes

### `pnpm diff-schema-migrations` (Schema vs Migrations)

- Compares schema files with existing migration files
- **This is the source of truth** for whether you need to generate migrations
- **Should return EMPTY** once all migrations have been generated
- If it shows differences, run `pnpm gen-migration <name>`
- **Formatting is critical**:
  - Function definitions must match the diff output formatting exactly
  - If the diff shows only formatting differences, update the schema file to match
  - Match indentation, spacing, and line breaks from the diff output
  - This ensures the diff returns empty when everything is truly in sync

## Critical Rules

### NEVER Touch the Remote Database

- ❌ **NEVER**: Push to remote database with `supabase db push --linked` or any `--linked` command
- ❌ **NEVER**: Reset remote database with `supabase db reset --linked`
- ❌ **NEVER**: Modify remote database in any way - ALL WORK IS LOCAL ONLY
- ❌ **NEVER**: Use the `--linked` flag with any Supabase command
- ✅ **ONLY**: Work with local database at localhost:54322

### Local Database Rules

- ✅ **DO**: Modify schema files, generate migrations, apply with psql
- ✅ **DO**: Fix failed migrations by editing the migration file and re-running psql
- ✅ **DO**: Create multiple migrations for iterative changes
- ✅ **DO**: Add data migrations to generated migration files when needed
- ✅ **DO**: Regenerate types after schema changes
- ✅ **DO**: Always verify you're targeting localhost:54322

- ❌ **NEVER**: Create migration files manually
- ❌ **NEVER**: Modify the database directly with `apply-schema` (emergency only)
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
