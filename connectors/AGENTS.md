# Connector Development Guide

This guide covers everything needed to build a Plot connector correctly.

**For twist development**: See `../twister/cli/templates/AGENTS.template.md`
**For general navigation**: See `../AGENTS.md`
**For type definitions**: See `../twister/src/tools/*.ts` (comprehensive JSDoc)

## Quick Start: Complete Connector Scaffold

Every connector follows this structure:

```
connectors/<name>/
  src/
    index.ts              # Re-exports: export { default, ClassName } from "./class-file"
    <class-name>.ts       # Main Connector class
    <api-name>.ts         # (optional) Separate API client + transform functions
  package.json
  tsconfig.json
  README.md
  LICENSE
```

### package.json

```json
{
  "name": "@plotday/connector-<name>",
  "private": true,
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
      "@plotday/connector": "./src/index.ts",
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
    "directory": "connectors/<name>"
  },
  "homepage": "https://plot.day",
  "keywords": ["plot", "connector", "<name>"],
}
```

**Notes:**
- `"@plotday/connector"` export condition resolves to TypeScript source during workspace development
- Add third-party SDKs to `dependencies` (e.g., `"@linear/sdk": "^72.0.0"`)
- Add `@plotday/connector-google-contacts` as `"workspace:^"` if your connector syncs contacts (Google connectors only)

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
export { default, ConnectorName } from "./connector-name";
```

## Connector Class Template

```typescript
import {
  ActivityType,
  LinkType,
  type NewActivity,
  type NewActivityWithNotes,
  type NewNote,
  type SyncToolOptions,
  Connector,
  type ConnectorBuilder,
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
import { Tasks } from "@plotday/twister/tools/tasks";

type SyncState = {
  cursor: string | null;
  batchNumber: number;
  itemsProcessed: number;
  initialSync: boolean;
};

export class MyConnector extends Connector<MyConnector> {
  // 1. Static constants
  static readonly PROVIDER = AuthProvider.Linear; // Use appropriate provider
  static readonly SCOPES = ["read", "write"];
  static readonly Options: SyncToolOptions;
  static readonly handleReplies = true; // Enable @-mentions on replies to synced threads
  declare readonly Options: SyncToolOptions;

  // 2. Declare dependencies
  build(build: ConnectorBuilder) {
    return {
      integrations: build(Integrations, {
        providers: [{
          provider: MyConnector.PROVIDER,
          scopes: MyConnector.SCOPES,
          getChannels: this.getChannels,
          onChannelEnabled: this.onChannelEnabled,
          onChannelDisabled: this.onChannelDisabled,
        }],
      }),
      network: build(Network, { urls: ["https://api.example.com/*"] }),
      callbacks: build(Callbacks),
      tasks: build(Tasks),
    };
  }

  // 3. Create API client using channel-based auth
  private async getClient(channelId: string): Promise<any> {
    const token = await this.tools.integrations.get(MyConnector.PROVIDER, channelId);
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

    // Queue webhook and sync as separate tasks — do NOT run inline,
    // onChannelEnabled blocks the HTTP response until it returns
    const webhookCallback = await this.callback(this.setupWebhook, channel.id);
    await this.runTask(webhookCallback);
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
    const webhookCallback = await this.callback(this.setupWebhook, options.projectId);
    await this.runTask(webhookCallback);
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

  // 8. Webhook setup (non-private so it can be used with this.callback())
  async setupWebhook(resourceId: string): Promise<void> {
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
        contentType: item.descriptionHtml ? "html" as const : "text" as const,
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

export default MyConnector;
```

## The Integrations Pattern (Auth + Channels)

**This is how ALL authentication works.** Auth is handled in the Flutter edit modal, not in code. Connectors declare their provider config in `build()`.

### How It Works

1. Connector declares providers in `build()` with `getChannels`, `onChannelEnabled`, `onChannelDisabled` callbacks
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
  MyConnector.PROVIDER,
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

### Cross-Connector Auth Sharing (Google Connectors)

When building a Google connector that should also sync contacts, merge scopes:

```typescript
import GoogleContacts from "@plotday/connector-google-contacts";

build(build: ConnectorBuilder) {
  return {
    integrations: build(Integrations, {
      providers: [{
        provider: AuthProvider.Google,
        scopes: Integrations.MergeScopes(
          MyGoogleConnector.SCOPES,
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

## Architecture: Connectors Save Directly

**Connectors save data directly** via `integrations.saveLink()`. Connectors build `NewLinkWithNotes` objects and save them, rather than passing them through a parent twist.

This means:
- Connectors request `Plot` with `ContactAccess.Write` (for contacts on threads)
- Connectors declare providers via `Integrations` with lifecycle callbacks
- Connectors call save methods directly to persist synced data

## Critical: Callback Serialization Pattern

**The #1 mistake when building connectors is passing function references as callback arguments.** Functions cannot be serialized across worker boundaries.

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

**All callbacks automatically upgrade to new connector versions on deployment.** You MUST maintain backward compatibility.

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

All connectors use consistent key prefixes:

| Key Pattern | Purpose |
|------------|---------|
| `item_callback_<id>` | Serialized callback to parent's `onItem` |
| `disable_callback_<id>` | Serialized callback to parent's `onChannelDisabled` |
| `sync_state_<id>` | Current batch pagination state |
| `sync_enabled_<id>` | Boolean tracking enabled state |
| `webhook_id_<id>` | External webhook registration ID |
| `webhook_secret_<id>` | Webhook signing secret |
| `watch_renewal_task_<id>` | Scheduled task token for webhook renewal |

## Activity Source URL Conventions

The `activity.source` field is the idempotency key for automatic upserts. Use a canonical format:

```
<provider>:<entity>:<id>        — Standard pattern
<provider>:<namespace>:<id>     — When provider has multiple entity types
```

### Source identifier uniqueness (CRITICAL)

`source` is the **cross-user deduplication key** for the Plot runtime. Two instances of the same connector that emit the same `source` string will **converge on a single shared thread** across users — that's how two users on the same Gmail message see one shared thread rather than two parallel ones.

This means your `source` must be globally unique for the logical external item — not merely unique within a single user's account. Before committing a source pattern, ask yourself: *"Could two different users' connector instances emit this exact string for different external items?"* If yes, you must include a qualifier (workspace, tenant, mailbox, project, …).

Safe patterns (globally unique external ids):
```
linear:issue:<uuid>                           — Linear issue UUIDs are globally unique
github:<owner>/<repo>/issue:<number>          — Scoped by owner+repo
google-chat:<spaceId>:thread:<threadKey>      — Space id globally unique
ms-teams:channel:<channelId>:message:<id>     — Teams channel id globally unique
ms-teams:dm:<chatId>                          — Chat ids globally unique
https://mail.google.com/mail/u/0/#inbox/<threadId>   — Gmail thread id globally unique
```

Patterns that need disambiguation:
```
attio:<workspaceId>:<type>:<recordId>         — Attio record ids are workspace-scoped
posthog:<projectId>:person:<distinctId>       — distinct_id is project-scoped (often just an email)
outlook-calendar:<mailboxId>:<eventId>        — Graph event ids are mailbox-local
fellow:<tenantId>:note:<id>                   — Fellow ids are tenant-scoped
```

**If you're adding a new connector, pick a source format that encodes the tenant/workspace/mailbox upfront.** Retrofits are possible but require a backfill migration.

**Mutable IDs:** For services where identifiers can change (like Jira issue keys that change on project move), use the immutable ID in `source` and store the mutable key in `meta` only.

### Attestation-based visibility for shared threads

When your connector populates `thread.contacts` from an external item's recipients, listing someone there does NOT automatically admit them to the thread. The runtime requires that each user's own connector instance independently sync the item (proof that it's in their authenticated account) before they gain a `thread_priority` row. Users whose own sync arrives before any other user has attested them land in `thread.pending_contacts` and are promoted to `thread.contacts` on the next attester's sync.

You don't need to do anything special for this — just continue to populate `contacts` with every recipient you see. The runtime's `upsert_thread` enforces attestation; connectors can treat visibility as a server-side concern.

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

## HTML Content Handling

**Never strip HTML tags locally.** When external APIs return HTML content, pass it through with `contentType: "html"` and let the server convert it to clean markdown. Local regex-based tag stripping produces broken encoding, loses link structure, and collapses whitespace.

### Pattern

```typescript
// ✅ CORRECT: Pass raw HTML with contentType
const note = {
  key: "description",
  content: item.bodyHtml,             // Raw HTML from API
  contentType: "html" as const,       // Server converts to markdown
};

// ✅ CORRECT: Use plain text when that's what you have
const note = {
  key: "description",
  content: item.bodyText,
  contentType: "text" as const,
};

// ❌ WRONG: Stripping HTML locally
const stripped = html.replace(/<[^>]+>/g, " ").trim();
const note = { content: stripped };    // Broken encoding, lost links
```

### When APIs provide both HTML and plain text

Prefer HTML — the server-side `toMarkdown()` conversion (via Cloudflare AI) produces cleaner output with proper links, formatting, and character encoding. Only use plain text if no HTML is available.

```typescript
function extractBody(part: MessagePart): { content: string; contentType: "text" | "html" } {
  // Prefer HTML for server-side conversion
  const htmlPart = findPart(part, "text/html");
  if (htmlPart) return { content: decode(htmlPart), contentType: "html" };

  const textPart = findPart(part, "text/plain");
  if (textPart) return { content: decode(textPart), contentType: "text" };

  return { content: "", contentType: "text" };
}
```

### Previews

For `preview` fields on threads/links, use a plain-text source (like Gmail's `snippet` or a truncated title) — never raw HTML. Previews are displayed directly and are not processed by the server.

### ContentType values

| Value | Meaning |
|-------|---------|
| `"text"` | Plain text — auto-links URLs, preserves line breaks |
| `"markdown"` | Already markdown (default if omitted) |
| `"html"` | HTML — converted to markdown server-side |

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

## Initial vs. Incremental Sync (REQUIRED)

**Every connector MUST track whether it is performing an initial sync (first import) or an incremental sync (ongoing updates).** Omitting this causes notification spam from bulk historical imports.

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

### How to propagate the flag

The `initialSync` flag must flow from the entry point (`onChannelEnabled` / `startSync`) through every batch to the point where activities are created. There are two patterns:

**Pattern A: Store in SyncState** (used in the scaffold above)

The scaffold's `SyncState` type includes `initialSync: boolean`. Set it to `true` in `startBatchSync`, read it in `syncBatch`, and preserve it across batches. Webhook/incremental handlers pass `false`.

**Pattern B: Pass as callback argument** (used by connectors like Gmail that don't store `initialSync` in state)

Pass `initialSync` as an explicit argument through `this.callback()`:

```typescript
// onChannelEnabled — initial sync
const syncCallback = await this.callback(this.syncBatch, 1, "full", channel.id, true);

// startIncrementalSync — not initial
const syncCallback = await this.callback(this.syncBatch, 1, "incremental", channelId, false);

// syncBatch — accept and propagate the flag
async syncBatch(
  batchNumber: number,
  mode: "full" | "incremental",
  channelId: string,
  initialSync?: boolean  // optional for backward compat with old serialized callbacks
): Promise<void> {
  const isInitial = initialSync ?? (mode === "full");  // safe default for old callbacks
  // ... pass isInitial to processItems and to next batch callback
}
```

**Whichever pattern you use, verify that ALL entry points set the flag correctly:**
- `onChannelEnabled` → `true` (first import)
- `startSync` → `true` (manual full sync)
- Webhook / incremental handler → `false`
- Next batch callback → propagate current value

## Webhook Patterns

### Localhost Guard (REQUIRED)

All connectors MUST skip webhook registration in local development:

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

For connectors that support write-backs (updating external items from Plot):

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
// In the twist (not the connector):
async onNoteCreated(note: Note): Promise<void> {
  if (note.author.type === ActorType.Twist) return; // Prevent loops
  // ... sync note to external service
}
```

### Default Mention on Replies

Connectors with bidirectional sync should set `static readonly handleReplies = true` so replies to synced threads automatically mention the connector:

```typescript
export class MyConnector extends Connector<MyConnector> {
  static readonly handleReplies = true;  // Replies to synced threads mention this connector by default
  // ...
}
```

Without this, the connector cannot be @-mentioned at all. Connectors that don't process replies (e.g., read-only calendar sync) should NOT set this flag.

### Creating New Items from Plot (`onCreateLink`)

Plot users can start a new thread tied to a brand-new external item (e.g. create a Linear issue, a Google Calendar event, a Slack DM) via "Create new …" in the Add link modal. Connectors opt in per link type:

1. **Mark a status as the creation default** on the `LinkTypeConfig` you expose for that type — either on the static `readonly linkTypes` on the class, or on the dynamic per-channel linkTypes returned by `getChannels`:

   ```typescript
   statuses: [
     { status: "backlog", label: "Backlog" },
     { status: "unstarted", label: "To Do", todo: true, createDefault: true },
     { status: "completed", label: "Done", tag: Tag.Done, done: true },
   ],
   ```

   A link type opts in to Plot-initiated creation by declaring at least one status with `createDefault: true`. The marked status is used as the default when the user selects "Create new X".

2. **Implement `onCreateLink(draft)`** — called after the Plot thread is saved and titled. Create the external item and return a `NewLinkWithNotes` describing it. The platform attaches the link to the originating thread; do NOT call `integrations.saveLink()` yourself.

   ```typescript
   async onCreateLink(draft: CreateLinkDraft): Promise<NewLinkWithNotes | null> {
     if (draft.type !== "issue") return null;
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
       // channelId/type default to draft.channelId/draft.type if you omit them.
     };
   }
   ```

**`CreateLinkDraft` shape** (see `twister/src/connector.ts`):
- `channelId`, `type`, `status` — identify the target channel + link type + status.
- `title` — Plot thread title (post AI title generation).
- `noteContent` — markdown of the thread's first note, or `null`.
- `contacts: Actor[]` — thread's contacts (excluding the creating user), for email recipients / DM members / invitees.

**Platform defaults**: the runtime fills in `channelId` and `type` on the returned link from the draft if the connector omits them. Status label resolution depends on `channel_id`, so this default keeps the UI rendering correct even if you forget to echo them.

**Do not**:
- Call `integrations.saveLink()` — the platform wires the returned link to the user's thread.
- Assume the draft's status matches an external state id verbatim. For dynamic-per-team statuses (Linear teams, Jira projects), the draft's status is whatever was shown in the picker — your connector is responsible for resolving categories like `"unstarted"` if your static `linkTypes` fallback was used.

**Loop prevention**: the link your `onCreateLink` returns is written with `updated_by` set to the twist, so subsequent syncs of the same external id won't retrigger `onCreateLink` or `onLinkUpdated` for the initial state.

## Contacts Pattern

Connectors that sync user data should create contacts for authors and assignees:

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

Contacts are created implicitly when saving threads/links via `integrations.saveLink()` — no explicit `addContacts()` call or `ContactAccess.Write` permission is needed.

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
# Build the connector
cd public/connectors/<name> && pnpm build

# Type-check without building
cd public/connectors/<name> && pnpm exec tsc --noEmit

# Install dependencies (from repo root)
pnpm install
```

After creating a new connector, add it to `pnpm-workspace.yaml` if not already covered by the glob pattern.

## Connector Development Checklist

- [ ] Extend `Connector<YourConnector>`
- [ ] Declare `static readonly PROVIDER`, `static readonly SCOPES`
- [ ] Declare `static readonly Options: SyncToolOptions` and `declare readonly Options: SyncToolOptions`
- [ ] Declare all dependencies in `build()`: Integrations, Network, Callbacks, Tasks
- [ ] Set `static readonly handleReplies = true` if the connector supports bidirectional sync
- [ ] Implement `getChannels()`, `onChannelEnabled()`, `onChannelDisabled()` — **use `runTask()` (not `run()`) in `onChannelEnabled` to avoid blocking the API response**
- [ ] Convert parent callbacks to tokens with `createFromParent()` — **never pass functions to `this.callback()`**
- [ ] Store callback tokens with `this.set()`, retrieve with `this.get<Callback>()`
- [ ] Pass only serializable values (no functions, no undefined) to `this.callback()`
- [ ] Implement batch sync with `this.tools.tasks.runTask()` for fresh request limits
- [ ] Add localhost guard in webhook setup
- [ ] Verify webhook signatures
- [ ] Use canonical `source` URLs for activity upserts (immutable IDs)
- [ ] Use `note.key` for note-level upserts
- [ ] Set `contentType: "html"` on notes with HTML content — **never strip HTML locally**
- [ ] Inject `syncProvider` and `channelId` into `activity.meta`
- [ ] Set `created` on notes using the external system's timestamp (not sync time)
- [ ] Handle `initialSync` flag in **every sync entry point**: `onChannelEnabled`/`startSync` set `true`, webhooks/incremental set `false`, and the flag is propagated through all batch callbacks to where activities are created. Set `unread: false` and `archived: false` for initial, omit both for incremental
- [ ] Create contacts for authors/assignees with `NewContact`
- [ ] Clean up all stored state and callbacks in `stopSync()` and `onChannelDisabled()`
- [ ] **If the connector should let users create new items from Plot**: mark one status per opted-in `LinkTypeConfig` with `createDefault: true` and implement `onCreateLink(draft)`. Return a `NewLinkWithNotes` — never call `integrations.saveLink()` from `onCreateLink`
- [ ] Add `package.json` with correct structure, `tsconfig.json`, and `src/index.ts` re-export
- [ ] Verify the connector builds: `pnpm build`

## Common Pitfalls

1. **❌ Passing functions to `this.callback()`** — Convert to tokens first with `createFromParent()`
2. **❌ Storing functions with `this.set()`** — Convert to tokens first
3. **❌ Not validating callback token exists** — Always check before `callbacks.run()`
4. **❌ Forgetting sync metadata** — Always inject `syncProvider` and `channelId` into `activity.meta`
5. **❌ Not propagating `initialSync` through the full sync pipeline** — The flag must flow from the entry point (`onChannelEnabled`/`startSync` → `true`, webhook → `false`) through every batch callback to where activities are created. Missing this causes notification spam from bulk historical imports
6. **❌ Using mutable IDs in `source`** — Use immutable IDs (Jira issue ID, not issue key)
7. **❌ Not breaking loops into batches** — Each execution has ~1000 request limit
8. **❌ Missing localhost guard** — Webhook registration fails silently on localhost
9. **❌ Calling `plot.createThread()` from a connector** — Connectors save data directly via `integrations.saveLink()`
10. **❌ Breaking callback signatures** — Old callbacks auto-upgrade; add optional params at end only
11. **❌ Passing `undefined` in serializable values** — Use `null` instead
12. **❌ Forgetting to clean up on disable** — Delete callbacks, webhooks, and stored state
13. **❌ Two-way sync without metadata correlation** — Embed Plot ID in external item metadata to prevent duplicates from race conditions (see SYNC_STRATEGIES.md §6)
14. **❌ Stripping HTML tags locally** — Pass raw HTML with `contentType: "html"` for server-side conversion. Local regex stripping breaks encoding and loses links
15. **❌ Using placeholder titles in comment/update webhooks** — `title` always overwrites on upsert. Always use the real entity title (fetch from API if not in the webhook payload). Never use IDs or keys as placeholder titles
16. **❌ Not setting `created` on notes from external data** — Always pass the external system's timestamp (e.g., `internalDate` from Gmail, `created_at` from an API) as the note's `created` field. Omitting it defaults to sync time, making all notes appear to have been created "just now"
17. **❌ Using `this.run()` in `onChannelEnabled` to start sync** — `onChannelEnabled` runs synchronously inside the API request handler. Using `this.run()` (which executes inline) blocks the HTTP response until the entire sync completes, causing client timeouts. Always use `this.runTask()` to queue the initial sync as a separate execution so `onChannelEnabled` returns quickly
18. **❌ Calling `integrations.saveLink()` from `onCreateLink`** — The platform wires the returned link to the user's originating thread. Calling `saveLink` yourself creates a duplicate thread. Just return the `NewLinkWithNotes`
19. **❌ Forgetting to mark a status with `createDefault: true`** — Without it, Plot has no idea the link type opts in to Plot-initiated creation, so the "Create new X" entry never appears in the Add link modal. Declaring the marker is what opts a link type in, not implementing `onCreateLink` alone

## Study These Examples

| Connector | Category | Key Patterns |
|-----------|----------|-------------|
| `linear/` | ProjectConnector | Clean reference implementation, webhook handling, bidirectional sync |
| `google-calendar/` | CalendarConnector | Recurring events, RSVP write-back, watch renewal, cross-connector auth sharing |
| `slack/` | MessagingConnector | Team-sharded webhooks, thread model, Slack-specific auth |
| `gmail/` | MessagingConnector | PubSub webhooks, email thread transformation, HTML contentType, callback-arg initialSync pattern |
| `google-drive/` | DocumentConnector | Document comments, reply threading, file watching |
| `jira/` | ProjectConnector | Immutable vs mutable IDs, comment metadata for dedup |
| `asana/` | ProjectConnector | HMAC webhook verification, section-based projects |
| `outlook-calendar/` | CalendarConnector | Microsoft Graph API, subscription management |
| `google-contacts/` | (Supporting) | Contact sync, cross-connector `syncWithAuth()` pattern |
