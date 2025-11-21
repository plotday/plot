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

// Create a note
await this.tools.plot.createActivity({
  type: ActivityType.Note,
  title: "Meeting notes",
  note: "Discussed Q1 planning",
});

// Create a task
await this.tools.plot.createActivity({
  type: ActivityType.Action,
  title: "Review pull request #123",
  links: [
    {
      type: ActivityLinkType.external,
      title: "View PR",
      url: "https://github.com/org/repo/pull/123",
    },
  ],
});

// Create an event
await this.tools.plot.createActivity({
  type: ActivityType.Event,
  title: "Team standup",
  start: new Date("2025-02-01T10:00:00Z"),
  end: new Date("2025-02-01T10:30:00Z"),
});
```

### Updating Activities

```typescript
// Mark task as done
await this.tools.plot.updateActivity(activity.id, {
  doneAt: new Date(),
});

// Update title and note
await this.tools.plot.updateActivity(activity.id, {
  title: "Updated title",
  note: "Additional information",
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

### Activity Meta

Use meta fields to store custom data and link external resources:

```typescript
await this.tools.plot.createActivity({
  type: ActivityType.Action,
  title: "Review PR",
  meta: {
    github_pr_id: "123",
    github_repo: "org/repo",
    review_status: "pending",
  },
});

// Later, find by meta
const activity = await this.tools.plot.getActivityByMeta({
  github_pr_id: "123",
});
```

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

  // Create activity with auth link
  await this.tools.plot.createActivity({
    type: ActivityType.Note,
    title: "Connect your Google Calendar",
    links: [{
      type: ActivityLinkType.auth,
      title: "Connect Google",
      url: authLink
    }]
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
      note: `Actions:\n${response.output.suggestedActions.join("\n")}`
    });
  }
}
```

---

## Next Steps

- **[Building Custom Tools](BUILDING_TOOLS.md)** - Create your own reusable tools
- **[Runtime Environment](RUNTIME.md)** - Understanding execution constraints
- **[Advanced Topics](ADVANCED.md)** - Complex patterns and techniques
- **API Reference** - Explore detailed API docs in the sidebar
