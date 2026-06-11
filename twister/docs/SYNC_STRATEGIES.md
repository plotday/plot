# Sync Strategies

This guide explains good ways to build connectors that sync other services with Plot. Choosing the right strategy depends on whether you need to update items, deduplicate them, or simply create them once.

## Table of Contents

- [Overview](#overview)
- [Strategy 1: Create Once (Fire and Forget)](#strategy-1-create-once-fire-and-forget)
- [Strategy 2: Upsert via Source and Key (Recommended)](#strategy-2-upsert-via-source-and-key-recommended)
- [Strategy 3: Generate and Store IDs (Advanced)](#strategy-3-generate-and-store-ids-advanced)
- [Tags and Reactions](#tags-and-reactions)
- [Initial vs Incremental Sync](#initial-vs-incremental-sync)
- [Choosing the Right Strategy](#choosing-the-right-strategy)

## Overview

Plot provides three main strategies for managing threads, links, and notes:

| Strategy                   | Use Case                                           | Complexity | Deduplication | Updates |
| -------------------------- | -------------------------------------------------- | ---------- | ------------- | ------- |
| **Create Once**            | One-time notifications, transient events           | Low        | None          | No      |
| **Upsert via Source/Key**  | Most integrations (calendars, tasks, issues)       | Low        | Automatic     | Yes     |
| **Generate and Store IDs** | Complex transformations, multiple items per source | High       | Manual        | Yes     |

**Recommended for most use cases**: Strategy 2 (Upsert via Source/Key)

## Strategy 1: Create Once (Fire and Forget)

### When to Use

Use this strategy when:

- Items are created once and never need updates
- Duplicates are acceptable or expected
- You're creating notifications, alerts, or transient events
- The external system doesn't provide stable identifiers

### How It Works

Simply create threads and notes without specifying `id` or `source` fields. Plot will generate unique IDs automatically.

### Example: Simple Notification

```typescript
export default class NotificationTwist extends Twist<NotificationTwist> {
  async sendAlert(title: string, message: string): Promise<void> {
    // Create a simple thread with one note
    await this.tools.plot.createThread({
      title: title,
      notes: [
        {
          content: message,
        },
      ],
    });
  }
}
```

### Pros and Cons

**Pros:**

- Simplest approach
- No storage overhead
- No external API lookups needed
- Fast execution

**Cons:**

- No deduplication
- Cannot update existing items
- Can create duplicates if called multiple times

## Strategy 2: Upsert via Source and Key (Recommended)

### When to Use

Use this strategy when:

- You're integrating with external systems that provide stable URLs or IDs
- Items need to be updated when the external source changes
- You want automatic deduplication without manual tracking
- You're syncing calendars, tasks, issues, messages, or similar entities

### How It Works

**For Links:**
Connectors save data with `integrations.saveLink()` (or the batch `saveLinks()`), passing a `NewLinkWithNotes`. Set the `source` field to a stable identifier (or list canonical aliases in `sources`). When you save a link whose source the user already has, Plot will **update** the existing thread+link instead of creating a duplicate.

**For Notes:**
Use the `key` field on each note to enable upserts. When you save a note with a key that already exists on the thread, Plot will **update** that note instead of creating a duplicate.

### Link Upserts

The `source` field should be:

- A stable identifier in a namespaced format (e.g., `linear:issue:<uuid>`, `gmail:thread-id-123`) — use immutable ids, and put the human-facing URL in `sourceUrl`
- **Globally unique for the logical external item** — see the cross-user dedup note below

> **Cross-user dedup:** Two instances of the same connector (run by two different Plot users) that emit the same `source` for the same external item will converge on a **single shared thread**. This is how two users on the same Gmail message, calendar event, or Linear issue see one thread rather than two.
>
> This means `source` must not merely be unique within one user's account — it must be globally unique for the item. If an external id is workspace- or tenant-scoped (Attio record ids, PostHog distinct_ids, Outlook event ids, Fellow note ids, etc.), include the workspace/tenant/mailbox id as a qualifier: `attio:<workspaceId>:person:<recordId>`, not `attio:person:<recordId>`. See `connectors/AGENTS.md` → "`source` — idempotency + cross-user dedup" for the full guidance.

For cross-connector bundling, use the plural `sources` array instead: any element shared with another link's `sources` bundles the two links into the same thread. For example, every calendar connector emits `icaluid:<iCalUID>` so a meeting-notes connector can attach onto the same event thread by emitting the same alias. (`source` is the single-value shorthand for `sources` and is kept for backward compatibility; the runtime normalizes between them.)

### Example: Calendar Event Sync

```typescript
export default class GoogleCalendarConnector extends Connector<GoogleCalendarConnector> {
  async syncEvent(event: calendar_v3.Schema$Event): Promise<void> {
    const notes: Omit<NewNote, "thread">[] = [];

    // Add description as an upsertable note
    if (event.description) {
      notes.push({
        // Use a key for this specific note type
        key: "description",
        content: event.description,
      });
    }

    const link: NewLinkWithNotes = {
      // Stable, cross-connector identifier for the event
      sources: [`icaluid:${event.iCalUID}`],
      type: "event",
      title: event.summary || "(No title)",
      sourceUrl: event.htmlLink ?? null,
      schedules: [
        {
          start: event.start?.dateTime || event.start?.date || new Date(),
          end: event.end?.dateTime || event.end?.date || undefined,
        },
      ],
      notes,
    };

    // Create or update the thread+link pair
    await this.tools.integrations.saveLink(link);
  }
}
```

**How it works:**

1. First sync: A thread+link with `sources: ["icaluid:..."]` is created with its description note and schedule
2. Event updated externally: Same source is used, so Plot updates the existing thread instead of creating a duplicate
3. Description changes: Note with `key: "description"` is updated
4. No duplicates created, no manual ID tracking needed

### Example: Task/Issue Sync

```typescript
export default class LinearConnector extends Connector<LinearConnector> {
  async syncIssue(issue: LinearIssue): Promise<void> {
    const notes: Omit<NewNote, "thread">[] = [];

    // Description note with upsert
    if (issue.description) {
      notes.push({
        key: "description",
        content: issue.description,
      });
    }

    const link: NewLinkWithNotes = {
      // Use the immutable issue ID, not the (mutable) URL slug
      source: `linear:issue:${issue.id}`,
      sourceUrl: issue.url,
      type: "issue",
      // Matches a statuses[].status entry in this connector's linkTypes
      status: issue.state.type === "completed" ? "done" : "open",
      title: `${issue.identifier}: ${issue.title}`,
      meta: { issueId: issue.id, issueKey: issue.identifier },
      notes,
    };

    await this.tools.integrations.saveLink(link);
  }
}
```

### Referencing Threads When Creating Notes

When creating a note separately (not as part of `NewLinkWithNotes`), reference the thread by its source. Connectors typically re-run `saveLink` with the new notes included (the link upserts, the notes upsert by key); twists with the Plot tool can address the thread directly:

```typescript
// Add a comment to an existing thread (Plot tool)
await this.tools.plot.createNote({
  thread: { source: "github:user/repo/issue:42" },
  key: `comment-${comment.id}`, // Unique key per comment
  content: comment.body,
});
```

### Note Key Patterns

The `key` field enables upsert behavior for notes. Choose keys based on your use case:

**Single instance notes** (will be updated on each sync):

- `key: "description"` - Main description/body
- `key: "metadata"` - Status, assignee, etc.
- `key: "attendees"` - Event attendees list

**Multiple instance notes** (use unique keys):

- `key: "comment-${commentId}"` - Each comment has unique ID
- `key: "attachment-${filename}"` - Each attachment has unique name
- `key: "change-${timestamp}"` - Each change log entry

**No key** (creates new note every time):

- Omit `key` field when you want new notes created on each sync
- Useful for chat messages, activity logs, or append-only data

### Pros and Cons

**Pros:**

- Automatic deduplication
- No storage overhead for ID mappings
- No need to look up existing items before creating
- Clean, maintainable code
- The human-facing URL still surfaces via `sourceUrl` (user-friendly)

**Cons:**

- Requires stable identifiers from external system
- One Plot thread per external source item
- Cannot create multiple Plot items from single source item

## Strategy 3: Generate and Store IDs (Advanced)

### When to Use

Use this strategy when:

- You need to create multiple Plot threads from a single external item
- External system doesn't provide stable identifiers
- You need complex transformations or splitting
- Source-based upserts aren't flexible enough for your use case

This strategy uses the Plot tool (`createThread` with explicit `id`s), so it applies to twists. Connectors save through `integrations.saveLink()` and should use Strategy 2.

### How It Works

1. Generate a unique ID using `Uuid.Generate()`
2. Store the mapping between external ID and Plot ID
3. Look up existing IDs before creating items
4. Use stored IDs when updating

### Example: Multiple Threads from Single Source

```typescript
export default class EmailTasksTwist extends Twist<EmailTasksTwist> {
  /**
   * Creates separate Plot threads for an email thread and individual messages.
   * One email thread can map to multiple Plot threads.
   */
  async syncThread(thread: GmailThread): Promise<void> {
    // Check if we've seen this thread before
    const threadKey = `thread:${thread.id}`;
    let plotThreadId = await this.get<Uuid>(threadKey);

    // Generate ID if this is a new thread
    if (!plotThreadId) {
      plotThreadId = Uuid.Generate();
      await this.set(threadKey, plotThreadId);
    }

    // Create/update the thread
    await this.tools.plot.createThread({
      id: plotThreadId,
      title: thread.snippet,
      // Note: we use `id` instead of `source` for manual control
    });

    // Create separate threads for each important message in the email thread
    for (const message of thread.messages) {
      if (this.isImportantMessage(message)) {
        const messageKey = `message:${message.id}`;
        let messageThreadId = await this.get<Uuid>(messageKey);

        if (!messageThreadId) {
          messageThreadId = Uuid.Generate();
          await this.set(messageKey, messageThreadId);
        }

        await this.tools.plot.createThread({
          id: messageThreadId,
          type: "action",
          title: `Reply to: ${message.subject}`,
          notes: [
            {
              content: message.body,
            },
          ],
        });
      }
    }
  }

  private isImportantMessage(message: GmailMessage): boolean {
    // Custom logic to determine if message needs a separate thread
    return message.labelIds?.includes("IMPORTANT") || false;
  }
}
```

### Storage Patterns

**Simple mapping:**

```typescript
// Store external ID → Plot ID
await this.set(`external:${externalId}`, plotId);

// Retrieve
const plotId = await this.get<string>(`external:${externalId}`);
```

**Structured mapping:**

```typescript
interface Mapping {
  plotId: string;
  externalId: string;
  lastSynced: string;
  syncCount: number;
}

await this.set(`mapping:${externalId}`, mapping);
```

### Lookup and Update Pattern

```typescript
async syncItem(externalItem: ExternalItem): Promise<void> {
  const key = `item:${externalItem.id}`;

  // Look up existing Plot ID
  let plotId = await this.get<Uuid>(key);

  // Generate new ID if not found
  if (!plotId) {
    plotId = Uuid.Generate();
    await this.set(key, plotId);
  }

  // Create or update using the ID
  await this.tools.plot.createThread({
    id: plotId,
    type: "action",
    title: externalItem.title,
    // ... other fields
  });
}
```

### Pros and Cons

**Pros:**

- Maximum flexibility
- Can create multiple Plot items per external item
- Works without stable external identifiers
- Full control over ID lifecycle

**Cons:**

- Requires storage for mappings
- Needs lookup before each create/update
- More code to maintain
- Slower due to additional storage operations
- Must manage cleanup of old mappings

## Tags and Reactions

Plot's `tags` are a small set of system "compute" tags (`Tag.Todo`, `Tag.Done`, `Tag.Twist` from `@plotday/twister/tag`) — not free-form labels. External system labels have no tag equivalent: keep them in the link's `meta` (or render them in a note), and map completion-style state to the link's `status`. Emoji reactions round-trip through the separate `reactions` field on threads and notes.

### Syncing Reactions

Include reactions in the note upsert, keyed by emoji with the actors who reacted:

```typescript
notes: [
  {
    key: `comment-${comment.id}`,
    content: comment.body,
    reactions: {
      "👍": [{ email: "amy@example.com", name: "Amy" }],
    },
  },
],
```

To remove a reaction for an actor, omit them from that emoji's list; an empty list removes the reaction entirely. Omit an emoji to leave it untouched.

### Updating Tags from a Twist

Twists with the Plot tool toggle their own compute tags via `twistTags` — `true` adds the tag, `false` removes it, and other actors' tags are untouched:

```typescript
await this.tools.plot.updateThread({
  id: threadId,
  twistTags: { [Tag.Todo]: true },
});
```

The same `twistTags` field exists on `updateNote()` for note-level tags.

### Completion State

For connectors, "done-ness" lives on the link's `status` (declared in `linkTypes` with `done: true` on completed statuses), not on a tag:

```typescript
await this.tools.integrations.saveLink({
  source: `linear:issue:${issue.id}`,
  status: issue.completed ? "done" : "open",
});
```

## Initial vs Incremental Sync

When syncing items from external systems, it's critical to distinguish between initial sync (first import) and incremental sync (ongoing updates). This prevents notification spam and properly handles archived state.

### The `initialSync` Flag Pattern

All sync-based connectors should track whether they're performing an initial sync or incremental sync:

| Field | Initial Sync | Incremental Sync | Reason |
|-------|--------------|------------------|---------|
| `unread` | `false` | *omit* | Avoid notification overload from historical items; omitting uses the default (unread for users) |
| `archived` | `false` | *omit* | Unarchive on install, preserve user choice on updates |

### Example Implementation

```typescript
async startSync(channelId: string): Promise<void> {
  // Store initial sync state
  await this.set(`sync_state_${channelId}`, {
    channelId,
    initialSync: true,
  });

  // Start first batch with initialSync = true
  const callback = await this.callback(this.syncBatch, channelId, true);
  // runTask creates NEW execution with fresh ~1000 request limit
  await this.runTask(callback);
}

async syncBatch(channelId: string, initialSync: boolean): Promise<void> {
  const token = await this.tools.integrations.get(channelId);
  if (!token) return;

  // Fetch events from external API (keep batch size reasonable to stay under request limit)
  const { events, hasMorePages } = await this.fetchEvents(token, channelId);

  // Save links with proper flags — one batched saveLinks call per page
  const links: NewLinkWithNotes[] = events.map((event) => ({
    source: `example:event:${event.id}`,
    sourceUrl: event.url,
    type: "event",
    title: event.title,
    ...(initialSync ? { unread: false, archived: false } : {}), // omit both for incremental
    notes: event.description
      ? [{ key: "description", content: event.description }]
      : [],
  }));
  await this.tools.integrations.saveLinks(links);

  // Queue next batch or switch to incremental mode
  if (hasMorePages) {
    const callback = await this.callback(this.syncBatch, channelId, initialSync);
    // Each runTask creates NEW execution with fresh request limit
    await this.runTask(callback);
  } else if (initialSync) {
    // Initial sync complete, switch to incremental mode
    await this.set(`sync_state_${channelId}`, {
      channelId,
      initialSync: false,
      lastSync: new Date().toISOString(),
    });
    // Clear the "syncing…" indicator on the connection
    await this.tools.integrations.channelSyncCompleted(channelId);
  }
}
```

### Why This Matters

**Initial sync (first import):**
- Threads are **unarchived** (`archived: false`) - gives user a fresh start
- Threads are marked as **read** (`unread: false`) - prevents notification spam from bulk historical imports
- Use case: When user first installs the connector or reconnects after disconnection

**Incremental sync (ongoing updates):**
- New threads appear as **unread** (`unread` omitted — the default) - user gets notified of new items
- Archived state is **preserved** (field omitted) - respects user's archiving decisions
- Use case: Regular syncs after initial setup is complete

**Reinstall behavior:**
- Acts as initial sync - previously archived threads are unarchived for fresh start
- User gets a clean slate without notification overload

### Tracking Sync State

Store the `initialSync` flag in your sync state:

```typescript
interface SyncState {
  channelId: string;
  initialSync: boolean;
  lastSync: string | null;
}

// Check sync mode before each batch
const state = await this.get<SyncState>(`sync_state_${channelId}`);
const initialSync = state?.initialSync ?? true;  // Default to initial if not set
```

## Choosing the Right Strategy

Use this decision tree to select the appropriate strategy:

```
Do items need to be updated after creation?
├─ No
│  └─ Use Strategy 1 (Create Once)
│     Example: Alerts, one-time notifications
│
└─ Yes
   │
   Does the external system provide stable URLs or IDs?
   ├─ Yes
   │  │
   │  Do you need multiple Plot items per external item?
   │  ├─ No
   │  │  └─ Use Strategy 2 (Upsert via Source/Key) ⭐ RECOMMENDED
   │  │     Example: Calendar events, tasks, issues
   │  │
   │  └─ Yes
   │     └─ Use Strategy 3 (Generate and Store IDs)
   │        Example: Email thread → multiple Plot threads
   │
   └─ No
      └─ Use Strategy 3 (Generate and Store IDs)
         Example: Systems without stable identifiers
```

### Common Use Cases

| Integration      | Recommended Strategy | Rationale                                                          |
| ---------------- | -------------------- | ------------------------------------------------------------------ |
| Google Calendar  | Strategy 2           | Events have stable `iCalUID`s (`icaluid:<uid>`)                     |
| Outlook Calendar | Strategy 2           | Events have stable IDs (qualify with the mailbox ID)                |
| Jira             | Strategy 2           | Issues have stable immutable IDs                                    |
| Linear           | Strategy 2           | Issues have stable immutable IDs                                    |
| Asana            | Strategy 2           | Tasks have stable IDs                                               |
| GitHub Issues    | Strategy 2           | Issues have stable `owner/repo` + number IDs                        |
| Gmail (threads)  | Strategy 2           | One thread per Gmail thread; messages upsert as notes keyed by message ID |
| Slack (threads)  | Strategy 2           | Threads have stable channel:thread IDs                              |
| RSS Feeds        | Strategy 2           | Items usually have GUIDs or links                                   |
| Webhooks         | Strategy 1 or 2      | Depends on whether updates are needed                               |
| Notifications    | Strategy 1           | Usually one-time, no updates needed                                 |

### Migration Between Strategies

If you need to change strategies for an existing tool:

**From Strategy 1 to Strategy 2:**

- Existing items will remain as duplicates
- New syncs will use source-based deduplication
- Consider adding migration logic to clean up duplicates

**From Strategy 3 to Strategy 2:**

- There is no way to attach a `source` to an existing thread that was created by ID, so old items can't be adopted into source-based upserts in place
- Either keep the stored ID mapping for items created before the migration (and use Strategy 2 only for new items), or archive the old threads and re-sync them by source
- Clean up mappings you no longer need with `this.clear(key)`

**From Strategy 2 to Strategy 3:**

- Existing threads will remain with their sources
- New items can use generated IDs
- Both can coexist if needed

## Best Practices

### 1. Be Consistent Within a Connector

Choose one strategy per connector and stick with it. Mixing strategies in the same connector can lead to confusion and bugs.

### 2. Use Descriptive Keys

```typescript
// Good: descriptive, unique keys
key: "description";
key: "metadata";
key: "comment-${commentId}";
key: "attachment-${filename}";

// Bad: generic, collision-prone keys
key: "note";
key: "data";
key: "1";
```

### 3. Handle Missing Sources Gracefully

```typescript
const source = event.id
  ? `example:event:${event.id}`
  : `temp:${Uuid.Generate()}`;
```

### 4. Document Your Strategy

Add comments explaining which strategy you're using and why:

```typescript
/**
 * Syncs calendar events using Strategy 2 (Upsert via Source).
 * Each Google Calendar event has a stable iCalUID that serves as the source.
 * Event details are stored as upsertable notes using keys.
 */
async syncEvents(): Promise<void> {
  // ...
}
```

### 5. Clean Up When Needed

For Strategy 3, implement cleanup for old mappings:

```typescript
async cleanupOldMappings(): Promise<void> {
  // Remove mappings for items deleted externally
  const keys = await this.tools.store.list("external:");
  for (const key of keys) {
    const externalId = key.replace("external:", "");
    const exists = await this.checkExternalItemExists(externalId);
    if (!exists) {
      await this.clear(key);
    }
  }
}
```

### 6. Avoid Race Conditions in Two-Way Sync

When implementing two-way sync where items can be created in Plot and pushed to an external system (e.g. Notes becoming comments), update the link's `source` / `Note.key` **after** creating the external item. If the external system supports setting custom metadata, include the `Thread.id` / `Note.id` in the metadata when creating the external item. Then, when processing an incoming webhook, check for the Plot ID in the metadata first and use it if present.

This eliminates a race condition where a webhook for an item you're creating arrives before you've updated the link/note with the external key. Without this pattern, the webhook handler won't find the item by external key and may create a duplicate.

In a connector, return a `NoteWriteBackResult` from `onNoteCreated` — the runtime sets the key atomically and also records the external content as the sync baseline:

```typescript
async onNoteCreated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
  const externalComment = await externalApi.createComment(thread.meta?.externalItemId, {
    body: note.content ?? "",
    metadata: { plotNoteId: note.id },  // Embed Plot ID for webhook correlation
  });
  if (!externalComment?.id) return;
  return {
    key: `comment-${externalComment.id}`,
    // What the external system NOW STORES — must match what your sync-in
    // path emits as NewNote.content on re-ingest. The runtime hashes this
    // so the next sync re-listing unchanged content preserves Plot's
    // (possibly richer-markdown) version instead of clobbering it.
    externalContent: externalComment.body,
  };
}

async onWebhook(payload: WebhookPayload): Promise<void> {
  const comment = payload.comment;

  // Use the Plot ID from metadata if present (handles the race where the
  // webhook arrives before onNoteCreated's return has been applied),
  // otherwise fall back to upserting by note key alone.
  await this.tools.integrations.saveLink({
    source: payload.itemSource, // upserts the existing thread+link
    notes: [
      {
        ...(comment.metadata?.plotNoteId
          ? { id: comment.metadata.plotNoteId }
          : {}),
        key: `comment-${comment.id}`,
        content: comment.body,
      },
    ],
  });
}
```

For twists that write notes outside the `onNoteCreated` dispatch path (explicit `pushNoteAsComment`-style methods), set `key` via `updateNote` after the external write. In that path the sync baseline is **not** established, so the next sync-in will overwrite Plot's content with the external version. Prefer the connector `onNoteCreated` flow when round-trip preservation matters.

See `connectors/AGENTS.md` → "Sync baseline preservation" for the full contract on what `externalContent` must equal.

## Summary

- **Strategy 1** (Create Once): Simplest, no deduplication, use for one-time items
- **Strategy 2** (Upsert via Source/Key): Recommended for most integrations, automatic deduplication
- **Strategy 3** (Generate and Store IDs): Advanced use cases, maximum flexibility, more complexity

Start with Strategy 2 for most integrations. Only use Strategy 3 when you have specific requirements that Strategy 2 cannot fulfill.

For more information:

- [Core Concepts](CORE_CONCEPTS.md) - Understanding threads, notes, and focuses
- [Tools Guide](TOOLS_GUIDE.md) - Complete reference for the Plot tool
- [Building Connectors](BUILDING_CONNECTORS.md) - Creating external service integrations
