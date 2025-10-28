---
title: Core Concepts
group: Guides
---

# Core Concepts

Understanding these core concepts will help you build effective Plot agents.

## Table of Contents

- [Agents](#agents)
- [Tools](#tools)
- [Priorities](#priorities)
- [Activities](#activities)
- [Lifecycle Methods](#lifecycle-methods)
- [Best Practices](#best-practices)

---

## Agents

Agents are the core building blocks of Plot automation. They implement integrations and automations that help organize and prioritize your work.

### What is an Agent?

An agent is a class that:

- Extends the `Agent<T>` base class
- Declares tool dependencies in the `build()` method
- Responds to lifecycle events (`activate`, `deactivate`, `upgrade`)
- Can process activities and create new ones

### Agent Anatomy

```typescript
import { Agent, type Priority, type ToolBuilder } from "@plotday/agent";
import { Plot } from "@plotday/agent/tools/plot";

export default class MyAgent extends Agent<MyAgent> {
  // 1. Declare dependencies
  build(build: ToolBuilder) {
    return {
      plot: build(Plot),
    };
  }

  // 2. Initialize on activation
  async activate(priority: Pick<Priority, "id">) {
    // Setup code - runs once when agent is added to a priority
  }

  // 3. Handle lifecycle events
  async upgrade() {
    // Runs when a new version is deployed
  }

  async deactivate() {
    // Cleanup - runs when agent is removed
  }
}
```

### When to Use Agents

Use agents for:

- **Integrations** - Connecting external services (Google Calendar, GitHub, Slack)
- **Automations** - Automatic task creation, reminders, status updates
- **Data Processing** - Analyzing and organizing activities
- **Notifications** - Sending alerts based on conditions

---

## Tools

Tools provide functionality to agents. They encapsulate reusable capabilities and can be composed together.

### Types of Tools

#### 1. Built-in Tools

Core Plot functionality provided by the Builder:

- **Plot** - Create and manage activities and priorities
- **Store** - Persistent key-value storage
- **Integrations** - OAuth authentication
- **Tasks** - Background task execution
- **Network** - HTTP access and webhooks
- **Callbacks** - Persistent function references
- **AI** - Language model integration

See the [Built-in Tools Guide](TOOLS_GUIDE.md) for complete documentation.

#### 2. Custom Tools

Tools you create or install from npm packages:

- **External Service Integrations** - Google Calendar, Slack, GitHub
- **Data Processors** - Text analysis, image processing
- **Utilities** - Date formatting, validation

See [Building Custom Tools](BUILDING_TOOLS.md) to create your own.

### Declaring Tool Dependencies

Use the `build()` method to declare which tools your agent needs:

```typescript
build(build: ToolBuilder) {
  return {
    plot: build(Plot),
    store: build(Store),
    calendar: build(GoogleCalendar, {
      // Tool-specific options
      defaultCalendar: "primary"
    }),
  };
}
```

### Accessing Tools

Access your tools via `this.tools`:

```typescript
async activate(priority: Pick<Priority, "id">) {
  // Tools are fully typed
  await this.tools.plot.createActivity({
    type: ActivityType.Note,
    title: "Hello from my agent"
  });
}
```

### Direct Access Methods

Some tool methods are available directly on the Agent class for convenience:

```typescript
// Store
await this.get("key");
await this.set("key", value);
await this.clear("key");

// Tasks
await this.runTask(callback);
await this.cancelTask(token);

// Callbacks
await this.callback("methodName", ...args);
await this.run(callbackToken);
```

---

## Priorities

Priorities are contexts that organize activities. Think of them like projects or focus areas.

### Priority Hierarchy

Priorities can be nested to create hierarchies:

```
Work
├── Project A
│   ├── Backend
│   └── Frontend
└── Project B
```

### Creating Priorities

```typescript
// Top-level priority
const work = await this.tools.plot.createPriority({
  title: "Work",
});

// Nested priority
const projectA = await this.tools.plot.createPriority({
  title: "Project A",
  parentId: work.id,
});
```

### Agent Activation

Agents are activated within a specific priority. When activated, the agent has access to that priority and all its children.

```typescript
async activate(priority: Pick<Priority, "id">) {
  // This agent is now active for this priority
  // It can create activities, set up webhooks, etc.
}
```

---

## Activities

Activities are the core data type in Plot, representing tasks, events, and notes.

### Activity Types

- **Note** - Information without actionable requirements
- **Task** - Actionable items that can be completed
- **Event** - Scheduled occurrences with start/end times

```typescript
import { ActivityType } from "@plotday/agent";

// Note
await this.tools.plot.createActivity({
  type: ActivityType.Note,
  title: "Meeting notes from sync",
});

// Task
await this.tools.plot.createActivity({
  type: ActivityType.Task,
  title: "Review pull request",
  doneAt: null, // null = not done
});

// Event
await this.tools.plot.createActivity({
  type: ActivityType.Event,
  title: "Team standup",
  start: new Date("2025-02-01T10:00:00Z"),
  end: new Date("2025-02-01T10:30:00Z"),
});
```

### Activity Properties

```typescript
type Activity = {
  id: string; // Unique identifier
  type: ActivityType; // Note, Task, or Event
  title: string | null; // Display title
  note: string | null; // Additional details
  start: Date | null; // Event start time
  end: Date | null; // Event end time
  doneAt: Date | null; // Task completion time
  links: ActivityLink[]; // Action links
  tags: Record<Tag, ActorId[]>; // Tag assignments
  // ... and more
};
```

### Activity Links

Links enable user interaction with activities:

```typescript
import { ActivityLinkType } from "@plotday/agent";

await this.tools.plot.createActivity({
  type: ActivityType.Task,
  title: "Fix bug #123",
  links: [
    {
      type: ActivityLinkType.external,
      title: "View Issue",
      url: "https://github.com/org/repo/issues/123",
    },
    {
      type: ActivityLinkType.callback,
      title: "Mark as Fixed",
      callback: await this.callback("markAsFixed", "123"),
    },
  ],
});
```

**Link Types:**

- **external** - Opens URL in browser
- **auth** - Initiates OAuth flow
- **hidden** - Not visible to users (for tracking)
- **callback** - Triggers agent method when clicked

---

## Lifecycle Methods

Agents have several lifecycle methods that are called at specific times.

### activate(priority)

Called when the agent is first activated for a priority.

**Use for:**

- Creating initial activities
- Setting up webhooks
- Initializing state
- Requesting authentication

```typescript
async activate(priority: Pick<Priority, "id">) {
  // Create welcome message
  await this.tools.plot.createActivity({
    type: ActivityType.Note,
    title: "Calendar sync is now active"
  });

  // Set up webhook
  const webhookUrl = await this.tools.network.createWebhook("onUpdate");
  await this.set("webhook_url", webhookUrl);
}
```

### upgrade()

Called when a new version of your agent is deployed to an existing priority.

**Use for:**

- Migrating data structures
- Updating webhook configurations
- Adding new features to existing installations

```typescript
async upgrade() {
  // Check version and migrate
  const version = await this.get<string>("version");

  if (!version || version < "2.0.0") {
    // Migrate old data format
    const oldData = await this.get("old_key");
    await this.set("new_key", transformData(oldData));
    await this.clear("old_key");
  }

  await this.set("version", "2.0.0");
}
```

### deactivate()

Called when the agent is removed from a priority.

**Use for:**

- Removing webhooks
- Cleanup of external resources
- Final data operations

```typescript
async deactivate() {
  // Clean up webhook
  const webhookUrl = await this.get<string>("webhook_url");
  if (webhookUrl) {
    await this.tools.network.deleteWebhook(webhookUrl);
  }

  // Clean up stored data
  await this.clearAll();
}
```

---

## Best Practices

### 1. State Management

Use the Store tool for persistent state, not instance variables:

```typescript
// ❌ WRONG - Instance variables don't persist
class MyAgent extends Agent<MyAgent> {
  private syncToken: string;  // This will be lost!
}

// ✅ CORRECT - Use Store
class MyAgent extends Agent<MyAgent> {
  async getSyncToken() {
    return await this.get<string>("sync_token");
  }

  async setSyncToken(token: string) {
    await this.set("sync_token", token);
  }
}
```

### 2. Error Handling

Always handle errors gracefully:

```typescript
async activate(priority: Pick<Priority, "id">) {
  try {
    await this.tools.plot.createActivity({
      type: ActivityType.Note,
      title: "Agent activated"
    });
  } catch (error) {
    console.error("Failed to create activity:", error);
    // Agent activation continues even if this fails
  }
}
```

### 3. Batch Long Operations

Break long-running operations into batches:

```typescript
async startSync() {
  const callback = await this.callback("syncBatch", { page: 1 });
  await this.runTask(callback);
}

async syncBatch(args: any, context: { page: number }) {
  // Process one page
  const hasMore = await processPage(context.page);

  if (hasMore) {
    // Queue next batch
    const callback = await this.callback("syncBatch", {
      page: context.page + 1
    });
    await this.runTask(callback);
  }
}
```

See [Runtime Environment](RUNTIME.md) for more details.

### 4. Type Safety

Leverage TypeScript for type safety:

```typescript
// Define interfaces for stored data
interface SyncState {
  lastSync: string;
  token: string;
  status: "active" | "paused";
}

async getSyncState(): Promise<SyncState | null> {
  return await this.get<SyncState>("sync_state");
}
```

### 5. Tool Composition

Build complex functionality by composing tools:

```typescript
build(build: ToolBuilder) {
  return {
    plot: build(Plot),
    network: build(Network, {
      urls: ["https://api.service.com/*"]
    }),
    auth: build(Integrations),
    ai: build(AI)
  };
}
```

### 6. Clear Activity Titles

Make activity titles clear and actionable:

```typescript
// ❌ Vague
await this.tools.plot.createActivity({
  type: ActivityType.Task,
  title: "Thing",
});

// ✅ Clear
await this.tools.plot.createActivity({
  type: ActivityType.Task,
  title: "Review pull request #123 for authentication fix",
});
```

---

## Next Steps

- **[Built-in Tools Guide](TOOLS_GUIDE.md)** - Learn about Plot, Store, AI, and more
- **[Building Custom Tools](BUILDING_TOOLS.md)** - Create reusable tools
- **[Runtime Environment](RUNTIME.md)** - Understand execution constraints
- **[Advanced Topics](ADVANCED.md)** - Complex patterns and techniques
