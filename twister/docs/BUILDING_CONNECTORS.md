---
title: Building Connectors
group: Guides
---

# Building Connectors

Connectors connect Plot to external services like Google Calendar, Slack, Linear, and more. They sync data into Plot and optionally support bidirectional updates. This guide covers everything you need to know about building connectors.

## Table of Contents

- [Connectors vs Twists](#connectors-vs-twists)
- [Connector Structure](#connector-structure)
- [OAuth and Channel Lifecycle](#oauth-and-channel-lifecycle)
- [Data Sync](#data-sync)
- [Batch Processing](#batch-processing)
- [Complete Example](#complete-example)
- [Creating Items from Plot (`onCreateLink`)](#creating-items-from-plot-oncreatelink)
- [Bidirectional Note Sync (Comments, Messages, Replies)](#bidirectional-note-sync-comments-messages-replies)
- [Best Practices](#best-practices)

---

## Connectors vs Twists

| | Connectors | Twists |
|---|---|---|
| **Purpose** | Sync data from external services | Implement opinionated workflows |
| **Base class** | `Connector<T>` (extends `Twist<T>`) | `Twist<T>` |
| **Auth** | OAuth via `Integrations` with channel lifecycle | Optional |
| **Data flow** | External service -> Plot (and optionally back) | Internal logic, orchestration |
| **Examples** | Google Calendar, Slack, Linear, Jira | Task automation, AI assistants |

**Build a Connector** when you need to integrate an external service — syncing calendars, issues, messages, etc.

**Build a Twist** when you need workflow logic that doesn't require external service integration, or when you want to orchestrate multiple connectors.

---

## Connector Structure

Connectors extend the `Connector<T>` base class. They declare their OAuth provider and scopes as class properties, declare tool dependencies in `build()`, and implement the channel lifecycle methods — the Integrations tool reads all of these automatically:

```typescript
import { Connector, type ToolBuilder } from "@plotday/twister";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  type Channel,
  Integrations,
} from "@plotday/twister/tools/integrations";
import { Network } from "@plotday/twister/tools/network";

export default class MyConnector extends Connector<MyConnector> {
  readonly provider = AuthProvider.Linear;
  readonly scopes = ["read", "write"];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, { urls: ["https://api.example.com/*"] }),
    };
  }

  // ... lifecycle methods below (getChannels, onChannelEnabled, onChannelDisabled)
}
```

`scopes` can be a flat array (all required) or a `ScopeConfig` declaring `required` plus `optional` scope groups the user can toggle at connect time. The built-in `callbacks`, `store`, and `tasks` tools are always available (via `this.callback()`, `this.set()`/`this.get()`/`this.clear()`, and `this.runTask()`) — they don't need a `build()` entry.

### Package Structure

```
connectors/my-connector/
  src/
    index.ts              # Re-exports: export { default, MyConnector } from "./my-connector"
    my-connector.ts       # Main Connector class
  package.json
  tsconfig.json
```

---

## OAuth and Channel Lifecycle

Connectors use the Integrations tool for OAuth. Auth is handled automatically in the Flutter edit modal — you don't need to build UI for it.

### How It Works

1. Connector declares `provider` and `scopes` as class properties and implements `getChannels`, `onChannelEnabled`, `onChannelDisabled`
2. User clicks "Connect" in the connection edit modal -> OAuth flow happens automatically
3. After auth, the runtime calls `getChannels()` to list available resources
4. User enables/disables resources in the modal

### getChannels

Return available resources after authentication:

```typescript
async getChannels(_auth: Authorization | null, token: AuthToken | null): Promise<Channel[]> {
  if (!token) return [];
  const client = new ApiClient({ accessToken: token.token });
  const resources = await client.listResources();
  return resources.map(r => ({ id: r.id, title: r.name }));
}
```

### onChannelEnabled

Called when a resource is enabled. **This method runs inline in the HTTP request handler** — any real work (webhook registration, API calls, the initial sync) must be queued as separate tasks via `this.runTask()`, never executed inline:

```typescript
async onChannelEnabled(channel: Channel, context?: SyncContext): Promise<void> {
  await this.set(`sync_state_${channel.id}`, { cursor: null, initialSync: true });

  const webhook = await this.callback(this.setupWebhook, channel.id);
  await this.runTask(webhook);

  const batch = await this.callback(this.syncBatch, channel.id);
  await this.runTask(batch);
}
```

The same channel can receive multiple `onChannelEnabled` calls over its lifetime — initial enable, auto-enable of newly discovered channels, and recovery after re-auth (`context?.recovering === true`). Make the implementation idempotent: overwrite stored state unconditionally rather than skipping when it already exists.

The framework marks the connection as "syncing" when it dispatches this method. Call `this.tools.integrations.channelSyncCompleted(channel.id)` exactly once when the initial backfill finishes so the UI clears the indicator (it's cleared automatically if `onChannelEnabled` throws).

### onChannelDisabled

Called when the user disables a resource. Clean up:

```typescript
async onChannelDisabled(channel: Channel): Promise<void> {
  // Remove webhook
  const webhookId = await this.get<string>(`webhook_id_${channel.id}`);
  if (webhookId) {
    const client = await this.getClient(channel.id);
    await client.deleteWebhook(webhookId);
    await this.clear(`webhook_id_${channel.id}`);
  }

  // Clean up stored state
  await this.clear(`sync_state_${channel.id}`);
}
```

### Getting Auth Tokens

Retrieve tokens for API calls using the channel ID:

```typescript
private async getClient(channelId: string): Promise<ApiClient> {
  const token = await this.tools.integrations.get(channelId);
  if (!token) throw new Error("No authentication token available");
  return new ApiClient({ accessToken: token.token });
}
```

---

## Data Sync

Connectors save data with `integrations.saveLink()` (or the batch `saveLinks()`), passing a `NewLinkWithNotes`. `link.source` and `note.key` drive automatic upserts (no manual ID tracking needed).

### Transforming External Items

```typescript
private transformItem(item: any, channelId: string, initialSync: boolean): NewLinkWithNotes {
  return {
    source: `myprovider:item:${item.id}`, // Canonical source for dedup/upsert
    type: "issue",                        // Matches a LinkTypeConfig.type
    title: item.title,
    status: item.state,                   // Matches a statuses[].status
    created: new Date(item.createdAt),    // External timestamp, not sync time
    channelId,                            // Required — write-back reads this, not meta.channelId
    meta: {
      externalId: item.id,
      syncProvider: "myprovider",         // Required for bulk operations
    },
    notes: [{
      key: "description",  // Enables note-level upserts
      content: item.description || null,
      contentType: item.descriptionHtml ? "html" as const : "text" as const,
    }],
    ...(initialSync ? { unread: false } : {}),   // Mark read on initial sync
    ...(initialSync ? { archived: false } : {}),  // Unarchive on initial sync
  };
}
```

### Initial vs Incremental Sync

All connectors **must** distinguish between initial sync (first import) and incremental sync (ongoing updates):

| Field | Initial Sync | Incremental Sync | Reason |
|-------|-------------|------------------|--------|
| `unread` | `false` | *omit* | Avoid notification spam from historical imports |
| `archived` | `false` | *omit* | Unarchive on install, preserve user choice on updates |

See [Sync Strategies](SYNC_STRATEGIES.md) for detailed patterns on deduplication, upserts, and tag management.

---

## Batch Processing

Connectors run in an ephemeral environment with ~1000 requests per execution. Break long operations into batches using `this.runTask()`, which creates a new execution with fresh request limits. Prefer the batch `saveLinks()` over looping `saveLink()` — each `saveLink` call counts against the request budget, while `saveLinks` collapses a whole page into one crossing.

```typescript
private async startBatchSync(channelId: string): Promise<void> {
  await this.set(`sync_state_${channelId}`, {
    cursor: null,
    batchNumber: 1,
    initialSync: true,
  });

  const batchCallback = await this.callback(this.syncBatch, channelId);
  await this.runTask(batchCallback);
}

private async syncBatch(channelId: string): Promise<void> {
  const state = await this.get(`sync_state_${channelId}`);
  if (!state) return;

  const client = await this.getClient(channelId);
  const result = await client.listItems({ cursor: state.cursor, limit: 50 });

  await this.tools.integrations.saveLinks(
    result.items.map((item) =>
      this.transformItem(item, channelId, state.initialSync)
    )
  );

  if (result.nextCursor) {
    await this.set(`sync_state_${channelId}`, {
      cursor: result.nextCursor,
      batchNumber: state.batchNumber + 1,
      initialSync: state.initialSync,
    });
    const nextBatch = await this.callback(this.syncBatch, channelId);
    await this.runTask(nextBatch);
  } else {
    await this.clear(`sync_state_${channelId}`);
    await this.tools.integrations.channelSyncCompleted(channelId);
  }
}
```

---

## Complete Example

A minimal connector that syncs issues from an external service:

```typescript
import {
  Connector,
  type NewLinkWithNotes,
  type ToolBuilder,
} from "@plotday/twister";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  type Channel,
  Integrations,
  type StatusIcon,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";

export default class IssueConnector extends Connector<IssueConnector> {
  readonly provider = AuthProvider.Linear;
  readonly scopes = ["read"];
  readonly linkTypes = [{
    type: "issue",
    label: "Issue",
    statuses: [
      { status: "unstarted", label: "To Do", icon: "todo" as StatusIcon },
      { status: "completed", label: "Done", done: true, icon: "done" as StatusIcon },
    ],
  }];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, { urls: ["https://api.linear.app/*"] }),
    };
  }

  async getChannels(_auth: Authorization | null, token: AuthToken | null): Promise<Channel[]> {
    // Return available projects/teams for the user to select
    if (!token) return [];
    const client = new LinearClient({ accessToken: token.token });
    const teams = await client.teams();
    return teams.nodes.map(t => ({ id: t.id, title: t.name }));
  }

  async onChannelEnabled(channel: Channel, context?: SyncContext): Promise<void> {
    // Recovery re-dispatch after re-auth: drop stale cursors.
    if (context?.recovering) {
      await this.clear(`sync_state_${channel.id}`);
    }

    // Queue webhook setup and initial sync as tasks — never run them inline.
    const webhook = await this.callback(this.setupWebhook, channel.id);
    await this.runTask(webhook);

    await this.set(`sync_state_${channel.id}`, {
      cursor: null, batchNumber: 1, initialSync: true,
    });
    const batch = await this.callback(this.syncBatch, channel.id);
    await this.runTask(batch);
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    const webhookId = await this.get<string>(`webhook_id_${channel.id}`);
    if (webhookId) {
      try {
        const client = await this.getClient(channel.id);
        await client.deleteWebhook(webhookId);
      } catch { /* ignore */ }
      await this.clear(`webhook_id_${channel.id}`);
    }
    await this.clear(`sync_state_${channel.id}`);
  }

  private async getClient(channelId: string) {
    const token = await this.tools.integrations.get(channelId);
    if (!token) throw new Error("No auth token");
    return new LinearClient({ accessToken: token.token });
  }

  private async setupWebhook(channelId: string): Promise<void> {
    const webhookUrl = await this.tools.network.createWebhook(
      {}, this.onWebhook, channelId
    );
    if (webhookUrl.includes("localhost") || webhookUrl.includes("127.0.0.1")) return;
    const client = await this.getClient(channelId);
    const webhook = await client.createWebhook({ url: webhookUrl });
    if (webhook?.id) await this.set(`webhook_id_${channelId}`, webhook.id);
  }

  private transformIssue(issue: any, channelId: string, initialSync: boolean): NewLinkWithNotes {
    return {
      source: `linear:issue:${issue.id}`,
      type: "issue",
      title: `${issue.identifier}: ${issue.title}`,
      status: issue.completedAt ? "completed" : "unstarted",
      created: new Date(issue.createdAt),
      sourceUrl: issue.url ?? null,
      channelId,
      meta: { syncProvider: "linear", externalId: issue.id },
      notes: [{
        key: "description",
        content: issue.description || null,
      }],
      ...(initialSync ? { unread: false, archived: false } : {}),
    };
  }

  private async syncBatch(channelId: string): Promise<void> {
    const state = await this.get<any>(`sync_state_${channelId}`);
    if (!state) return;

    const client = await this.getClient(channelId);
    const result = await client.issues({ teamId: channelId, after: state.cursor });

    await this.tools.integrations.saveLinks(
      result.nodes.map((issue: any) =>
        this.transformIssue(issue, channelId, state.initialSync)
      )
    );

    if (result.pageInfo.hasNextPage) {
      await this.set(`sync_state_${channelId}`, {
        cursor: result.pageInfo.endCursor,
        batchNumber: state.batchNumber + 1,
        initialSync: state.initialSync,
      });
      const next = await this.callback(this.syncBatch, channelId);
      await this.runTask(next);
    } else {
      await this.clear(`sync_state_${channelId}`);
      // Clear the "syncing…" indicator now that the backfill is done.
      await this.tools.integrations.channelSyncCompleted(channelId);
    }
  }

  private async onWebhook(request: WebhookRequest, channelId: string): Promise<void> {
    const payload = JSON.parse(request.rawBody || "{}");
    if (payload.type !== "Issue") return;

    // Incremental sync: initialSync=false omits unread and archived
    await this.tools.integrations.saveLink(
      this.transformIssue(payload.data, channelId, false)
    );
  }
}
```

---

## Creating Items from Plot (`onCreateLink`)

Some connectors let users start a new thread that creates a brand-new
external item — a Linear issue, a Google Calendar event, a Slack DM. Opt
in per link type:

### 1. Declare a `compose` block

Add a `compose` block to the `LinkTypeConfig` for that type. Either on the
class-level `readonly linkTypes` or on the dynamic per-channel linkTypes
returned by `getChannels`:

```typescript
readonly linkTypes = [{
  type: "issue",
  label: "Issue",
  statuses: [
    { status: "backlog", label: "Backlog", icon: "backlog" as StatusIcon },
    { status: "unstarted", label: "To Do", icon: "todo" as StatusIcon },
    { status: "completed", label: "Done", done: true, icon: "done" as StatusIcon },
  ],
  compose: { status: "unstarted" },   // targets defaults to "channels"
}];
```

A link type opts in to Plot-initiated creation by declaring `compose` —
without it, the "Create new …" picker entry never appears. `compose.status`
is the status assigned to newly-created links: a literal `statuses[]` entry,
or a symbolic id your `onCreateLink` resolves itself; omit it for status-less
link types. For closed-roster DM-style compose set
`compose.targets: "contacts"`; for open address spaces (email) use
`"addresses"`. See `ComposeConfig` in `twister/src/tools/integrations.ts`.

### 2. Implement `onCreateLink(draft)`

```typescript
async onCreateLink(draft: CreateLinkDraft): Promise<CreateLinkResult | null> {
  const client = await this.getClient(draft.channelId);
  const payload = await client.createIssue({
    teamId: draft.channelId,
    title: draft.title,
    description: draft.noteContent ?? undefined,
    stateId: await this.resolveStateId(client, draft.channelId, draft.status),
  });
  const issue = await payload.issue;
  if (!issue) return null;
  return {
    source: `linear:issue:${issue.id}`,
    type: "issue",
    title: issue.title,
    status: draft.status,
    created: issue.createdAt,
    sourceUrl: issue.url ?? null,
    meta: { linearId: issue.id, projectId: draft.channelId },
  };
}
```

### `CreateLinkDraft`

| Field | Purpose |
|-------|---------|
| `channelId` | Target channel (Linear team, Google calendar, Slack workspace). |
| `type` | Link type id matching a `LinkTypeConfig.type`. |
| `status` | Status the user selected; matches `statuses[].status`. `null` for status-less link types. |
| `title` | Thread title (post AI title generation). |
| `noteContent` | Markdown of the thread's first note, or `null`. |
| `contacts` | Thread's contacts, minus the creating user — use for email recipients, DM members, invitees. |
| `recipients` | For `compose.targets: "contacts"` / `"addresses"` only: contacts pre-resolved to platform account IDs (`externalAccountId`) with their thread `role` (e.g. to/cc/bcc) — use these instead of re-resolving `contacts`. |
| `inviteEmails` | For `compose.targets: "addresses"` only: free-form addresses the user typed with no Plot contact row. |

### Platform guarantees

- The returned link is attached to the originating Plot thread
  automatically. **Don't call `integrations.saveLink()` yourself** — doing
  so creates a duplicate thread.
- The runtime fills `channelId` and `type` on the saved link from the
  draft if you omit them, so status-label lookup and channel-scoped
  rendering keep working.
- Loop prevention is handled by the runtime: the link is written with
  the twist as `updated_by`, so subsequent syncs of the same external id
  won't retrigger `onLinkUpdated` for the initial state.

### Return `null` to abort

If creation shouldn't proceed (wrong link type, external API refused,
user not authorized), return `null`. The Plot thread is still saved; no
link is attached.

## Bidirectional Note Sync (Comments, Messages, Replies)

When a user adds a note to a thread your connector created, the runtime dispatches `onNoteCreated` (and `onNoteUpdated` when the note is edited). Implement these to push the note to the external system as a comment/message/reply and return a `NoteWriteBackResult`:

```typescript
import type { NoteWriteBackResult } from "@plotday/twister";

async onNoteCreated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
  if (note.author.type === ActorType.Twist) return; // Prevent loops
  const comment = await client.createComment(thread.meta.externalId, { body: note.content ?? "" });
  if (!comment?.id) return;
  return {
    key: `comment-${comment.id}`,
    // What the external system NOW STORES, byte-for-byte equal to what
    // your sync-in path will emit as NewNote.content on re-ingest.
    externalContent: comment.body,
  };
}

async onNoteUpdated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
  if (!note.key?.startsWith("comment-")) return;
  const commentId = note.key.slice("comment-".length);
  const updated = await client.updateComment(commentId, { body: note.content ?? "" });
  return { externalContent: updated.body };
}
```

The `externalContent` field establishes a sync baseline: the runtime hashes it and stores it on `note.external_content_hash`. On the next sync-in, the incoming content is hashed the same way — if the hashes match, the external side hasn't changed since we wrote, so Plot's stored content (which may be richer markdown than what the external system round-tripped) is preserved. If the hashes differ, the external was edited and Plot is overwritten.

**Contract**: `externalContent` must exactly equal the `NewNote.content` your sync-in's `build*Note` function emits for this note on re-ingest. If sync-in runs a transform (ADF extraction, mention translation, HTML sanitisation), apply the same transform to the write-back response before returning it. Bidirectional connectors must also set `static readonly handleReplies = true` so the dispatch reaches your hooks. See **[Connector Development Guide](../../connectors/AGENTS.md)** → "Sync baseline preservation" for the full contract and failure modes.

## Best Practices

### 1. Always Inject Sync Metadata

Every synced link must set the first-class `channelId` field and include `syncProvider` in `meta` for bulk operations (e.g., `integrations.archiveLinks({ channelId })` when a channel is disabled).

### 2. Use Canonical Source IDs

Use immutable IDs in `link.source` for deduplication. For services with mutable identifiers (like Jira issue keys), use the immutable ID in `source` and store the mutable key in `meta`.

### 3. Handle HTML Content Correctly

Never strip HTML tags locally. Pass raw HTML with `contentType: "html"` for server-side markdown conversion.

### 4. Add Localhost Guard for Webhooks

Skip webhook registration in development when the URL contains "localhost".

### 5. Maintain Callback Backward Compatibility

All callbacks automatically upgrade to new connector versions. Only add optional parameters at the end of callback method signatures.

### 6. Clean Up on Disable

Delete webhooks, callbacks, and stored state in `onChannelDisabled()`.

---

## Next Steps

- **[Connector Development Guide](../../connectors/AGENTS.md)** - Comprehensive scaffold, patterns, and checklist
- **[Sync Strategies](SYNC_STRATEGIES.md)** - Deduplication, upserts, and tag management
- **[Built-in Tools Guide](TOOLS_GUIDE.md)** - Complete reference for Plot, Store, Integrations, and more
- **[Multi-User Auth](MULTI_USER_AUTH.md)** - Per-user auth for write-backs
