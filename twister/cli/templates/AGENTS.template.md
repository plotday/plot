# Twist Implementation Guide for LLMs

This document provides context for AI assistants generating or modifying twists.

## Architecture Overview

Plot Twists are TypeScript classes that extend the `Twist` base class. Twists interact with external services and Plot's core functionality through a tool-based architecture.

### Runtime Environment

**Critical**: All Twists and tool functions are executed in a sandboxed, ephemeral environment with limited resources:

- **Memory is temporary**: Anything stored in memory (e.g. as a variable in the twist/tool object) is lost after the function completes. Use the Store tool instead. Only use memory for temporary caching.
- **Limited CPU time**: Each execution has limited CPU time (typically 10 seconds) and memory (128MB)
- **Use the Run tool**: Queue separate chunks of work with `run.now(functionName, context)`
- **Break long operations**: Split large operations into smaller batches that can be processed independently
- **Store intermediate state**: Use the Store tool to persist state between batches
- **Examples**: Syncing large datasets, processing many API calls, or performing batch operations

## twist Structure Pattern

```typescript
import {
  type Activity,
  twist,
  type Priority,
  type ToolBuilder,
} from "@plotday/twister";
import { Plot } from "@plotday/twister/tools/plot";

export default class MyTwist extends Twist<MyTwist> {
  build(build: ToolBuilder) {
    return {
      plot: build(Plot),
    };
  }

  async activate(priority: Pick<Priority, "id">) {
    // Called when twist is enabled for a priority
    // Common actions: request auth, create setup activities
  }

  async activity(activity: Activity) {
    // Called when an activity is routed to this twist
    // Common actions: process external events, update activities
  }
}
```

## Tool System

### Accessing Tools

All tools are declared in the `build` method:

```typescript
build(build: ToolBuilder) {
  return {
    toolName: build(ToolClass),
  };
}
```

All `build()` calls must occur in the `build` method as they are used for dependency analysis.

IMPORTANT: HTTP access is restricted to URLs requested via `build(Network, { urls: [url1, url2, ...] })` in the `build` method. Wildcards are supported. Use `build(Network, { urls: ['*'] })` if full access is needed.

### Built-in Tools (Always Available)

For complete API documentation of built-in tools including all methods, types, and detailed examples, see the TypeScript definitions in your installed package at `node_modules/@plotday/twister/src/tools/*.ts`. Each tool file contains comprehensive JSDoc documentation.

**Quick reference - Available tools:**

- `@plotday/twister/tools/plot` - Core data layer (create/update activities, priorities, contacts)
- `@plotday/twister/tools/ai` - LLM integration (text generation, structured output, reasoning)
  - Use ModelPreferences to specify `speed` (fast/balanced/capable) and `cost` (low/medium/high)
- `@plotday/twister/tools/store` - Persistent key-value storage (also via `this.set()`, `this.get()`)
- `@plotday/twister/tools/tasks` - Queue batched work (also via `this.run()`)
- `@plotday/twister/tools/callbacks` - Persistent function references (also via `this.callback()`)
- `@plotday/twister/tools/integrations` - OAuth2 authentication flows
- `@plotday/twister/tools/network` - HTTP access permissions and webhook management
- `@plotday/twister/tools/twists` - Manage other Twists

**Critical**: Never use instance variables for state. They are lost after function execution. Always use Store methods.

### External Tools (Add to package.json)

Add tool dependencies to `package.json`:

```json
{
  "dependencies": {
    "@plotday/twister": "workspace:^",
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

Called when the twist is enabled for a priority. Common patterns:

**Request Authentication:**

```typescript
async activate(_priority: Pick<Priority, "id">) {
  const authLink = await this.tools.externalTool.requestAuth(
    this.onAuthComplete,
    "google"
  );

  await this.tools.plot.createActivity({
    type: ActivityType.Task,
    title: "Connect your account",
    links: [authLink],
  });
}
```

**Store Parent Activity for Later:**

```typescript
const activity = await this.tools.plot.createActivity({
  type: ActivityType.Task,
  title: "Setup",
});

await this.set("setup_activity_id", activity.id);
```

### activity(activity: Activity)

Called when an activity is routed to the twist. Common patterns:

**Create Activities from External Events:**

```typescript
async activity(activity: Activity) {
  await this.tools.plot.createActivity(activity);
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
import { type ActivityLink, ActivityLinkType } from "@plotday/twister";

// URL link
const urlLink: ActivityLink = {
  title: "Open website",
  type: ActivityLinkType.url,
  url: "https://example.com",
};

// Callback link (uses Callbacks tool)
const token = await this.callback(this.onLinkClicked, "context");
const callbackLink: ActivityLink = {
  title: "Click me",
  type: ActivityLinkType.callback,
  token: token,
};

// Add to activity
await this.tools.plot.createActivity({
  type: ActivityType.Task,
  title: "Task with links",
  links: [urlLink, callbackLink],
});
```

## Authentication Pattern

Common pattern for OAuth authentication:

```typescript
async activate(_priority: Pick<Priority, "id">) {
  // Request auth link from tool with callback
  const authLink = await this.tools.googleTool.requestAuth(
    this.onAuthComplete,
    "google"
  );

  // Create activity with auth link
  const activity = await this.tools.plot.createActivity({
    type: ActivityType.Task,
    title: "Connect Google account",
    links: [authLink],
  });

  // Store for later use
  await this.set("auth_activity_id", activity.id);
}

async onAuthComplete(authResult: { authToken: string }, provider: string) {
  // Store auth token
  await this.set(`${provider}_auth`, authResult.authToken);

  // Continue setup flow
  await this.setupSyncOptions(authResult.authToken);
}
```

## Sync Pattern

Pattern for syncing external data with callbacks:

```typescript
async startSync(calendarId: string): Promise<void> {
  const authToken = await this.get<string>("auth_token");

  await this.tools.calendarTool.startSync(
    authToken,
    calendarId,
    this.handleEvent,
    calendarId
  );
}

async handleEvent(activity: Activity, calendarId: string): Promise<void> {
  // Process incoming event from external service
  await this.tools.plot.createActivity(activity);
}

async stopSync(calendarId: string): Promise<void> {
  const authToken = await this.get<string>("auth_token");
  await this.tools.calendarTool.stopSync(authToken, calendarId);
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
    const token = await this.callback(
      this.onCalendarSelected,
      provider,
      calendar.id,
      calendar.name,
      authToken
    );

    links.push({
      title: `📅 ${calendar.name}${calendar.primary ? " (Primary)" : ""}`,
      type: ActivityLinkType.callback,
      token: token,
    });
  }

  await this.tools.plot.createActivity({
    type: ActivityType.Note,
    title: "Which calendars would you like to connect?",
    links,
  });
}

async onCalendarSelected(
  link: ActivityLink,
  provider: string,
  calendarId: string,
  calendarName: string,
  authToken: string
): Promise<void> {
  // Start sync for selected calendar
  await this.tools.tool.startSync(
    authToken,
    calendarId,
    this.handleEvent,
    provider,
    calendarId
  );
}
```

## Batch Processing Pattern

**Important**: Because Twists run in an ephemeral environment with limited execution time, you must break long operations into batches. Each batch runs independently in a new execution context.

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

  // Queue first batch using runTask method
  const callback = await this.callback(this.syncBatch, resourceId);
  await this.runTask(callback);
}

async syncBatch(args: any, resourceId: string): Promise<void> {
  // Load state from Store (set by previous execution)
  const state = await this.get(`sync_state_${resourceId}`);

  // Process one batch (keep under time limit)
  const result = await this.fetchBatch(state.nextPageToken);

  // Process results
  for (const item of result.items) {
    await this.tools.plot.createActivity(item);
  }

  if (result.nextPageToken) {
    // Update state in Store for next batch
    await this.set(`sync_state_${resourceId}`, {
      nextPageToken: result.nextPageToken,
      batchNumber: state.batchNumber + 1,
      itemsProcessed: state.itemsProcessed + result.items.length,
    });

    // Queue next batch (runs in new execution context)
    const nextCallback = await this.callback(this.syncBatch, resourceId);
    await this.runTask(nextCallback);
  } else {
    // Cleanup when complete
    await this.clear(`sync_state_${resourceId}`);

    // Optionally notify user of completion
    await this.tools.plot.createActivity({
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

  await this.tools.plot.createActivity({
    type: ActivityType.Note,
    note: `Failed to complete operation: ${error.message}`,
  });
}
```

## Common Pitfalls

- **Don't use instance variables for state** - Anything stored in memory is lost after function execution. Always use the Store tool for data that needs to persist.
- **Processing self-created activities** - Other users may change an Activity created by the twist, resulting in an \`activity\` call. Be sure to check the \`changes === null\` and/or \`activity.author.id !== this.id\` to avoid re-processing.
- Most activity should be `type = ActivityType.Note` with a `title` and `note`, and no `start` or `end`. This represents a typical message. `start` and `end` should only be used for a note if it should be displayed for a specific date or time, such as a birthday.
- Tools are declared in the `build` method and accessed via `this.tools.toolName` in twist methods.
- **Don't forget runtime limits** - Each execution has ~10 seconds. Break long operations into batches with the Tasks tool. Process enough items per batch to be efficient, but few enough to stay under time limits.
- **Always use Callbacks tool for persistent references** - Direct function references don't survive worker restarts.
- **Store auth tokens** - Don't re-request authentication unnecessarily.
- **Clean up callbacks and stored state** - Delete callbacks and Store entries when no longer needed.
- **Handle missing auth gracefully** - Check for stored auth before operations.

## Testing

Before deploying, verify:

1. Linting passes: `{{packageManager}} lint`
2. All dependencies are in package.json
3. Authentication flow works end-to-end
4. Batch operations handle pagination correctly
5. Error cases are handled gracefully
