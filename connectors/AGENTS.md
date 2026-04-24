# Connector Development Guide

Covers everything needed to build a Plot connector correctly. For twists, see `../twister/cli/templates/AGENTS.template.md`. For navigation, `../AGENTS.md`. Type definitions with full JSDoc live in `../twister/src/tools/*.ts`.

## Scaffold

```
connectors/<name>/
  src/
    index.ts          # export { default, ConnectorName } from "./connector-name";
    <connector-name>.ts
    <api-name>.ts     # (optional)
  package.json
  tsconfig.json
  README.md
  LICENSE
```

### package.json essentials

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
  "scripts": { "build": "tsc", "clean": "rm -rf dist" },
  "dependencies": { "@plotday/twister": "workspace:^" },
  "devDependencies": { "typescript": "^5.9.3" },
  "repository": { "type": "git", "url": "https://github.com/plotday/plot.git", "directory": "connectors/<name>" },
  "homepage": "https://plot.day",
  "keywords": ["plot", "connector", "<name>"]
}
```

- `"@plotday/connector"` export condition resolves to TS source during workspace dev.
- Add third-party SDKs to `dependencies` (e.g. `"@linear/sdk": "^72.0.0"`).
- Add `@plotday/connector-google-contacts` as `"workspace:^"` if you sync contacts (Google connectors only).

### tsconfig.json

```json
{
  "$schema": "https://json.schemastore.org/tsconfig",
  "extends": "@plotday/twister/tsconfig.base.json",
  "compilerOptions": { "outDir": "./dist" },
  "include": ["src/**/*.ts"]
}
```

## Class skeleton

Use `connectors/linear/` as the canonical reference. Minimum shape:

```typescript
import {
  ActivityType, LinkType, Connector,
  type NewActivityWithNotes, type SyncToolOptions, type ConnectorBuilder,
} from "@plotday/twister";
import { type Callback, Callbacks } from "@plotday/twister/tools/callbacks";
import {
  AuthProvider, Integrations,
  type AuthToken, type Authorization, type Channel,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { Tasks } from "@plotday/twister/tools/tasks";

export class MyConnector extends Connector<MyConnector> {
  static readonly PROVIDER = AuthProvider.Linear;
  static readonly SCOPES = ["read", "write"];
  static readonly Options: SyncToolOptions;
  static readonly handleReplies = true; // only for bidirectional connectors
  declare readonly Options: SyncToolOptions;

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

  async getChannels(_auth: Authorization, token: AuthToken): Promise<Channel[]> { /* list resources */ }

  async onChannelEnabled(channel: Channel): Promise<void> {
    // 1. Store parent callback tokens via tools.callbacks.createFromParent(this.options.onItem)
    // 2. Queue webhook + initial sync as SEPARATE tasks via runTask() — never inline;
    //    onChannelEnabled blocks the HTTP response until it returns.
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    // Delete webhook, delete callback tokens, clear() all per-channel state.
  }
}

export default MyConnector;
```

Required private helpers: `getClient(channelId)`, `setupWebhook(id)`, `startBatchSync(id)`, `syncBatch(id)`, `transformItem(item, id, initialSync)`, `onWebhook(req, id)`. See `linear/` for the full pattern.

## Integrations (auth + channels)

Auth is handled in the Flutter edit modal — you declare providers in `build()`, the runtime drives OAuth.

1. User clicks "Connect" → OAuth runs automatically.
2. Runtime calls your `getChannels()` to list resources.
3. User enables → `onChannelEnabled()`. User disables → `onChannelDisabled()`.
4. Read tokens via `this.tools.integrations.get(PROVIDER, channelId)`.

`AuthProvider` values: `Google`, `Microsoft`, `Notion`, `Slack`, `Atlassian`, `Linear`, `Monday`, `GitHub`, `Asana`, `HubSpot`.

### Per-user auth for write-backs

```typescript
await this.tools.integrations.actAs(MyConnector.PROVIDER, actorId, activityId, this.performWriteBack, ...args);

async performWriteBack(token: AuthToken, ...args: any[]): Promise<void> {
  // token is the acting user's token
}
```

### Cross-connector auth sharing (Google)

Merge scopes with `Integrations.MergeScopes(MyGoogleConnector.SCOPES, GoogleContacts.SCOPES)` and add `googleContacts: build(GoogleContacts)` to your `build()` return.

## Architecture

Connectors persist data directly via `integrations.saveLink()` (building `NewLinkWithNotes`). They do not push through a parent twist, and should not call `plot.createThread()`.

## Callback serialization (the #1 mistake)

Functions are not serializable across worker boundaries. Convert to tokens, store primitives.

```typescript
// ❌ WRONG — passing a function as a callback arg
await this.callback(this.syncBatch, callback, ...extraArgs);
// Error: Cannot create callback args: Found function at path "value[0]"

// ✅ CORRECT
const token = await this.tools.callbacks.createFromParent(callback, ...extraArgs);
await this.set(`callback_${resourceId}`, token);
const batch = await this.callback(this.syncBatch, resourceId); // primitives only
await this.tools.tasks.runTask(batch);

// In syncBatch:
const token = await this.get<Callback>(`callback_${resourceId}`);
if (!token) throw new Error(`Callback not found for ${resourceId}`);
await this.tools.callbacks.run(token, item);
```

Serializable: strings, numbers, booleans, `null`, plain objects, arrays, Dates (SuperJSON), callback tokens.  
Not serializable: functions, `undefined` (use `null`), symbols, RPC stubs, circular refs.

## Callback backward compatibility

Deployed callbacks auto-upgrade to new connector versions. Signatures must stay compatible:

- ✅ Add optional params at the end with safe defaults.
- ❌ Don't remove/reorder params or change existing types.

```typescript
// v1.0
async syncBatch(batchNumber: number, resourceId: string) { ... }
// v1.1 — safe
async syncBatch(batchNumber: number, resourceId: string, initialSync?: boolean) {
  const isInitial = initialSync ?? true;
}
```

For breaking changes, do migration in `preUpgrade()` (e.g. clear stale locks).

## Storage key conventions

| Key | Purpose |
|---|---|
| `item_callback_<id>` | Token for parent's `onItem` |
| `disable_callback_<id>` | Token for parent's `onChannelDisabled` |
| `sync_state_<id>` | Current batch pagination state |
| `sync_enabled_<id>` | Boolean tracking enabled state |
| `webhook_id_<id>` | External webhook registration id |
| `webhook_secret_<id>` | Webhook signing secret |
| `watch_renewal_task_<id>` | Scheduled task for webhook renewal |

## `source` — idempotency + cross-user dedup (CRITICAL)

`activity.source` / `link.source` is the upsert key AND the cross-user dedup key: two instances emitting the same `source` converge on a single shared thread across users (that's how two users on the same Gmail message share one thread).

**Your `source` must be globally unique for the external item, not merely unique within a user's account.** If two different users' connectors could emit the same string for different items, include a qualifier (workspace, tenant, mailbox, project).

Safe (globally unique ids):
```
linear:issue:<uuid>
github:<owner>/<repo>/issue:<number>
google-chat:<spaceId>:thread:<threadKey>
ms-teams:channel:<channelId>:message:<id>
ms-teams:dm:<chatId>
https://mail.google.com/mail/u/0/#inbox/<threadId>
```

Need disambiguation (scoped ids):
```
attio:<workspaceId>:<type>:<recordId>
posthog:<projectId>:person:<distinctId>
outlook-calendar:<mailboxId>:<eventId>
fellow:<tenantId>:note:<id>
```

Pick the format up front — retrofits require a backfill migration.

**Mutable ids:** use the immutable id in `source`, store the mutable key in `meta` only (e.g. Jira issue id in `source`, issue key in `meta`).

### Attestation-based visibility

Populating `thread.contacts` with recipients does NOT automatically admit them. The runtime requires each user's own connector to sync the item before they get a `thread_priority` row. Users whose sync lands first go to `thread.pending_contacts` and are promoted on the next attester's sync. You just populate `contacts` with every recipient you see — the runtime's `upsert_thread` handles the rest.

## Note key conventions

`note.key` enables note-level upserts AND is the only way the runtime can correlate a Plot-authored note with its external counterpart for baseline preservation (see "Sync baseline preservation" above). Bidirectional connectors must assign keys on write-back.

```
"description"                 — main body
"summary"                     — document summary
"metadata"                    — status/priority/assignee
"cancellation"                — cancelled event note
"comment-<externalCommentId>"
"reply-<commentId>-<replyId>"
```

## HTML content

**Never strip HTML locally.** Pass raw HTML with `contentType: "html"` and let the server convert to markdown (cleaner output, preserved links/encoding).

```typescript
const note = { key: "description", content: item.bodyHtml, contentType: "html" as const };
```

When both are available, prefer HTML. Use `"text"` only if no HTML is available.

Previews (`preview` fields) always use plain text — `snippet` or truncated title, never HTML.

`contentType`: `"text"` (auto-links URLs), `"markdown"` (default), `"html"` (server-converted).

## Sync metadata injection

Every synced activity must include provider and channel metadata — the twist's bulk operations (e.g. archiving on disable) rely on it:

```typescript
activity.meta = { ...activity.meta, syncProvider: "myprovider", channelId: resourceId };
```

## Initial vs incremental sync (REQUIRED)

Missing this causes notification spam from bulk historical imports.

| Field | Initial | Incremental |
|---|---|---|
| `unread` | `false` | *omit* |
| `archived` | `false` | *omit* |

```typescript
const activity = {
  ...(initialSync ? { unread: false, archived: false } : {}),
};
```

The flag must flow from entry point through every batch to the activity-creation site.

- **Pattern A — store in SyncState**: include `initialSync: boolean` in your state type; set `true` in `startBatchSync`, preserve across batches, webhooks pass `false`.
- **Pattern B — pass as callback arg**: make it the last, optional param (for backward compat) and propagate: `async syncBatch(batch: number, mode: "full"|"incremental", channelId: string, initialSync?: boolean)`. Used by connectors like Gmail.

Entry points: `onChannelEnabled`/`startSync` → `true`; webhook/incremental → `false`; next batch → propagate current value.

## Webhooks

### Localhost guard (REQUIRED)

```typescript
const webhookUrl = await this.tools.network.createWebhook({}, this.onWebhook, resourceId);
if (webhookUrl.includes("localhost") || webhookUrl.includes("127.0.0.1")) return;
```

### Signature verification

| Provider | Method |
|---|---|
| Linear | `LinearWebhookClient` from `@linear/sdk/webhooks` |
| Slack | Challenge response + event type filter |
| Google | UUID secret in channel token query |
| Microsoft | Subscription `clientState` |
| Asana | HMAC-SHA256 via `crypto.subtle` |

### Watch renewal (Calendar/Drive)

```typescript
const renewalTime = new Date(expiresAt.getTime() - 24 * 60 * 60 * 1000);
const renewal = await this.callback(this.renewWatch, resourceId);
const taskToken = await this.runTask(renewal, { runAt: renewalTime });
if (taskToken) await this.set(`watch_renewal_task_${resourceId}`, taskToken);
```

## Bidirectional sync

```typescript
// Update issue/task from Plot
async updateIssue(activity: Activity): Promise<void> {
  const externalId = activity.meta?.externalId as string;
  const client = await this.getClient(activity.meta?.resourceId as string);
  await client.updateItem(externalId, { title: activity.title, done: /* ... */ });
}

// Post a comment. Return a NoteWriteBackResult with externalContent so the
// runtime can establish a sync baseline (see "Sync baseline preservation"
// below). Returning just a string still works, but without a baseline the
// next sync-in will overwrite Plot's (possibly richer-markdown) content
// with the round-tripped plain text the external system stored.
async onNoteCreated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
  const client = await this.getClient(thread.meta?.resourceId as string);
  const comment = await client.createComment(thread.meta?.externalId as string, { body: note.content ?? "" });
  if (!comment?.id) return;
  return {
    key: `comment-${comment.id}`,
    externalContent: comment.body, // what the external system NOW STORES
  };
}

// Push a local edit back to the external system. `note.key` identifies the
// target; refresh the baseline from the response so the next sync-in
// recognises the round-trip and preserves Plot's edited content.
async onNoteUpdated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
  if (!note.key?.startsWith("comment-")) return;
  const commentId = note.key.slice("comment-".length);
  const client = await this.getClient(thread.meta?.resourceId as string);
  const updated = await client.updateComment(commentId, { body: note.content ?? "" });
  return { externalContent: updated.body };
}
```

**Loop prevention** (in the twist, not the connector): `if (note.author.type === ActorType.Twist) return;`

**`handleReplies`**: bidirectional connectors must set `static readonly handleReplies = true` to enable @-mentions on replies. Read-only connectors should NOT.

### Sync baseline preservation (required for any note round-trip)

When Plot pushes a note to an external system that stores content in a lossier format than Plot does (e.g. plain-text comments APIs, ADF, HTML that gets sanitised), the external's version re-ingested on the next sync would overwrite Plot's original content with the round-tripped form — `1.` → `1\.`, `[name]` → `\[name\]`, etc. To prevent this, the runtime tracks a per-note "external baseline" hash in `note.external_content_hash`:

- **Write-back (`onNoteCreated` / `onNoteUpdated`) returns `NoteWriteBackResult`** with `externalContent` set to what the external system now stores. The runtime hashes this and stores it as the note's baseline. (The hash is over the content string only — no contentType prefix — so write-back and sync-in don't need to agree on a contentType label to match.)
- **Sync-in** computes the same hash on each incoming `NewNote.content`. Match → preserve Plot's stored content (skip overwrite). Mismatch → external was edited, overwrite.

The hard contract:

> **`externalContent` must exactly equal the `NewNote.content` string your sync-in path will emit for this note on re-ingest.**

If your sync-in runs incoming comment bodies through a transform (e.g. Airtable's `translateMentionsInbound`, Jira's `extractTextFromADF`), apply the same transform to the write-back response before returning it. Pick the value by looking at the sync-in `build*Note` function and returning exactly what ends up in `content`.

For systems that return the stored representation on write (Drive, GitHub, Linear, Slack `chat.postMessage`), use the response directly. For systems that don't (Gmail `messages.send`), either fetch the stored form with an extra API call or skip `externalContent` — the first sync-in after the write will organically establish the baseline. Document the tradeoff.

**Failure modes you must avoid:**

- Returning `externalContent` that differs from what sync-in will produce → every sync-in clobbers Plot's content.
- Not setting `handleReplies = true` → dispatch never reaches `onNoteCreated`.
- Calling `integrations.saveLink()` inside `onNoteCreated` to propagate the key → no longer needed (runtime now does it). Remove any such workaround.

**Legacy:** `onNoteCreated` may still return a plain `string` — treated as `{ key }` with no baseline. Don't use this shape in new connectors.

### Creating new items from Plot (`onCreateLink`)

Opt a link type in by marking one status with `createDefault: true`:

```typescript
statuses: [
  { status: "backlog", label: "Backlog" },
  { status: "unstarted", label: "To Do", todo: true, createDefault: true },
  { status: "completed", label: "Done", tag: Tag.Done, done: true },
]
```

Then implement `onCreateLink` — return the link, do NOT call `integrations.saveLink()` (platform wires it to the originating thread):

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
    // channelId/type default to draft values if omitted
  };
}
```

`CreateLinkDraft`: `channelId`, `type`, `status`, `title`, `noteContent`, `contacts: Actor[]`. See `twister/src/connector.ts`.

Resolve category statuses (`"unstarted"`, etc.) to the provider's state id yourself — the draft's status is whatever the picker showed.

The returned link is written with `updated_by` set to the twist, so subsequent syncs of the same id won't re-fire `onCreateLink`/`onLinkUpdated` for the initial state.

## Contacts

Contacts are created implicitly when you save threads/links — no `addContacts()` call, no `ContactAccess.Write`.

```typescript
const author: NewContact | undefined = creator?.email
  ? { email: creator.email, name: creator.name, avatar: creator.avatarUrl ?? undefined }
  : undefined;

const activity: NewActivityWithNotes = {
  author,
  assignee: assigneeContact ?? null,
  notes: [{ author /* note-level author too */ }],
};
```

## Buffer declaration

Cloudflare Workers provide `Buffer` globally but TS doesn't know. Add at file top:

```typescript
declare const Buffer: {
  from(data: string | ArrayBuffer | Uint8Array, encoding?: string):
    Uint8Array & { toString(encoding?: string): string };
};
```

## Build & test

```bash
cd public/connectors/<name> && pnpm build
cd public/connectors/<name> && pnpm exec tsc --noEmit
pnpm install  # from repo root
```

Add to `pnpm-workspace.yaml` if not already covered by a glob.

## Checklist

- [ ] Extend `Connector<YourConnector>`; declare `PROVIDER`, `SCOPES`, `Options` (static + `declare readonly`)
- [ ] `build()` declares Integrations, Network, Callbacks, Tasks (plus GoogleContacts if applicable)
- [ ] Set `handleReplies = true` only if bidirectional
- [ ] For bidirectional note sync: `onNoteCreated` / `onNoteUpdated` return `NoteWriteBackResult` with `externalContent` matching what sync-in will emit for this note — no `Promise<string | void>` in new connectors
- [ ] For bidirectional note sync: implement `onNoteUpdated` if the external supports editing (document the gap if it doesn't)
- [ ] `onChannelEnabled` uses `runTask()` (NOT `run()`) for webhook setup and initial sync — blocks HTTP response otherwise
- [ ] Convert parent callbacks to tokens with `createFromParent()`; store via `this.set()`; retrieve with `this.get<Callback>()`
- [ ] Never pass functions, RPC stubs, or `undefined` to `this.callback()` — use `null`
- [ ] Validate token exists before `callbacks.run()`
- [ ] Localhost guard in webhook setup; verify webhook signatures
- [ ] Canonical, globally-unique `source` using immutable ids; mutable keys in `meta` only
- [ ] `note.key` for note-level upserts
- [ ] Inject `syncProvider` + `channelId` into `activity.meta`
- [ ] `contentType: "html"` for HTML — never strip tags locally
- [ ] `created` on notes = external timestamp, not sync time
- [ ] `initialSync` propagated through every entry point and batch; set `unread: false, archived: false` on initial, omit on incremental
- [ ] Create `NewContact` for authors/assignees
- [ ] Clean up callbacks, webhooks, stored state in `stopSync()` and `onChannelDisabled()`
- [ ] For Plot-initiated creation: mark status with `createDefault: true` AND implement `onCreateLink` — don't call `saveLink` from inside it
- [ ] `pnpm build` succeeds

## Common pitfalls

1. Passing functions/`undefined`/RPC stubs to `this.callback()` → use tokens + `null`.
2. Forgetting sync metadata (`syncProvider`, `channelId`) → breaks bulk archive on disable.
3. Not propagating `initialSync` through the whole pipeline → notification spam.
4. Mutable ids in `source` (e.g. Jira issue key) → use immutable id, store key in `meta`.
5. `source` that's only unique within one user's account → breaks cross-user dedup; add workspace/tenant/mailbox qualifier.
6. Not breaking long loops into batches → each execution has ~1000 request limit.
7. Missing localhost guard → webhook registration fails silently.
8. Calling `plot.createThread()` from a connector → use `integrations.saveLink()`.
9. Breaking callback signatures → add optional params at end only; use `preUpgrade()` for breaking migrations.
10. Not cleaning up on disable → orphan callbacks, webhooks, state.
11. Two-way sync without metadata correlation → embed Plot id in external metadata to prevent race-condition duplicates (see SYNC_STRATEGIES.md §6).
12. Stripping HTML locally → breaks encoding + loses links; use `contentType: "html"`.
13. Placeholder titles in comment/update webhooks → `title` overwrites on upsert; fetch the real title if webhook doesn't carry it.
14. Omitting `created` on notes → everything appears "just now"; pass external timestamp.
15. `this.run()` in `onChannelEnabled` → blocks HTTP response until full sync completes; always `runTask()`.
16. Calling `integrations.saveLink()` inside `onCreateLink` → duplicate thread; just return the link.
17. Implementing `onCreateLink` without `createDefault: true` on a status → "Create new X" entry never appears.
18. Returning a bare `string` (key only) from `onNoteCreated` when the external stores content lossily (plain-text comments APIs, ADF, sanitised HTML) → next sync-in clobbers Plot's content with the round-tripped form (e.g. `1.` → `1\.`). Return a `NoteWriteBackResult` with `externalContent` matching sync-in's shape instead.
19. Returning `externalContent` that doesn't match what sync-in emits for the same note (e.g. post-write raw HTML when sync-in extracts plain text; pre-translation mentions when sync-in translates them) → baseline hash always mismatches and every sync clobbers. Inspect the sync-in `build*Note` path and return exactly what it produces.
20. Calling `integrations.saveLink()` inside `onNoteCreated` to set the note's `key` → legacy workaround, no longer needed. The runtime sets `key` automatically from the `NoteWriteBackResult` return.

## Examples

| Connector | Category | Key patterns |
|---|---|---|
| `linear/` | ProjectConnector | Canonical reference; webhooks; bidirectional |
| `google-calendar/` | CalendarConnector | Recurring events; RSVP write-back; watch renewal; shared Google auth |
| `slack/` | MessagingConnector | Team-sharded webhooks; thread model |
| `gmail/` | MessagingConnector | PubSub webhooks; HTML contentType; callback-arg `initialSync` |
| `google-drive/` | DocumentConnector | Document comments; reply threading; file watching; canonical `NoteWriteBackResult` + `onNoteUpdated` example |
| `jira/` | ProjectConnector | Immutable vs mutable ids; comment metadata dedup |
| `asana/` | ProjectConnector | HMAC webhook verification; section-based projects |
| `outlook-calendar/` | CalendarConnector | Microsoft Graph; subscription management |
| `google-contacts/` | Supporting | Contact sync; cross-connector `syncWithAuth()` |
