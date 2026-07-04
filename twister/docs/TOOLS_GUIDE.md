---
title: Built-in Tools
group: Guides
---

# Built-in Tools

Plot provides a comprehensive set of built-in tools that give your twists powerful capabilities. This guide covers all built-in tools with detailed examples and best practices.

## Table of Contents

- [Plot](#plot) - Managing threads, notes, and focuses
- [Store](#store) - Persistent key-value storage
- [Integrations](#integrations) - OAuth authentication and connector data sync
- [Tasks](#tasks) - Background task execution
- [Network](#network) - HTTP access and webhooks
- [Callbacks](#callbacks) - Persistent function references
- [AI](#ai) - Language model integration
- [Files](#files) - Reading note attachments
- [Other Built-in Tools](#other-built-in-tools) - Imap, Smtp, Twists

---

## Plot

The Plot tool is the core interface for creating and managing threads, notes, and focuses.

### Workspace-Level Twists

A twist is installed by a single user at the workspace level — it is **not** scoped to a particular focus. `this.userId` exposes the installing user's ID, and `plot.getUserId()` is available if you need it explicitly. `plot.getOwner()` returns the full `Actor` (name/email) for the installing user.

When a twist creates a thread without specifying a focus, the server classifies it automatically using the owner's focus rules. You only need to provide a `focus` when you want to override that automatic routing.

### Understanding Threads and Notes

**Thread** represents a conversation or item (a task, event, or discussion), while **Notes** represent the updates and details on that thread.

**Think of a Thread as a thread** on a messaging platform, and **Notes as the messages in that thread**. Always create threads with an initial note, and add notes to existing threads for updates rather than creating new threads.

### Setup

All Plot permissions must be explicitly requested in `build()` — there are no default permissions:

```typescript
import { Plot, ThreadAccess, FocusAccess, ContactAccess } from "@plotday/twister/tools/plot";

build(build: ToolBuilder) {
  return {
    plot: build(Plot, {
      thread: {
        access: ThreadAccess.Create,
      },
      focus: {
        access: FocusAccess.Create,
      },
      contact: {
        access: ContactAccess.Read,
      },
    }),
  };
}
```

Available permission levels:

- **`ThreadAccess`**: `Respond` (notes/tags on threads where the twist is mentioned) → `Create` (create threads, notes in own threads) → `Full` (list/query and update any of the owner's threads)
- **`FocusAccess`**: `Create` (create focuses, update own) → `Full` (read, create, update, and archive any of the owner's focuses)
- **`ContactAccess.Read`**: read contact details (name/email). Without it, only actor IDs are provided.
- **`LinkAccess`**: `Read` → `Full` (update links, including moving them between threads). Enabled under the `link` option.
- **`link: true`**: receive links from connected source channels (`getLinks()`, `onLinkCreated`, `onLinkUpdated`, `onLinkNoteCreated`)
- **`search: true`**: semantic search across the owner's notes and links
- **`requireApproval: true`**: admin write operations require user approval via plans (see [Plans](#plans-user-approved-operations))

### Creating Threads

```typescript
import { ActionType } from "@plotday/twister";

// Create a thread with an initial note
const threadId = await this.tools.plot.createThread({
  title: "Q1 Planning Meeting Notes",
  notes: [
    {
      content: "Discussed goals for Q1 and assigned action items.",
    },
  ],
});

// Create a task-style thread with an action button
await this.tools.plot.createThread({
  type: "action",
  title: "Review pull request #123",
  notes: [
    {
      key: "description", // Using key enables upserts
      content: "Please review the changes and provide feedback.",
      actions: [
        {
          type: ActionType.external,
          title: "View PR",
          url: "https://github.com/org/repo/pull/123",
        },
      ],
    },
  ],
});

// Create an event with a schedule
await this.tools.plot.createThread({
  title: "Team standup",
  notes: [
    {
      content: "Daily standup meeting to sync on progress.",
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

`createThread()` returns the new thread's `Uuid`. Use `createThreads()` to create many threads in one batch — it's significantly more efficient than calling `createThread()` in a loop.

The optional `type` field sets the thread's sub-type and icon: `"action"`, `"notes"`, `"idea"`, `"goal"`, `"decision"`, and (in shared focuses) `"discussion"`, `"announcement"`, `"ask"`.

**Marking items read for historical imports:** Set `unread: false` on threads/notes created during bulk imports so historical items don't flood the user with unread indicators. Omit `unread` for normal, fresh content.

### Updating Threads

```typescript
// Rename a thread
await this.tools.plot.updateThread({
  id: threadId,
  title: "Updated title",
});

// Archive a thread (there is no delete — archive instead)
await this.tools.plot.updateThread({
  id: threadId,
  archived: true,
});

// Add or remove the twist's own tags without touching other actors' tags
import { Tag } from "@plotday/twister";

await this.tools.plot.updateThread({
  id: threadId,
  twistTags: {
    [Tag.Todo]: true,  // Add the to-do tag
    [Tag.Done]: false, // Remove the done tag
  },
});

// Move a thread to a different focus (requires ThreadAccess.Full)
await this.tools.plot.updateThread({
  id: threadId,
  focus: { id: focusId },
});
```

`updateThread()` only updates existing threads and throws if the thread doesn't exist. Only the fields you provide are changed. The thread can be identified by `id`, by `source` (the canonical external ID of a link on the thread), or by `match` for bulk updates of threads the twist created:

```typescript
// Bulk-archive all threads this twist created with matching metadata
await this.tools.plot.updateThread({
  match: { meta: { projectId: "TEAM" } },
  archived: true,
});
```

Scheduling is handled separately via `createSchedule()` / `getSchedules()` (see below).

### Creating and Managing Notes

#### Creating Notes on New Threads

**Best Practice:** Always create Threads with at least one initial Note containing detailed information. The `title` is a short summary that may be truncated—detailed content should go in Notes.

```typescript
await this.tools.plot.createThread({
  type: "action",
  title: "Customer feedback: Login issues",
  notes: [
    {
      key: "description", // Using key enables upserts
      content: "Customer reported:\n\n\"I'm unable to log in using Google SSO.\"\n\nPriority: High\nAffected users: ~15 reports",
      actions: [
        {
          type: ActionType.external,
          title: "View Support Ticket",
          url: "https://support.example.com/tickets/12345",
        },
      ],
    },
  ],
});
```

#### Adding Notes to Existing Threads

**Best Practice:** For related content (email threads, chat conversations, workflows), add Notes to the existing Thread rather than creating new Threads. Think of it like adding a message to an existing thread.

```typescript
// Add a new Note to an existing Thread (add message to thread)
await this.tools.plot.createNote({
  thread: { id: threadId },
  content: "Update: Engineering team has identified the root cause. Fix will be deployed in the next release.",
  actions: [
    {
      type: ActionType.external,
      title: "View PR Fix",
      url: "https://github.com/org/repo/pull/789",
    },
  ],
});
```

The `thread` reference accepts `{ id }` or `{ source }` (the canonical external ID of a link on the thread — useful for attaching notes to connector-synced threads). Notes support:

- **`content`** — markdown content (set `contentType: "text"` or `"html"` to have the server convert; `"markdown"` is the default)
- **`key`** — a stable identifier that enables upserts: creating a note with an existing key updates it instead of duplicating
- **`actions`** — interactive buttons (`ActionType.external`, `ActionType.callback`, etc.)
- **`author`** — attribute the note to a contact instead of the twist

Use `createNotes()` for batches, and `updateNote()` for partial updates to an existing note (identified by `id` or `key`).

```typescript
// Update note content
await this.tools.plot.updateNote({
  id: noteId,
  content: "Updated content with more details",
});
```

#### Pattern: Conversations and Message Threads

Keep all messages in a conversation within a single Thread. Think of it like a messaging app — one thread, many messages. Use stable note `key`s so re-syncing the same messages upserts instead of duplicating:

```typescript
async handleConversation(conversation: Conversation) {
  // Look up the thread created for this conversation, if any
  const mappingKey = `conversation:${conversation.id}`;
  let threadId = await this.get<Uuid>(mappingKey);

  if (!threadId) {
    threadId = await this.tools.plot.createThread({
      title: conversation.subject,
      notes: conversation.messages.map((msg) => ({
        key: `message-${msg.id}`, // Unique, immutable key per message
        content: msg.body,
      })),
    });
    await this.set(mappingKey, threadId);
  } else {
    // Upsert messages into the existing thread — keys deduplicate
    await this.tools.plot.createNotes(
      conversation.messages.map((msg) => ({
        thread: { id: threadId! },
        key: `message-${msg.id}`,
        content: msg.body,
      }))
    );
  }
}
```

**Why this matters:** A conversation with 20 messages should be one Thread with 20 Notes, not 20 separate Threads. This keeps the workspace organized and provides better context.

**Note for connectors:** If you're building a Connector that syncs an external system, don't use the Plot tool for this — use `integrations.saveLink()` / `saveLinks()`, which handle thread+link upserts by `sources` automatically. See [Sync Strategies](SYNC_STRATEGIES.md) and [Building Connectors](BUILDING_CONNECTORS.md).

### Reading Threads and Notes

```typescript
// Look up a thread by ID or by a link's canonical source
const thread = await this.tools.plot.getThread({ id: threadId });
const synced = await this.tools.plot.getThread({ source: "linear:issue:ABC-123" });

// Look up a note by ID or key
const note = await this.tools.plot.getNote({ key: "description" });

// All notes in a thread, ordered by creation time
const notes = await this.tools.plot.getNotes(thread);

// List the owner's threads (requires ThreadAccess.Full).
// Defaults to the owner's Inbox; limit defaults to 50 (max 200).
const inboxThreads = await this.tools.plot.getThreads();
const focusThreads = await this.tools.plot.getThreads({
  focusId,
  includeArchived: false,
  limit: 100,
  offset: 0,
});
```

### Managing Focuses

Focuses are flat organizational containers (like projects or areas of life) — they have no parents or children. Threads not matched to any focus live in the Inbox.

```typescript
// Create a focus (upserts by key if one is provided)
const focus = await this.tools.plot.createFocus({
  title: "Work",
  key: "work", // Optional: enables lookup/upsert without storing the UUID
});
// focus.created tells you whether it was newly created or already existed

// Look up a focus by ID or key
const existing = await this.tools.plot.getFocus({ key: "work" });

// Update a focus
await this.tools.plot.updateFocus({
  key: "work",
  title: "Work Projects",
});

// List the owner's focuses (requires FocusAccess.Full)
const focuses = await this.tools.plot.getFocuses({ includeArchived: false });
```

### Schedules

Schedules define when a thread occurs in time. A thread can have multiple schedules.

```typescript
const threadId = await this.tools.plot.createThread({
  title: "Team standup",
});

await this.tools.plot.createSchedule({
  threadId,
  start: new Date("2025-01-15T10:00:00Z"),
  end: new Date("2025-01-15T10:30:00Z"),
  recurrenceRule: "FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR",
});

const schedules = await this.tools.plot.getSchedules(threadId);
```

For all-day events, pass `"YYYY-MM-DD"` date strings for `start`/`end` instead of `Date` objects.

### Contacts

```typescript
// The user who installed the twist
const owner = await this.tools.plot.getOwner();

// Resolve actor IDs to actors (requires ContactAccess.Read for name/email)
const actors = await this.tools.plot.getActors([actorId1, actorId2]);
```

### Links from Connected Channels

With `link: true` in the Plot options, a twist can read links synced by the user's connections (calendar events, issues, messages, etc.) and react to them via the `onLinkCreated` / `onLinkUpdated` / `onLinkNoteCreated` lifecycle methods on `Twist`.

```typescript
const results = await this.tools.plot.getLinks({
  since: new Date(Date.now() - 24 * 60 * 60 * 1000),
  type: "event",
  limit: 50,
});

for (const { link, notes } of results) {
  console.log(link.title, link.status, notes.length);
}

// Move a link to a different thread (requires LinkAccess.Full)
await this.tools.plot.updateLink({ id: linkId, threadId: otherThreadId });
```

### Semantic Search

With `search: true` in the Plot options, search the owner's notes and links by meaning:

```typescript
const results = await this.tools.plot.search("budget discussion with finance", {
  limit: 10,      // Default 10, max 30
  threshold: 0.3, // Minimum similarity 0-1 (default 0.3)
  focusId,        // Optional: scope to one focus
});

for (const result of results) {
  // result.type is "note" or "link"
  console.log(result.thread.title, result.similarity);
}
```

### Plans (User-Approved Operations)

With `requireApproval: true` in the Plot options, write operations on content the twist didn't create require user approval. Build a plan and attach it to a note as an action; the user can approve or deny it, and approved operations are executed by Plot:

```typescript
const planAction = this.tools.plot.createPlan({
  title: "Organize project threads",
  operations: [
    {
      type: "updateThread",
      threadId,
      threadTitle: "Old thread",
      changes: { archived: true },
    },
  ],
  callback: await this.actionCallback(this.onPlanResolved, threadId as string),
});

await this.tools.plot.createNote({
  thread: { id: threadId },
  content: "Here's my proposed cleanup:",
  actions: [planAction],
});

// Called when the user responds; approved operations are executed by Plot
async onPlanResolved(action: Action, threadId: string) {
  // e.g. post a confirmation note
}
```

### Responding to Mentions

The `note` options let a twist respond when a user @-mentions it in a note. Declare either a fixed set of `intents` (the system matches the note against intent descriptions and examples) or a single conversational `handler` that receives every mention:

```typescript
plot: build(Plot, {
  thread: { access: ThreadAccess.Create },
  note: {
    defaultMention: true, // Auto-mention this twist on replies in its threads
    handler: this.respond, // (note: Note) => Promise<void>
  },
}),
```

`handler` and `intents` are mutually exclusive — when both are present, `handler` wins.

See [Sync Strategies](SYNC_STRATEGIES.md) for comprehensive guidance on data synchronization patterns.

---

## Store

Persistent key-value storage for twist state. Store methods are available directly on the twist class.

### Setup

Store is available automatically - no build() declaration needed!

### Storing Data

```typescript
// Save a string
await this.set("last_sync", new Date().toISOString());

// Save an object — Dates are preserved
await this.set("config", {
  enabled: true,
  interval: 3600,
  lastRun: new Date(),
});

// Save an array
await this.set("items", ["a", "b", "c"]);
```

### Batch Writes

Every `set()` is a network round-trip to the storage backend. When you write
per-item state in a batch (e.g. an id→channel mapping for every message in a
sync pass), a loop of `set()` calls dominates the execution's wall-clock time
and request budget. Use `setMany()` — one round-trip, atomic (all entries land
or none do):

```typescript
// ❌ WRONG — one round-trip per message
for (const message of thread.messages) {
  await this.set(`msg-channel:${message.id}`, channelId);
}

// ✅ CORRECT — one round-trip for the whole batch
await this.setMany(
  thread.messages.map((m) => [`msg-channel:${m.id}`, channelId])
);
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

### Listing Keys

`list()` is available on the tool itself (`this.tools.store`):

```typescript
// All keys starting with a prefix
const webhookKeys = await this.tools.store.list("webhook:");
```

### Locks

For operations that must not run concurrently (e.g. overlapping syncs), use the self-expiring locks on `this.tools.store` instead of hand-rolling an "in progress" flag. The lock auto-releases after `ttlMs`, so a crashed holder can't wedge the system:

```typescript
if (!(await this.tools.store.acquireLock(`sync_${id}`, 30 * 60_000))) {
  return; // another sync is already running
}
try {
  await this.runSync(id);
} finally {
  await this.tools.store.releaseLock(`sync_${id}`);
}
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

Values are serialized with SuperJSON, so `Date`, `Map`, `Set`, `RegExp`, `URL`, `BigInt`, and `undefined` all round-trip correctly. Functions, Symbols, circular references, and custom class instances cannot be stored.

```typescript
// ❌ WRONG
await this.set("handler", this.myFunction); // Functions can't be stored

// ✅ CORRECT - Use callbacks instead
const token = await this.callback(this.myFunction);
await this.set("handler_token", token);
```

---

## Integrations

OAuth authentication and data persistence for **connectors** — packages that extend `Connector` (a specialization of `Twist`) to sync an external service.

Plot owns the OAuth flow and the channel enable/disable UI. A connector declares its provider, scopes, and link types as class properties, builds the Integrations tool, and implements the channel lifecycle methods. See [Building Connectors](BUILDING_CONNECTORS.md) for the full guide.

### Setup

```typescript
import { Connector, type ToolBuilder } from "@plotday/twister";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  type Channel,
  Integrations,
} from "@plotday/twister/tools/integrations";

class CalendarConnector extends Connector<CalendarConnector> {
  readonly provider = AuthProvider.Google;
  readonly scopes = ["https://www.googleapis.com/auth/calendar.readonly"];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
    };
  }

  // List the syncable resources for a newly authorized account
  async getChannels(auth: Authorization, token: AuthToken): Promise<Channel[]> {
    const calendars = await this.listCalendars(token);
    return calendars.map((c) => ({ id: c.id, title: c.name }));
  }

  async onChannelEnabled(channel: Channel) {
    // Start syncing this channel
  }

  async onChannelDisabled(channel: Channel) {
    // Stop syncing; archive this channel's content
  }
}
```

### Auth Providers

`AuthProvider` currently includes: `Google`, `Microsoft`, `Notion`, `Slack`, `Atlassian`, `Linear`, `Monday`, `GitHub`, `Asana`, `HubSpot`, `Todoist`, and `Airtable`.

### Using Auth Tokens

`integrations.get(channelId)` returns the access token of the user who enabled sync on that channel, or `null` if the channel is not enabled or the token is expired/invalid:

```typescript
async syncChannel(channelId: string) {
  const authToken = await this.tools.integrations.get(channelId);
  if (!authToken) return;

  const response = await fetch(
    `https://www.googleapis.com/calendar/v3/calendars/${channelId}/events`,
    {
      headers: {
        Authorization: `Bearer ${authToken.token}`,
      },
    }
  );
}
```

If an API call fails with a permanent auth error the runtime can't observe (e.g. Slack `token_revoked`), call `integrations.markNeedsReauth(channelId)` so the app prompts the user to reconnect.

### Saving Synced Data

Connectors save external items with `saveLink()` — each call upserts a thread+link pair keyed on the link's canonical `sources`:

```typescript
await this.tools.integrations.saveLink({
  sources: [`linear:issue:${issue.id}`],
  title: issue.title,
  type: "issue",
  status: issue.state,
  channelId,
  meta: { url: issue.url },
  notes: [
    {
      key: "description",
      content: issue.description,
      contentType: "markdown",
    },
  ],
});
```

Other key methods:

- **`saveLinks(links)`** — batch version of `saveLink`. Prefer it when syncing pages of items: it collapses N saves into one runtime crossing (saving request budget), and a failure on one item doesn't abort the batch (failed items return `null`).
- **`saveNote(note)` / `saveNotes(notes)`** — attach notes to an *existing* thread (by `thread: { id }` or `{ source }`), optionally carrying a note-scoped link. Used by augmenter connectors (e.g. meeting notes attached to a calendar event).
- **`saveContacts(contacts)`** — bulk-upsert contacts (e.g. workspace members) so the recipient picker can address them.
- **`archiveLinks(filter)` / `archiveNotes(filter)`** — archive content this connector created (e.g. in `onChannelDisabled`).
- **`setThreadToDo(source, actorId, todo)`** — set or clear a user's to-do flag on a synced thread (e.g. Gmail star, Slack "later").
- **`channelSyncCompleted(channelId)`** — signal that the initial backfill for a channel finished, clearing the "syncing…" indicator. Call exactly once per initial sync, not on incremental updates.
- **`saveCustomEmoji(emoji)`** — cache workspace custom emoji so reactions render and round-trip.

### Auth Actions in Twists

Regular twists don't manage OAuth directly, but they can prompt for it by attaching an `ActionType.auth` action to a note. When the user completes the flow, the callback is invoked with the resulting `Authorization`:

```typescript
import { ActionType } from "@plotday/twister";
import { AuthProvider, type Authorization } from "@plotday/twister/tools/integrations";

const authCallback = await this.callback(this.onAuthComplete);

await this.tools.plot.createThread({
  title: "Connect your Google Calendar",
  notes: [
    {
      content: "Click below to connect your Google account",
      actions: [
        {
          type: ActionType.auth,
          title: "Connect Google",
          provider: AuthProvider.Google,
          scopes: ["https://www.googleapis.com/auth/calendar.readonly"],
          callback: authCallback,
        },
      ],
    },
  ],
});

async onAuthComplete(authorization: Authorization) {
  // authorization.provider, authorization.scopes, authorization.actor
}
```

See [Multi-User Auth](MULTI_USER_AUTH.md) for per-user auth patterns.

---

## Tasks

Queue background tasks and schedule operations. **Critical for staying under request limits**: each execution has ~1000 requests (HTTP requests, tool calls, database operations), and running a task creates a NEW execution with a fresh request limit.

**Key distinction:**
- **Calling a callback** (via `this.run()`) continues the same execution and shares the request count
- **Running a task** (via `this.runTask()`) creates a NEW execution with fresh ~1000 request limit

Tasks methods are available directly on the twist class.

### Setup

Tasks are available automatically - no build() declaration needed!

### Running Tasks Immediately

```typescript
// Create a callback to a method, currying extra arguments
const callback = await this.callback(this.processData, 1);

// Run immediately in a fresh execution
await this.runTask(callback);

// The method receives the curried arguments
async processData(batchId: number) {
  console.log("Processing batch:", batchId);
}
```

### Scheduling Tasks

```typescript
// Schedule for a specific time
const reminderCallback = await this.callback(
  this.sendReminder,
  "123",
  "Meeting in 10 minutes"
);

const token = await this.runTask(reminderCallback, {
  runAt: new Date("2025-02-01T09:50:00Z"),
});

// Save token to cancel later if needed (returned only for scheduled tasks)
if (token) {
  await this.set("reminder_token", token);
}

async sendReminder(userId: string, message: string) {
  // ...
}
```

### Canceling Tasks

```typescript
// Cancel a specific scheduled task
const token = await this.get<string>("reminder_token");
if (token) {
  await this.cancelTask(token);
}

// Cancel all scheduled tasks for this twist
await this.cancelAllTasks();
```

Immediate (non-scheduled) tasks cannot be cancelled.

### Recurring / self-renewing tasks → `scheduleRecurring`

The `runTask` + store-token + `cancelTask` pattern above is fine for a **one-off**
scheduled task. For anything **recurring or self-renewing** (watch/webhook
renewals, periodic polling, daily syncs, self-heal loops), use `scheduleRecurring`
instead — it manages a **durable singleton** per key that the platform re-arms
automatically every `intervalMs`:

```typescript
const renewal = await this.callback(this.renewWatch, resourceId);
// The platform fires this every intervalMs. firstRunAt sets a precise earlier
// next fire (e.g. renew 24 h before expiry rather than waiting the full interval).
await this.scheduleRecurring(`watch-renewal:${resourceId}`, renewal, {
  intervalMs: 24 * 60 * 60 * 1000, // safety ceiling: re-arm every 24 h
  firstRunAt: new Date(expiresAt.getTime() - 24 * 60 * 60 * 1000),
});

// Teardown:
await this.cancelScheduledTask(`watch-renewal:${resourceId}`);
```

**Why it matters:** `scheduleRecurring` survives dropped queue messages, worker
restarts, and deploys — the platform re-arms the chain even if a callback throws
before it can reschedule itself. The callback does **not** need to call
`scheduleRecurring` again on each run; the platform owns the cadence. To tighten
timing (e.g. re-arm at expiry-minus-24h rather than waiting the full ceiling),
re-calling under the same key is fine and atomic — it replaces the pending run
without forking. Use `scheduleTask(key, cb, { runAt })` only for **one-shot**
keyed deferred work (a single future task, atomically replaced if re-keyed).

### Coalescing Webhook-Driven Work

Never enqueue an immediate task per provider notification. Providers like Gmail
push one notification per mailbox change, so `runTask()` in a webhook handler
turns a busy period into a flood of queued sync passes — they batch together,
run concurrently in one worker, and can multiply the working set past the
memory limit. Schedule the pass as a keyed, coalescing task instead:

```typescript
// ❌ WRONG — one queued execution per webhook notification
async onWebhook(request: WebhookRequest) {
  const cb = await this.callback(this.incrementalSync);
  await this.runTask(cb);
}

// ✅ CORRECT — a notification burst collapses into ONE pending pass
async onWebhook(request: WebhookRequest) {
  const cb = await this.callback(this.incrementalSync);
  await this.scheduleTask("incremental-sync", cb, {
    runAt: new Date(Date.now() + 10_000),
    coalesce: true,
  });
}
```

With `coalesce: true` an existing pending task under the key is **kept** — its
fire time is pulled earlier when the new `runAt` is sooner, but never pushed
later, so a continuous stream of notifications can't starve the timer (plain
keyed replace would reset it on every call). A notification arriving while a
pass is already running schedules exactly one follow-up pass. Note that the
callback you pass may be discarded when an existing task is kept — create a
fresh callback each call and don't store or reuse its token.

### Batch Processing Pattern

Use tasks to break long operations into chunks that stay under the ~1000 request limit per execution:

```typescript
async startSync() {
  // Initialize state
  await this.set("sync_state", {
    page: 1,
    hasMore: true
  });

  // Start first batch
  const callback = await this.callback(this.syncBatch);
  // runTask creates NEW execution with fresh request limit
  await this.runTask(callback);
}

async syncBatch() {
  const state = await this.get<{ page: number; hasMore: boolean }>("sync_state");
  if (!state || !state.hasMore) return;

  // Process one page (sized to stay under request limit)
  // If each item makes ~10 requests, fetch ~100 items per page
  // 100 items × 10 requests = 1000 requests (at limit)
  const results = await this.fetchPage(state.page, 100);
  await this.processResults(results);

  // Check if more work remains
  if (results.hasMore) {
    await this.set("sync_state", {
      page: state.page + 1,
      hasMore: true
    });

    // Queue next batch - creates NEW execution with fresh request limit
    const callback = await this.callback(this.syncBatch);
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

All outbound HTTP is blocked except the declared URLs. Wildcards are supported for domains (`https://*.example.com`) and paths (`https://api.example.com/v1/*`).

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

`createWebhook(options, callback, ...extraArgs)` takes a method reference plus optional curried arguments, and returns a unique URL. The method is invoked with the `WebhookRequest` first, followed by the curried arguments:

```typescript
async activate() {
  // Create webhook endpoint
  const webhookUrl = await this.tools.network.createWebhook(
    {},
    this.onCalendarUpdate,
    "primary"
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
async onCalendarUpdate(request: WebhookRequest, calendarId: string) {
  console.log("Webhook received:", request.method);
  console.log("Calendar:", calendarId);

  // Process the webhook (request.body is parsed JSON)
  const event = request.body as { type?: string; event?: unknown };
  if (event.type === "event.created") {
    await this.syncEvent(event.event);
  }
}
```

`WebhookRequest` carries `method`, `headers`, `params` (query string), `body` (parsed JSON when applicable), and `rawBody` (for signature verification).

#### Delivery Mode

By default webhooks are **asynchronous**: Plot immediately responds `200 { queued: true }` to the sender and runs your callback from a queue with at-least-once delivery — so callbacks must be idempotent. This is the right default for event notifications because slow callbacks can't trigger sender-side retry storms.

Pass `async: false` when the sender needs the callback's response — e.g. a subscription validation handshake that must echo a token, or a sender that retries based on status codes. In sync mode, a `string` return value is sent as `text/plain` and other values as JSON.

#### Provider-Specific Webhooks

- **Slack** (`provider: AuthProvider.Slack`): routes by team; requires the `authorization` option.
- **Google Pub/Sub** (`pubsub: "gmail" | "workspace"`): returns a Pub/Sub **topic name** instead of a URL, for Gmail `users.watch` or Google Workspace Events. Other Google products (Calendar, Drive) use standard HTTPS webhooks — don't set `pubsub` for them.

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

Always pass `deleteWebhook()` the exact value returned from `createWebhook()` (a URL, Pub/Sub topic name, or opaque Slack identifier).

---

## Callbacks

Create persistent function references that survive worker restarts. Callbacks methods are available directly on the twist class.

### Setup

Callbacks are available automatically - no build() declaration needed!

### Creating Callbacks

`this.callback()` takes a **method reference** (not a string) plus optional extra arguments to curry. The extra arguments are type-checked against the method's signature and must be serializable:

```typescript
// Create a callback to a method, currying two arguments
const callback = await this.callback(this.handleEvent, "calendar_sync", "high");

// Save it for later use
await this.set("event_handler", callback);
```

For interactive buttons, use `this.actionCallback()` — the method receives the clicked `Action` as its first argument:

```typescript
import { type Action, ActionType } from "@plotday/twister";

const action: Action = {
  type: ActionType.callback,
  title: "Approve",
  callback: await this.actionCallback(this.onApprove, requestId),
};

async onApprove(action: Action, requestId: string) {
  // ...
}
```

### Executing Callbacks

```typescript
import { type Callback } from "@plotday/twister/tools/callbacks";

// Retrieve saved callback
const callback = await this.get<Callback>("event_handler");

if (callback) {
  // Execute inline in the current execution
  const result = await this.run(callback);
}
```

`this.run()` executes inline — it shares the current execution's request count and is appropriate when you need the callback's return value. For fire-and-forget work or batch continuations, prefer `this.runTask()` (see [Tasks](#tasks)). To pass call-time arguments, use the tool directly: `this.tools.callbacks.run(callback, arg1, arg2)`.

### Method Signature

The callback method receives any call-time arguments first, followed by the arguments curried at creation:

```typescript
// Created with: this.callback(this.handleEvent, "calendar_sync", "high")
// Webhooks, actions, etc. supply their own first argument(s) at call time
async handleEvent(
  data: WebhookRequest,           // From the caller (e.g. webhook delivery)
  eventType: string,              // Curried at creation
  priority: string                // Curried at creation
) {
  console.log("Event type:", eventType);
  console.log("Priority:", priority);
}
```

### Callback Versioning and Upgrades

**CRITICAL:** Callbacks automatically upgrade to new twist versions when you deploy an update. This means:

- Callbacks created before an upgrade will execute using the **new version's code**
- The callback is resolved **by function name** at execution time, not at creation time
- You can receive calls with arguments from the previous version running on the new version

#### Handling Version Transitions

You have two options when deploying a new version with callback changes:

**Option 1: Maintain Backward Compatibility** (Recommended)

```typescript
// v1.0 - Original signature
async syncBatch(batchNumber: number, calendarId: string) {
  // Process batch
}

// v1.1 - Add optional parameter at the end
async syncBatch(
  batchNumber: number,
  calendarId: string,
  initialSync?: boolean  // New optional parameter
) {
  const isInitial = initialSync ?? true;  // Safe default for old calls
  // Process batch with new logic
}
```

**Option 2: Maintain Old Function Temporarily**

For breaking changes, keep the old function and create a new one:

```typescript
// v2.0 - Keep old function for in-flight callbacks
async syncBatch(batchNumber: number, calendarId: string) {
  // Old implementation still works for callbacks created in v1.x
  this.processOldBatch(batchNumber, calendarId);
}

// New function with better design
async syncBatchV2(options: SyncOptions) {
  // New implementation
  this.processNewBatch(options);
}

// Later in v3.0 - Remove old function once all callbacks complete
// async syncBatch - REMOVED
```

#### Affected Callback Types

This versioning behavior applies to ALL callbacks:

- **Webhooks** - Long-lived, called by external services
- **Scheduled tasks** - Created with `runTask()`, may run days later
- **Batch operations** - Multi-step processes that span upgrades
- **Action callbacks** - Interactive buttons on notes
- **Auth callbacks** - OAuth completion handlers

#### Migration in upgrade()

For breaking changes, you can recreate callbacks in the `upgrade()` lifecycle method:

```typescript
async upgrade() {
  // Get all active syncs that use old callback signature
  const syncs = await this.get<SyncState[]>("active_syncs");

  for (const sync of syncs ?? []) {
    // Cancel old callback
    const oldCallback = await this.get<Callback>(`sync_callback_${sync.id}`);
    if (oldCallback) {
      await this.deleteCallback(oldCallback);
    }

    // Create new callback with updated signature
    const newCallback = await this.callback(this.syncBatchV2, { syncId: sync.id });
    await this.set(`sync_callback_${sync.id}`, newCallback);
  }
}
```

**Important:** If you don't handle breaking changes, existing callbacks may fail when they execute with incompatible arguments.

### Deleting Callbacks

```typescript
// Delete a specific callback
const callback = await this.get<Callback>("event_handler");
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
- **Note actions** - Interactive buttons on notes

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

Pass `build(AI, { required: false })` if your twist can function without AI; users can disable AI features, and a non-required AI tool then throws on `prompt()`. Check availability first:

```typescript
const { prompt: canPrompt, webSearch } = await this.tools.ai.available();
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
console.log(response.output?.category); // "work" | "personal" | "urgent"
console.log(response.output?.priority); // number (1-5)
console.log(response.output?.summary); // string
```

### Tool Calling

Give the AI access to tools it can call. Each tool declares an `inputSchema` (Typebox) and an optional `execute` function. Set `maxSteps` above 1 so tool results are fed back to the model for a final answer (the default of 1 returns the tool calls without looping):

```typescript
import { Type } from "typebox";

const response = await this.tools.ai.prompt({
  model: { speed: "fast", cost: "medium" },
  prompt: "What's 15% of $250?",
  maxSteps: 3,
  tools: {
    calculate: {
      description: "Perform mathematical calculations",
      inputSchema: Type.Object({
        expression: Type.String({ description: "Math expression to evaluate" }),
      }),
      execute: async ({ expression }) => {
        return { result: evaluate(expression) };
      },
    },
  },
});

console.log(response.text); // "15% of $250 is $37.50"
console.log(response.toolCalls); // Array of tool calls made
```

### Multi-turn Conversations

Build conversations with message history:

```typescript
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

### Web Search

On providers with native web search (check `available().webSearch`), pass `webSearch: true` (or `{ maxUses: n }`) to let the model retrieve up-to-date information; pages used are returned in `response.sources`.

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

Plot automatically selects the best available model matching your preferences. You can optionally suggest a specific model via `hint` (e.g. `hint: AIModel.CLAUDE_SONNET_46`), which the system may override based on user preferences.

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

  // Create thread based on triage
  if (response.output?.category === "urgent") {
    await this.tools.plot.createThread({
      type: "action",
      title: `URGENT: ${response.output.summary}`,
      notes: [
        {
          content: `Actions:\n${response.output.suggestedActions.join("\n")}`,
        },
      ],
    });
  }
}
```

---

## Files

Read files that users attach to notes. Uploaded files appear on notes as `ActionType.file` actions; connectors call `read()` during outbound sync (e.g. `onNoteCreated`) to retrieve the bytes and send them to the source system.

### Setup

```typescript
import { Files } from "@plotday/twister/tools/files";

build(build: ToolBuilder) {
  return {
    files: build(Files),
  };
}
```

### Reading Files

```typescript
import { ActionType } from "@plotday/twister";

async onNoteCreated(note: Note) {
  for (const action of note.actions ?? []) {
    if (action.type === ActionType.file) {
      const file = await this.tools.files.read(action.fileId);
      // file.data: Uint8Array, plus fileName, mimeType, fileSize
      await this.uploadToSource(file);
    }
  }
}
```

`read()` throws `FileNotFoundError` if the file is missing or out of scope.

For **inbound** attachments (files that live in the external system), connectors emit `ActionType.fileRef` actions and implement `Connector.downloadAttachment()` — the bytes are fetched on demand and never stored in Plot.

---

## Other Built-in Tools

A few specialized tools are also available — see their type definitions for full APIs:

- **Imap** (`@plotday/twister/tools/imap`) and **Smtp** (`@plotday/twister/tools/smtp`) — raw IMAP/SMTP sessions for password-based email connectors (connect, list mailboxes, search/fetch messages, set flags, send).
- **Twists** (`@plotday/twister/tools/twists`) — programmatically create, generate, and deploy twists, and subscribe to their logs. Used by twist-builder twists.

---

## Link Type Safety Pattern

When defining `linkTypes` in your connector, use `as const satisfies LinkTypeConfig[]` to get type-safe status strings:

```typescript
import type { LinkTypeConfig } from "@plotday/twister/tools/integrations";

const LINK_TYPES = [
  {
    type: "issue",
    label: "Issue",
    logo: "https://api.iconify.design/simple-icons/linear.svg",
    statuses: [
      { status: "open", label: "Open", icon: "todo" },
      { status: "done", label: "Done", icon: "done", done: true },
    ],
  },
  {
    type: "pull_request",
    label: "Pull Request",
    logo: "https://api.iconify.design/simple-icons/github.svg",
    statuses: [
      { status: "open", label: "Open", icon: "inProgress" },
      { status: "merged", label: "Merged", icon: "done", done: true },
      { status: "closed", label: "Closed", icon: "cancelled", done: true },
    ],
  },
] as const satisfies LinkTypeConfig[];

// Derive type-safe union types from the config
type IssueStatus = (typeof LINK_TYPES)[0]["statuses"][number]["status"]; // "open" | "done"
type PRStatus = (typeof LINK_TYPES)[1]["statuses"][number]["status"]; // "open" | "merged" | "closed"
```

Note that every status requires a curated `icon` (`StatusIcon`) so the UI always has a glyph to render.

Then declare `linkTypes` as a class property on your connector:

```typescript
class MyConnector extends Connector<MyConnector> {
  readonly provider = MyConnector.PROVIDER;
  readonly scopes = MyConnector.SCOPES;
  readonly linkTypes = [...LINK_TYPES];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      // ...
    };
  }
}
```

---

## Next Steps

- **[Building Connectors](BUILDING_CONNECTORS.md)** - Build external service integrations
- **[Runtime Environment](RUNTIME.md)** - Understanding execution constraints
- **API Reference** - Explore detailed API docs in the sidebar
