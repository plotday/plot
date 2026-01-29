# Twist Implementation Guide for LLMs

This document provides context for AI assistants generating or modifying twists.

## Architecture Overview

Plot Twists are TypeScript classes that extend the `Twist` base class. Twists interact with external services and Plot's core functionality through a tool-based architecture.

### Runtime Environment

**Critical**: All Twists and tool functions are executed in a sandboxed, ephemeral environment with limited resources:

- **Memory is temporary**: Anything stored in memory (e.g. as a variable in the twist/tool object) is lost after the function completes. Use the Store tool instead. Only use memory for temporary caching.
- **Limited requests per execution**: Each execution has ~1000 requests (HTTP requests, tool calls, database operations)
- **Limited CPU time**: Each execution has limited CPU time (typically ~60 seconds) and memory (128MB)
- **Use tasks to get fresh request limits**: `this.runTask()` creates a NEW execution with a fresh ~1000 request limit
- **Calling callbacks continues same execution**: `this.run()` continues the same execution and shares the request count
- **Break long loops**: Split large operations into batches that each stay under the ~1000 request limit
- **Store intermediate state**: Use the Store tool to persist state between batches
- **Examples**: Syncing large datasets, processing many API calls, or performing batch operations

## Understanding Activities and Notes

**CRITICAL CONCEPT**: An **Activity** represents something done or to be done (a task, event, or conversation), while **Notes** represent the updates and details on that activity.

**Think of an Activity as a thread** on a messaging platform, and **Notes as the messages in that thread**.

### Key Guidelines

1. **Always create Activities with an initial Note** - The title is just a summary; detailed content goes in Notes
2. **Add Notes to existing Activities for updates** - Don't create a new Activity for each related message
3. **Use Activity.source and Note.key for automatic upserts (Recommended)** - Set Activity.source to the external item's URL for deduplication, and use Note.key for upsertable note content. No manual ID tracking needed.
4. **For advanced cases, use generated UUIDs** - Only when you need multiple Plot activities per external item (see SYNC_STRATEGIES.md)
5. **Most Activities should be `ActivityType.Note`** - Use `Action` only for tasks with `done`, use `Event` only for items with `start`/`end`

### Recommended Decision Tree (Strategy 2: Upsert via Source/Key)

```
New event/task/conversation from external system?
  ├─ Has stable URL or ID?
  │   └─ Yes → Set Activity.source to the canonical URL/ID
  │             Create Activity (Plot handles deduplication automatically)
  │             Use Note.key for different note types:
  │               - "description" for main content
  │               - "metadata" for status/priority/assignee
  │               - "comment-{id}" for individual comments
  │
  └─ No stable identifier OR need multiple Plot activities per external item?
      └─ Use Advanced Pattern (Strategy 3: Generate and Store IDs)
          See SYNC_STRATEGIES.md for details
```

### Advanced Decision Tree (Strategy 3: Generate and Store IDs)

Only use when source/key upserts aren't sufficient (e.g., creating multiple activities from one external item):

```
New event/task/conversation?
  ├─ Yes → Generate UUID with Uuid.Generate()
  │         Create new Activity with that UUID
  │         Store mapping: external_id → activity_uuid
  │
  └─ No (update/reply/comment) → Look up mapping by external_id
      ├─ Found → Add Note to existing Activity using stored UUID
      └─ Not found → Create new Activity with UUID + store mapping
```

## Twist Structure Pattern

```typescript
import {
  type Activity,
  type Priority,
  type ToolBuilder,
  twist,
} from "@plotday/twister";
import { Plot } from "@plotday/twister/tools/plot";
import { Uuid } from "@plotday/twister/utils/uuid";

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
    type: ActivityType.Note,
    title: "Connect your account",
    notes: [
      {
        content: "Click the link below to connect your account and start syncing.",
        links: [authLink],
      },
    ],
  });
}
```

**Store Parent Activity for Later:**

```typescript
const activity = await this.tools.plot.createActivity({
  type: ActivityType.Note,
  title: "Setup",
  notes: [
    {
      content: "Your twist is being set up. Configuration steps will appear here.",
    },
  ],
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

// Add to activity note
await this.tools.plot.createActivity({
  type: ActivityType.Note,
  title: "Task with links",
  notes: [
    {
      content: "Click the links below to take action.",
      links: [urlLink, callbackLink],
    },
  ],
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
    type: ActivityType.Note,
    title: "Connect Google account",
    notes: [
      {
        content: "Click below to connect your Google account and start syncing.",
        links: [authLink],
      },
    ],
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

### Recommended: Upsert via Source/Key (Strategy 2)

Pattern for syncing external data using automatic upserts - **no manual ID tracking needed**:

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

async handleEvent(
  event: ExternalEvent,
  calendarId: string
): Promise<void> {
  // Use the event's canonical URL as the source for automatic deduplication
  const activity: NewActivityWithNotes = {
    source: event.htmlLink, // or event.url, depending on your external system
    type: ActivityType.Event,
    title: event.summary || "(No title)",
    start: event.start?.dateTime || event.start?.date || null,
    end: event.end?.dateTime || event.end?.date || null,
    notes: [],
  };

  // Add description as an upsertable note
  if (event.description) {
    activity.notes.push({
      activity: { source: event.htmlLink },
      key: "description", // This key enables upserts - same key updates the note
      content: event.description,
    });
  }

  // Add attendees as an upsertable note
  if (event.attendees?.length) {
    const attendeeList = event.attendees
      .map(a => `- ${a.email}${a.displayName ? ` (${a.displayName})` : ''}`)
      .join('\n');

    activity.notes.push({
      activity: { source: event.htmlLink },
      key: "attendees", // Different key for different note types
      content: `## Attendees\n${attendeeList}`,
    });
  }

  // Create or update - Plot automatically handles deduplication based on source
  await this.tools.plot.createActivity(activity);
}

async stopSync(calendarId: string): Promise<void> {
  const authToken = await this.get<string>("auth_token");
  await this.tools.calendarTool.stopSync(authToken, calendarId);
}
```

### Advanced: Generate and Store IDs (Strategy 3)

Only use this pattern when you need to create multiple Plot activities from a single external item, or when the external system doesn't provide stable identifiers. See SYNC_STRATEGIES.md for details.

```typescript
async handleEventAdvanced(
  incomingActivity: NewActivityWithNotes,
  calendarId: string
): Promise<void> {
  // Extract external event ID from meta (adapt based on your tool's data)
  const externalId = incomingActivity.meta?.eventId;

  if (!externalId) {
    console.error("Event missing external ID");
    return;
  }

  // Check if we've already synced this event
  const mappingKey = `event_mapping:${calendarId}:${externalId}`;
  const existingActivityId = await this.get<Uuid>(mappingKey);

  if (existingActivityId) {
    // Event already exists - add update as a Note (add message to thread)
    if (incomingActivity.notes?.[0]?.content) {
      await this.tools.plot.createNote({
        activity: { id: existingActivityId },
        content: incomingActivity.notes[0].content,
      });
    }
    return;
  }

  // New event - generate UUID and store mapping
  const activityId = Uuid.Generate();
  await this.set(mappingKey, activityId);

  // Create new Activity with initial Note (new thread with first message)
  await this.tools.plot.createActivity({
    ...incomingActivity,
    id: activityId,
  });
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
    notes: [
      {
        content: "Select the calendars you want to sync:",
        links,
      },
    ],
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

**Important**: Because Twists run in an ephemeral environment with limited requests per execution (~1000 requests), you must break long operations into batches. Each batch runs independently in a new execution context with its own fresh request limit.

### Key Principles

1. **Stay under request limits**: Each execution has ~1000 requests. Size batches accordingly.
2. **Use runTask() for fresh limits**: Each call to `this.runTask()` creates a NEW execution with fresh ~1000 requests
3. **Store state between batches**: Use the Store tool to persist progress
4. **Calculate safe batch sizes**: Determine requests per item to size batches (e.g., ~10 requests per item = ~100 items per batch)
5. **Clean up when done**: Delete stored state after completion
6. **Handle failures**: Store enough state to resume if a batch fails

### Example Implementation

```typescript
async startSync(resourceId: string): Promise<void> {
  // Initialize state in Store (persists between executions)
  await this.set(`sync_state_${resourceId}`, {
    nextPageToken: null,
    batchNumber: 1,
    itemsProcessed: 0,
    initialSync: true,  // Track whether this is the first sync
  });

  // Queue first batch using runTask method
  const callback = await this.callback(this.syncBatch, resourceId);
  // runTask creates NEW execution with fresh ~1000 request limit
  await this.runTask(callback);
}

async syncBatch(args: any, resourceId: string): Promise<void> {
  // Load state from Store (set by previous execution)
  const state = await this.get(`sync_state_${resourceId}`);

  // Process one batch (size to stay under ~1000 request limit)
  const result = await this.fetchBatch(state.nextPageToken);

  // Process results using source/key pattern (automatic upserts, no manual tracking)
  // If each item makes ~10 requests, keep batch size ≤ 100 items to stay under limit
  for (const item of result.items) {
    // Each createActivity may make ~5-10 requests depending on notes/links
    await this.tools.plot.createActivity({
      source: item.url, // Use item's canonical URL for automatic deduplication
      type: ActivityType.Note,
      title: item.title,
      notes: [{
        activity: { source: item.url },
        key: "description", // Use key for upsertable notes
        content: item.description,
      }],
      unread: !state.initialSync, // false for initial sync, true for incremental
      ...(state.initialSync ? { archived: false } : {}), // unarchive on initial only
    });
  }

  if (result.nextPageToken) {
    // Update state in Store for next batch
    await this.set(`sync_state_${resourceId}`, {
      nextPageToken: result.nextPageToken,
      batchNumber: state.batchNumber + 1,
      itemsProcessed: state.itemsProcessed + result.items.length,
      initialSync: state.initialSync, // Preserve initialSync flag across batches
    });

    // Queue next batch - creates NEW execution with fresh request limit
    const nextCallback = await this.callback(this.syncBatch, resourceId);
    await this.runTask(nextCallback);
  } else {
    // Cleanup when complete
    await this.clear(`sync_state_${resourceId}`);

    // Optionally notify user of completion
    await this.tools.plot.createActivity({
      type: ActivityType.Note,
      title: "Sync complete",
      notes: [
        {
          content: `Successfully processed ${state.itemsProcessed + result.items.length} items.`,
        },
      ],
    });
  }
}
```

## Activity Sync Best Practices

When syncing activities from external systems, follow these patterns for optimal user experience:

### The `initialSync` Flag

All sync-based tools should distinguish between initial sync (first import) and incremental sync (ongoing updates):

| Field | Initial Sync | Incremental Sync | Reason |
|-------|--------------|------------------|---------|
| `unread` | `false` | `true` | Avoid notification overload from historical items |
| `archived` | `false` | *omit* | Unarchive on install, preserve user choice on updates |

**Example:**
```typescript
const activity: NewActivity = {
  type: ActivityType.Event,
  source: event.url,
  title: event.title,
  unread: !initialSync,                      // false for initial, true for incremental
  ...(initialSync ? { archived: false } : {}),  // unarchive on initial only
};
```

**Why this matters:**
- **Initial sync**: Activities are unarchived and marked as read, preventing spam from bulk historical imports
- **Incremental sync**: New activities appear as unread, and archived state is preserved (respects user's archiving decisions)
- **Reinstall**: Acts as initial sync, so previously archived activities are unarchived (fresh start)

## Error Handling

Always handle errors gracefully and communicate them to users:

```typescript
try {
  await this.externalOperation();
} catch (error) {
  console.error("Operation failed:", error);

  await this.tools.plot.createActivity({
    type: ActivityType.Note,
    title: "Operation failed",
    notes: [
      {
        content: `Failed to complete operation: ${error.message}`,
      },
    ],
  });
}
```

## Common Pitfalls

- **Don't use instance variables for state** - Anything stored in memory is lost after function execution. Always use the Store tool for data that needs to persist.
- **Processing self-created activities** - Other users may change an Activity created by the twist, resulting in an \`activity\` call. Be sure to check the \`changes === null\` and/or \`activity.author.id !== this.id\` to avoid re-processing.
- **Always create Activities with Notes** - See "Understanding Activities and Notes" section above for the thread/message pattern and decision tree.
- **Use correct Activity types** - Most should be `ActivityType.Note`. Only use `Action` for tasks with `done`, and `Event` for items with `start`/`end`.
- **Use Activity.source and Note.key for automatic upserts (Recommended)** - Set Activity.source to the external item's URL for automatic deduplication. Only use UUID generation and storage for advanced cases (see SYNC_STRATEGIES.md).
- **Add Notes to existing Activities** - For source/key pattern, reference activities by source. For UUID pattern, look up stored mappings before creating new Activities. Think thread replies, not new threads.
- Tools are declared in the `build` method and accessed via `this.tools.toolName` in twist methods.
- **Don't forget request limits** - Each execution has ~1000 requests (HTTP requests, tool calls). Break long loops into batches with `this.runTask()` to get fresh request limits. Calculate requests per item to determine safe batch size (e.g., if each item needs ~10 requests, batch size = ~100 items).
- **Always use Callbacks tool for persistent references** - Direct function references don't survive worker restarts.
- **Store auth tokens** - Don't re-request authentication unnecessarily.
- **Clean up callbacks and stored state** - Delete callbacks and Store entries when no longer needed.
- **Handle missing auth gracefully** - Check for stored auth before operations.
- **CRITICAL: Maintain callback backward compatibility** - All callbacks (webhooks, tasks, batch operations) automatically upgrade to new twist versions. You **must** maintain backward compatibility in callback method signatures. Only add optional parameters at the end, never remove or reorder parameters. For breaking changes, implement migration logic in the `upgrade()` lifecycle method to recreate affected callbacks.

## Testing

Before deploying, verify:

1. Linting passes: `{{packageManager}} lint`
2. All dependencies are in package.json
3. Authentication flow works end-to-end
4. Batch operations handle pagination correctly
5. Error cases are handled gracefully
