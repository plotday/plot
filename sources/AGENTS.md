# Source Development Guide

This guide covers everything needed to build a Plot source correctly.

**For twist development**: See `../twister/cli/templates/AGENTS.template.md`
**For general navigation**: See `../AGENTS.md`
**For type definitions**: See `../twister/src/tools/*.ts` (comprehensive JSDoc)

## Quick Start: Complete Source Scaffold

Every source follows this structure:

```
sources/<name>/
  src/
    index.ts              # Re-exports: export { default, ClassName } from "./class-file"
    <class-name>.ts       # Main Source class
    <api-name>.ts         # (optional) Separate API client + transform functions
  package.json
  tsconfig.json
  README.md
  LICENSE
```

### package.json

```json
{
  "name": "@plotday/source-<name>",
  "displayName": "Human Name",
  "description": "One-line purpose statement",
  "author": "Plot <team@plot.day> (https://plot.day)",
  "license": "MIT",
  "version": "0.1.0",
  "type": "module",
  "main": "./dist/index.js",
  "types": "./dist/index.d.ts",
  "exports": {
    ".": {
      "@plotday/source": "./src/index.ts",
      "types": "./dist/index.d.ts",
      "default": "./dist/index.js"
    }
  },
  "files": ["dist", "README.md", "LICENSE"],
  "scripts": {
    "build": "tsc",
    "clean": "rm -rf dist"
  },
  "dependencies": {
    "@plotday/twister": "workspace:^"
  },
  "devDependencies": {
    "typescript": "^5.9.3"
  },
  "repository": {
    "type": "git",
    "url": "https://github.com/plotday/plot.git",
    "directory": "sources/<name>"
  },
  "homepage": "https://plot.day",
  "keywords": ["plot", "source", "<name>"],
  "publishConfig": { "access": "public" }
}
```

**Notes:**
- `"@plotday/source"` export condition resolves to TypeScript source during workspace development
- Add third-party SDKs to `dependencies` (e.g., `"@linear/sdk": "^72.0.0"`)
- Add `@plotday/source-google-contacts` as `"workspace:^"` if your source syncs contacts (Google sources only)

### tsconfig.json

```json
{
  "$schema": "https://json.schemastore.org/tsconfig",
  "extends": "@plotday/twister/tsconfig.base.json",
  "compilerOptions": {
    "outDir": "./dist"
  },
  "include": ["src/**/*.ts"]
}
```

### src/index.ts

```typescript
export { default, SourceName } from "./source-name";
```

## Source Class Template

```typescript
import {
  ActivityType,
  LinkType,
  type NewActivity,
  type NewActivityWithNotes,
  type NewNote,
  type SyncToolOptions,
  Source,
  type SourceBuilder,
} from "@plotday/twister";
import type { NewContact } from "@plotday/twister/plot";
import { type Callback, Callbacks } from "@plotday/twister/tools/callbacks";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { ContactAccess, Plot } from "@plotday/twister/tools/plot";
import { Tasks } from "@plotday/twister/tools/tasks";

// Choose the correct common interface for your source category:
// import type { CalendarSource, SyncOptions } from "@plotday/twister/common/calendar";
// import type { ProjectSource, ProjectSyncOptions } from "@plotday/twister/common/projects";
// import type { MessagingSource, MessageSyncOptions } from "@plotday/twister/common/messaging";
// import type { DocumentSource, DocumentSyncOptions } from "@plotday/twister/common/documents";

type SyncState = {
  cursor: string | null;
  batchNumber: number;
  itemsProcessed: number;
  initialSync: boolean;
};

export class MySource extends Source<MySource> implements ProjectSource {
  // 1. Static constants
  static readonly PROVIDER = AuthProvider.Linear; // Use appropriate provider
  static readonly SCOPES = ["read", "write"];
  static readonly Options: SyncToolOptions;
  declare readonly Options: SyncToolOptions;

  // 2. Declare dependencies
  build(build: SourceBuilder) {
    return {
      integrations: build(Integrations, {
        providers: [{
          provider: MySource.PROVIDER,
          scopes: MySource.SCOPES,
          getChannels: this.getChannels,
          onChannelEnabled: this.onChannelEnabled,
          onChannelDisabled: this.onChannelDisabled,
        }],
      }),
      network: build(Network, { urls: ["https://api.example.com/*"] }),
      callbacks: build(Callbacks),
      tasks: build(Tasks),
      plot: build(Plot, { contact: { access: ContactAccess.Write } }),
    };
  }

  // 3. Create API client using channel-based auth
  private async getClient(channelId: string): Promise<any> {
    const token = await this.tools.integrations.get(MySource.PROVIDER, channelId);
    if (!token) throw new Error("No authentication token available");
    return new SomeApiClient({ accessToken: token.token });
  }

  // 4. Return available resources for the user to select
  async getChannels(_auth: Authorization, token: AuthToken): Promise<Channel[]> {
    const client = new SomeApiClient({ accessToken: token.token });
    const resources = await client.listResources();
    return resources.map(r => ({ id: r.id, title: r.name }));
  }

  // 5. Called when user enables a resource
  async onChannelEnabled(channel: Channel): Promise<void> {
    await this.set(`sync_enabled_${channel.id}`, true);

    // Store parent callback tokens
    const itemCallbackToken = await this.tools.callbacks.createFromParent(
      this.options.onItem
    );
    await this.set(`item_callback_${channel.id}`, itemCallbackToken);

    if (this.options.onChannelDisabled) {
      const disableCallbackToken = await this.tools.callbacks.createFromParent(
        this.options.onChannelDisabled,
        { meta: { syncProvider: "myprovider", channelId: channel.id } }
      );
      await this.set(`disable_callback_${channel.id}`, disableCallbackToken);
    }

    // Setup webhook and start initial sync
    await this.setupWebhook(channel.id);
    await this.startBatchSync(channel.id);
  }

  // 6. Called when user disables a resource
  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.stopSync(channel.id);

    const disableCallbackToken = await this.get<Callback>(`disable_callback_${channel.id}`);
    if (disableCallbackToken) {
      await this.tools.callbacks.run(disableCallbackToken);
      await this.tools.callbacks.delete(disableCallbackToken);
      await this.clear(`disable_callback_${channel.id}`);
    }

    const itemCallbackToken = await this.get<Callback>(`item_callback_${channel.id}`);
    if (itemCallbackToken) {
      await this.tools.callbacks.delete(itemCallbackToken);
      await this.clear(`item_callback_${channel.id}`);
    }

    await this.clear(`sync_enabled_${channel.id}`);
  }

  // 7. Public interface methods (from common interface)
  async getProjects(projectId: string): Promise<any[]> {
    const client = await this.getClient(projectId);
    const projects = await client.listProjects();
    return projects.map(p => ({
      id: p.id,
      name: p.name,
      description: p.description || null,
      key: p.key || null,
    }));
  }

  async startSync<TArgs extends any[], TCallback extends Function>(
    options: { projectId: string },
    callback: TCallback,
    ...extraArgs: TArgs
  ): Promise<void> {
    const callbackToken = await this.tools.callbacks.createFromParent(callback, ...extraArgs);
    await this.set(`item_callback_${options.projectId}`, callbackToken);
    await this.setupWebhook(options.projectId);
    await this.startBatchSync(options.projectId);
  }

  async stopSync(projectId: string): Promise<void> {
    // Remove webhook
    const webhookId = await this.get<string>(`webhook_id_${projectId}`);
    if (webhookId) {
      try {
        const client = await this.getClient(projectId);
        await client.deleteWebhook(webhookId);
      } catch (error) {
        console.warn("Failed to delete webhook:", error);
      }
      await this.clear(`webhook_id_${projectId}`);
    }

    // Cleanup callbacks
    const itemCallbackToken = await this.get<Callback>(`item_callback_${projectId}`);
    if (itemCallbackToken) {
      await this.deleteCallback(itemCallbackToken);
      await this.clear(`item_callback_${projectId}`);
    }

    await this.clear(`sync_state_${projectId}`);
  }

  // 8. Webhook setup
  private async setupWebhook(resourceId: string): Promise<void> {
    try {
      const webhookUrl = await this.tools.network.createWebhook(
        {},
        this.onWebhook,
        resourceId
      );

      // REQUIRED: Skip webhook registration in development
      if (webhookUrl.includes("localhost") || webhookUrl.includes("127.0.0.1")) {
        return;
      }

      const client = await this.getClient(resourceId);
      const webhook = await client.createWebhook({ url: webhookUrl });
      if (webhook?.id) {
        await this.set(`webhook_id_${resourceId}`, webhook.id);
      }
    } catch (error) {
      console.error("Failed to set up webhook:", error);
    }
  }

  // 9. Batch sync
  private async startBatchSync(resourceId: string): Promise<void> {
    await this.set(`sync_state_${resourceId}`, {
      cursor: null,
      batchNumber: 1,
      itemsProcessed: 0,
      initialSync: true,
    });

    const batchCallback = await this.callback(this.syncBatch, resourceId);
    await this.tools.tasks.runTask(batchCallback);
  }

  private async syncBatch(resourceId: string): Promise<void> {
    const state = await this.get<SyncState>(`sync_state_${resourceId}`);
    if (!state) throw new Error(`Sync state not found for ${resourceId}`);

    const callbackToken = await this.get<Callback>(`item_callback_${resourceId}`);
    if (!callbackToken) throw new Error(`Callback not found for ${resourceId}`);

    const client = await this.getClient(resourceId);
    const result = await client.listItems({ cursor: state.cursor, limit: 50 });

    for (const item of result.items) {
      const activity = this.transformItem(item, resourceId, state.initialSync);
      // Inject sync metadata for bulk operations
      activity.meta = {
        ...activity.meta,
        syncProvider: "myprovider",
        channelId: resourceId,
      };
      await this.tools.callbacks.run(callbackToken, activity);
    }

    if (result.nextCursor) {
      await this.set(`sync_state_${resourceId}`, {
        cursor: result.nextCursor,
        batchNumber: state.batchNumber + 1,
        itemsProcessed: state.itemsProcessed + result.items.length,
        initialSync: state.initialSync,
      });
      const nextBatch = await this.callback(this.syncBatch, resourceId);
      await this.tools.tasks.runTask(nextBatch);
    } else {
      await this.clear(`sync_state_${resourceId}`);
    }
  }

  // 10. Data transformation
  private transformItem(item: any, resourceId: string, initialSync: boolean): NewActivityWithNotes {
    return {
      source: `myprovider:item:${item.id}`,  // Canonical source for upsert
      type: ActivityType.Action,
      title: item.title,
      created: item.createdAt,
      author: item.creator?.email ? {
        email: item.creator.email,
        name: item.creator.name,
      } : undefined,
      meta: {
        externalId: item.id,
        resourceId,
      },
      notes: [{
        key: "description",  // Enables note upsert
        content: item.description || null,
        links: item.url ? [{
          type: LinkType.external,
          title: "Open in Service",
          url: item.url,
        }] : null,
      }],
      ...(initialSync ? { unread: false } : {}),
      ...(initialSync ? { archived: false } : {}),
    };
  }

  // 11. Webhook handler
  private async onWebhook(request: WebhookRequest, resourceId: string): Promise<void> {
    // Verify webhook signature (provider-specific)
    // ...

    const callbackToken = await this.get<Callback>(`item_callback_${resourceId}`);
    if (!callbackToken) return;

    const payload = JSON.parse(request.rawBody || "{}");
    const activity = this.transformItem(payload.item, resourceId, false);
    activity.meta = {
      ...activity.meta,
      syncProvider: "myprovider",
      channelId: resourceId,
    };
    await this.tools.callbacks.run(callbackToken, activity);
  }
}

export default MySource;
```

## Common Source Interfaces

Choose the correct interface based on what your service provides. Import from `@plotday/twister/common/*`.

| Interface | For | Examples | Key resource |
|-----------|-----|----------|-------------|
| `CalendarSource` | Calendar/scheduling services | Google Calendar, Outlook, Apple Calendar | Calendars with events |
| `ProjectSource` | Project/task management | Linear, Jira, Asana, GitHub Issues, Todoist, ClickUp, Trello, Monday | Projects with issues/tasks |
| `MessagingSource` | Email and chat services | Gmail, Slack, Discord, Microsoft Teams, Intercom | Channels/inboxes with threads |
| `DocumentSource` | Document/file services | Google Drive, Notion, Dropbox, OneDrive, Confluence | Folders with documents |
| None | Services that don't fit above | CRM, analytics, monitoring | Define your own interface |

Each interface requires these methods: `get[Resources]()`, `startSync()`, `stopSync()`. Some have optional methods for bidirectional sync (`updateIssue`, `addIssueComment`, `addDocumentComment`, etc.).

## The Integrations Pattern (Auth + Channels)

**This is how ALL authentication works.** Auth is handled in the Flutter edit modal, not in code. Sources declare their provider config in `build()`.

### How It Works

1. Source declares providers in `build()` with `getChannels`, `onChannelEnabled`, `onChannelDisabled` callbacks
2. User clicks "Connect" in the twist edit modal → OAuth flow happens automatically
3. After auth, the runtime calls your `getChannels()` to list available resources
4. User enables resources in the modal → `onChannelEnabled()` fires
5. User disables resources → `onChannelDisabled()` fires
6. Get tokens via `this.tools.integrations.get(PROVIDER, channelId)`

### Available Providers

`AuthProvider` enum: `Google`, `Microsoft`, `Notion`, `Slack`, `Atlassian`, `Linear`, `Monday`, `GitHub`, `Asana`, `HubSpot`.

### Per-User Auth for Write-Backs

For bidirectional sync where actions should be attributed to the acting user:

```typescript
await this.tools.integrations.actAs(
  MySource.PROVIDER,
  actorId,      // The user who performed the action
  activityId,   // Activity to create auth prompt in (if user hasn't connected)
  this.performWriteBack,
  ...extraArgs
);

async performWriteBack(token: AuthToken, ...extraArgs: any[]): Promise<void> {
  // token is the acting user's token
  const client = new ApiClient({ accessToken: token.token });
  await client.doSomething();
}
```

### Cross-Source Auth Sharing (Google Sources)

When building a Google source that should also sync contacts, merge scopes:

```typescript
import GoogleContacts from "@plotday/source-google-contacts";

build(build: SourceBuilder) {
  return {
    integrations: build(Integrations, {
      providers: [{
        provider: AuthProvider.Google,
        scopes: Integrations.MergeScopes(
          MyGoogleSource.SCOPES,
          GoogleContacts.SCOPES
        ),
        getChannels: this.getChannels,
        onChannelEnabled: this.onChannelEnabled,
        onChannelDisabled: this.onChannelDisabled,
      }],
    }),
    googleContacts: build(GoogleContacts),
    // ...
  };
}
```

## Architecture: Sources Save Directly

**Sources save data directly** via `integrations.saveLink()`. Sources build `NewLinkWithNotes` objects and save them, rather than passing them through a parent twist.

This means:
- Sources request `Plot` with `ContactAccess.Write` (for contacts on threads)
- Sources declare providers via `Integrations` with lifecycle callbacks
- Sources call save methods directly to persist synced data

## Critical: Callback Serialization Pattern

**The #1 mistake when building sources is passing function references as callback arguments.** Functions cannot be serialized across worker boundaries.

### ❌ WRONG - Passing Function as Callback Argument

```typescript
async startSync(callback: Function, ...extraArgs: any[]): Promise<void> {
  // ❌ WRONG: callback is a function — NOT SERIALIZABLE!
  await this.callback(this.syncBatch, callback, ...extraArgs);
}
```

**Error:** `Cannot create callback args: Found function at path "value[0]"`

### ✅ CORRECT - Store Token, Pass Primitives

```typescript
async startSync(resourceId: string, callback: Function, ...extraArgs: any[]): Promise<void> {
  // Step 1: Convert function to token and STORE it
  const callbackToken = await this.tools.callbacks.createFromParent(callback, ...extraArgs);
  await this.set(`callback_${resourceId}`, callbackToken);

  // Step 2: Pass ONLY serializable values to this.callback()
  const batchCallback = await this.callback(this.syncBatch, resourceId);
  await this.tools.tasks.runTask(batchCallback);
}

async syncBatch(resourceId: string): Promise<void> {
  // Step 3: Retrieve token from storage
  const callbackToken = await this.get<Callback>(`callback_${resourceId}`);
  if (!callbackToken) throw new Error(`Callback not found for ${resourceId}`);

  // Step 4: Fetch data and execute callback with result
  const result = await this.fetchItems(resourceId);
  for (const item of result.items) {
    await this.tools.callbacks.run(callbackToken, item);
  }
}
```

### What's Serializable

| ✅ Safe | ❌ NOT Serializable |
|---------|---------------------|
| Strings, numbers, booleans, null | Functions, `() => {}`, method refs |
| Plain objects `{ key: "value" }` | `undefined` (use `null` instead) |
| Arrays `[1, 2, 3]` | Symbols |
| Dates (serialized via SuperJSON) | RPC stubs |
| Callback tokens (branded strings) | Circular references |

## Callback Backward Compatibility

**All callbacks automatically upgrade to new source versions on deployment.** You MUST maintain backward compatibility.

- ❌ Don't change function signatures (remove/reorder params, change types)
- ✅ Do add optional parameters at the end
- ✅ Do handle both old and new data formats with version guards

```typescript
// v1.0 - Original
async syncBatch(batchNumber: number, resourceId: string) { ... }

// v1.1 - ✅ GOOD: Optional parameter at end
async syncBatch(batchNumber: number, resourceId: string, initialSync?: boolean) {
  const isInitial = initialSync ?? true; // Safe default for old callbacks
}

// v2.0 - ❌ BAD: Completely changed signature
async syncBatch(options: SyncOptions) { ... }
```

For breaking changes, implement migration logic in `preUpgrade()`:

```typescript
async preUpgrade(): Promise<void> {
  // Clean up stale locks from previous version
  const keys = await this.list("sync_lock_");
  for (const key of keys) {
    await this.clear(key);
  }
}
```

## Storage Key Conventions

All sources use consistent key prefixes:

| Key Pattern | Purpose |
|------------|---------|
| `item_callback_<id>` | Serialized callback to parent's `onItem` |
| `disable_callback_<id>` | Serialized callback to parent's `onChannelDisabled` |
| `sync_state_<id>` | Current batch pagination state |
| `sync_enabled_<id>` | Boolean tracking enabled state |
| `webhook_id_<id>` | External webhook registration ID |
| `webhook_secret_<id>` | Webhook signing secret |
| `watch_renewal_task_<id>` | Scheduled task token for webhook renewal |

## Source URL Conventions

The `activity.source` field is the idempotency key for automatic upserts. Use a canonical format:

```
<provider>:<entity>:<id>        — Standard pattern
<provider>:<namespace>:<id>     — When provider has multiple entity types
```

Examples from existing sources:
```
linear:issue:<issueId>
asana:task:<taskGid>
jira:<cloudId>:issue:<issueId>    — Uses immutable ID, NOT mutable key like "PROJ-123"
google-calendar:<eventId>
outlook-calendar:<eventId>
google-drive:file:<fileId>
https://mail.google.com/mail/u/0/#inbox/<threadId>   — Gmail uses full URL
https://slack.com/app_redirect?channel=<id>&message_ts=<ts>  — Slack uses full URL
```

**Critical:** For services with mutable identifiers (like Jira where issue keys change on project move), use the immutable ID in `source` and store the mutable key in `meta` only.

## Note Key Conventions

`note.key` enables note-level upserts within an activity:

```
"description"                    — Main content / description note
"summary"                        — Document summary
"metadata"                       — Status/priority/assignee metadata
"cancellation"                   — Cancelled event note
"comment-<externalCommentId>"    — Individual comment
"reply-<commentId>-<replyId>"    — Reply to a comment
```

## Sync Metadata Injection

**Every synced activity MUST include sync metadata** in `activity.meta` for bulk operations (e.g., archiving all activities when a sync is disabled):

```typescript
activity.meta = {
  ...activity.meta,
  syncProvider: "myprovider",    // Provider identifier
  channelId: resourceId,         // Resource being synced
};
```

This metadata is used by the twist's `onChannelDisabled` callback to match and archive activities:

```typescript
// In the twist:
async onChannelDisabled(filter: ActivityFilter): Promise<void> {
  await this.tools.plot.updateActivity({ match: filter, archived: true });
}
```

## Initial vs. Incremental Sync

| Field | Initial Sync | Incremental Sync | Reason |
|-------|-------------|------------------|--------|
| `unread` | `false` | *omit* | Initial: mark all read. Incremental: auto-mark read for author only |
| `archived` | `false` | *omit* | Unarchive on install, preserve user choice on updates |

```typescript
const activity = {
  // ...
  ...(initialSync ? { unread: false } : {}),
  ...(initialSync ? { archived: false } : {}),
};
```

## Webhook Patterns

### Localhost Guard (REQUIRED)

All sources MUST skip webhook registration in local development:

```typescript
const webhookUrl = await this.tools.network.createWebhook({}, this.onWebhook, resourceId);

if (webhookUrl.includes("localhost") || webhookUrl.includes("127.0.0.1")) {
  return; // Skip — webhooks can't reach localhost
}
```

### Webhook Verification

Verify webhook signatures to prevent unauthorized calls. Each provider has its own method:

| Provider | Method |
|----------|--------|
| Linear | `LinearWebhookClient` from `@linear/sdk/webhooks` |
| Slack | Challenge response + event type filtering |
| Google | UUID secret in channel token query |
| Microsoft | Subscription `clientState` |
| Asana | HMAC-SHA256 via `crypto.subtle` |

### Watch Renewal (Calendar/Drive)

For providers that expire watches, schedule proactive renewal:

```typescript
private async scheduleWatchRenewal(resourceId: string): Promise<void> {
  const expiresAt = /* watch expiry from provider */;
  const renewalTime = new Date(expiresAt.getTime() - 24 * 60 * 60 * 1000); // 24h before

  const renewalCallback = await this.callback(this.renewWatch, resourceId);
  const taskToken = await this.runTask(renewalCallback, { runAt: renewalTime });
  if (taskToken) await this.set(`watch_renewal_task_${resourceId}`, taskToken);
}
```

## Bidirectional Sync

For sources that support write-backs (updating external items from Plot):

### Issue/Task Updates (`updateIssue`)

```typescript
async updateIssue(activity: Activity): Promise<void> {
  const externalId = activity.meta?.externalId as string;
  if (!externalId) throw new Error("External ID not found in meta");

  const client = await this.getClient(activity.meta?.resourceId as string);
  await client.updateItem(externalId, {
    title: activity.title,
    done: activity.type === ActivityType.Action ? activity.done : undefined,
  });
}
```

### Comment Sync (`addIssueComment`)

```typescript
async addIssueComment(meta: ActivityMeta, body: string, noteId?: string): Promise<string | void> {
  const externalId = meta.externalId as string;
  if (!externalId) throw new Error("External ID not found");

  const client = await this.getClient(meta.resourceId as string);
  const comment = await client.createComment(externalId, { body });
  if (comment?.id) return `comment-${comment.id}`;
}
```

### Loop Prevention

The parent twist prevents infinite loops by checking note authorship:

```typescript
// In the twist (not the source):
async onNoteCreated(note: Note): Promise<void> {
  if (note.author.type === ActorType.Twist) return; // Prevent loops
  // ... sync note to external service
}
```

## Contacts Pattern

Sources that sync user data should create contacts for authors and assignees:

```typescript
import type { NewContact } from "@plotday/twister/plot";

const authorContact: NewContact | undefined = creator?.email ? {
  email: creator.email,
  name: creator.name,
  avatar: creator.avatarUrl ?? undefined,
} : undefined;

const activity: NewActivityWithNotes = {
  // ...
  author: authorContact,
  assignee: assigneeContact ?? null,
  notes: [{
    author: authorContact,  // Note-level author too
    // ...
  }],
};
```

Declare `ContactAccess.Write` in build:
```typescript
plot: build(Plot, { contact: { access: ContactAccess.Write } }),
```

## Buffer Declaration

Cloudflare Workers provides `Buffer` globally, but TypeScript doesn't know about it. Declare it at the top of files that need it:

```typescript
declare const Buffer: {
  from(
    data: string | ArrayBuffer | Uint8Array,
    encoding?: string
  ): Uint8Array & { toString(encoding?: string): string };
};
```

## Building and Testing

```bash
# Build the source
cd public/sources/<name> && pnpm build

# Type-check without building
cd public/sources/<name> && pnpm exec tsc --noEmit

# Install dependencies (from repo root)
pnpm install
```

After creating a new source, add it to `pnpm-workspace.yaml` if not already covered by the glob pattern.

## Source Development Checklist

- [ ] Extend `Source<YourSource>` and implement the correct common interface
- [ ] Declare `static readonly PROVIDER`, `static readonly SCOPES`
- [ ] Declare `static readonly Options: SyncToolOptions` and `declare readonly Options: SyncToolOptions`
- [ ] Declare all dependencies in `build()`: Integrations, Network, Callbacks, Tasks, Plot
- [ ] Implement `getChannels()`, `onChannelEnabled()`, `onChannelDisabled()`
- [ ] Convert parent callbacks to tokens with `createFromParent()` — **never pass functions to `this.callback()`**
- [ ] Store callback tokens with `this.set()`, retrieve with `this.get<Callback>()`
- [ ] Pass only serializable values (no functions, no undefined) to `this.callback()`
- [ ] Implement batch sync with `this.tools.tasks.runTask()` for fresh request limits
- [ ] Add localhost guard in webhook setup
- [ ] Verify webhook signatures
- [ ] Use canonical `source` URLs for activity upserts (immutable IDs)
- [ ] Use `note.key` for note-level upserts
- [ ] Inject `syncProvider` and `channelId` into `activity.meta`
- [ ] Handle `initialSync` flag: `unread: false` and `archived: false` for initial, omit both for incremental
- [ ] Create contacts for authors/assignees with `NewContact`
- [ ] Clean up all stored state and callbacks in `stopSync()` and `onChannelDisabled()`
- [ ] Add `package.json` with correct structure, `tsconfig.json`, and `src/index.ts` re-export
- [ ] Verify the source builds: `pnpm build`

## Common Pitfalls

1. **❌ Passing functions to `this.callback()`** — Convert to tokens first with `createFromParent()`
2. **❌ Storing functions with `this.set()`** — Convert to tokens first
3. **❌ Not validating callback token exists** — Always check before `callbacks.run()`
4. **❌ Forgetting sync metadata** — Always inject `syncProvider` and `channelId` into `activity.meta`
5. **❌ Using mutable IDs in `source`** — Use immutable IDs (Jira issue ID, not issue key)
6. **❌ Not breaking loops into batches** — Each execution has ~1000 request limit
7. **❌ Missing localhost guard** — Webhook registration fails silently on localhost
8. **❌ Calling `plot.createThread()` from a source** — Sources save data directly via `integrations.saveLink()`
9. **❌ Breaking callback signatures** — Old callbacks auto-upgrade; add optional params at end only
10. **❌ Passing `undefined` in serializable values** — Use `null` instead
11. **❌ Forgetting to clean up on disable** — Delete callbacks, webhooks, and stored state
12. **❌ Two-way sync without metadata correlation** — Embed Plot ID in external item metadata to prevent duplicates from race conditions (see SYNC_STRATEGIES.md §6)

## Study These Examples

| Source | Category | Key Patterns |
|--------|----------|-------------|
| `linear/` | ProjectSource | Clean reference implementation, webhook handling, bidirectional sync |
| `google-calendar/` | CalendarSource | Recurring events, RSVP write-back, watch renewal, cross-source auth sharing |
| `slack/` | MessagingSource | Team-sharded webhooks, thread model, Slack-specific auth |
| `gmail/` | MessagingSource | PubSub webhooks, email thread transformation |
| `google-drive/` | DocumentSource | Document comments, reply threading, file watching |
| `jira/` | ProjectSource | Immutable vs mutable IDs, comment metadata for dedup |
| `asana/` | ProjectSource | HMAC webhook verification, section-based projects |
| `outlook-calendar/` | CalendarSource | Microsoft Graph API, subscription management |
| `google-contacts/` | (Supporting) | Contact sync, cross-source `syncWithAuth()` pattern |
