---
title: Built-in Tools
group: Guides
---

# Built-in Tools

Plot provides a comprehensive set of built-in tools that give your twists powerful capabilities. This guide covers all built-in tools with detailed examples and best practices.

## Table of Contents

- [Plot](#plot) - Managing activities and priorities
- [Store](#store) - Persistent key-value storage
- [Integrations](#integrations) - OAuth authentication
- [Tasks](#tasks) - Background task execution
- [Network](#network) - HTTP access and webhooks
- [Callbacks](#callbacks) - Persistent function references
- [AI](#ai) - Language model integration

---

## Plot

The Plot tool is the core interface for creating and managing activities and priorities.

### Understanding Activities and Notes

**Activity** represents something done or to be done (a task, event, or conversation), while **Notes** represent the updates and details on that activity.

**Think of an Activity as a thread** on a messaging platform, and **Notes as the messages in that thread**. Always create activities with an initial note, and add notes to existing activities for updates rather than creating new activities.

### Setup

```typescript
import { Plot } from "@plotday/twister/tools/plot";

build(build: ToolBuilder) {
  return {
    plot: build(Plot),
  };
}
```

### Creating Activities

```typescript
import { ActivityLinkType, ActivityType } from "@plotday/twister";

// Create a note (thread with initial message)
await this.tools.plot.createActivity({
  type: ActivityType.Note,
  title: "Q1 Planning Meeting Notes",
  notes: [
    {
      content: "Discussed goals for Q1 and assigned action items.",
    },
  ],
});

// Create a task with a note containing links
const activityId = Uuid.Generate();
await this.tools.plot.createActivity({
  id: activityId,
  type: ActivityType.Action,
  title: "Review pull request #123",
  notes: [
    {
      id: Uuid.Generate(),
      content: "Please review the changes and provide feedback.",
      links: [
        {
          type: ActivityLinkType.external,
          title: "View PR",
          url: "https://github.com/org/repo/pull/123",
        },
      ],
    },
  ],
});

// Create an event with description in a note
await this.tools.plot.createActivity({
  id: Uuid.Generate(),
  type: ActivityType.Event,
  title: "Team standup",
  start: new Date("2025-02-01T10:00:00Z"),
  end: new Date("2025-02-01T10:30:00Z"),
  notes: [
    {
      id: Uuid.Generate(),
      content: "Daily standup meeting to sync on progress.",
    },
  ],
});
```

#### Action Scheduling States

When creating Actions (tasks), the `start` field determines their scheduling state. **Important:** Omitting `start` defaults to "Do Now" (current time). For most integrations, explicitly set `start: null` to create backlog items.

```typescript
// "Do Now" - Actionable today (DEFAULT - use sparingly!)
// Only use for tasks that are urgent or actively in progress
await this.tools.plot.createActivity({
  type: ActivityType.Action,
  title: "Fix production bug",
  notes: [{ content: "Critical issue affecting users" }],
  // Omitting start defaults to new Date() - becomes "Do Now"
});

// "Do Someday" - Backlog item (RECOMMENDED default for most synced tasks)
// Use for tasks from project management tools, backlog items, future work
await this.tools.plot.createActivity({
  type: ActivityType.Action,
  title: "Refactor user service",
  start: null, // Explicitly null for backlog
  source: "linear:issue:ABC-123",
  notes: [{ content: "Technical debt to address" }],
});

// "Do Later" - Scheduled for specific date
// Use when task has a concrete due date
await this.tools.plot.createActivity({
  type: ActivityType.Action,
  title: "Submit quarterly report",
  start: new Date("2025-03-31"), // Due date
  notes: [{ content: "Q1 report due end of March" }],
});
```

**Best practice for integrations:** Default to `start: null` for synced tasks, and only set `start` to current time if the task is explicitly marked as current/in-progress in the source system.

### Updating Activities

```typescript
// Mark task as done
await this.tools.plot.updateActivity(activity.id, {
  doneAt: new Date(),
});

// Update title and preview
await this.tools.plot.updateActivity(activity.id, {
  title: "Updated title",
  preview: "Additional information",
});

// Reschedule event
await this.tools.plot.updateActivity(activity.id, {
  start: new Date("2025-02-02T10:00:00Z"),
  end: new Date("2025-02-02T10:30:00Z"),
});
```

### Deleting Activities

```typescript
await this.tools.plot.deleteActivity(activity.id);
```

### Managing Priorities

```typescript
// Create a top-level priority
const work = await this.tools.plot.createPriority({
  title: "Work",
});

// Create a nested priority
const project = await this.tools.plot.createPriority({
  title: "Project A",
  parentId: work.id,
});
```

### Activity Meta and UUID Tracking

Use the `meta` field to store additional custom data and track external items using UUID mappings:

```typescript
// Generate UUID for the activity
const activityId = Uuid.Generate();

// Store mapping from external ID to Plot UUID
await this.set("pr_mapping:123", activityId);

await this.tools.plot.createActivity({
  id: activityId,
  type: ActivityType.Action,
  title: "Review PR",
  meta: {
    github_pr_id: "123",
    github_repo: "org/repo",
    review_status: "pending",
  },
  notes: [
    {
      id: Uuid.Generate(),
      content: "Please review this pull request.",
    },
  ],
});

// Later, find by looking up the mapping
const storedActivityId = await this.get<Uuid>("pr_mapping:123");
if (storedActivityId) {
  // Use the stored UUID to update or add notes
  await this.tools.plot.createNote({
    activity: { id: storedActivityId },
    content: "PR has been updated",
  });
}
```

### Creating and Managing Notes

#### Creating Notes on New Activities

**Best Practice:** Always create Activities with at least one initial Note containing detailed information. The `title` is a short summary that may be truncated—detailed content should go in Notes.

```typescript
// ✅ Recommended - Activity with initial Note (thread with first message)
const activityId = Uuid.Generate();
await this.set("ticket_mapping:12345", activityId); // Track for deduplication

await this.tools.plot.createActivity({
  id: activityId,
  type: ActivityType.Action,
  title: "Customer feedback: Login issues",
  notes: [
    {
      content: "Customer reported:\n\n\"I'm unable to log in using Google SSO. The page redirects but then shows an error 'Invalid state parameter'.\"\n\nPriority: High\nAffected users: ~15 reports",
      links: [
        {
          type: ActivityLinkType.external,
          title: "View Support Ticket",
          url: "https://support.example.com/tickets/12345",
        },
      ],
    },
  ],
});
```

#### Adding Notes to Existing Activities

**Best Practice:** For related content (email threads, chat conversations, workflows), add Notes to the existing Activity rather than creating new Activities. Think of it like adding a message to an existing thread.

```typescript
// Add a new Note to an existing Activity (add message to thread)
await this.tools.plot.createNote({
  activity: { id: activity.id },
  content: "Update: Engineering team has identified the root cause. Fix will be deployed in the next release.",
  links: [
    {
      type: ActivityLinkType.external,
      title: "View PR Fix",
      url: "https://github.com/org/repo/pull/789",
    },
  ],
});
```

#### Pattern: Email Threads and Conversations

Keep all messages in a thread or conversation within a single Activity. Think of it like a messaging app - one thread, many messages:

```typescript
async handleEmailThread(thread: EmailThread) {
  const mappingKey = `email_thread_mapping:${thread.id}`;

  // Check if Activity exists for this thread
  const existingActivityId = await this.get<Uuid>(mappingKey);

  if (existingActivityId) {
    // Add new messages as Notes to the existing thread
    for (const message of thread.newMessages) {
      await this.tools.plot.createNote({
        activity: { id: existingActivityId },
        id: Uuid.Generate(),
        content: message.body,
      });
    }
  } else {
    // Create new thread with initial messages
    const activityId = Uuid.Generate();
    await this.set(mappingKey, activityId);

    await this.tools.plot.createActivity({
      id: activityId,
      type: ActivityType.Note,
      title: thread.subject,
      notes: thread.messages.map((msg) => ({
        id: Uuid.Generate(),
        content: msg.body,
      })),
    });
  }
}
```

**Why this matters:** A conversation with 20 messages should be one Activity with 20 Notes, not 20 separate Activities. This keeps the workspace organized and provides better context.

---

## Store

Persistent key-value storage for twist state. Store methods are available directly on the twist class.

### Setup

Store is available automatically - no build() declaration needed!

### Storing Data

```typescript
// Save a string
await this.set("last_sync", new Date().toISOString());

// Save an object
await this.set("config", {
  enabled: true,
  interval: 3600,
});

// Save an array
await this.set("items", ["a", "b", "c"]);
```

### Retrieving Data

```typescript
// Get with type safety
const lastSync = await this.get<string>("last_sync");
const config = await this.get<{ enabled: boolean; interval: number }>("config");

// Handle missing data
const value = await this.get<string>("key");
if (value === null) {
  // Key doesn't exist
}
```

### Clearing Data

```typescript
// Clear a specific key
await this.clear("last_sync");

// Clear all data for this twist
await this.clearAll();
```

### Best Practices

#### Type Safety

Define interfaces for complex stored data:

```typescript
interface SyncState {
  lastSync: string;
  token: string;
  status: "active" | "paused";
}

async getSyncState(): Promise<SyncState | null> {
  return await this.get<SyncState>("sync_state");
}

async setSyncState(state: SyncState): Promise<void> {
  await this.set("sync_state", state);
}
```

#### Namespacing

Use prefixes to organize related data:

```typescript
await this.set("webhook:calendar", webhookUrl);
await this.set("webhook:github", githubWebhookUrl);
await this.set("config:sync_interval", 3600);
```

#### Serialization Limits

Remember: Values must be JSON-serializable. Functions, Symbols, and undefined values cannot be stored.

```typescript
// ❌ WRONG
await this.set("handler", this.myFunction); // Functions can't be stored

// ✅ CORRECT - Use callbacks instead
const token = await this.callback("myFunction");
await this.set("handler_token", token);
```

---

## Integrations

OAuth authentication for external services (Google, Microsoft, etc.).

### Setup

```typescript
import { Integrations } from "@plotday/twister/tools/integrations";

build(build: ToolBuilder) {
  return {
    integrations: build(Integrations),
  };
}
```

### Requesting Authentication

```typescript
import { AuthLevel, AuthProvider, type Authorization } from "@plotday/twister/tools/integrations";
import { ActivityLinkType } from "@plotday/twister";

async activate(priority: Pick<Priority, "id">) {
  // Create callback for auth completion
  const authCallback = await this.callback("onAuthComplete");

  // Request Google auth
  const authLink = await this.tools.integrations.request(
    {
      provider: AuthProvider.Google,
      level: AuthLevel.User,
      scopes: [
        "https://www.googleapis.com/auth/calendar.readonly"
      ]
    },
    authCallback
  );

  // Create activity with auth link in a note
  await this.tools.plot.createActivity({
    type: ActivityType.Note,
    title: "Connect your Google Calendar",
    notes: [
      {
        note: "Click below to connect your Google account",
        links: [
          {
            type: ActivityLinkType.auth,
            title: "Connect Google",
            url: authLink,
          },
        ],
      },
    ],
  });
}

// Handle auth completion
async onAuthComplete(authorization: Authorization) {
  // Get access token
  const authToken = await this.tools.integrations.get(authorization);

  if (authToken) {
    console.log("Access token:", authToken.token);
    await this.set("google_auth", authorization);

    // Start syncing
    await this.startSync();
  }
}
```

### Auth Providers

- **AuthProvider.Google** - Google services
- **AuthProvider.Microsoft** - Microsoft services

### Auth Levels

- **AuthLevel.Priority** - Auth scoped to the current priority
- **AuthLevel.User** - Auth scoped to the user across all priorities

### Using Auth Tokens

```typescript
// Retrieve saved authorization
const authorization = await this.get<Authorization>("google_auth");

if (authorization) {
  const authToken = await this.tools.integrations.get(authorization);

  // Use token with external API
  const response = await fetch(
    "https://www.googleapis.com/calendar/v3/calendars/primary/events",
    {
      headers: {
        Authorization: `Bearer ${authToken.token}`,
      },
    }
  );
}
```

---

## Tasks

Queue background tasks and schedule operations. Tasks methods are available directly on the twist class.

### Setup

Tasks are available automatically - no build() declaration needed!

### Running Tasks Immediately

```typescript
// Create a callback
const callback = await this.callback("processData", { batchId: 1 });

// Run immediately
await this.runTask(callback);

// The processData method will be called
async processData(args: any, context: { batchId: number }) {
  console.log("Processing batch:", context.batchId);
}
```

### Scheduling Tasks

```typescript
// Schedule for a specific time
const reminderCallback = await this.callback("sendReminder", {
  userId: "123",
  message: "Meeting in 10 minutes",
});

const token = await this.runTask(reminderCallback, {
  runAt: new Date("2025-02-01T09:50:00Z"),
});

// Save token to cancel later if needed
await this.set("reminder_token", token);
```

### Canceling Tasks

```typescript
// Cancel a specific task
const token = await this.get<string>("reminder_token");
if (token) {
  await this.cancelTask(token);
}

// Cancel all scheduled tasks for this twist
await this.cancelAllTasks();
```

### Batch Processing Pattern

Use tasks to break long operations into manageable chunks:

```typescript
async startSync() {
  // Initialize state
  await this.set("sync_state", {
    page: 1,
    hasMore: true
  });

  // Start first batch
  const callback = await this.callback("syncBatch");
  await this.runTask(callback);
}

async syncBatch() {
  const state = await this.get<{ page: number; hasMore: boolean }>("sync_state");
  if (!state || !state.hasMore) return;

  // Process one page
  const results = await this.fetchPage(state.page);
  await this.processResults(results);

  // Check if more work remains
  if (results.hasMore) {
    await this.set("sync_state", {
      page: state.page + 1,
      hasMore: true
    });

    // Queue next batch
    const callback = await this.callback("syncBatch");
    await this.runTask(callback);
  } else {
    await this.set("sync_state", { page: state.page, hasMore: false });
  }
}
```

See [Runtime Environment](RUNTIME.md) for more about handling long operations.

---

## Network

Request HTTP access and create webhook endpoints for real-time notifications.

### Setup

```typescript
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";

build(build: ToolBuilder) {
  return {
    network: build(Network, {
      // Declare which URLs you'll access
      urls: ['https://api.example.com/*']
    })
  };
}
```

### Making HTTP Requests

Once declared in the `urls` array, you can use fetch() normally:

```typescript
async fetchData() {
  const response = await fetch("https://api.example.com/data", {
    headers: {
      Authorization: `Bearer ${token}`
    }
  });

  return await response.json();
}
```

### Creating Webhooks

```typescript
async activate(priority: Pick<Priority, "id">) {
  // Create webhook endpoint
  const webhookUrl = await this.tools.network.createWebhook(
    "onCalendarUpdate",
    { calendarId: "primary" }
  );

  // Save for cleanup later
  await this.set("webhook_url", webhookUrl);

  // Register with external service
  await fetch("https://api.service.com/webhooks", {
    method: "POST",
    body: JSON.stringify({ url: webhookUrl })
  });
}

// Handle webhook requests
async onCalendarUpdate(request: WebhookRequest, context: { calendarId: string }) {
  console.log("Webhook received:", request.method);
  console.log("Body:", request.body);
  console.log("Calendar:", context.calendarId);

  // Process the webhook
  if (request.body.type === "event.created") {
    await this.syncEvent(request.body.event);
  }
}
```

### Deleting Webhooks

```typescript
async deactivate() {
  const webhookUrl = await this.get<string>("webhook_url");

  if (webhookUrl) {
    // Unregister from external service
    await fetch("https://api.service.com/webhooks", {
      method: "DELETE",
      body: JSON.stringify({ url: webhookUrl })
    });

    // Delete webhook endpoint
    await this.tools.network.deleteWebhook(webhookUrl);
  }
}
```

---

## Callbacks

Create persistent function references that survive worker restarts. Callbacks methods are available directly on the twist class.

### Setup

Callbacks are available automatically - no build() declaration needed!

### Creating Callbacks

```typescript
// Create a callback to a method
const callback = await this.callback("handleEvent", {
  eventType: "calendar_sync",
  priority: "high",
});

// Save it for later use
await this.set("event_handler", callback);
```

### Executing Callbacks

```typescript
// Retrieve saved callback
const callback = await this.get<string>("event_handler");

if (callback) {
  // Execute with additional arguments
  const result = await this.run(callback, {
    data: eventData,
    timestamp: new Date(),
  });
}
```

### Method Signature

The callback method receives both the execution args and the original context:

```typescript
async handleEvent(
  args: { data: any; timestamp: Date },      // From run()
  context: { eventType: string; priority: string }  // From callback()
) {
  console.log("Event type:", context.eventType);
  console.log("Priority:", context.priority);
  console.log("Data:", args.data);
}
```

### Deleting Callbacks

```typescript
// Delete a specific callback
const callback = await this.get<string>("event_handler");
if (callback) {
  await this.deleteCallback(callback);
}

// Delete all callbacks for this twist
await this.deleteAllCallbacks();
```

### Use Cases

Callbacks are essential for:

- **Webhooks** - Persistent handlers that survive restarts
- **Auth flows** - Handling OAuth completion
- **Scheduled tasks** - Functions to run at specific times
- **Activity links** - Interactive buttons in activities

---

## AI

Prompt large language models with support for structured output and tool calling.

### Setup

```typescript
import { AI } from "@plotday/twister/tools/ai";

build(build: ToolBuilder) {
  return {
    ai: build(AI),
  };
}
```

### Simple Text Generation

```typescript
const response = await this.tools.ai.prompt({
  model: { speed: "fast", cost: "low" },
  prompt: "Explain quantum computing in simple terms",
});

console.log(response.text);
```

### Structured Output

Use Typebox schemas to get type-safe structured responses:

```typescript
import { Type } from "typebox";

const schema = Type.Object({
  category: Type.Union([
    Type.Literal("work"),
    Type.Literal("personal"),
    Type.Literal("urgent"),
  ]),
  priority: Type.Number({ minimum: 1, maximum: 5 }),
  summary: Type.String({ description: "Brief summary" }),
});

const response = await this.tools.ai.prompt({
  model: { speed: "balanced", cost: "medium" },
  prompt: "Categorize this email: Meeting at 3pm tomorrow about Q1 planning",
  outputSchema: schema,
});

// Fully typed output!
console.log(response.output.category); // "work" | "personal" | "urgent"
console.log(response.output.priority); // number (1-5)
console.log(response.output.summary); // string
```

### Tool Calling

Give the AI access to tools it can call:

```typescript
import { Type } from "typebox";

const response = await this.tools.ai.prompt({
  model: { speed: "fast", cost: "medium" },
  prompt: "What's 15% of $250?",
  tools: {
    calculate: {
      description: "Perform mathematical calculations",
      parameters: Type.Object({
        expression: Type.String({ description: "Math expression to evaluate" }),
      }),
      execute: async ({ expression }) => {
        return { result: eval(expression) };
      },
    },
  },
});

console.log(response.text); // "15% of $250 is $37.50"
```

### Multi-turn Conversations

Build conversations with message history:

```typescript
import { Type } from "typebox";

const messages = [
  {
    role: "user" as const,
    content: "What's the weather like?",
  },
  {
    role: "assistant" as const,
    content:
      "I don't have access to weather data. Would you like me to help with something else?",
  },
  {
    role: "user" as const,
    content: "What's 2+2?",
  },
];

const response = await this.tools.ai.prompt({
  model: { speed: "fast", cost: "low" },
  messages,
});
```

### Model Selection

Specify your requirements using speed and cost tiers:

```typescript
// Fast and cheap - Good for simple tasks
model: { speed: "fast", cost: "low" }

// Balanced - Good for most tasks
model: { speed: "balanced", cost: "medium" }

// Most capable - Complex reasoning
model: { speed: "capable", cost: "high" }
```

Plot automatically selects the best available model matching your preferences.

### Typebox Schemas

Typebox provides JSON Schema with full TypeScript type inference:

```typescript
import { Type } from "typebox";

// Objects
const PersonSchema = Type.Object({
  name: Type.String(),
  age: Type.Number(),
  email: Type.Optional(Type.String({ format: "email" })),
});

// Arrays
const PeopleSchema = Type.Array(PersonSchema);

// Unions (enums)
const StatusSchema = Type.Union([
  Type.Literal("pending"),
  Type.Literal("active"),
  Type.Literal("completed"),
]);

// Nested objects
const ProjectSchema = Type.Object({
  title: Type.String(),
  status: StatusSchema,
  assignees: Type.Array(PersonSchema),
});
```

See the [Typebox documentation](https://github.com/sinclairzx81/typebox) for more schema types.

### Real-World Example: Email Triage

```typescript
import { Type } from "typebox";

async triageEmail(emailContent: string) {
  const schema = Type.Object({
    category: Type.Union([
      Type.Literal("urgent"),
      Type.Literal("important"),
      Type.Literal("informational"),
      Type.Literal("spam")
    ]),
    requiresResponse: Type.Boolean(),
    suggestedActions: Type.Array(Type.String()),
    summary: Type.String({ maxLength: 200 })
  });

  const response = await this.tools.ai.prompt({
    model: { speed: "balanced", cost: "medium" },
    prompt: `Analyze this email and provide triage information:\n\n${emailContent}`,
    outputSchema: schema
  });

  // Create activity based on triage
  if (response.output.category === "urgent") {
    await this.tools.plot.createActivity({
      type: ActivityType.Action,
      title: `URGENT: ${response.output.summary}`,
      notes: [
        {
          note: `Actions:\n${response.output.suggestedActions.join("\n")}`,
        },
      ],
    });
  }
}
```

---

## Next Steps

- **[Building Custom Tools](BUILDING_TOOLS.md)** - Create your own reusable tools
- **[Runtime Environment](RUNTIME.md)** - Understanding execution constraints
- **API Reference** - Explore detailed API docs in the sidebar
