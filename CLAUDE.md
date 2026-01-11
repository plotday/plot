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
- Tool: Provide capabilities to twists. Some are built-in and implemented in the API, while others are available as separate packages. They tend to be unopinionated building blocks (e.g. watch and send Gmail messages).
- Twist Creator aka Twister: The SDK for building twists and tools. Sometimes represented with 🌪️.

## Data

The app is local-first, so it can function without an internet connection while syncing when one is available.
Local storage uses the Drift package (which uses SQLite), with entities defined in "apps/plot/libs/store/".
Data is synchronized to a remote Supabase (PostgreSQL) database for backup, multi-device sync, and collaboration.
The Supabase database schema is defined in "libs/db/schema/".

## Code Structure

- This is a private monorepo containing:
  - The main app, written in Flutter, is in "apps/plot/".
  - All other packages are written in Typescript and use pnpm for package management.
  - The website (mostly marketing, plus some Twist management) is in "apps/site/".
  - APIs and server tasks are implemented using Cloudflare Workers, located in "workers/".
    - The API also implements the twist runtime including built-in tools.
  - Non-open-source twists (particularly the default Plot twist) are in "twists/".
- There is a public monorepo mounted as a git submodule at `public/` containing:
  - The Plot Twist Creator aka Twister is at `public/twister/`. It's the SDK for building twists and twist tools, but with a name that's friendly for non-developers.
    - Twister includes all type definitions for building twists and tool, including type definitions for built-in tools (which are implemented in the api).
    - The CLI is also in the twister package.
  - Public twist tools at `public/tools/`.
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

The Twist Creator repository (`public/twist/`) contains all type definitions and is the single source of truth for twist types. This repo uses it via pnpm workspace links.

### Creator Location and Structure

- **Creator Repository**: `public/twist/` (git submodule)
- **Type Definitions**: `public/twist/src/` (twist.ts, plot.ts, tag.ts, tools/\*.ts, common/\*.ts)
- **Workspace Link**: Configured in `pnpm-workspace.yaml` as `public/twist`
- **Import Pattern**: Use `@plotday/twister`, `@plotday/twister/plot`, `@plotday/twister/tools/*`, etc.

### Making Changes to SDK Types

**IMPORTANT**: Twister types must be modified in the Twister submodule, never in this repo's main code.

1. **Edit Twister files**: Make changes in `public/twist/src/`
2. **Rebuild Twister**: Run `pnpm build` in the Twister folder
3. **Test locally**: Changes are immediately available via workspace link
4. **Verify builds**: Run `pnpm lint` in affected packages (workers/api, twists/\*)

### Where Twister Types Are Used

- **API Worker** (`workers/api/src/`): Built-in tools import Twister types
  - Example: `import type { Activity } from "@plotday/twister/plot"`
  - Built-in tools (`workers/api/src/twist/tools/*`) implement Twister interfaces
- **Twists** (`twists/*/src/`): Import Twister types directly
  - Example: `import { Twist, type Priority } from "@plotday/twister"`

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

### Important Notes

- **Never create or modify types in `workers/api/src/twist/types/`** - this directory no longer exists
- **TypeScript Configuration**: Uses `moduleResolution: "bundler"` in `libs/tsconfig/base.json` to support Twister package exports
- **Workspace Dependencies**: API and twists use `"@plotday/twister": "workspace:*"` for local development

## Twists and Tools

### Twist Tool Types

There are two types of tools for twists:

#### BuiltInTools (workers/api/src/twist/tools/\*)

- Located in `workers/api/src/twist/tools/*`
- Extend the `BuiltInTool` class
- Have access to internal API resources, database connections, and backend services as they run inside the API worker
- Examples: `Plot`, `Integrations`, `Store`
- Use this pattern for tools that need direct access to the Plot backend infrastructure

#### Regular Tools

- Implemented in separate packages outside this monorepo
- Extend the base `Tool` class from the Twist Creator
- Run in isolation, inside the twist worker, with access only to the other tools they request
- These tools typically build on built-in tools and often implement integrations with external services

### Runtime Limitations

All twist and tool functions are executed in a sandboxed, ephemeral environment with limited resources. This means:

- Anything stored in memory (e.g. as a variable in the twist/tool object) is lost
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

When tools need to pass function references that persist across worker invocations, use the **callback tool** instead of direct function passing. Regular function passing cannot be serialized and will not survive worker restarts.

#### When to Use Callbacks

- **Webhook handlers**: Setting up webhooks that need to callback to your tool
- **Scheduled operations**: Functions that run after worker timeouts
- **Event handlers**: Persistent event callbacks that survive restarts
- **Inter-tool communication**: When tools need to call back to their parent

#### Using the Callback Tool

All twists and tools have access to the `callback` tool. It provides a simple interface for creating persistent function references:

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

// Or clean up all callbacks for this tool's parent
await this.callback.deleteAll();
```

#### Callback Tool API

- **`create(functionName, context?)`**: Creates a callback to the tool's parent

  - `functionName`: Name of the function to call on the parent tool/twist
  - `context`: Optional data to pass as context to the callback
  - Returns: Promise resolving to a callback token

- **`call(token, args?)`**: Executes a callback by token

  - `token`: The callback token returned by create()
  - `args`: Optional arguments to pass to the callback function
  - Returns: Promise resolving to the callback result

- **`delete(token)`**: Removes a specific callback
- **`deleteAll()`**: Removes all callbacks for the tool's parent

#### Important Notes

- Callbacks are **hardcoded to target the tool's parent** for security
- Only `functionName` and `context` parameters are supported for simplicity
- Callbacks persist across worker restarts and timeouts
- Use callbacks instead of direct function references in webhook, auth, and tasks tools

### Google Tool Integration Pattern

When building Google-based tools (calendar, contacts, gmail, etc.), use this pattern to enable cross-tool integration with a single OAuth flow and automatic data syncing.

#### Pattern Overview

This pattern allows one Google tool to:
1. Request combined OAuth scopes for multiple tools in a single authorization flow
2. Automatically trigger syncing in related tools after successful authorization
3. Share authorization tokens explicitly across tool boundaries

#### Implementation Steps

**1. Export Scopes as Static Constants**

Each tool should export its required scopes for reuse:

```typescript
export default class GoogleCalendar extends Tool<GoogleCalendar> {
  static readonly SCOPES = [
    "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
    "https://www.googleapis.com/auth/calendar.events",
  ];

  async requestAuth(...) {
    return await this.tools.integrations.request({
      provider: AuthProvider.Google,
      level: AuthLevel.User,
      scopes: GoogleCalendar.SCOPES, // Use static constant
    }, ...);
  }
}
```

**2. Add `syncWithAuth()` Method to Consumer Tools**

Tools that can be triggered by other tools should implement a `syncWithAuth()` method:

```typescript
export default class GoogleContacts extends Tool<GoogleContacts> {
  static readonly SCOPES = [
    "https://www.googleapis.com/auth/contacts.readonly",
    "https://www.googleapis.com/auth/contacts.other.readonly",
  ];

  /**
   * Start contact sync using an existing Authorization from another tool.
   */
  async syncWithAuth(
    authorization: Authorization,
    callback?: Function,
    ...extraArgs: any[]
  ): Promise<void> {
    // Validate authorization has required scopes
    const hasRequiredScopes = GoogleContacts.SCOPES.every(scope =>
      authorization.scopes.includes(scope)
    );

    if (!hasRequiredScopes) {
      throw new Error(`Authorization missing required scopes`);
    }

    // Generate opaque token for storage
    const authToken = crypto.randomUUID();

    // Get actual auth token via integrations
    const token = await this.tools.integrations.get(authorization);

    // Store and start sync
    await this.set(`auth_token:${authToken}`, token);
    // ... initialize and start sync
  }
}
```

**3. Add Dependency and Combine Scopes in Coordinator Tool**

The coordinating tool (e.g., google-calendar) should:
- Declare the consumer tool as a dependency
- Combine scopes in `requestAuth()`
- Trigger `syncWithAuth()` in `onAuthSuccess()`

```typescript
import GoogleContacts from "@plotday/tool-google-contacts";

export class GoogleCalendar extends Tool<GoogleCalendar> {
  static readonly SCOPES = [
    "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
    "https://www.googleapis.com/auth/calendar.events",
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      googleContacts: build(GoogleContacts), // Add dependency
    };
  }

  async requestAuth(...): Promise<ActivityLink> {
    // Combine scopes for single OAuth flow
    const combinedScopes = [
      ...GoogleCalendar.SCOPES,
      ...GoogleContacts.SCOPES,
    ];

    return await this.tools.integrations.request({
      provider: AuthProvider.Google,
      scopes: combinedScopes, // Request combined scopes
    }, this.onAuthSuccess, ...);
  }

  async onAuthSuccess(authorization: Authorization, ...): Promise<void> {
    // Store authorization
    await this.set(`authorization:${authToken}`, authorization);

    // Trigger contacts sync with same authorization
    try {
      await this.tools.googleContacts.syncWithAuth(authorization);
    } catch (error) {
      // Log but don't fail calendar auth
      console.error("Failed to start contacts sync:", error);
    }

    // Continue with calendar setup...
  }
}
```

**4. Update package.json Dependencies**

Add the consumer tool as a workspace dependency:

```json
{
  "dependencies": {
    "@plotday/tool-google-contacts": "workspace:^",
    "@plotday/twister": "workspace:^"
  }
}
```

#### Key Benefits

- **Single OAuth Flow**: Users authorize once for all related Google tools
- **Automatic Integration**: Contacts sync automatically when calendar is authorized
- **Explicit Token Passing**: Authorization is passed as a parameter, avoiding path-dependent storage issues
- **Independent Storage**: Each tool maintains its own storage namespace
- **Scope Validation**: Consumer tools validate they have required scopes before syncing
- **Graceful Degradation**: If consumer sync fails, coordinator auth still succeeds

#### Extending the Pattern

This pattern can be extended to other Google tools:

```typescript
// Gmail tool following the same pattern
export class GoogleGmail extends Tool<GoogleGmail> {
  static readonly SCOPES = [
    "https://www.googleapis.com/auth/gmail.readonly",
    "https://www.googleapis.com/auth/gmail.send",
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      googleContacts: build(GoogleContacts), // Reuse contacts integration
    };
  }

  async requestAuth(...): Promise<ActivityLink> {
    const combinedScopes = [
      ...GoogleGmail.SCOPES,
      ...GoogleContacts.SCOPES, // Add contacts scopes
    ];
    // ... same pattern as calendar
  }
}
```

#### Important Notes

- **Tool Dependency**: The coordinator tool directly depends on consumer tools
- **Workspace Packages**: Use `workspace:^` for local development
- **Build Order**: Rebuild Twister, then rebuild all modified tools
- **Scope Overlap**: Duplicate scopes in combined arrays are automatically deduplicated by OAuth provider
- **Error Handling**: Always wrap consumer sync calls in try-catch to prevent coordinator failure
- **Package Names**: Use full package names like `@plotday/tool-google-contacts` in imports and dependencies

## Database Schema Changes

**CRITICAL: Follow this exact process for ALL schema changes. Never skip steps or use shortcuts.**

### The Correct Schema Change Workflow

1. **Make schema changes in `libs/db/schema/` files ONLY**
   - The schema files are the source of truth
   - Organize changes in the appropriate subdirectories (50-tables, 60-views, 70-rls, 80-triggers, etc.)
   - Never modify migration files directly or create migrations manually

2. **Generate a migration**
   ```bash
   pnpm gen-migration <descriptive_migration_name>
   ```
   - This compares the schema files with existing migrations and generates a new timestamped migration file
   - The migration will be created in `libs/db/supabase/migrations/`

3. **Add data migrations if needed (optional)**
   - If you need to migrate existing data (not schema), add SQL to the generated migration file
   - Example: UPDATE statements to populate new columns, data transformations, etc.
   - Keep data migrations separate from schema changes when possible

4. **Apply the migration to the LOCAL database**
   ```bash
   # Apply the migration file using psql
   psql postgresql://postgres:postgres@localhost:54322/postgres < libs/db/supabase/migrations/YOUR_MIGRATION.sql
   ```
   - This targets the LOCAL database only (localhost:54322)
   - Migrations are automatically wrapped in transactions by PostgreSQL
   - If a migration fails, the transaction rolls back - no partial changes
   - You can modify the migration file and try again until it succeeds

5. **If migration fails or you need more schema changes**
   - Fix the migration file or make additional schema changes
   - Generate another migration: `pnpm gen-migration <another_descriptive_name>`
   - Apply it with psql: `psql postgresql://postgres:postgres@localhost:54322/postgres < libs/db/supabase/migrations/NEW_MIGRATION.sql`
   - Repeat as needed

6. **Verify the changes**
   ```bash
   # Check that schema and database are in sync
   pnpm diff-schema-db

   # Should return no differences if everything is applied correctly
   ```

### Available Database Commands

```bash
# View differences between schema and local database
pnpm diff-schema-db

# Generate a new migration from schema changes
pnpm gen-migration <name>

# Apply a migration to LOCAL database
psql postgresql://postgres:postgres@localhost:54322/postgres < libs/db/supabase/migrations/MIGRATION_FILE.sql

# Check for pending migrations (used in CI)
pnpm --filter @plotday/db lint:pending-migrations

# Regenerate TypeScript types from local database
pnpm types
```

### Understanding Diff Commands

**`pnpm diff-schema-db` (Schema vs Database)**
- Compares schema files with the running local database
- **Often shows false-positive function changes** that have already been applied
- If a function/extension already exists in migrations, ignore it in the diff output
- Use this to get a general sense of what changed, but don't trust it completely
- The migration generator (`pnpm gen-migration`) is smarter about what needs to be migrated

**`pnpm diff-schema-migrations` (Schema vs Migrations)**
- Compares schema files with existing migration files
- **Should return no changes** once all migrations have been generated
- If it shows differences, you have unapplied schema changes
- **Formatting matters**: Function definitions must match the diff output formatting exactly
  - If the diff shows formatting differences, update the schema file to match the diff
  - This ensures the diff returns empty once everything is in sync
- This is the source of truth for whether migrations are complete

### Critical Rules

#### NEVER Touch the Remote Database

- **NEVER push to remote database** - No `supabase db push`, no remote migrations, nothing
- **NEVER reset remote database** - No `supabase db reset --linked`, ever
- **NEVER modify remote database** - All work is LOCAL ONLY (localhost:54322)
- **NEVER use `--linked` flag** - This targets remote database, which is forbidden
- **ONLY work with local database** - Always use localhost:54322 connection

#### Local Database Rules

- **NEVER use `pnpm apply-schema`** - This is a dangerous emergency-only command that bypasses migrations
- **NEVER do a database reset** (`pnpm reset`) without explicit user permission - it destroys all local data
- **NEVER modify migration files** after they've been applied - create a new migration instead
- **NEVER create migrations manually** - always generate them from schema changes
- **ALWAYS use transactions** - migrations are automatically transactional via psql
- **ALWAYS generate types** after schema changes: `pnpm types`
- **ALWAYS verify** you're targeting local database (localhost:54322) before running SQL

### Why This Process Matters

- **Migrations are version-controlled** and provide a complete history of schema evolution
- **Transactions ensure consistency** - either the entire migration succeeds or nothing changes
- **Reproducibility** - the same migrations apply cleanly across all environments
- **Collaboration** - other developers see exactly what changed and when
- **Rollback safety** - failed migrations don't leave the database in a broken state

### Common Mistakes to Avoid

❌ **Wrong**: Running `supabase db push --linked` or any command with `--linked` flag
✅ **Correct**: Only work with local database at localhost:54322

❌ **Wrong**: Pushing or resetting remote database
✅ **Correct**: NEVER touch remote database under any circumstances

❌ **Wrong**: Modifying the database directly with `apply-schema`
✅ **Correct**: Make schema changes, generate migration, apply migration

❌ **Wrong**: Creating migration files manually
✅ **Correct**: Modify schema files, then run `pnpm gen-migration`

❌ **Wrong**: Editing an already-applied migration
✅ **Correct**: Generate a new migration to make additional changes

❌ **Wrong**: Using `pnpm reset` to fix migration issues
✅ **Correct**: Fix the migration file and re-apply with psql

## Hints

- If you get the Typescript error "TS2589: Type instantiation is excessively deep and possibly infinite.", simply add @ts-ignore with a comment above the line causing the error.
- **After modifying Twister types** in `public/twist/src/`, always rebuild Twister with `cd public/twist && pnpm build && cd ../..` before running or testing code in this repo.
- If you see import errors for `@plotday/twister/*` after making Twister changes, ensure Twister has been rebuilt and the package exports are configured correctly in `public/twist/package.json`.
- Only work locally. Never deploy. This includes workers, which only run locally.
- When creating Cloudflare Durable Objects via idFromName(), ctx.id.name IS NOT SET inside the DO. If the DO needs the name (often the priorityTwistId), you MUST add a separate init() method to the DO and ensure it's called after creation to set the name.
- In TypeScript, use static imports at the top of the file wherever possible.
- **When adding new features**, update `docs/features.md` to reflect the new capabilities for marketing content generation.
