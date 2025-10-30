# Plot Project Guidelines

## Overview

Plot is multi-platform app with everything from all your apps and messages, organized and prioritized by agents. When you choose a focus, you have the context and actions you need to make progress on what matters.

Supported platforms:

- Web
- Desktop: macOS, Windows
- Mobile: Android, iOS

## Data

The app is local-first, so it can function without an internet connection while syncing when one is available.
Local storage uses the Drift package (which uses SQLite), with entities defined in "apps/plot/libs/store/".
Data is synchronized to a remote Supabase (PostgreSQL) database for backup, multi-device sync, and collaboration.
The Supabase database schema is defined in "libs/db/schema/".

## Code Structure

- The main app, written in Flutter, is in "apps/plot/".
- All other packages are written in Typescript and use pnpm for package management.
- APIs and server tasks are implemented using Cloudflare Workers, located in "workers/".
- The Agent Builder is in a git submodule at `public/builder/`. It includes the `plot` CLI tool and all agent type definitions.
- Agents are in "agents/".

## Agent Builder Entity Standards

For all entities in the builder folder of the agent package (Activity, Priority, etc.), use the following type pattern:

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

## Agent Builder Development

The Agent Builder repository (`public/builder/`) contains all type definitions and is the single source of truth for agent types. This repo uses it via pnpm workspace links.

### Builder Location and Structure

- **Builder Repository**: `public/builder/` (git submodule)
- **Type Definitions**: `public/builder/src/` (agent.ts, plot.ts, tag.ts, tools/\*.ts, common/\*.ts)
- **Workspace Link**: Configured in `pnpm-workspace.yaml` as `public/builder`
- **Import Pattern**: Use `@plotday/agent`, `@plotday/agent/plot`, `@plotday/agent/tools/*`, etc.

### Making Changes to Builder Types

**IMPORTANT**: Builder types must be modified in the Builder submodule, never in this repo's main code.

1. **Edit Builder files**: Make changes in `public/builder/src/`
2. **Rebuild Builder**: Run `pnpm build` in the builder folder
3. **Test locally**: Changes are immediately available via workspace link
4. **Verify builds**: Run `pnpm lint` in affected packages (workers/api, agents/\*)

### Where Builder Types Are Used

- **API Worker** (`workers/api/src/`): Built-in tools import builder types
  - Example: `import type { Activity } from "@plotday/agent/plot"`
  - Built-in tools (`workers/api/src/agent/tools/*`) implement builder interfaces
- **Agents** (`agents/*/src/`): Import builder types directly
  - Example: `import { Agent, type Priority } from "@plotday/agent"`

### Adding New Builder Exports

When adding new top-level type files to the Builder, update `public/builder/package.json` exports:

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

Then rebuild the Builder and run `pnpm install` in this repo to update the workspace link.

### Publishing Builder Updates

Only publish after testing locally:

1. Update version in `public/builder/package.json`
2. Build: `cd public/builder && pnpm build`
3. Publish: `npm publish` (from `public/builder` directory)
4. Commit changes to the Builder submodule, then commit the submodule reference update in this repo

### Important Notes

- **Never create or modify types in `workers/api/src/agent/types/`** - this directory no longer exists
- **TypeScript Configuration**: Uses `moduleResolution: "bundler"` in `libs/tsconfig/base.json` to support builder package exports
- **Workspace Dependencies**: API and agents use `"@plotday/agent": "workspace:*"` for local development

## Agents and Tools

### Agent Tool Types

There are two types of tools for agents:

#### BuiltInTools (workers/api/src/agent/tools/\*)

- Located in `workers/api/src/agent/tools/*`
- Extend the `BuiltInTool` class
- Have access to internal API resources, database connections, and backend services as they run inside the API worker
- Examples: `Plot`, `Integrations`, `Store`
- Use this pattern for tools that need direct access to the Plot backend infrastructure

#### Regular Tools

- Implemented in separate packages outside this monorepo
- Extend the base `Tool` class from the Agent Builder
- Run in isolation, inside the agent worker, with access only to the other tools they request
- These tools typically build on built-in tools and often implement integrations with external services

### Runtime Limitations

All agent and tool functions are executed in a sandboxed, ephemeral environment with limited resources. This means:

- Anything stored in memory (e.g. as a variable in the agent/tool object) is lost
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

All agents and tools have access to the `callback` tool. It provides a simple interface for creating persistent function references:

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

  - `functionName`: Name of the function to call on the parent tool/agent
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
- **After modifying builder types** in `public/builder/src/`, always rebuild the builder with `cd public/builder && pnpm build && cd ../..` before running or testing code in this repo.
- If you see import errors for `@plotday/agent/*` after making builder changes, ensure the builder has been rebuilt and the package exports are configured correctly in `public/builder/package.json`.
- Only work locally. Never deploy. This includes workers, which only run locally.
- When creating Cloudflare Durable Objects via idFromName(), ctx.id.name IS NOT SET inside the DO. If the DO needs the name (often the priorityAgentId), you MUST add a separate init() method to the DO and ensure it's called after creation to set the name.
