# Plot Project Guidelines

## Overview

Plot is multi-platform app with tasks, messages, and links to documents from all your apps, organized and prioritized. When you choose a focus, you have the context and actions you need to make progress on what matters.

Supported platforms:

- Web
- Desktop: macOS, Windows
- Mobile: Android, iOS

## Definitions

- Activity: A single item in Plot, containing notes. An activity might be just notes, or it might be an event or action (task).
- Note: Content associated with an activity, such as Markdown notes and links.
- Priority: Similar to a project or folder for Activity. Priorities are nested using paths, and display all Activity related to them and their descendants.
- Twist: The Plot version of an extension/plugin/app/agent. Users add them to a Priority where they have access to that Priority and its descendants. They tend to implement opinionated workflows (e.g. create tasks from emails).
- Source: A Plot package that syncs data from external services (replaces the old Tool pattern for external integrations). Sources save threads directly via `integrations.saveThread()`. They expose channels that users can enable/disable.
- Twist Creator aka Twister: The SDK for building twists and sources. Sometimes represented with 🌪️.
- RSVP Tags: Special count tags (Attend, Skip, Undecided) that are mutually exclusive per actor. When an actor adds one RSVP tag, any other RSVP tags they have are automatically removed. This exclusivity is enforced at both the database level and in the Flutter app for offline support. The exclusivity respects occurrence boundaries for recurring events.
- Count Tag Ownership: Count tags can only be added/removed by the user themselves. Users cannot modify count tags for other actors. This is enforced by database trigger functions (`update_activity_tags`, `update_note_tags`) and validated in the Flutter app.

## Data

The app is local-first, so it can function without an internet connection while syncing when one is available.
Local storage uses the Drift package (which uses SQLite), with entities defined in "apps/plot/libs/store/".
Data is synchronized to a remote PostgreSQL database for backup, multi-device sync, and collaboration.
The database schema is defined in "libs/db/schema/".
The local development database runs as a Docker container (PostgreSQL 18.1) on port 54322.
Atlas is used for schema diffing and migration management. Type generation uses `@supabase/postgres-meta` as a library (via `pnpm types`).

## Code Structure

- This is a private monorepo containing:
  - The main app, written in Flutter, is in "apps/plot/".
  - All other packages are written in Typescript and use pnpm for package management.
  - The website (mostly marketing, plus some Twist management) is in "apps/site/".
  - APIs and server tasks are implemented using Cloudflare Workers, located in "workers/".
    - The API also implements the twist runtime including built-in tools.
  - Non-open-source twists and sources are in "twists/".
- There is a public monorepo mounted as a git submodule at `public/` containing:
  - The Plot Twist Creator aka Twister is at `public/twister/`. It's the SDK for building twists and sources, but with a name that's friendly for non-developers.
    - Twister includes all type definitions for building twists and sources, including type definitions for built-in tools (which are implemented in the api).
    - The CLI is also in the twister package.
  - Public sources at `public/sources/`.
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

The Twist Creator repository (`public/twist/`) contains all type definitions and is the single source of truth for twist and source types. This repo uses it via pnpm workspace links.

### Creator Location and Structure

- **Creator Repository**: `public/twist/` (git submodule)
- **Type Definitions**: `public/twist/src/` (twist.ts, plot.ts, tag.ts, sources/\*.ts, common/\*.ts)
- **Workspace Link**: Configured in `pnpm-workspace.yaml` as `public/twist`
- **Import Pattern**: Use `@plotday/twister`, `@plotday/twister/plot`, `@plotday/twister/sources/*`, etc.

### Making Changes to SDK Types

**IMPORTANT**: Twister types must be modified in the Twister submodule, never in this repo's main code.

1. **Edit Twister files**: Make changes in `public/twist/src/`
2. **Rebuild Twister**: Run `pnpm build` in the Twister folder
3. **Test locally**: Changes are immediately available via workspace link
4. **Verify builds**: Run `pnpm lint` in affected packages (workers/api, twists/\*)

### Adding New Twister Exports

When adding new top-level type files to Twister, update `public/twist/package.json` exports:

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

1. Update version in `public/twist/package.json`
2. Build: `cd public/twist && pnpm build`
3. Publish: `npm publish` (from `public/twist` directory)
4. Commit changes to the Twister submodule, then commit the submodule reference update in this repo

### Changesets

**IMPORTANT**: Any change to Twister files in `public/twist/src/` MUST include a changeset file. Never skip this step.

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

## Twists and Sources

### Built-in Tools vs Sources

Sources have replaced the old Tool pattern for external integrations. Sources sync data from external services and expose channels that users can enable/disable.

#### BuiltInTools (workers/api/src/twist/tools/\*)

- Located in `workers/api/src/twist/tools/*`
- Extend the `BuiltInTool` class
- Have access to internal API resources, database connections, and backend services as they run inside the API worker
- Examples: `Plot`, `Integrations`, `Store`
- Use this pattern for tools that need direct access to the Plot backend infrastructure

#### Sources

- Implemented in separate packages in `public/sources/`
- Extend the base `Source` class from the Twist Creator
- Run in isolation, inside the twist worker, with access only to the other tools they request
- Sources sync data from external services and expose channels via `getChannels()`
- Users enable/disable channels, triggering `onChannelEnabled()` / `onChannelDisabled()` callbacks
- Sources save threads directly via `integrations.saveThread()`

### Runtime Limitations

All twist and source functions are executed in a sandboxed, ephemeral environment with limited resources. This means:

- Anything stored in memory (e.g. as a variable in the twist/source object) is lost
  after the function completes. Use the store tool instead. Only use memory for
  temporary caching.
- Each execution has limited CPU time
- **Use the Tasks tool** to queue separate chunks of work by passing a callback
- **Break long operations** into smaller batches that can be processed independently
- **Store intermediate state** using the `store` tool between batches
- **Examples**: Syncing large datasets, processing many API calls, or performing batch operations

Pattern example:

```typescript
// Instead of processing everything in one function
async startSync(calendarId: string): Promise<void> {
  // Setup initial state
  await this.store.set(`sync_state_${calendarId}`, initialState);

  // Create callback and queue first batch using tasks tool
  const callback = await this.callback("syncBatch", { calendarId, batchNumber: 1 });
  await this.runTask(callback);
}

async syncBatch(args: any, context: { calendarId: string; batchNumber: number }): Promise<void> {
  // Process one batch
  const result = await processBatch(context.calendarId);

  if (result.hasMore) {
    // Queue next batch
    const callback = await this.callback("syncBatch", {
      calendarId: context.calendarId,
      batchNumber: context.batchNumber + 1
    });
    await this.runTask(callback);
  }
}
```

### Callbacks for Persistent Function References

When sources need to pass function references that persist across worker invocations, use the **callback tool** instead of direct function passing. Regular function passing cannot be serialized and will not survive worker restarts.

#### When to Use Callbacks

- **Webhook handlers**: Setting up webhooks that need to callback to your source
- **Scheduled operations**: Functions that run after worker timeouts
- **Event handlers**: Persistent event callbacks that survive restarts
- **Inter-source communication**: When sources need to call back to their parent

#### Using the Callback Tool

All twists and sources have access to the `callback` tool. It provides a simple interface for creating persistent function references:

```typescript
// Create a persistent callback
const token = await this.callback.create("onWebhookReceived", {
  calendarId: "primary",
  syncType: "incremental",
});

// The token can be stored or passed to external services
await this.store.set("webhook_token", token);

// Later, execute the callback (can happen in different worker instance)
const result = await this.callback.call(token, {
  eventData: webhookPayload,
});

// Clean up when no longer needed
await this.callback.delete(token);

// Or clean up all callbacks for this source's parent
await this.callback.deleteAll();
```

#### Important Notes

- Callbacks are **hardcoded to target the source's parent** for security
- Callbacks persist across worker restarts and timeouts
- Use callbacks instead of direct function references in webhook, auth, and tasks sources

### Activity Sync Best Practices

When syncing activities from external systems, follow these patterns to ensure correct archiving behavior and prevent notification spam:

#### The `initialSync` Flag Pattern

All sync-based sources should track whether they're performing an initial sync (first import) or an incremental sync (ongoing updates). Key pattern for activity creation:

```typescript
const activity: NewActivity = {
  type: ActivityType.Event,
  title: event.title,
  ...(initialSync ? { unread: false } : {}), // false for initial, omit for incremental
  ...(initialSync ? { archived: false } : {}), // unarchive on initial only
};
```

#### Field Behavior by Sync Type

| Field      | Initial Sync | Incremental Sync | Reason                                                                                         |
| ---------- | ------------ | ---------------- | ---------------------------------------------------------------------------------------------- |
| `unread`   | `false`      | _omit_           | Initial: mark read for all. Incremental: auto-mark read for author if they are the twist owner |
| `archived` | `false`      | _omit_           | Unarchive on install, preserve user choice on updates                                          |

**Why this matters**:

- **Initial sync**: Activities are unarchived and marked as read for all users, avoiding spam from bulk historical imports
- **Incremental sync**: Activities are auto-marked as read for the author if they are the twist owner (user), unread for everyone else. Archived state is preserved (respects user's archiving decisions)
- **Reinstall**: Acts as initial sync, so archived activities are unarchived (fresh start)

### Multi-User Priority Auth

Twists and sources that require authentication must handle multi-user priorities correctly. There are three auth models:

#### Auth Models

1. **No auth**: The twist/source doesn't need external credentials (e.g. a text-only twist).
2. **Read-only single auth**: One user connects (installer), and all synced data is visible to priority members. No per-user write-back needed.
3. **Two-way per-user auth**: Write-backs (comments, RSVP, issue updates) should use the acting user's credentials when available, falling back to the installer's.

#### Private Auth Activities

When a twist creates an auth activity in `activate()`, it should use `access: "private"` with `accessContacts` targeting the installing user so only they see the auth prompt:

```typescript
async activate(_priority: Pick<Priority, "id">, context?: { actor: Actor }) {
  await this.tools.plot.createActivity({
    type: ActivityType.Action,
    title: "Connect your account",
    access: "private",
    accessContacts: context?.actor ? [context.actor.id] : [],
    notes: [{
      links: [authLink],
    }],
  });
}
```

#### Per-User Auth for Write-Backs

For two-way sync, try the acting user's credentials first, then fall back to the installer's. The simplest pattern passes the actor's ID as `authToken` — the source's `getClient()` will look it up via `integrations.get(provider, actorId)`:

```typescript
// In onNoteCreated (note.author.id is available):
const actorId = note.author.id as string;
const installerAuthToken = await this.getAuthToken(provider);

// Try actor first, fall back to installer
for (const authToken of [actorId, installerAuthToken]) {
  try {
    await tool.addIssueComment(authToken, activity.meta, note.content, note.id);
    return; // Success
  } catch {
    continue; // Try next
  }
}
```

For `onThreadUpdated` where the acting user is not available in the callback signature, continue using the installer's auth token.

### Google Source Integration Pattern

When building Google-based sources, use cross-source integration with a single OAuth flow. The pattern:

1. Each source exports its required scopes as `static readonly SCOPES`
2. A coordinator source (e.g. google-calendar) combines scopes from multiple sources in `requestAuth()`
3. On auth success, the coordinator calls `syncWithAuth(authorization)` on consumer sources
4. Consumer sources validate they have required scopes before syncing
5. Always wrap consumer sync calls in try-catch so coordinator auth doesn't fail if consumer sync fails

See `public/sources/google-calendar/` and `public/sources/google-contacts/` for the reference implementation. Consumer sources are added as `workspace:^` dependencies.

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

3. **Add data migrations if needed (optional)**

   - If you need to migrate existing data (not schema), add SQL to the generated migration file
   - Example: UPDATE statements to populate new columns, data transformations, etc.
   - Keep data migrations separate from schema changes when possible

4. **Apply migrations to the LOCAL database**

   ```bash
   pnpm apply-migrations
   ```

   - This uses Atlas to apply all pending migrations to the LOCAL database (localhost:54322)
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

- **NEVER modify remote database** - All work is LOCAL ONLY (localhost:54322)
- **ONLY work with local database** - Always use localhost:54322 connection

#### Local Database Rules

- **NEVER do a database reset** (`pnpm reset`) without explicit user permission - it destroys all local data
- **NEVER modify migration files** after they've been applied - create a new migration instead
- **NEVER create migrations manually** - always generate them with `pnpm gen-migration`
- **ALWAYS generate types** after schema changes: `pnpm types`
- **ALWAYS verify** you're targeting local database (localhost:54322) before running SQL

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

### Conditional Setup (run when needed)

**Submodule changes** (modifying `public/` — twister types, sources, twists):

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

The `user.thread` view is the canonical reference for visibility logic. When querying `thread_unread` directly (outside the view), you MUST replicate these filters:

```sql
-- Required visibility filters when joining thread_unread with thread:
AND t.archived_at IS NULL                           -- exclude archived threads
AND (t.draft = false OR t.created_by = :userId)     -- only show own drafts
AND (CASE
  WHEN t.access = 'public' THEN true                -- public threads: visible to all
  WHEN t.created_by = :userId THEN true             -- creator always has access
  WHEN t.access = 'members' AND :userRole = 'member' THEN true  -- members see members-only threads
  WHEN "user".user_contact_id(:userId) = ANY(t.access_contacts) THEN true  -- listed contacts
  ELSE false
END)
```

### When these filters are required

- **Notification queries**: Any query that decides whether to send a push notification or what content to show in a notification. Without these filters, invisible threads (private threads from other users, archived threads) will generate phantom notifications.
- **Unread indicators**: Views/queries that compute whether a priority has unread threads (e.g. `user.priority_unread`). Without these filters, the unread dot shows on priorities where the user has no visible unread threads.
- **Thread listing/counting**: Any query that lists or counts threads for a specific user outside of the `user.thread` view.

### When these filters are NOT required

- **Twist/source callbacks**: Views like `priority_twist_thread_read` are scoped to threads the twist itself created (`a.created_by = pt.id`). The twist has inherent visibility into its own threads.
- **Admin/system queries**: Internal operations that don't surface results to users.
- **RPC functions with access control**: Functions that call `assert_priority_access()` before querying.

### Common mistake

Querying `thread_unread` with only `read_at IS NULL` and `urgency != 'passive'` — this misses archived, draft, and access-restricted thread visibility, causing phantom notifications and incorrect unread counts.

## Plot App URLs

The app uses base58-encoded UUIDs in URLs. URL formats:

- **Production**: `https://app.plot.day/{priority_base58}/{thread_base58?}`
- **Dev**: `http://localhost:8788/{priority_base58}/{thread_base58?}`

The first path segment is the priority ID, the second (optional) is the thread ID.

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

- **Local DB**: `psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -c "SELECT id, title FROM priority WHERE id = '<uuid>'"`
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
