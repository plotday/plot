---
title: Core Concepts
group: Guides
---

# Core Concepts

Understanding these core concepts will help you build effective Plot Twists.

## Table of Contents

- [Twists](#twists)
- [Twist Tools](#twist-tools)
- [Focuses](#focuses)
- [Threads](#threads)
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
- Can create threads and respond to new notes, links, and thread changes

A twist is installed at the workspace level and owned by a single user. Threads it creates are filed against the owner's focuses, with automatic focus matching when no explicit focus is provided.

### Twist Anatomy

```typescript
import { type ToolBuilder, Twist } from "@plotday/twister";
import { Plot, ThreadAccess } from "@plotday/twister/tools/plot";

export default class MyTwist extends Twist<MyTwist> {
  // 1. Declare dependencies
  build(build: ToolBuilder) {
    return {
      plot: build(Plot, {
        thread: { access: ThreadAccess.Create },
      }),
    };
  }

  // 2. Initialize on activation
  async activate() {
    // Setup code - runs once when the twist is installed
  }

  // 3. Handle lifecycle events
  async upgrade() {
    // Runs when a new version is deployed
  }

  async deactivate() {
    // Cleanup - runs when the twist is uninstalled
  }
}
```

### When to Use Twists

Use twists for:

- **Automations** - Automatic task creation, reminders, status updates
- **Data Processing** - Analyzing and organizing threads
- **Notifications** - Sending alerts based on conditions

For external service integrations (Google Calendar, GitHub, Slack, etc.), build a **Connector** instead. Connectors extend `Connector<T>` (which itself extends `Twist<T>`) and provide the OAuth and channel lifecycle needed for syncing external data. See [Building Connectors](BUILDING_CONNECTORS.md).

---

## Twist Tools

Twist tools provide capabilities to twists. They are usually unopinionated and do nothing on their own. Tools encapsulate reusable capabilities and can be composed together.

### Types of Tools

#### 1. Built-in Tools

Core Plot functionality provided by the Twist Creator:

- **Plot** - Create and manage threads, notes, and focuses
- **Store** - Persistent key-value storage
- **Integrations** - OAuth authentication
- **Tasks** - Background task execution
- **Network** - HTTP access and webhooks
- **Callbacks** - Persistent function references
- **AI** - Language model integration

See the [Built-in Tools Guide](TOOLS_GUIDE.md) for complete documentation.

#### 2. Connectors

External service integrations are built as Connectors, which extend `Connector<T>`. Connectors declare OAuth providers, expose channels for users to enable/disable, and sync data from services like Google Calendar, Slack, GitHub, and more.

See [Building Connectors](BUILDING_CONNECTORS.md) to create your own.

### Declaring Tool Dependencies

Use the `build()` method to declare which tools your twist needs:

```typescript
build(build: ToolBuilder) {
  return {
    plot: build(Plot, {
      thread: { access: ThreadAccess.Create },
    }),
    network: build(Network, {
      // Tool-specific options
      urls: ["https://api.service.com/*"],
    }),
  };
}
```

### Accessing Tools

Access your tools via `this.tools`:

```typescript
async activate() {
  // Tools are fully typed
  await this.tools.plot.createThread({
    title: "Hello from my twist",
    notes: [{ content: "The twist is now set up." }],
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

// Callbacks (pass a method reference, not a string)
await this.callback(this.methodName, ...args);
await this.run(callbackToken);
```

---

## Focuses

Focuses are contexts that organize threads. Think of them like projects or areas of life. Focuses are flat — they have no parent and no children. Threads not matched to any focus live in the Inbox.

### Creating Focuses

Creating focuses requires `FocusAccess` in the Plot tool options. A focus can carry a `key` (unique per user) so it can be upserted without tracking its UUID:

```typescript
import { FocusAccess, Plot } from "@plotday/twister/tools/plot";

build(build: ToolBuilder) {
  return {
    plot: build(Plot, {
      thread: { access: ThreadAccess.Create },
      focus: { access: FocusAccess.Create },
    }),
  };
}

// Create (or upsert by key) a focus
const work = await this.tools.plot.createFocus({
  title: "Work",
  key: "work",
});
```

### Automatic Focus Matching

When a twist creates a thread without specifying a `focus`, the server classifies the thread into one of the owner's focuses automatically. Provide an explicit `focus: { id }` only when you want to override that routing:

```typescript
await this.tools.plot.createThread({
  title: "Quarterly planning",
  focus: { id: work.id }, // Optional - omit to let Plot classify it
  notes: [{ content: "Kick off Q3 planning." }],
});
```

---

## Threads

Threads are the core data type in Plot, representing tasks, events, and conversations.

**Think of a Thread as a thread** on a messaging platform, and **Notes as the messages in that thread**. A Thread represents something done or to be done, while Notes represent the updates and details on that thread. Always create threads with an initial note, and add notes for updates rather than creating new threads.

### Thread Types

A thread's `type` is a sub-type/category that determines its icon. Available types depend on whether the focus is shared:

- **Private focuses**: `"action"` (tasks), `"notes"` (default), `"idea"`, `"goal"`, `"decision"`
- **Shared focuses**: all of the above plus `"discussion"` (default), `"announcement"`, `"ask"`

```typescript
// Notes - Information without actionable requirements (default)
await this.tools.plot.createThread({
  title: "Meeting notes from sync",
  notes: [
    {
      content: "Discussed Q1 roadmap and team priorities...",
    },
  ],
});

// Action - Actionable item
await this.tools.plot.createThread({
  type: "action",
  title: "Review pull request",
  notes: [
    {
      content: "PR adds new authentication flow. Please review for security concerns.",
    },
  ],
});

// Scheduled event - a thread with a schedule
await this.tools.plot.createThread({
  title: "Team standup",
  notes: [
    {
      content: "Daily sync meeting",
    },
  ],
  schedules: [
    {
      start: new Date("2025-02-01T10:00:00Z"),
      end: new Date("2025-02-01T10:30:00Z"),
    },
  ],
});
```

### Thread Properties

```typescript
type Thread = {
  id: Uuid; // Unique identifier
  created: Date; // When the thread was created
  title: string; // Display title
  focus: Focus; // The focus this thread belongs to
  type: ThreadType | null; // Sub-type/category, determines the icon
  archived: boolean; // Whether the thread has been archived
  access: ThreadAccessLevel; // "public", "members", or "private"
  tags: Tags; // Tag assignments (tag -> actors who added it)
  reactions: Reactions; // Emoji reactions (emoji -> actors who reacted)
  schedule?: Schedule; // The schedule associated with this thread, if any
  // ... and more
};
```

**Key Properties:**

- **`title`**: Short summary that may be truncated in the UI - detailed content should go in Notes
- **`type`**: Determines how the thread is displayed (icon and category)
- **`focus`**: The focus the thread is filed in - assigned automatically unless you provide one

### Thread Notes

Threads can have multiple Notes attached to them, like messages in a thread. Notes contain detailed content and interactive actions.

**Data Sync:** When syncing from external systems, connectors use `Link.sources` and `Note.key` for automatic upserts. See [Sync Strategies](SYNC_STRATEGIES.md).

```typescript
import { ActionType } from "@plotday/twister";

await this.tools.plot.createThread({
  type: "action",
  title: "Fix bug #123",
  notes: [
    {
      key: "description", // Using key enables upserts
      content: "Users are unable to log in with SSO. Error occurs in auth middleware.",
      actions: [
        {
          type: ActionType.external,
          title: "View Issue",
          url: "https://github.com/org/repo/issues/123",
        },
        {
          type: ActionType.callback,
          title: "Mark as Fixed",
          callback: await this.actionCallback(this.markAsFixed, "123"),
        },
      ],
    },
  ],
});
```

**Action Types:**

- **external** - Opens URL in browser
- **auth** - Initiates OAuth flow
- **callback** - Triggers twist method when clicked
- **conferencing** - Video conferencing links (Zoom, Meet, Teams, etc.)
- **file** / **fileRef** - File attachments (stored in Plot or referenced from a connector's source system)
- **thread** - Navigates to a related thread
- **plan** - Structured plan of operations for user approval

### Best Practices for Threads and Notes

#### Always Create Threads with an Initial Note

**In most cases, a Thread should be created with at least one initial Note.** The Thread's `title` is just a short summary that may be truncated in the UI. Detailed information, context, and actions should always go in Notes.

Think of it like starting a new thread with a first message - the thread title gives context, but the real content is in the messages.

```typescript
// ✅ GOOD - Thread with detailed Note (thread with first message)
await this.tools.plot.createThread({
  type: "action",
  title: "Review PR #456",
  notes: [
    {
      key: "description", // Using key enables upserts
      content: "Please review the OAuth 2.0 implementation. Key changes include:\n- Token refresh logic\n- Session management\n- Error handling for expired tokens",
      actions: [
        {
          type: ActionType.external,
          title: "View PR",
          url: "https://github.com/org/repo/pull/456",
        },
      ],
    },
  ],
});

// ❌ BAD - Relying only on title
await this.tools.plot.createThread({
  type: "action",
  title: "Review PR #456 - OAuth implementation with token refresh and session management",
  // Missing Notes with full context and actions
});
```

**Why?** Just as you wouldn't create a messaging thread without a first message, Threads need Notes to provide meaningful context and detail.

#### Add Notes to Existing Threads for Related Content

**Wherever possible, related messages should be added to an existing Thread rather than creating a new Thread.** This keeps conversations, workflows, and related information together.

Think of it like replying to a message thread instead of starting a new thread for every reply.

**Use this pattern for:**

- **Email threads** - All messages in a thread as Notes on one Thread
- **Chat conversations** - All messages in a channel or thread as Notes
- **Workflows** - All steps in an end-to-end process as Notes
- **Document collaboration** - All comments and updates as Notes
- **Issue tracking** - All comments and status updates as Notes

```typescript
// ✅ GOOD - Track the thread ID and add replies as Notes
async onNewMessage(message: Message, conversationId: string) {
  let threadId = await this.get<Uuid>(`thread_${conversationId}`);

  if (!threadId) {
    // First message - create the thread with the message as its initial note
    threadId = await this.tools.plot.createThread({
      title: message.subject || "New conversation",
      notes: [
        {
          key: `message-${message.id}`, // Unique key per message for upserts
          content: message.text,
        },
      ],
    });
    await this.set(`thread_${conversationId}`, threadId);
    return;
  }

  // Follow-up message - add a note to the existing thread
  await this.tools.plot.createNote({
    thread: { id: threadId },
    key: `message-${message.id}`,
    content: message.text,
  });
}

// ❌ BAD - Creating separate Thread for each message (new thread for every reply!)
async onNewMessage(message: Message, conversationId: string) {
  // This creates clutter - each message becomes its own Thread
  await this.tools.plot.createThread({
    title: `Message from ${message.author}`,
    notes: [{ content: message.text }],
  });
}
```

**For connectors:** When syncing from an external service, there's no need to store thread IDs — save links with `integrations.saveLink()` using `Link.sources` for deduplication, and reference the thread by source (`thread: { source: ... }`) when creating notes.

See [Sync Strategies](SYNC_STRATEGIES.md) for more details on choosing the right pattern.

**Why?** Grouping related content keeps the user's workspace organized and provides better context. A chat conversation with 20 messages should be one Thread with 20 Notes, not 20 separate Threads.

---

## Lifecycle Methods

Twists have several lifecycle methods that are called at specific times.

### activate()

Called when the twist is installed by a user. When it runs, `this.userId` is already populated with the installing user's ID.

**Use for:**

- Creating initial threads
- Setting up webhooks
- Initializing state

```typescript
async activate() {
  // Create welcome message
  await this.tools.plot.createThread({
    title: "Calendar sync is now active",
    notes: [{ content: "Events will appear as they sync." }],
  });

  // Set up webhook
  const webhookUrl = await this.tools.network.createWebhook({}, this.onUpdate);
  await this.set("webhook_url", webhookUrl);
}
```

### upgrade()

Called when a new version of your twist is deployed to existing installations.

**Use for:**

- Migrating data structures
- Updating webhook configurations
- Adding new features to existing installations
- Handling breaking changes to callback signatures

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

#### Callback Versioning During Upgrades

**IMPORTANT:** All callbacks automatically upgrade to the new twist version. Callbacks are resolved **by function name** at execution time, so callbacks created in v1.0 will execute using v2.0's code after upgrade.

This means:

- **Webhooks** continue working after upgrades using new code
- **Scheduled tasks** execute with the latest version when they run
- **In-progress batch operations** use new logic for subsequent batches
- You can receive callbacks with **old arguments** running on **new code**

**Best Practice:** Maintain backward compatibility in callback method signatures:

```typescript
// v1.0
async syncBatch(batchNumber: number, authToken: string) {
  // Original logic
}

// v2.0 - Add optional parameter at end
async syncBatch(batchNumber: number, authToken: string, calendarId?: string) {
  const calendar = calendarId ?? "primary";  // Safe default
  // New logic
}
```

**For Breaking Changes:** Recreate callbacks in `upgrade()`:

```typescript
async upgrade() {
  const version = await this.get<string>("version");

  if (version === "1.0.0") {
    // Recreate callbacks with new signature
    const syncs = await this.get<SyncState[]>("active_syncs");
    for (const sync of syncs) {
      // Delete old callback
      const oldCallback = await this.get<Callback>(`sync_${sync.id}`);
      if (oldCallback) await this.deleteCallback(oldCallback);

      // Create new callback with updated signature
      const newCallback = await this.callback(this.syncBatchV2, sync.id);
      await this.set(`sync_${sync.id}`, newCallback);
    }
  }

  await this.set("version", "2.0.0");
}
```

Alternatively, keep the old function temporarily while callbacks complete:

```typescript
// Keep old signature for in-flight callbacks
async syncBatch(batchNumber: number, authToken: string) {
  // Delegate to new implementation
  return this.syncBatchV2({ batchNumber, authToken });
}

// New signature for new callbacks
async syncBatchV2(options: SyncOptions) {
  // New implementation
}
```

### deactivate()

Called when the twist is uninstalled.

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
async activate() {
  try {
    await this.tools.plot.createThread({
      title: "Twist activated",
      notes: [{ content: "Setup is complete." }],
    });
  } catch (error) {
    console.error("Failed to create thread:", error);
    // Twist activation continues even if this fails
  }
}
```

### 3. Batch Long Operations

Break long-running operations into batches:

```typescript
async startSync() {
  const callback = await this.callback(this.syncBatch, 1);
  await this.runTask(callback);
}

async syncBatch(page: number) {
  // Process one page
  const hasMore = await this.processPage(page);

  if (hasMore) {
    // Queue next batch
    const callback = await this.callback(this.syncBatch, page + 1);
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
    plot: build(Plot, {
      thread: { access: ThreadAccess.Create },
    }),
    network: build(Network, {
      urls: ["https://api.service.com/*"]
    }),
    integrations: build(Integrations),
    ai: build(AI)
  };
}
```

### 6. Clear Thread Titles

Make thread titles clear and actionable:

```typescript
// ❌ Vague
await this.tools.plot.createThread({
  type: "action",
  title: "Thing",
});

// ✅ Clear
await this.tools.plot.createThread({
  type: "action",
  title: "Review pull request #123 for authentication fix",
});
```

---

## Next Steps

- **[Built-in Tools Guide](TOOLS_GUIDE.md)** - Learn about Plot, Store, AI, and more
- **[Building Connectors](BUILDING_CONNECTORS.md)** - Build external service integrations
- **[Runtime Environment](RUNTIME.md)** - Understand execution constraints
