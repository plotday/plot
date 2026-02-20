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
  type NewActivityWithNotes,
  type ActivityFilter,
  type Priority,
  type ToolBuilder,
  Twist,
  ActivityType,
} from "@plotday/twister";
import { ActivityAccess, Plot } from "@plotday/twister/tools/plot";
// Import your tools:
// import { GoogleCalendar } from "@plotday/tool-google-calendar";
// import { Linear } from "@plotday/tool-linear";

export default class MyTwist extends Twist<MyTwist> {
  build(build: ToolBuilder) {
    return {
      // myTool: build(MyTool, {
      //   onItem: this.handleItem,
      //   onSyncableDisabled: this.onSyncableDisabled,
      // }),
      plot: build(Plot, {
        activity: { access: ActivityAccess.Create },
      }),
    };
  }

  async activate(_priority: Pick<Priority, "id">) {
    // Auth and resource selection handled in the twist edit modal.
  }

  async handleItem(activity: NewActivityWithNotes): Promise<void> {
    await this.tools.plot.createActivity(activity);
  }

  async onSyncableDisabled(filter: ActivityFilter): Promise<void> {
    await this.tools.plot.updateActivity({ match: filter, archived: true });
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

#### Available External Tools

- `@plotday/tool-google-calendar`: Google Calendar sync (CalendarTool)
- `@plotday/tool-outlook-calendar`: Outlook Calendar sync (CalendarTool)
- `@plotday/tool-google-contacts`: Google Contacts sync (supporting tool)
- `@plotday/tool-google-drive`: Google Drive sync (DocumentTool)
- `@plotday/tool-gmail`: Gmail sync (MessagingTool)
- `@plotday/tool-slack`: Slack sync (MessagingTool)
- `@plotday/tool-linear`: Linear sync (ProjectTool)
- `@plotday/tool-jira`: Jira sync (ProjectTool)
- `@plotday/tool-asana`: Asana sync (ProjectTool)

## Lifecycle Methods

### activate(priority: Pick<Priority, "id">)

Called when the twist is enabled for a priority. Auth and resource selection are handled automatically via the twist edit modal when using external tools with Integrations.

Most twists have an empty or minimal `activate()`:

```typescript
async activate(_priority: Pick<Priority, "id">) {
  // Auth and resource selection are handled in the twist edit modal.
  // Only add custom initialization here if needed.
}
```

**Store Parent Activity for Later (optional):**

```typescript
async activate(_priority: Pick<Priority, "id">) {
  const activityId = await this.tools.plot.createActivity({
    type: ActivityType.Note,
    title: "Setup complete",
    notes: [{
      content: "Your twist is ready. Activities will appear as they sync.",
    }],
  });
  await this.set("setup_activity_id", activityId);
}
```

### Event Callbacks (via build options)

Twists respond to events through callbacks declared in `build()`:

**Receive synced items from a tool (most common):**

```typescript
build(build: ToolBuilder) {
  return {
    myTool: build(MyTool, {
      onItem: this.handleItem,
      onSyncableDisabled: this.onSyncableDisabled,
    }),
    plot: build(Plot, { activity: { access: ActivityAccess.Create } }),
  };
}

async handleItem(activity: NewActivityWithNotes): Promise<void> {
  await this.tools.plot.createActivity(activity);
}

async onSyncableDisabled(filter: ActivityFilter): Promise<void> {
  await this.tools.plot.updateActivity({ match: filter, archived: true });
}
```

**React to activity changes (for two-way sync):**

```typescript
plot: build(Plot, {
  activity: {
    access: ActivityAccess.Create,
    updated: this.onActivityUpdated,
  },
  note: {
    created: this.onNoteCreated,
  },
}),

async onActivityUpdated(activity: Activity, changes: { tagsAdded, tagsRemoved }): Promise<void> {
  const tool = this.getToolForActivity(activity);
  if (tool?.updateIssue) await tool.updateIssue(activity);
}

async onNoteCreated(note: Note): Promise<void> {
  if (note.author.type === ActorType.Twist) return; // Prevent loops
  // Sync note to external service as a comment
}
```

**Respond to mentions (AI twist pattern):**

```typescript
plot: build(Plot, {
  activity: { access: ActivityAccess.Respond },
  note: {
    intents: [{
      description: "Respond to general questions",
      examples: ["What's the weather?", "Help me plan my week"],
      handler: this.respond,
    }],
  },
}),
```

## Activity Links

Activity links enable user interaction:

```typescript
import { type ActivityLink, ActivityLinkType } from "@plotday/twister";

// External URL link
const urlLink: ActivityLink = {
  title: "Open website",
  type: ActivityLinkType.external,
  url: "https://example.com",
};

// Callback link (uses Callbacks tool — use linkCallback, not callback)
const token = await this.linkCallback(this.onLinkClicked, "context");
const callbackLink: ActivityLink = {
  title: "Click me",
  type: ActivityLinkType.callback,
  callback: token,
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

// Callback handler receives the ActivityLink as first argument
async onLinkClicked(link: ActivityLink, context: string): Promise<void> {
  // Handle link click
}
```

## Authentication Pattern

Auth is handled automatically via the Integrations tool. Tools declare their OAuth provider in `build()`, and users connect in the twist edit modal. **You do not need to create auth activities manually.**

```typescript
// In your tool's build() method:
build(build: ToolBuilder) {
  return {
    integrations: build(Integrations, {
      providers: [{
        provider: AuthProvider.Google,
        scopes: ["https://www.googleapis.com/auth/calendar"],
        getSyncables: this.getSyncables,      // List available resources after auth
        onSyncEnabled: this.onSyncEnabled,    // User enabled a resource
        onSyncDisabled: this.onSyncDisabled,  // User disabled a resource
      }],
    }),
    // ...
  };
}

// Get a token for API calls:
const token = await this.tools.integrations.get(AuthProvider.Google, syncableId);
if (!token) throw new Error("No auth token available");
const client = new ApiClient({ accessToken: token.token });
```

For per-user write-backs (e.g., RSVP, comments attributed to the acting user):

```typescript
await this.tools.integrations.actAs(
  AuthProvider.Google,
  actorId,       // The user who performed the action
  activityId,    // Activity to prompt for auth if needed
  this.performWriteBack,
  ...extraArgs
);
```

## Sync Pattern

### Recommended: Using External Tools with SyncToolOptions

Most twists use external tools (CalendarTool, ProjectTool, etc.) that handle sync internally. The twist just receives `NewActivityWithNotes` objects and saves them:

```typescript
build(build: ToolBuilder) {
  return {
    calendarTool: build(GoogleCalendar, {
      onItem: this.handleEvent,                     // Receives synced items
      onSyncableDisabled: this.onSyncableDisabled,  // Clean up when disabled
    }),
    plot: build(Plot, { activity: { access: ActivityAccess.Create } }),
  };
}

// Tools deliver NewActivityWithNotes — twist saves them
async handleEvent(activity: NewActivityWithNotes): Promise<void> {
  await this.tools.plot.createActivity(activity);
}

async onSyncableDisabled(filter: ActivityFilter): Promise<void> {
  await this.tools.plot.updateActivity({ match: filter, archived: true });
}
```

### Custom Sync: Upsert via Source/Key (Strategy 2)

For direct API integration without an external tool, use source/key for automatic upserts:

```typescript
async handleEvent(event: ExternalEvent): Promise<void> {
  const activity: NewActivityWithNotes = {
    source: event.htmlLink,  // Canonical URL for automatic deduplication
    type: ActivityType.Event,
    title: event.summary || "(No title)",
    start: event.start?.dateTime || event.start?.date || null,
    end: event.end?.dateTime || event.end?.date || null,
    notes: [],
  };

  if (event.description) {
    activity.notes.push({
      activity: { source: event.htmlLink },
      key: "description",  // This key enables note-level upserts
      content: event.description,
    });
  }

  // Create or update — Plot handles deduplication automatically
  await this.tools.plot.createActivity(activity);
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

## Resource Selection

Resource selection (calendars, projects, channels) is handled automatically in the twist edit modal via the Integrations tool. Users see a list of available resources returned by your tool's `getSyncables()` method and toggle them on/off. You do **not** need to build custom selection UI.

```typescript
// In your tool:
async getSyncables(_auth: Authorization, token: AuthToken): Promise<Syncable[]> {
  const client = new ApiClient({ accessToken: token.token });
  const calendars = await client.listCalendars();
  return calendars.map(c => ({
    id: c.id,
    title: c.name,
    children: c.subCalendars?.map(sc => ({ id: sc.id, title: sc.name })),
  }));
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

async syncBatch(resourceId: string): Promise<void> {
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
      ...(state.initialSync ? { unread: false } : {}), // false for initial, omit for incremental
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
| `unread` | `false` | *omit* | Initial: mark read for all. Incremental: auto-mark read for author only |
| `archived` | `false` | *omit* | Unarchive on install, preserve user choice on updates |

**Example:**
```typescript
const activity: NewActivity = {
  type: ActivityType.Event,
  source: event.url,
  title: event.title,
  ...(initialSync ? { unread: false } : {}),     // false for initial, omit for incremental
  ...(initialSync ? { archived: false } : {}),    // unarchive on initial only
};
```

**Why this matters:**
- **Initial sync**: Activities are unarchived and marked as read for all users, preventing spam from bulk historical imports
- **Incremental sync**: Activities are auto-marked read for the author (twist owner), unread for everyone else. Archived state is preserved
- **Reinstall**: Acts as initial sync, so previously archived activities are unarchived (fresh start)

### Two-Way Sync: Avoiding Race Conditions

When implementing two-way sync where items created in Plot are pushed to an external system (e.g. Notes becoming comments), a race condition can occur: the external system may send a webhook for the newly created item before you've updated the Activity/Note with the external key. The webhook handler won't find the item by external key and may create a duplicate.

**Solution:** Embed the Plot `Activity.id` / `Note.id` in the external item's metadata when creating it, and update `Activity.source` / `Note.key` after creation. When processing webhooks, check for the Plot ID in metadata first.

```typescript
async pushNoteAsComment(note: Note, externalItemId: string): Promise<void> {
  // Create external item with Plot ID in metadata for webhook correlation
  const externalComment = await externalApi.createComment(externalItemId, {
    body: note.content,
    metadata: { plotNoteId: note.id },
  });

  // Update Note with external key AFTER creation
  // A webhook may arrive before this completes — that's OK (see onWebhook below)
  await this.tools.plot.updateNote({
    id: note.id,
    key: `comment-${externalComment.id}`,
  });
}

async onWebhook(payload: WebhookPayload): Promise<void> {
  const comment = payload.comment;

  // Use Plot ID from metadata if present (handles race condition),
  // otherwise fall back to upserting by activity source and key
  await this.tools.plot.createNote({
    ...(comment.metadata?.plotNoteId
      ? { id: comment.metadata.plotNoteId }
      : { activity: { source: payload.itemUrl } }),
    key: `comment-${comment.id}`,
    content: comment.body,
  });
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
