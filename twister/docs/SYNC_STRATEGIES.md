# Sync Strategies

This guide explains good ways to build tools that sync other services with Plot. Choosing the right strategy depends on whether you need to update items, deduplicate them, or simply create them once.

## Table of Contents

- [Overview](#overview)
- [Strategy 1: Create Once (Fire and Forget)](#strategy-1-create-once-fire-and-forget)
- [Strategy 2: Upsert via Source and Key (Recommended)](#strategy-2-upsert-via-source-and-key-recommended)
- [Strategy 3: Generate and Store IDs (Advanced)](#strategy-3-generate-and-store-ids-advanced)
- [Tag Management](#tag-management)
- [Choosing the Right Strategy](#choosing-the-right-strategy)

## Overview

Plot provides three main strategies for managing activities and notes:

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

Simply create activities and notes without specifying `id` or `source` fields. Plot will generate unique IDs automatically.

### Example: Simple Notification

```typescript
export default class NotificationTwist extends Twist {
  async sendAlert(title: string, message: string): Promise<void> {
    // Create a simple note-only activity
    await this.tools.plot.createActivity({
      type: ActivityType.Note,
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

**For Activities:**
Set the `source` field to a canonical URL or stable identifier. When you create an activity with a source that already exists in the priority tree, Plot will **update** the existing activity instead of creating a duplicate.

**For Notes:**
Use the `key` field combined with the activity's source to enable upserts. When you create a note with a key that already exists on the activity, Plot will **update** that note instead of creating a duplicate.

### Activity Upserts

The `source` field should be:

- A canonical URL from the external system (preferred)
- A stable identifier in a namespaced format (e.g., `gmail:thread-id-123`)
- Unique within the priority tree

```typescript
// Activity.source field definition
interface Activity {
  /**
   * Canonical URL for the item in an external system.
   * For example, https://acme.atlassian.net/browse/PROJ-42 could represent a Jira issue.
   * When set, it uniquely identifies the activity within a priority tree.
   */
  source: string | null;
}
```

### Example: Calendar Event Sync

```typescript
export default class GoogleCalendarTool extends Tool<GoogleCalendarTool> {
  async syncEvent(event: calendar_v3.Schema$Event): Promise<void> {
    const activity: NewActivityWithNotes = {
      // Use the event's canonical URL as the source
      source: event.htmlLink,
      type: ActivityType.Event,
      title: event.summary || "(No title)",
      start: event.start?.dateTime || event.start?.date || null,
      end: event.end?.dateTime || event.end?.date || null,
      notes: [],
    };

    // Add description as an upsertable note
    if (event.description) {
      activity.notes.push({
        // Reference the activity by its source
        activity: { source: event.htmlLink },
        // Use a key for this specific note type
        key: "description",
        content: event.description,
      });
    }

    // Add attendees as an upsertable note
    if (event.attendees?.length) {
      const attendeeList = event.attendees
        .map((a) => `- ${a.email}${a.displayName ? ` (${a.displayName})` : ""}`)
        .join("\n");

      activity.notes.push({
        activity: { source: event.htmlLink },
        key: "attendees",
        content: `## Attendees\n${attendeeList}`,
      });
    }

    // Create or update the activity
    await this.tools.plot.createActivity(activity);
  }
}
```

**How it works:**

1. First sync: Activity with `source: event.htmlLink` is created with two notes (description and attendees)
2. Event updated externally: Same `source` is used, so Plot updates the existing activity
3. Description changes: Note with `key: "description"` is updated
4. Attendees change: Note with `key: "attendees"` is updated
5. No duplicates created, no manual ID tracking needed

### Example: Task/Issue Sync

```typescript
export default class LinearTool extends Tool<LinearTool> {
  async syncIssue(issue: LinearIssue): Promise<void> {
    const activity: NewActivityWithNotes = {
      source: issue.url, // Linear provides stable URLs
      type: ActivityType.Action,
      title: `${issue.identifier}: ${issue.title}`,
      done: issue.state.type === "completed" ? new Date() : null,
      notes: [],
    };

    // Description note with upsert
    if (issue.description) {
      activity.notes.push({
        activity: { source: issue.url },
        key: "description",
        content: issue.description,
      });
    }

    // Metadata note with upsert
    activity.notes.push({
      activity: { source: issue.url },
      key: "metadata",
      content: [
        `**Status**: ${issue.state.name}`,
        `**Priority**: ${issue.priority}`,
        `**Assignee**: ${issue.assignee?.name || "Unassigned"}`,
      ].join("\n"),
    });

    await this.tools.plot.createActivity(activity);
  }
}
```

### Referencing Activities When Creating Notes

When creating a note separately (not as part of `NewActivityWithNotes`), reference the activity by its source:

```typescript
// Add a comment to an existing activity
await this.tools.plot.createNote({
  activity: { source: "https://github.com/user/repo/issues/42" },
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
- Works with external URLs (user-friendly)

**Cons:**

- Requires stable identifiers from external system
- One Plot activity per external source item
- Cannot create multiple Plot items from single source item

## Strategy 3: Generate and Store IDs (Advanced)

### When to Use

Use this strategy when:

- You need to create multiple Plot activities from a single external item
- External system doesn't provide stable identifiers
- You need complex transformations or splitting
- Source-based upserts aren't flexible enough for your use case

### How It Works

1. Generate a unique ID using `Uuid.Generate()`
2. Store the mapping between external ID and Plot ID
3. Look up existing IDs before creating items
4. Use stored IDs when updating

### Example: Multiple Activities from Single Source

```typescript
export default class EmailTool extends Tool<EmailTool> {
  /**
   * Creates separate activities for email threads and individual messages.
   * One email thread can have multiple Plot activities.
   */
  async syncThread(thread: GmailThread): Promise<void> {
    // Check if we've seen this thread before
    const threadKey = `thread:${thread.id}`;
    let threadActivityId = await this.get<string>(threadKey);

    // Generate ID if this is a new thread
    if (!threadActivityId) {
      threadActivityId = Uuid.Generate();
      await this.set(threadKey, threadActivityId);
    }

    // Create/update the thread activity
    await this.tools.plot.createActivity({
      id: threadActivityId,
      type: ActivityType.Note,
      title: thread.snippet,
      // Note: we use `id` instead of `source` for manual control
    });

    // Create separate activities for each important message in thread
    for (const message of thread.messages) {
      if (this.isImportantMessage(message)) {
        const messageKey = `message:${message.id}`;
        let messageActivityId = await this.get<string>(messageKey);

        if (!messageActivityId) {
          messageActivityId = Uuid.Generate();
          await this.set(messageKey, messageActivityId);
        }

        await this.tools.plot.createActivity({
          id: messageActivityId,
          type: ActivityType.Action,
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
    // Custom logic to determine if message needs separate activity
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
  let plotId = await this.get<string>(key);

  // Generate new ID if not found
  if (!plotId) {
    plotId = Uuid.Generate();
    await this.set(key, plotId);
  }

  // Create or update using the ID
  await this.tools.plot.createActivity({
    id: plotId,
    type: ActivityType.Action,
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

## Tag Management

Tags can be applied to both activities and notes. Plot provides helpers for managing tags during sync operations.

### Tag Helpers

The Plot tool provides tag management methods:

```typescript
// Activity tags
await this.tools.plot.setActivityTags(activity, ["work", "urgent"]);
await this.tools.plot.addActivityTag(activity, "client-meeting");
await this.tools.plot.removeActivityTag(activity, "draft");

// Note tags
await this.tools.plot.setNoteTags(note, ["comment", "external"]);
await this.tools.plot.addNoteTag(note, "resolved");
await this.tools.plot.removeNoteTag(note, "pending");
```

### Tag Sync Patterns

**Replace all tags (set):**

```typescript
// Sync tags from external system, replacing existing tags
await this.tools.plot.setActivityTags(
  { source: issue.url },
  issue.labels.map((l) => l.name)
);
```

**Additive tagging (add):**

```typescript
// Add tags without removing existing ones
if (event.isRecurring) {
  await this.tools.plot.addActivityTag({ source: event.htmlLink }, "recurring");
}
```

**Conditional tagging:**

```typescript
// Tag based on external state
if (task.priority === "high") {
  await this.tools.plot.addActivityTag({ source: task.url }, "urgent");
} else {
  await this.tools.plot.removeActivityTag({ source: task.url }, "urgent");
}
```

### Tag Namespacing

To avoid tag collisions between different twists and tools, consider namespacing:

```typescript
// Namespace tags with tool name
const tags = externalLabels.map((label) => `jira:${label}`);
await this.tools.plot.setActivityTags({ source: issue.url }, tags);

// Or use a prefix constant
const TAG_PREFIX = "linear-";
await this.tools.plot.addActivityTag(
  { source: issue.url },
  `${TAG_PREFIX}${issue.state.name}`
);
```

### Referencing Items for Tag Operations

Like note creation, tag operations can reference activities by source:

```typescript
// Using source
await this.tools.plot.addActivityTag(
  { source: "https://app.asana.com/0/123/456" },
  "in-progress"
);

// Using ID (if you're using Strategy 3)
await this.tools.plot.addActivityTag({ id: storedActivityId }, "synced");
```

### Tag Cleanup

When an external item is deleted or tags are removed, clean up tags in Plot:

```typescript
// Remove all tags from external system
const externalTags = issue.labels.map((l) => `jira:${l}`);
await this.tools.plot.setActivityTags({ source: issue.url }, externalTags);

// Or remove specific tags
for (const removedLabel of removedLabels) {
  await this.tools.plot.removeActivityTag(
    { source: issue.url },
    `jira:${removedLabel}`
  );
}
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
   │        Example: Email thread → multiple activities
   │
   └─ No
      └─ Use Strategy 3 (Generate and Store IDs)
         Example: Systems without stable identifiers
```

### Common Use Cases

| Integration      | Recommended Strategy | Rationale                                   |
| ---------------- | -------------------- | ------------------------------------------- |
| Google Calendar  | Strategy 2           | Events have stable `htmlLink` URLs          |
| Outlook Calendar | Strategy 2           | Events have `webLink` URLs                  |
| Jira             | Strategy 2           | Issues have stable URLs                     |
| Linear           | Strategy 2           | Issues have stable URLs                     |
| Asana            | Strategy 2           | Tasks have stable URLs                      |
| GitHub Issues    | Strategy 2           | Issues have stable URLs                     |
| Gmail (threads)  | Strategy 2 or 3      | Use 2 for thread-level, 3 for message-level |
| Slack (threads)  | Strategy 2           | Threads have stable channel:thread IDs      |
| RSS Feeds        | Strategy 2           | Items usually have GUIDs or links           |
| Webhooks         | Strategy 1 or 2      | Depends on whether updates are needed       |
| Notifications    | Strategy 1           | Usually one-time, no updates needed         |

### Migration Between Strategies

If you need to change strategies for an existing tool:

**From Strategy 1 to Strategy 2:**

- Existing items will remain as duplicates
- New syncs will use source-based deduplication
- Consider adding migration logic to clean up duplicates

**From Strategy 3 to Strategy 2:**

```typescript
// Migration: lookup existing ID, add source, then clean up mapping
const existingId = await this.get<string>(`external:${item.id}`);
if (existingId) {
  await this.tools.plot.createActivity({
    id: existingId,
    source: item.url, // Add source to existing activity
    // ... other fields
  });
  await this.delete(`external:${item.id}`); // Clean up mapping
}
```

**From Strategy 2 to Strategy 3:**

- Existing activities will remain with their sources
- New items can use generated IDs
- Both can coexist if needed

## Best Practices

### 1. Be Consistent Within a Tool

Choose one strategy per tool and stick with it. Mixing strategies in the same tool can lead to confusion and bugs.

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
const source = event.htmlLink || event.id || `temp:${Uuid.Generate()}`;
```

### 4. Document Your Strategy

Add comments explaining which strategy you're using and why:

```typescript
/**
 * Syncs calendar events using Strategy 2 (Upsert via Source).
 * Each Google Calendar event has a stable htmlLink that serves as the source.
 * Event details and attendees are stored as upsertable notes using keys.
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
  const allKeys = await this.keys();
  for (const key of allKeys) {
    if (key.startsWith('external:')) {
      const externalId = key.replace('external:', '');
      const exists = await this.checkExternalItemExists(externalId);
      if (!exists) {
        await this.delete(key);
      }
    }
  }
}
```

## Summary

- **Strategy 1** (Create Once): Simplest, no deduplication, use for one-time items
- **Strategy 2** (Upsert via Source/Key): Recommended for most integrations, automatic deduplication
- **Strategy 3** (Generate and Store IDs): Advanced use cases, maximum flexibility, more complexity

Start with Strategy 2 for most integrations. Only use Strategy 3 when you have specific requirements that Strategy 2 cannot fulfill.

For more information:

- [Core Concepts](CORE_CONCEPTS.md) - Understanding activities, notes, and priorities
- [Tools Guide](TOOLS_GUIDE.md) - Complete reference for the Plot tool
- [Building Tools](BUILDING_TOOLS.md) - Creating custom tools
