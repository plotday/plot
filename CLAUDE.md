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
- All other packages are wrritten in Typescript and use pnpm for package management.
- APIs and server tasks are implemented using Clouflare Workers, located in "workers/".
- The agent SDK is in "libs/agent/". It includes the `plot` CLI tool.
- Agents are in "agents/".

## SDK Entity Standards

For all entities in the sdk folder of the agent package (Activity, Priority, etc.), use the following type pattern:

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

## Agents and Tools

### Agent Tool Types

There are two types of tools for agents:

#### Regular Tools (libs/agent/tools/\*)

- Located in `libs/agent/tools/*`
- Extend the base `Tool` class from the agent SDK
- Run in isolation, with access only to other tools declared in their package.json.
- Constructor must have this signature: `constructor(protected tools: Tools)`
- All other tools required must be added to the package.json file,
  and accessed via `tools.get(ToolClass)` (e.g. `Plot`, `Store`)
- Always prefer regular tools unless internal resources are required

**Use Regular Tools when:**

- The tool primarily interacts with external APIs (Google, Microsoft, etc.)
- The tool provides utility functions that don't require backend access
- The tool can be reused across different agent implementations
- The functionality is self-contained and doesn't need Plot's internal state

#### BuiltInTools (workers/api/src/agent/tools/\*)

- Located in `workers/api/src/agent/tools/*`
- Extend the `BuiltInTool` class
- Have access to internal API resources, database connections, and backend services
- Examples: `Plot`, `Auth`, `Store`
- Use this pattern for tools that need direct access to the Plot backend infrastructure

**Use BuiltInTools when:**

- The tool needs direct access to the Plot database
- The tool requires authentication or authorization through Plot's systems
- The tool needs to interact with internal Plot APIs or services
- The functionality is tightly coupled to Plot's backend infrastructure

### Configuration Files

#### package.json

Every agent and tool must have a `package.json` file in its root directory that defines its metadata and dependencies:

**Agent example:**

```json
{
  "name": "@plotday/sdk-events",
  "displayName": "Events",
  "description": "Sync calendar events",
  "author": "Plot <team@plot.day> (https://plot.day)",
  "license": "MIT",
  "version": "0.1.0",
  "private": true,
  "main": "src/index.ts",
  "dependencies": {
    "@plotday/sdk": "workspace:^"
  }
}
```

**Tool example:**

```json
{
  "name": "@plotday/tool-google-calendar",
  "displayName": "Google Calendar",
  "description": "Sync with Google Calendar",
  "author": "Plot <team@plot.day> (https://plot.day)",
  "license": "MIT",
  "version": "0.1.0",
  "private": true,
  "main": "index.ts",
  "dependencies": {
    "@plotday/sdk": "workspace:^"
  }
}
```

**Required fields:**

- `name`: NPM package name (should follow @plotday/sdk-_or @plotday/tool-_ convention)
- `displayName`: Human-readable display name
- `description`: Brief description of the agent/tool's purpose
- `author`: Author in NPM format: "Name <email> (url)"
- `license`: License type (typically "MIT")
- `plotAgentId`: Unique identifier (kebab-case)

**Creating New Agents/Tools:**

1. Create the directory structure under `agents/` or `libs/agent/tools/`
2. Add a `package.json` file with the required fields
3. Implement the agent/tool class extending `Agent` or `Tool`
4. Add tool dependencies to the `plotAgent.tools` array in package.json

### Runtime Limitations

All agent and tool functions are executed in a sandboxed, ephemeral environment with limited resources. This means:

- Anything stored in memory (e.g. as a variable in the agent/tool object) is lost
  after the function completes. Use the store tool instead. Only use memory for
  temporary caching.
- Each execution has limited CPU time (typically 10 seconds) and memory (128MB)
- **Use the `run` tool** to queue separate chunks of work with `run.now(functionName, context)`
- **Break long operations** into smaller batches that can be processed independently
- **Store intermediate state** using the `store` tool between batches
- **Examples**: Syncing large datasets, processing many API calls, or performing batch operations

Pattern example:

```typescript
// Instead of processing everything in one function
async startSync(calendarId: string): Promise<void> {
  // Setup initial state
  await this.store.set(`sync_state_${calendarId}`, initialState);

  // Queue first batch using run tool
  await this.run.now("syncBatch", { calendarId, batchNumber: 1 });
}

async syncBatch(context: { calendarId: string; batchNumber: number }): Promise<void> {
  // Process one batch
  const result = await processBatch(context.calendarId);

  if (result.hasMore) {
    // Queue next batch
    await this.run.now("syncBatch", {
      calendarId: context.calendarId,
      batchNumber: context.batchNumber + 1
    });
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
