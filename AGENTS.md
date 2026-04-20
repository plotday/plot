# Plot Project Guidelines

## Overview

Plot is multi-platform app with tasks, messages, and links to documents from all your apps, organized and prioritized. When you choose a focus, you have the context and actions you need to make progress on what matters.

Supported platforms:

- Web
- Desktop: macOS, Windows
- Mobile: Android, iOS

## Definitions

- Thread: A single item in Plot, containing notes. A thread might be just notes, or it might be an event or action (task). (Previously called "activity".)
- Note: Content associated with a thread, such as Markdown notes and links.
- Priority: Similar to a project or folder for threads. Priorities are nested using paths, and display all threads related to them and their descendants.
- Twist: The Plot version of an extension/plugin/app/agent. Users install them at the workspace level, where they operate across the user's priorities. They tend to implement opinionated workflows (e.g. create tasks from emails).
- Connection: One source system (e.g. Google Calendar) paired with one account (e.g. <kris@plot.day>). Connections are provided by connectors that expose channels that users can enable/disable.
- Twist Creator aka Twister: The SDK for building twists and connectors. Sometimes represented with 🌪️.
- RSVP: A user's response to a scheduled event (`attend`, `skip`, or unset). RSVPs are stored exclusively as `schedule_contact` rows keyed on `(schedule_id, contact_id)`. Connectors populate them from synced attendee data; users update their own via POST `/sync/schedule/status`. The Flutter app derives all RSVP UI from `schedule_contact` and never reads or writes count tags for RSVP. A single human user may have multiple `schedule_contact` rows on the same schedule when more than one of their linked contacts (e.g. work + personal email) was invited.
- Count Tag Ownership: Count tags can only be added/removed by the user themselves. Users cannot modify count tags for other actors. "The user themselves" means any non-archived contact linked to the user, not only their primary contact. This is enforced by database trigger functions (`update_thread_tags`, `upsert_thread_tag`, `upsert_note_tag`) via `user.user_contact_ids()` and validated in the Flutter app.

## Data

The app is local-first, so it can function without an internet connection while syncing when one is available.
Local storage uses the Drift package (which uses SQLite), with entities defined in "apps/plot/libs/store/".
Data is synchronized to a remote PostgreSQL database for backup, multi-device sync, and collaboration.
The database schema is defined in "libs/db/schema/".
The local development database runs as a Docker container (PostgreSQL 18.1) on port 54322 by default. **Worktrees use a different port** — see "Worktree Development" below.
Atlas is used for schema diffing and migration management. Type generation uses `@supabase/postgres-meta` as a library (via `pnpm types`).

## Code Structure

- This is a private monorepo containing:
  - The main app, written in Flutter, is in "apps/plot/".
  - All other packages are written in Typescript and use pnpm for package management.
  - The website (mostly marketing, plus some Twist management) is in "apps/site/".
  - APIs and server tasks are implemented using Cloudflare Workers, located in "workers/".
    - The API also implements the twist runtime including built-in tools.
  - Non-open-source twists and connectors are in "twists/".
- There is a public monorepo mounted as a git submodule at `public/` containing:
  - The Plot Twist Creator aka Twister is at `public/twister/`. It's the SDK for building twists and connectors, but with a name that's friendly for non-developers.
    - Twister includes all type definitions for building twists and connectors, including type definitions for built-in tools (which are implemented in the api).
    - The CLI is also in the twister package.
  - Public connectors at `public/connectors/`.
  - Public twists at `public/twists/`.

## Twister Entity Standards

For all entities in Twister (Activity, Priority, etc.), use the following type pattern:

- **Required fields**: Defined without `?` and cannot be `undefined`
- **Nullable fields**: Use `| null` instead of `| undefined` or optional (`?`)
- **New entity types**: Only required fields should be mandatory, all others should be `Partial<>` to support partial updates

Example:

```typescript
export type Activity = {
  id: string; // Required
  type: ActivityType; // Required
  title: string | null; // Nullable (not optional)
  start: Date | string | null; // Nullable (not optional)
};

// type is required, all other fields are optional
export type NewActivity = Pick<Activity, "type"> &
  Partial<Omit<Activity, "id" | "type">>;
```

This pattern allows functions to distinguish between:

- Omitted fields (undefined in Partial types)
- Explicitly set to null (clearing a value)
- Set to a value

## Twist Creator Development

The Twist Creator package (`public/twister/`) contains all type definitions and is the single source of truth for twist and connector types. This repo uses it via pnpm workspace links.

### Creator Location and Structure

- **Creator Package**: `public/twister/` (inside the `public/` git submodule)
- **Type Definitions**: `public/twister/src/` (twist.ts, connector.ts, plot.ts, tag.ts, tools/\*.ts, common/\*.ts)
- **Workspace Link**: Configured in `pnpm-workspace.yaml` as `public/twister`
- **Import Pattern**: Use `@plotday/twister`, `@plotday/twister/plot`, `@plotday/twister/tools/*`, etc.

### Making Changes to SDK Types

**IMPORTANT**: Twister types must be modified in the Twister package, never in this repo's main code.

1. **Edit Twister files**: Make changes in `public/twister/src/`
2. **Rebuild Twister**: Run `pnpm build` in `public/twister`
3. **Test locally**: Changes are immediately available via workspace link
4. **Verify builds**: Run `pnpm lint` in affected packages (workers/api, twists/\*)

### Adding New Twister Exports

When adding new top-level type files to Twister, update `public/twister/package.json` exports:

```json
{
  "exports": {
    "./your-new-file": {
      "types": "./dist/your-new-file.d.ts",
      "default": "./dist/your-new-file.js"
    }
  }
}
```

Then rebuild Twister and run `pnpm install` in this repo to update the workspace link.

### Publishing Twister Updates

Only publish after testing locally:

1. Update version in `public/twister/package.json`
2. Build: `cd public/twister && pnpm build`
3. Publish: `npm publish` (from `public/twister` directory)
4. Commit changes in the `public/` submodule, then commit the submodule reference update in this repo

### Changesets

**IMPORTANT**: Any change to Twister files in `public/twister/src/` MUST include a changeset file. Never skip this step.

1. **Create a changeset file** at `public/.changeset/<descriptive-name>.md` with this exact format:

   ```markdown
   ---
   "@plotday/twister": minor
   ---

   Added: description of what changed
   ```

2. **Version bump rules** (Twister is pre-1.0, so `major` is reserved for the 1.0 release):

   - `minor`: Breaking changes OR new features (removing/renaming exports, changing function signatures, adding types/fields/exports)
   - `patch`: Bug fixes, documentation, internal changes

3. **Summary format**: The first line after the frontmatter MUST start with a category prefix:

   - `Added:` — new features or exports
   - `Changed:` — modifications to existing behavior
   - `Fixed:` — bug fixes
   - `Removed:` — removed features or exports
   - `Deprecated:` — features marked for removal
   - `Security:` — security-related changes

4. **Validate** your changeset: `cd public && pnpm validate-changesets`

### Important Notes

- **TypeScript Configuration**: Uses `moduleResolution: "bundler"` in `libs/tsconfig/base.json` to support Twister package exports
- **Workspace Dependencies**: API and twists use `"@plotday/twister": "workspace:*"` for local development

## Twists and Connectors

### Where things live

- **Twist runtime**: `workers/api/src/twist/` — the API worker hosts the twist runtime and dispatches twist/connector callbacks.
- **Built-in tools**: `workers/api/src/twist/tools/*.ts` — classes like `Plot`, `Integrations`, `Store`, `Network`, `Tasks`, `Callbacks`, `AI`. They all `extend Tool` (from `@plotday/twister`) and have privileged access to API worker internals (database, services). Twists and connectors consume them via `this.tools.<name>`.
- **Public connectors**: `public/connectors/*` — open-source packages that each implement one type of connection (e.g. Google Calendar, Linear, Slack). They extend the `Connector` base class from `@plotday/twister`, save data via `integrations.saveLink()`, and run in isolation inside the twist runtime with access only to the tools they declare in `build()`.
- **Public twists**: `public/twists/*` — open-source twists (orchestrators users install into a priority).
- **Private twists/connectors**: `twists/*` — non-open-source packages that follow the same conventions as the public ones.

**Terminology reminder**: "**connection**" is the user-facing term (a connected Google Calendar account, etc.); "**connector**" refers to the package that provides that type of connection.

### Development guidance

Full guidance for building twists and connectors lives in the `public/` submodule and is the source of truth. When working on anything that extends `Twist` or `Connector`, start there:

- **Navigation**: `public/AGENTS.md`
- **Connector dev guide** (scaffold, patterns, checklist, pitfalls): `public/connectors/AGENTS.md`
- **Twist template**: `public/twister/cli/templates/AGENTS.template.md`
- **Runtime limits** (request budget, batching with `runTask()`, state via `this.set`/`this.get`): `public/twister/docs/RUNTIME.md`
- **Built-in tools reference** (including the `this.callback(this.method, ...)` / `this.run()` / `this.deleteCallback()` API and version-upgrade rules): `public/twister/docs/TOOLS_GUIDE.md`
- **Multi-user auth** (private auth activities, per-user write-back fallback): `public/twister/docs/MULTI_USER_AUTH.md`
- **Sync strategies** (upsert via `source`/`key`, `initialSync` flag propagation, cross-connector Google auth sharing): `public/twister/docs/SYNC_STRATEGIES.md` and `public/connectors/AGENTS.md`

Do not duplicate that content back into this file — the submodule is kept in sync with the `@plotday/twister` package that every twist and connector imports.

## Database Schema Changes

**CRITICAL: Follow this exact process for ALL schema changes. Never skip steps or use shortcuts.**

### The Correct Schema Change Workflow

1. **Make schema changes in `libs/db/schema/` files ONLY**

   - The schema files are the source of truth
   - Organize changes in the appropriate subdirectories (40-functions, 50-tables, 60-functions, 70-views, 90-user-schema, 95-triggers, 99-data, etc.)
   - Never modify migration files directly or create migrations manually

2. **Generate a migration**

   ```bash
   pnpm gen-migration -- <descriptive_migration_name>
   ```

   - This uses Atlas to compare schema files with existing migrations and generates a new timestamped migration file
   - The migration will be created in `libs/db/migrations/`
   - **IMPORTANT**: If you manually create or edit a migration file in `libs/db/migrations/`, you MUST run `atlas migrate hash --dir file://libs/db/migrations` to update the `atlas.sum` checksum file. Failing to do this will cause CI/CD failures.

3. **Add data migrations if needed (optional)**

   - If you need to migrate existing data (not schema), add SQL to the generated migration file
   - Example: UPDATE statements to populate new columns, data transformations, etc.
   - Keep data migrations separate from schema changes when possible

4. **Apply migrations to the LOCAL database**

   ```bash
   pnpm apply-migrations
   ```

   - This uses Atlas to apply all pending migrations to the LOCAL database (uses `$DATABASE_URL`)
   - Atlas tracks applied migrations in its `atlas_schema_revisions` table
   - You can modify the migration file and re-run until it succeeds

5. **If migration fails or you need more schema changes**

   - Fix the migration file or make additional schema changes
   - Generate another migration: `pnpm gen-migration -- <another_descriptive_name>`
   - Apply it: `pnpm apply-migrations`
   - Repeat as needed

6. **Verify the changes**

   ```bash
   # Check that schema files match existing migrations
   pnpm diff-schema-migrations

   # Should return no differences if everything is generated correctly
   ```

### Available Database Commands

```bash
# Start the local database (Docker Compose)
pnpm --filter @plotday/db start

# Stop the local database
pnpm --filter @plotday/db stop

# Generate a new migration from schema changes (Atlas)
pnpm gen-migration -- <name>

# Apply all pending migrations to LOCAL database (Atlas)
pnpm apply-migrations

# Check that schema files match existing migrations (Atlas)
pnpm diff-schema-migrations

# Check for pending migrations (used in CI)
pnpm --filter @plotday/db lint:pending-migrations

# Regenerate TypeScript types from local database
pnpm types

# Full reset (destroys all data - requires user permission)
pnpm reset
```

### Verifying Schema and Migrations Are In Sync

**`pnpm diff-schema-migrations`**

- Uses Atlas to compare schema files with existing migration files
- **Should produce no changes** once all migrations have been generated
- If it shows differences, you have unapplied schema changes that need a new migration
- This is the source of truth for whether migrations are complete

### Critical Rules

#### NEVER Touch the Remote Database

- **NEVER modify remote database** - All work is LOCAL ONLY
- **ONLY work with local database** - Always use `$DATABASE_URL` (port 54322 in main repo, different port in worktrees — see "Worktree Database Port")

#### Local Database Rules

- **NEVER do a database reset** (`pnpm reset`) without explicit user permission - it destroys all local data
- **NEVER modify migration files** after they've been applied - create a new migration instead
- **NEVER create migrations manually** - always generate them with `pnpm gen-migration`
- **ALWAYS generate types** after schema changes: `pnpm types`
- **ALWAYS use `$DATABASE_URL`** for psql commands — never hardcode a port number

## Development Webhooks with Cloudflare Tunnel

For testing webhooks from external services (Slack, Gmail, etc.) during local development, you can expose your local API worker via a Cloudflare Tunnel.

### Quick Start

**1. One-time setup:**

```bash
pnpm tunnel:setup
cloudflared tunnel route dns plot-dev api-kris.plot.day
```

**2. Start development with webhooks:**

```bash
# Terminal 1: API worker
pnpm --filter @plotday/api dev

# Terminal 2: Tunnel
pnpm tunnel:start
```

**3. Configure external services:**

Use `https://api-kris.plot.day` as the webhook URL in your external service configuration. Webhooks will route to your local API (localhost:8787).

**4. Stop tunnel when done:**

```bash
pnpm tunnel:stop
```

### Webhook URLs

When the tunnel is active, use these public URLs:

- **Slack**: `https://api-kris.plot.day/hook/slack`
- **Gmail**: `https://api-kris.plot.day/hook/gmail/:topicId`
- **Generic callbacks**: `https://api-kris.plot.day/hook/:token`

### Available Commands

- `pnpm tunnel:setup` - Create tunnel and generate config (one-time)
- `pnpm tunnel:start` - Start tunnel in background
- `pnpm tunnel:stop` - Stop background tunnel
- `pnpm tunnel:status` - Check if tunnel is running
- `pnpm tunnel` - Start tunnel in foreground (blocks terminal)

### Troubleshooting

- Check tunnel status: `pnpm tunnel:status` and `tail -f .tunnel.log`
- Ensure API worker is running: `pnpm --filter @plotday/api dev`
- For signature verification issues, check `.dev.vars` has correct webhook secrets

## Worktree Development

Worktrees are automatically set up via WorktreeCreate/WorktreeRemove hooks in
`.claude/settings.json`. The hooks handle: git worktree creation, submodule init,
env file copying, and pnpm install. Submodule init uses `--reference` to borrow
objects from the main repo's local `public/` directory, so worktrees work even
when the submodule has unpushed local commits.

### Worktree Database Port

**CRITICAL: Worktrees do NOT use port 54322.** Each worktree gets its own isolated PostgreSQL instance on a unique port. The port is stored in `.worktree-db` at the repo root and in `$DATABASE_URL` (set in `.claude/settings.local.json`).

**Never hardcode port 54322 in a worktree.** Always use `$DATABASE_URL` or read the port from `.worktree-db`:

```bash
# Correct: use $DATABASE_URL (set automatically by worktree-db script)
psql "$DATABASE_URL" -c "SELECT ..."

# Correct: read port from .worktree-db
source .worktree-db && psql "postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres" -c "SELECT ..."

# WRONG: hardcoding 54322 connects to the MAIN repo's database, not this worktree's
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -c "SELECT ..."
```

If `.worktree-db` does not exist, the worktree database hasn't been set up yet — run `bash scripts/worktree-db` first.

### Conditional Setup (run when needed)

**Submodule changes** (modifying `public/` — twister types, connectors, twists):

```bash
cd public && git checkout -b <branch-name>
cd twister && pnpm build && cd ../..
pnpm install
```

**Database schema changes:**

```bash
bash scripts/worktree-db
```

This starts an isolated PostgreSQL on a unique port with migrations applied.

**Flutter app development:**

```bash
cd apps/plot && flutter pub run build_runner build --delete-conflicting-outputs
```

### Manual env copy (outside worktree hooks)

```bash
pnpm cp-env /path/to/main/repo
```

## Change Finalization

Before committing or declaring any code change complete, run `/finalize` to execute the finalization checklist. This is mandatory for all changes and covers:

1. **Lint**: Run `pnpm lint` in changed packages or repo-wide. All errors must be fixed.
2. **Backwards compatibility**: Verify old clients work with new APIs. No removed/renamed fields without migration paths.
3. **Error capture**: All new `catch` blocks for unexpected errors must call `captureException` (PostHog).
4. **Documentation**: Notable user-facing changes go in `docs/updates.md`. Major new functionality also updates `docs/features.md`.
5. **Public submodule**: Changes in `public/` need a separate PR. Twister SDK changes require a changeset.

## Thread Visibility Rules

**CRITICAL: Any query on `thread_unread` or `thread` that determines what a user can see or what triggers notifications MUST enforce thread visibility filters.**

The `user.thread` view is the canonical reference for visibility logic. In the per-user priority model visibility is driven by `thread_priority` (who filed the thread where) plus membership in `thread.contacts` OR `thread.groups`.

```sql
-- Required visibility filters when joining thread_unread with thread:
JOIN public.thread_priority tp ON tp.thread_id = t.id
LEFT JOIN public.thread_unread tu
    ON tu.user_id = tp.user_id AND tu.thread_id = t.id
WHERE t.archived_at IS NULL                             -- exclude archived threads
  AND (t.draft = false OR t.created_by = tp.user_id)    -- only own drafts
  AND (                                                 -- access via contacts OR groups
    t.contacts && "user".user_contact_ids(tp.user_id)
    OR t.groups && "user".user_group_ids(tp.user_id)
  )
```

- Always use the contacts-OR-groups pair. A contacts-only filter silently drops threads the user can see only through group membership (e.g. team-wide feedback threads), which suppresses unread indicators and push/email notifications.
- `thread_priority` is populated automatically by the
  `populate_thread_priority_for_author`, `file_thread_priority_peers`,
  and `file_thread_priority_for_group_members` triggers, so raw inserts
  and RPC-driven upserts both get correct filings. Callers do not need
  to write `thread_priority` directly.
- `thread.contacts` must include every linked contact the thread is
  authored by or shared with. `thread.groups` lists every group the
  thread was sent to.
- `user.user_contact_ids(user_id)` returns every contact linked to the
  user (not only the primary). `user.user_group_ids(user_id)` returns
  every group the user belongs to via any of those contacts.
- `thread.access` and `thread.access_contacts` are vestigial — kept in
  the schema for Flutter backwards compatibility but **no longer
  consulted** by visibility logic. New code should read `thread.contacts`
  and `thread.groups` only.

### When these filters are required

- **Notification queries**: Any query that decides whether to send a push notification or what content to show in a notification. Without these filters, invisible threads (private threads from other users, archived threads) will generate phantom notifications.
- **Unread indicators**: Views/queries that compute whether a priority has unread threads (e.g. `user.priority_unread`). Without these filters, the unread dot shows on priorities where the user has no visible unread threads.
- **Thread listing/counting**: Any query that lists or counts threads for a specific user outside of the `user.thread` view.

### When these filters are NOT required

- **Twist/connector callbacks**: Views like `priority_twist_thread_read` are scoped to threads the twist itself created (`a.created_by = pt.id`). The twist has inherent visibility into its own threads.
- **Admin/system queries**: Internal operations that don't surface results to users.
- **RPC functions with access control**: Functions that call `assert_priority_access()` before querying.

## Plot App URLs

The app uses base58-encoded UUIDs in URLs. URL formats:

- **Priority**: `/p/{priority_base58}` (e.g. `https://app.plot.day/p/CXH9QUq4zFmvTopn1i8Xv`)
- **Thread**: `/t/{thread_base58}` (globally shareable, e.g. `https://app.plot.day/t/2kF8...`)
- **Dev**: `http://localhost:8788/p/{priority_base58}` or `http://localhost:8788/t/{thread_base58}`
- **Legacy**: `/{priority_base58}/{thread_base58?}` is translated client-side to `/p/` or `/t/` on open

### Decoding base58 to UUID

Base58 alphabet: `123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz`

Decode a segment to a UUID:

```bash
python3 -c "
A='123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
s='CXH9QUq4zFmvTopn1i8Xv'; n=0
for c in s: n=n*58+A.index(c)
h=format(n,'032x'); print(f'{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:]}')
"
```

### Existing implementations

- **Dart** (decode + encode): `apps/plot/lib/util/uuid.dart` — `Uuid.fromShortString()` / `toShortString()`
- **TypeScript** (encode only): `workers/api/src/state/email-notify.ts` — `uuidToBase58()`

### Looking up decoded IDs

Once decoded, query the database:

- **Local DB**: `psql "$DATABASE_URL" -c "SELECT id, title FROM priority WHERE id = '<uuid>'"` (see "Worktree Database Port" for how the URL is set)
- **Prod DB**: Use the `prod-db-investigate` skill (psql on port 5433)

## Connector Icon Guidelines

When adding or updating connector logos in `apps/site/app/data/connections.ts`:

### Logo Source Priority

1. **`logos/{name}-icon`** from Iconify -- preferred for multicolor icons that work at small sizes (check aspect ratio is near 1:1)
2. **`si()` helper** with `simple-icons/{name}` -- for monochrome icon marks. Provide brand color for light mode and a lighter/white variant for dark mode
3. **Local SVG** in `apps/site/public/assets/` -- when Iconify options are wordmarks or don't exist

### Choosing the Right Logo

- **Always verify the SVG** before using it. Fetch the URL and check:
  - **Aspect ratio**: must be close to 1:1 (max ~1.5:1). Wide wordmarks (text logos) are unacceptable at 40x40px display size
  - **Content**: must be an icon/mark, not rendered text. Some `simple-icons` entries render brand names as text (e.g. `caldotcom`, `gusto`, `typeform`)
  - **Dark mode**: must be visible on dark backgrounds. Test both `logo` and `logoDark` values
- **Iconify `logos/` collection**: Many entries are wordmarks. Always check for a `-icon` variant first (e.g. `logos/gitlab-icon` instead of `logos/gitlab`)
- **Iconify `simple-icons/` collection**: Most are true icon marks, but some render as text wordmarks. Verify the SVG content before using
- Quick check: fetch the SVG and look at the `width` attribute. If `width` is more than ~1.5em, it's likely a wordmark

### Dark Mode Colors

- When using `si()`, the dark color must have sufficient contrast on dark backgrounds (~#1a1a2e)
- Medium blues like #2B88D8 can be hard to see -- prefer brighter variants (#47A5ED) or white (#ffffff)
- Multicolor icons from `logos/` that include their own background (like Apple Calendar, Google Calendar) typically don't need a separate dark variant

### Local SVG Conventions

- Named: `logo-{service}.svg` and `logo-{service}-dark.svg`
- Use a compact viewBox (e.g. `0 0 32 32`)
- Simple path-based SVGs with brand colors
- Dark variants use `#ffffff` fills (or inverted color scheme)
- Remove unnecessary SVG metadata (Adobe/Inkscape attributes, XML declarations)
- Source paths from official brand/press kits when available

## Hints

- If you get the Typescript error "TS2589: Type instantiation is excessively deep and possibly infinite.", simply add @ts-ignore with a comment above the line causing the error.
- Only work locally. Never deploy. This includes workers, which only run locally.
- When creating Cloudflare Durable Objects via idFromName(), ctx.id.name IS NOT SET inside the DO. If the DO needs the name (often the priorityTwistId), you MUST add a separate init() method to the DO and ensure it's called after creation to set the name.
- In TypeScript, use static imports at the top of the file wherever possible. DO NOT insert dynamic import('filename') unless absolutely necessary to resolve a circular dependency.
- **When adding new features**, update `docs/features.md` to reflect the new capabilities for marketing content generation.
- **When completing user-facing changes** (new features, UX improvements, notable bug fixes), add a brief bullet point to the top section of `docs/updates.md`. Write in plain language users would understand — no technical jargon or internal details. Skip internal refactors, infra changes, and minor fixes users wouldn't notice. When the user publishes an update, add `---` below the current section to archive it and start fresh above.
- **Never ignore database errors** in the API. Use `safeQuery()` from `@plotday/db` which throws a `DbError` if the query fails. Never use fire-and-forget patterns like `await supabase.from(...).insert(...)` without checking the result.
- **Report unexpected errors to PostHog error tracking.** Any catch block handling an unexpected error must call `captureException`. In the Flutter app, use `Tracker.captureException(error, stackTrace)`. In TypeScript workers, use `tracker.captureException(error)` (or `postHog.captureException(error, distinctId)` when no tracker is available). Do NOT report expected/handled errors like network timeouts, auth failures the user will see, or validation errors — only unexpected failures that indicate bugs or system issues.
- **`withUserDb` already opens a transaction.** Its callback receives a `Kysely<DB>` handle that is the transaction — use it directly (e.g. `sql\`...\`.execute(trx)` or `rpc(trx, ...)`). Do NOT call `trx.transaction().execute(...)` inside the callback; Kysely rejects nested transactions with "calling the transaction method for a Transaction is not supported". For multi-step mutations, put all statements in one `withUserDb` block for atomicity.
- **When adding a new dispatch shape on a built-in tool, update BOTH `callCallback` and `dispatchToTool` in `workers/api/src/twist/entrypoint.ts`.** A tool's `dispatch()` returns `{ sourceMethod, forwardTo, deferredTagRemoval, deferredNoteKeyUpdate, ... }` entries. `callCallback` and `dispatchToTool` each process those entries independently. Adding a field to one handler but not the other makes callbacks routed through the other path silently no-op (e.g. `forwardTo` was missing from `dispatchToTool`, so `onCreateLink` ran but `saveCreatedLink` never fired and the returned link was dropped). The top of `dispatchToTool` has the authoritative list of recognized fields — keep it current.
- **`workers/api/src/twist/entrypoint.ts` is consumed as a template literal.** All backticks in that file must be written as `\`` (escaped). Raw backticks break the esbuild bundle with `Expected ";" but found ...` and the connector deploy fails.
- **Never use `c.var.db` inside `c.executionCtx.waitUntil(...)`.** The request-scoped Kysely connection is destroyed once the handler returns, and any later query throws `driver has already been destroyed`. Open a fresh connection inside the background task and destroy it in `finally`:
  ```ts
  c.executionCtx.waitUntil((async () => {
    const db = createDb(c.env);
    try {
      // ...use `db` here...
    } finally {
      await db.destroy();
    }
  })());
  ```
  Also snapshot any values you need from `c.var` / request body into locals before the `waitUntil` — the Hono `c` object itself is safe to reference by closure, but don't assume per-request resources on it outlive the response. See `workers/api/src/app/sync/links.ts` for the canonical pattern.
