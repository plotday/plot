---
title: Core Concepts
group: Guides
---

# Core Concepts

Understanding these core concepts will help you build effective Plot Twists.

## Table of Contents

- [Twists](#twists)
- [Twist Tools](#twist-tools)
- [Priorities](#priorities)
- [Activities](#activities)
- [Lifecycle Methods](#lifecycle-methods)
- [Best Practices](#best-practices)

---

## Twists

Twists are smart automations that connect, organize, and prioritize your work. They implement opinionated workflows and integrations.

### What is a Twist?

A twist is a class that:

- Extends the `Twist<T>` base class
- Declares tool dependencies in the `build()` method
- Responds to lifecycle events (`activate`, `deactivate`, `upgrade`)
- Can process activities and create new ones

### Twist Anatomy

```typescript
import { type Priority, type ToolBuilder, Twist } from "@plotday/twister";
import { Plot } from "@plotday/twister/tools/plot";

export default class MyTwist extends Twist<MyTwist> {
  // 1. Declare dependencies
  build(build: ToolBuilder) {
    return {
      plot: build(Plot),
    };
  }

  // 2. Initialize on activation
  async activate(priority: Pick<Priority, "id">) {
    // Setup code - runs once when twist is added to a priority
  }

  // 3. Handle lifecycle events
  async upgrade() {
    // Runs when a new version is deployed
  }

  async deactivate() {
    // Cleanup - runs when twist is removed
  }
}
```

### When to Use Twists

Use twists for:

- **Integrations** - Connecting external services (Google Calendar, GitHub, Slack)
- **Automations** - Automatic task creation, reminders, status updates
- **Data Processing** - Analyzing and organizing activities
- **Notifications** - Sending alerts based on conditions

---

## Twist Tools

Twist tools provide capabilities to twists. They are usually unopinionated and do nothing on their own. Tools encapsulate reusable capabilities and can be composed together.

### Types of Tools

#### 1. Built-in Tools

Core Plot functionality provided by the Twist Creator:

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

Use the `build()` method to declare which tools your twist needs:

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
    title: "Hello from my twist"
  });
}
```

### Direct Access Methods

Some tool methods are available directly on the Twist class for convenience:

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

### Twist Activation

Twists are activated within a specific priority. When activated, the twist has access to that priority and all its children.

```typescript
async activate(priority: Pick<Priority, "id">) {
  // This twist is now active for this priority
  // It can create activities, set up webhooks, etc.
}
```

---

## Activities

Activities are the core data type in Plot, representing tasks, events, and notes.

**Think of an Activity as a thread** on a messaging platform, and **Notes as the messages in that thread**. An Activity represents something done or to be done, while Notes represent the updates and details on that activity. Always create activities with an initial note, and add notes for updates rather than creating new activities.

### Activity Types

- **Note** - Information without actionable requirements
- **Task** - Actionable items that can be completed
- **Event** - Scheduled occurrences with start/end times

```typescript
import { ActivityType } from "@plotday/twister";

// Note - Information without actionable requirements
await this.tools.plot.createActivity({
  type: ActivityType.Note,
  title: "Meeting notes from sync",
  notes: [
    {
      content: "Discussed Q1 roadmap and team priorities...",
    },
  ],
});

// Task - Actionable item
await this.tools.plot.createActivity({
  type: ActivityType.Action,
  title: "Review pull request",
  doneAt: null, // null = not done
  notes: [
    {
      content: "PR adds new authentication flow. Please review for security concerns.",
    },
  ],
});

// Event - Scheduled occurrence
await this.tools.plot.createActivity({
  type: ActivityType.Event,
  title: "Team standup",
  start: new Date("2025-02-01T10:00:00Z"),
  end: new Date("2025-02-01T10:30:00Z"),
  notes: [
    {
      content: "Daily sync meeting",
    },
  ],
});
```

### Activity Scheduling States

When creating Activities of type `Action` (tasks), the `start` field determines how they appear in Plot:

- **"Do Now"** (Current/Actionable) - Tasks that should be done today
- **"Do Later"** (Future Scheduled) - Tasks scheduled for a specific future date
- **"Do Someday"** (Unscheduled Backlog) - Tasks without a specific timeline

#### Default Behavior

**Important:** When creating an Action, omitting the `start` field defaults to the current time, making it a "Do Now" task.

For most integrations (project management tools, issue trackers), you should explicitly set `start: null` to create backlog items, only using "Do Now" for tasks that are actively in progress or urgent.

```typescript
// "Do Now" - Appears in today's actionable list
// WARNING: This is the default when start is omitted!
await this.tools.plot.createActivity({
  type: ActivityType.Action,
  title: "Urgent: Review security PR",
  // Omitting start defaults to new Date()
});

// "Do Someday" - Backlog item (RECOMMENDED for most synced tasks)
await this.tools.plot.createActivity({
  type: ActivityType.Action,
  title: "Refactor authentication service",
  start: null, // Explicitly set to null for backlog
});

// "Do Later" - Scheduled for specific date
await this.tools.plot.createActivity({
  type: ActivityType.Action,
  title: "Prepare Q1 review",
  start: new Date("2025-03-15"), // Scheduled for future date
});
```

#### When to Use Each State

**Use "Do Now" (omit `start`)** when:

- Task is actively being worked on
- Task has a due date of today
- Task is marked as "In Progress" in source system
- Task is high priority AND explicitly assigned as current work

**Use "Do Someday" (`start: null`)** when:

- Syncing backlog items from project management tools
- Task is in "To Do" or "Backlog" status
- Task doesn't have a specific due date
- This should be the **default for most integrations**

**Use "Do Later" (future `start`)** when:

- Task has a specific due date in the future
- Task is scheduled for a particular day

### Activity Properties

```typescript
type Activity = {
  id: string; // Unique identifier
  type: ActivityType; // Note, Task, or Event
  title: string | null; // Display title
  preview: string | null; // Brief preview text
  start: Date | null; // Event start time
  end: Date | null; // Event end time
  doneAt: Date | null; // Task completion time
  tags: Record<Tag, ActorId[]>; // Tag assignments
  // ... and more
};
```

### Activity Notes

Activities can have multiple Notes attached to them, like messages in a thread. Notes contain detailed content and links:

```typescript
await this.tools.plot.createActivity({
  type: ActivityType.Action,
  title: "Fix bug #123",
  source: "github:issue:123", // For deduplication
  notes: [
    {
      content: "Users are unable to log in with SSO. Error occurs in auth middleware.",
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
    },
  ],
});
```

**Link Types:**

- **external** - Opens URL in browser
- **auth** - Initiates OAuth flow
- **callback** - Triggers twist method when clicked
- **conferencing** - Video conferencing links (Zoom, Meet, Teams, etc.)

### Best Practices for Activities and Notes

#### Always Create Activities with an Initial Note

**In most cases, an Activity should be created with at least one initial Note.** The Activity's `title` is just a short summary that may be truncated in the UI. Detailed information, context, and links should always go in Notes.

Think of it like starting a new thread with a first message - the thread title gives context, but the real content is in the messages.

```typescript
// ✅ GOOD - Activity with detailed Note (thread with first message)
await this.tools.plot.createActivity({
  type: ActivityType.Action,
  title: "Review PR #456",
  source: "github:pr:456", // For deduplication
  notes: [
    {
      content: "Please review the OAuth 2.0 implementation. Key changes include:\n- Token refresh logic\n- Session management\n- Error handling for expired tokens",
      links: [
        {
          type: ActivityLinkType.external,
          title: "View PR",
          url: "https://github.com/org/repo/pull/456",
        },
      ],
    },
  ],
});

// ❌ BAD - Relying only on title
await this.tools.plot.createActivity({
  type: ActivityType.Action,
  title: "Review PR #456 - OAuth implementation with token refresh and session management",
  // Missing Notes with full context and links
});
```

**Why?** Just as you wouldn't create a messaging thread without a first message, Activities need Notes to provide meaningful context and detail.

#### Add Notes to Existing Activities for Related Content

**Wherever possible, related messages should be added to an existing Activity rather than creating a new Activity.** This keeps conversations, workflows, and related information together.

Think of it like replying to a message thread instead of starting a new thread for every reply.

**Use this pattern for:**

- **Email threads** - All messages in a thread as Notes on one Activity
- **Chat conversations** - All messages in a channel or thread as Notes
- **Workflows** - All steps in an end-to-end process as Notes
- **Document collaboration** - All comments and updates as Notes
- **Issue tracking** - All comments and status updates as Notes

```typescript
// ✅ GOOD - Add reply to existing thread
async onNewMessage(message: Message, threadId: string) {
  // Find existing activity for this thread (check if thread exists)
  const source = `chat:thread:${threadId}`;
  const activity = await this.tools.plot.getActivityBySource(source);

  if (activity) {
    // Add new message as a Note to the existing thread
    await this.tools.plot.createNote({
      activity: { id: activity.id },
      content: message.text,
    });
  } else {
    // Create new thread with initial message
    await this.tools.plot.createActivity({
      type: ActivityType.Note,
      title: message.subject || "New conversation",
      source, // For future deduplication
      notes: [
        {
          content: message.text,
        },
      ],
    });
  }
}

// ❌ BAD - Creating separate Activity for each message (new thread for every reply!)
async onNewMessage(message: Message, threadId: string) {
  // This creates clutter - each message becomes its own Activity
  await this.tools.plot.createActivity({
    type: ActivityType.Note,
    title: `Message from ${message.author}`,
    notes: [{ content: message.text }],
  });
}
```

**Why?** Grouping related content keeps the user's workspace organized and provides better context. A chat conversation with 20 messages should be one Activity with 20 Notes, not 20 separate Activities.

---

## Lifecycle Methods

Twists have several lifecycle methods that are called at specific times.

### activate(priority)

Called when the twist is first activated for a priority.

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

Called when a new version of your twist is deployed to an existing priority.

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

Called when the twist is removed from a priority.

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
class MyTwist extends Twist<MyTwist> {
  private syncToken: string;  // This will be lost!
}

// ✅ CORRECT - Use Store
class MyTwist extends Twist<MyTwist> {
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
      title: "Twist activated"
    });
  } catch (error) {
    console.error("Failed to create activity:", error);
    // Twist activation continues even if this fails
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
  type: ActivityType.Action,
  title: "Thing",
});

// ✅ Clear
await this.tools.plot.createActivity({
  type: ActivityType.Action,
  title: "Review pull request #123 for authentication fix",
});
```

---

## Next Steps

- **[Built-in Tools Guide](TOOLS_GUIDE.md)** - Learn about Plot, Store, AI, and more
- **[Building Custom Tools](BUILDING_TOOLS.md)** - Create reusable tools
- **[Runtime Environment](RUNTIME.md)** - Understand execution constraints
