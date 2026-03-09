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

Connectors extend the `Connector<T>` base class and declare dependencies using `ConnectorBuilder`:

```typescript
import {
  ActivityType,
  Connector,
  type ConnectorBuilder,
} from "@plotday/twister";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  type Channel,
  Integrations,
} from "@plotday/twister/tools/integrations";
import { Network } from "@plotday/twister/tools/network";
import { Plot } from "@plotday/twister/tools/plot";
import { Tasks } from "@plotday/twister/tools/tasks";
import { Callbacks } from "@plotday/twister/tools/callbacks";

export default class MyConnector extends Connector<MyConnector> {
  static readonly PROVIDER = AuthProvider.Linear;
  static readonly SCOPES = ["read", "write"];

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
      plot: build(Plot),
      tasks: build(Tasks),
      callbacks: build(Callbacks),
    };
  }

  // ... lifecycle methods below
}
```

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

1. Connector declares providers in `build()` with `getChannels`, `onChannelEnabled`, `onChannelDisabled` callbacks
2. User clicks "Connect" in the twist edit modal -> OAuth flow happens automatically
3. After auth, the runtime calls `getChannels()` to list available resources
4. User enables/disables resources in the modal

### getChannels

Return available resources after authentication:

```typescript
async getChannels(_auth: Authorization, token: AuthToken): Promise<Channel[]> {
  const client = new ApiClient({ accessToken: token.token });
  const resources = await client.listResources();
  return resources.map(r => ({ id: r.id, title: r.name }));
}
```

### onChannelEnabled

Called when the user enables a resource. Set up syncing:

```typescript
async onChannelEnabled(channel: Channel): Promise<void> {
  await this.setupWebhook(channel.id);
  await this.startBatchSync(channel.id);
}
```

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
  const token = await this.tools.integrations.get(MyConnector.PROVIDER, channelId);
  if (!token) throw new Error("No authentication token available");
  return new ApiClient({ accessToken: token.token });
}
```

---

## Data Sync

Connectors sync data using `Activity.source` and `Note.key` for automatic upserts (no manual ID tracking needed).

### Transforming External Items

```typescript
private transformItem(item: any, channelId: string, initialSync: boolean) {
  return {
    source: `myprovider:item:${item.id}`, // Canonical source for deduplication
    type: ActivityType.Action,
    title: item.title,
    meta: {
      externalId: item.id,
      syncProvider: "myprovider",  // Required for bulk operations
      channelId,                   // Required for bulk operations
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

Connectors run in an ephemeral environment with ~1000 requests per execution. Break long operations into batches using `runTask()`, which creates a new execution with fresh request limits.

```typescript
private async startBatchSync(channelId: string): Promise<void> {
  await this.set(`sync_state_${channelId}`, {
    cursor: null,
    batchNumber: 1,
    initialSync: true,
  });

  const batchCallback = await this.callback(this.syncBatch, channelId);
  await this.tools.tasks.runTask(batchCallback);
}

private async syncBatch(channelId: string): Promise<void> {
  const state = await this.get(`sync_state_${channelId}`);
  if (!state) return;

  const client = await this.getClient(channelId);
  const result = await client.listItems({ cursor: state.cursor, limit: 50 });

  for (const item of result.items) {
    const activity = this.transformItem(item, channelId, state.initialSync);
    await this.tools.plot.createActivity(activity);
  }

  if (result.nextCursor) {
    await this.set(`sync_state_${channelId}`, {
      cursor: result.nextCursor,
      batchNumber: state.batchNumber + 1,
      initialSync: state.initialSync,
    });
    const nextBatch = await this.callback(this.syncBatch, channelId);
    await this.tools.tasks.runTask(nextBatch);
  } else {
    await this.clear(`sync_state_${channelId}`);
  }
}
```

---

## Complete Example

A minimal connector that syncs issues from an external service:

```typescript
import {
  ActivityType,
  LinkType,
  Connector,
  type ConnectorBuilder,
  type SyncToolOptions,
} from "@plotday/twister";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  type Channel,
  Integrations,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { Plot } from "@plotday/twister/tools/plot";
import { Tasks } from "@plotday/twister/tools/tasks";
import { Callbacks } from "@plotday/twister/tools/callbacks";

export default class IssueConnector extends Connector<IssueConnector> {
  static readonly PROVIDER = AuthProvider.Linear;
  static readonly SCOPES = ["read"];
  static readonly Options: SyncToolOptions;
  declare readonly Options: SyncToolOptions;

  build(build: ConnectorBuilder) {
    return {
      integrations: build(Integrations, {
        providers: [{
          provider: IssueConnector.PROVIDER,
          scopes: IssueConnector.SCOPES,
          getChannels: this.getChannels,
          onChannelEnabled: this.onChannelEnabled,
          onChannelDisabled: this.onChannelDisabled,
        }],
      }),
      network: build(Network, { urls: ["https://api.linear.app/*"] }),
      plot: build(Plot),
      tasks: build(Tasks),
      callbacks: build(Callbacks),
    };
  }

  async getChannels(_auth: Authorization, token: AuthToken): Promise<Channel[]> {
    // Return available projects/teams for the user to select
    const client = new LinearClient({ accessToken: token.token });
    const teams = await client.teams();
    return teams.nodes.map(t => ({ id: t.id, title: t.name }));
  }

  async onChannelEnabled(channel: Channel): Promise<void> {
    // Set up webhook
    const webhookUrl = await this.tools.network.createWebhook(
      {}, this.onWebhook, channel.id
    );
    if (!webhookUrl.includes("localhost")) {
      const client = await this.getClient(channel.id);
      const webhook = await client.createWebhook({ url: webhookUrl });
      if (webhook?.id) await this.set(`webhook_id_${channel.id}`, webhook.id);
    }

    // Start initial sync
    await this.set(`sync_state_${channel.id}`, {
      cursor: null, batchNumber: 1, initialSync: true,
    });
    const batch = await this.callback(this.syncBatch, channel.id);
    await this.tools.tasks.runTask(batch);
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
    const token = await this.tools.integrations.get(IssueConnector.PROVIDER, channelId);
    if (!token) throw new Error("No auth token");
    return new LinearClient({ accessToken: token.token });
  }

  private async syncBatch(channelId: string): Promise<void> {
    const state = await this.get<any>(`sync_state_${channelId}`);
    if (!state) return;

    const client = await this.getClient(channelId);
    const result = await client.issues({ teamId: channelId, after: state.cursor });

    for (const issue of result.nodes) {
      await this.tools.plot.createActivity({
        source: `linear:issue:${issue.id}`,
        type: ActivityType.Action,
        title: `${issue.identifier}: ${issue.title}`,
        done: issue.completedAt ? new Date(issue.completedAt) : null,
        meta: { syncProvider: "linear", channelId },
        notes: [{
          key: "description",
          content: issue.description || null,
          links: issue.url ? [{
            type: LinkType.external,
            title: "Open in Linear",
            url: issue.url,
          }] : null,
        }],
        ...(state.initialSync ? { unread: false } : {}),
        ...(state.initialSync ? { archived: false } : {}),
      });
    }

    if (result.pageInfo.hasNextPage) {
      await this.set(`sync_state_${channelId}`, {
        cursor: result.pageInfo.endCursor,
        batchNumber: state.batchNumber + 1,
        initialSync: state.initialSync,
      });
      const next = await this.callback(this.syncBatch, channelId);
      await this.tools.tasks.runTask(next);
    } else {
      await this.clear(`sync_state_${channelId}`);
    }
  }

  private async onWebhook(request: WebhookRequest, channelId: string): Promise<void> {
    const payload = JSON.parse(request.rawBody || "{}");
    if (payload.type !== "Issue") return;

    const issue = payload.data;
    await this.tools.plot.createActivity({
      source: `linear:issue:${issue.id}`,
      type: ActivityType.Action,
      title: `${issue.identifier}: ${issue.title}`,
      done: issue.completedAt ? new Date(issue.completedAt) : null,
      meta: { syncProvider: "linear", channelId },
      notes: [{
        key: "description",
        content: issue.description || null,
      }],
      // Incremental sync: omit unread and archived
    });
  }
}
```

---

## Best Practices

### 1. Always Inject Sync Metadata

Every synced activity must include `syncProvider` and `channelId` in `meta` for bulk operations (e.g., archiving all activities when a channel is disabled).

### 2. Use Canonical Source URLs

Use immutable IDs in `Activity.source` for deduplication. For services with mutable identifiers (like Jira issue keys), use the immutable ID in `source` and store the mutable key in `meta`.

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
