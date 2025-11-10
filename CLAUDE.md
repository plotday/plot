# Plot Project Guidelines

## Overview

Plot is multi-platform app with tasks, messages, and links to documents from all your apps, organized and prioritized. When you choose a focus, you have the context and actions you need to make progress on what matters.

Supported platforms:

- Web
- Desktop: macOS, Windows
- Mobile: Android, iOS

## Definitions

- Activity: A single item in Plot, such as a task, message, or document link.
- Thread: A top-level Activity (with a top-level path) and all Activity with child paths.
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
  note: string | null; // Nullable (not optional)
  start: Date | string | null; // Nullable (not optional)
};

export type NewActivity = {
  type: Activity["type"]; // Only type is required
} & Partial<Omit<Activity, "id" | "author" | "type">>;
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
- **Use the `run` tool** to queue separate chunks of work by passing a callback
- **Break long operations** into smaller batches that can be processed independently
- **Store intermediate state** using the `store` tool between batches
- **Examples**: Syncing large datasets, processing many API calls, or performing batch operations

Pattern example:

```typescript
// Instead of processing everything in one function
async startSync(calendarId: string): Promise<void> {
  // Setup initial state
  await this.store.set(`sync_state_${calendarId}`, initialState);

  // Create callback and queue first batch using run tool
  const callback = await this.callback("syncBatch", { calendarId, batchNumber: 1 });
  await this.run.run(callback);
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
    await this.run.run(callback);
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
- Use callbacks instead of direct function references in webhook, auth, and run tools

## Hints

- If you get the Typescript error "TS2589: Type instantiation is excessively deep and possibly infinite.", simply add @ts-ignore with a comment above the line causing the error.
- To generate a migration, use "pnpm gen-migration MIGRATION_NAME".
- **After modifying Twister types** in `public/twist/src/`, always rebuild Twister with `cd public/twist && pnpm build && cd ../..` before running or testing code in this repo.
- If you see import errors for `@plotday/twister/*` after making Twister changes, ensure Twister has been rebuilt and the package exports are configured correctly in `public/twist/package.json`.
- Only work locally. Never deploy. This includes workers, which only run locally.
- When creating Cloudflare Durable Objects via idFromName(), ctx.id.name IS NOT SET inside the DO. If the DO needs the name (often the priorityTwistId), you MUST add a separate init() method to the DO and ensure it's called after creation to set the name.
- In TypeScript, use static imports at the top of the file wherever possible.
