# Agent Implementation Guide for LLMs

This document provides context for AI assistants generating or modifying agent code.

## Architecture Overview

Plot agents are TypeScript classes that extend the `Agent` base class. Agents interact with external services and Plot's core functionality through a tool-based architecture.

### Runtime Environment

**Critical**: All agent and tool functions are executed in a sandboxed, ephemeral environment with limited resources:

- **Memory is temporary**: Anything stored in memory (e.g. as a variable in the agent/tool object) is lost after the function completes. Use the Store tool instead. Only use memory for temporary caching.
- **Limited CPU time**: Each execution has limited CPU time (typically 10 seconds) and memory (128MB)
- **Use the Run tool**: Queue separate chunks of work with `run.now(functionName, context)`
- **Break long operations**: Split large operations into smaller batches that can be processed independently
- **Store intermediate state**: Use the Store tool to persist state between batches
- **Examples**: Syncing large datasets, processing many API calls, or performing batch operations

## Agent Structure Pattern

```typescript
import { type Activity, Agent, type Priority, type Tools } from "@plotday/sdk";
import { Plot } from "@plotday/sdk/tools/plot";

export default class MyAgent extends Agent {
  private plot: Plot;

  constructor(id: string, protected tools: Tools) {
    super(id, tools);
    this.plot = tools.get(Plot);
    // Store, Run, and Callback methods are available directly via this
  }

  async activate(priority: Pick<Priority, "id">) {
    // Called when agent is enabled for a priority
    // Common actions: request auth, create setup activities
  }

  async activity(activity: Activity) {
    // Called when an activity is routed to this agent
    // Common actions: process external events, update activities
  }
}
```

## Tool System

### Accessing Tools

All tools are accessed through the `tools` parameter in the constructor:

```typescript
constructor(id: string, protected tools: Tools) {
  super(id, tools);
  this.toolName = tools.get(ToolClass);
}
```

All `tools.get()` calls must occur in the constructor as they are used for dependency analysis.

### Built-in Tools (Always Available)

For complete API documentation of built-in tools including all methods, types, and detailed examples, see the TypeScript definitions in your installed package at `node_modules/@plotday/sdk/src/tools/*.ts`. Each tool file contains comprehensive JSDoc documentation.

**Quick reference - Available tools:**

- `@plotday/sdk/tools/plot` - Core data layer (create/update activities, priorities, contacts)
- `@plotday/sdk/tools/ai` - LLM integration (text generation, structured output, reasoning)
  - Use ModelPreferences to specify `speed` (fast/balanced/capable) and `cost` (low/medium/high)
- `@plotday/sdk/tools/store` - Persistent key-value storage (also via `this.set()`, `this.get()`)
- `@plotday/sdk/tools/run` - Queue batched work (also via `this.run()`)
- `@plotday/sdk/tools/callback` - Persistent function references (also via `this.callback()`)
- `@plotday/sdk/tools/auth` - OAuth2 authentication flows
- `@plotday/sdk/tools/webhook` - HTTP webhook management
- `@plotday/sdk/tools/agent` - Manage other agents

**Critical**: Never use instance variables for state. They are lost after function execution. Always use Store methods.

### External Tools (Add to package.json)

Add tool dependencies to `package.json`:

```json
{
  "dependencies": {
    "@plotday/sdk": "workspace:^",
    "@plotday/tool-google-calendar": "workspace:^"
  }
}
```

#### Common External Tools

- `@plotday/tool-google-calendar`: Google Calendar integration
- `@plotday/tool-outlook-calendar`: Outlook Calendar integration
- `@plotday/tool-google-contacts`: Google Contacts integration

## Lifecycle Methods

### activate(priority: Pick<Priority, "id">)

Called when the agent is enabled for a priority. Common patterns:

**Request Authentication:**

```typescript
async activate(_priority: Pick<Priority, "id">) {
  const callback = await this.callback.create("onAuthComplete", { provider: "google" });
  const authLink = await this.externalTool.requestAuth(callback);

  await this.plot.createActivity({
    type: ActivityType.Task,
    title: "Connect your account",
    start: new Date(),
    links: [authLink],
  });
}
```

**Store Parent Activity for Later:**

```typescript
const activity = await this.plot.createActivity({
  type: ActivityType.Task,
  title: "Setup",
  start: new Date(),
});

await this.set("setup_activity_id", activity.id);
```

### activity(activity: Activity)

Called when an activity is routed to the agent. Common patterns:

**Create Activities from External Events:**

```typescript
async activity(activity: Activity) {
  await this.plot.createActivity(activity);
}
```

**Update Based on User Action:**

```typescript
async activity(activity: Activity) {
  if (activity.completed) {
    await this.handleCompletion(activity);
  }
}
```

## Activity Links

Activity links enable user interaction:

```typescript
import { type ActivityLink, ActivityLinkType } from "@plotday/sdk";

// URL link
const urlLink: ActivityLink = {
  title: "Open website",
  type: ActivityLinkType.url,
  url: "https://example.com",
};

// Callback link (uses Callback tool)
const token = await this.callback.create("onLinkClicked", { data: "context" });
const callbackLink: ActivityLink = {
  title: "Click me",
  type: ActivityLinkType.callback,
  token: token,
};

// Add to activity
await this.plot.createActivity({
  type: ActivityType.Task,
  title: "Task with links",
  links: [urlLink, callbackLink],
});
```

## Authentication Pattern

Common pattern for OAuth authentication:

```typescript
async activate(_priority: Pick<Priority, "id">) {
  // Create callback for auth completion
  const callback = await this.callback.create("onAuthComplete", {
    provider: "google",
  });

  // Request auth link from tool
  const authLink = await this.googleTool.requestAuth(callback);

  // Create activity with auth link
  const activity = await this.plot.createActivity({
    type: ActivityType.Task,
    title: "Connect Google account",
    start: new Date(),
    links: [authLink],
  });

  // Store for later use
  await this.store.set("auth_activity_id", activity.id);
}

async onAuthComplete(authResult: { authToken: string }, context?: any) {
  const provider = context?.provider;

  // Store auth token
  await this.store.set(`${provider}_auth`, authResult.authToken);

  // Continue setup flow
  await this.setupSyncOptions(authResult.authToken);
}
```

## Sync Pattern

Pattern for syncing external data with callbacks:

```typescript
async startSync(calendarId: string): Promise<void> {
  const authToken = await this.store.get<string>("auth_token");

  // Create callback for event handling
  const callback = await this.callback.create("handleEvent", {
    calendarId,
  });

  await this.calendarTool.startSync(authToken, calendarId, callback);
}

async handleEvent(activity: Activity, context?: any): Promise<void> {
  // Process incoming event from external service
  await this.plot.createActivity(activity);
}

async stopSync(calendarId: string): Promise<void> {
  const authToken = await this.store.get<string>("auth_token");
  await this.calendarTool.stopSync(authToken, calendarId);
}
```

## Calendar Selection Pattern

Pattern for letting users select from multiple calendars/accounts:

```typescript
private async createCalendarSelectionActivity(
  provider: string,
  calendars: Calendar[],
  authToken: string
): Promise<void> {
  const links: ActivityLink[] = [];

  for (const calendar of calendars) {
    const token = await this.callback.create("onCalendarSelected", {
      provider,
      calendarId: calendar.id,
      calendarName: calendar.name,
      authToken,
    });

    links.push({
      title: `📅 ${calendar.name}${calendar.primary ? " (Primary)" : ""}`,
      type: ActivityLinkType.callback,
      token: token,
    });
  }

  await this.plot.createActivity({
    type: ActivityType.Task,
    title: "Which calendars would you like to connect?",
    start: new Date(),
    links,
  });
}

async onCalendarSelected(link: ActivityLink, context: any): Promise<void> {
  // Start sync for selected calendar
  const callback = await this.callback.create("handleEvent", {
    provider: context.provider,
    calendarId: context.calendarId,
  });

  await this.tool.startSync(context.authToken, context.calendarId, callback);
}
```

## Batch Processing Pattern

**Important**: Because agents run in an ephemeral environment with limited execution time (~10 seconds), you must break long operations into batches. Each batch runs independently in a new execution context.

### Key Principles

1. **Store state between batches**: Use the Store tool to persist progress
2. **Queue next batch**: Use the Run tool to schedule the next chunk
3. **Clean up when done**: Delete stored state after completion
4. **Handle failures**: Store enough state to resume if a batch fails

### Example Implementation

```typescript
async startSync(resourceId: string): Promise<void> {
  // Initialize state in Store (persists between executions)
  await this.set(`sync_state_${resourceId}`, {
    nextPageToken: null,
    batchNumber: 1,
    itemsProcessed: 0,
  });

  // Queue first batch using run method
  const callback = await this.callback("syncBatch", { resourceId });
  await this.run(callback);
}

async syncBatch(args: any, context: { resourceId: string }): Promise<void> {
  // Load state from Store (set by previous execution)
  const state = await this.get(`sync_state_${context.resourceId}`);

  // Process one batch (keep under time limit)
  const result = await this.fetchBatch(state.nextPageToken);

  // Process results
  for (const item of result.items) {
    await this.plot.createActivity(item);
  }

  if (result.nextPageToken) {
    // Update state in Store for next batch
    await this.set(`sync_state_${context.resourceId}`, {
      nextPageToken: result.nextPageToken,
      batchNumber: state.batchNumber + 1,
      itemsProcessed: state.itemsProcessed + result.items.length,
    });

    // Queue next batch (runs in new execution context)
    const nextCallback = await this.callback("syncBatch", context);
    await this.run(nextCallback);
  } else {
    // Cleanup when complete
    await this.clear(`sync_state_${context.resourceId}`);

    // Optionally notify user of completion
    await this.plot.createActivity({
      type: ActivityType.Note,
      note: `Sync complete: ${state.itemsProcessed + result.items.length} items processed`,
    });
  }
}
```

## Error Handling

Always handle errors gracefully and communicate them to users:

```typescript
try {
  await this.externalOperation();
} catch (error) {
  console.error("Operation failed:", error);

  await this.plot.createActivity({
    type: ActivityType.Note,
    note: `Failed to complete operation: ${error.message}`,
  });
}
```

## Common Pitfalls

1. **Don't use instance variables for state** - Anything stored in memory is lost after function execution. Always use the Store tool for data that needs to persist.
2. **Don't forget timeout limits** - Each execution has ~10 seconds. Break long operations into batches with the Run tool.
3. **Don't assume execution order** - Batches may run on different workers. Store all necessary state between executions.
4. **Always use Callback tool for persistent references** - Direct function references don't survive worker restarts.
5. **Store auth tokens** - Don't re-request authentication unnecessarily.
6. **Clean up callbacks and stored state** - Delete callbacks and Store entries when no longer needed.
7. **Handle missing auth gracefully** - Check for stored auth before operations.
8. **Batch size matters** - Process enough items per batch to be efficient, but few enough to stay under time limits.
9. **Processing self-created activities** - Other users may change an Activity created by the agent, resulting in an \`activity\` call. Be sure to check the \`changes === null\` and/or \`activity.author.id !== this.id\` to avoid re-processing.
10. Activity with type ActivityType.Note typically do not have a start or end set, unless they're a note about a specific day or time that shouldn't be shown until then.

## Type Patterns

### Entity Types

Follow Plot's entity type patterns:

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

This pattern distinguishes between:

- Omitted fields (`undefined` in Partial types)
- Explicitly set to null (clearing a value)
- Set to a value

## Testing

Before deploying, verify:

1. Linting passes: `{{packageManager}} lint`
2. All dependencies are in package.json
3. Authentication flow works end-to-end
4. Batch operations handle pagination correctly
5. Error cases are handled gracefully
