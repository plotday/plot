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
  "plotTwistId": "<uuid>",
  "displayName": "Human Name",
  "description": "One-line purpose statement",
  "logoUrl": "https://api.iconify.design/logos/<name>-icon.svg",
  "publisher": "Plot",
  "publisherUrl": "https://plot.day",
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
  "scripts": { "build": "tsc", "clean": "rm -rf dist", "lint": "plot lint", "deploy": "plot deploy" },
  "dependencies": { "@plotday/twister": "workspace:^" },
  "devDependencies": { "typescript": "^5.9.3" },
  "repository": { "type": "git", "url": "https://github.com/plotday/plot.git", "directory": "connectors/<name>" },
  "homepage": "https://plot.day",
  "keywords": ["plot", "connector", "<name>"]
}
```

- `"@plotday/connector"` export condition resolves to TS source during workspace dev.
- `plotTwistId` is the connector's stable twist UUID — `plot create --connector` generates one; `plot deploy` reads it along with `displayName`, `description`, `logoUrl`/`logoUrlDark`, and `publisher`.
- Add third-party SDKs to `dependencies` (e.g. `"@linear/sdk": "^72.0.0"`).
- Add `@plotday/google-contacts` as `"workspace:^"` if you sync contacts (Google connectors only).

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
  Connector,
  type NewLinkWithNotes, type ToolBuilder,
} from "@plotday/twister";
import {
  AuthProvider, Integrations,
  type AuthToken, type Authorization, type Channel,
  type StatusIcon, type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";

export class MyConnector extends Connector<MyConnector> {
  static readonly handleReplies = true; // only for bidirectional connectors

  readonly provider = AuthProvider.Linear;
  readonly scopes = ["read", "write"]; // or a ScopeConfig: { required, optional }
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
      network: build(Network, { urls: ["https://api.example.com/*"] }),
    };
  }

  async getChannels(_auth: Authorization | null, token: AuthToken | null): Promise<Channel[]> { /* list resources */ }

  async onChannelEnabled(channel: Channel, context?: SyncContext): Promise<void> {
    // Runs inline in the HTTP request handler — only this.set()/this.get()/
    // this.callback()/this.runTask() belong here. Queue webhook setup +
    // initial sync as SEPARATE tasks via this.runTask(), never inline.
    // Can be re-dispatched (auto-enable, recovery: context.recovering) —
    // overwrite stored state unconditionally, don't skip-if-present.
    // Call integrations.channelSyncCompleted(channel.id) once the initial
    // backfill finishes (from the last syncBatch, not from here).
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    // Delete webhook, delete callback tokens, clear() all per-channel state.
  }
}

export default MyConnector;
```

The runtime reads `provider`, `scopes`, and `linkTypes` from the class and drives OAuth and channel management automatically. The built-in `callbacks`, `store`, and `tasks` tools are always available (`this.callback()`, `this.set()`/`this.get()`/`this.clear()`, `this.runTask()`) and need no `build()` entry.

Required private helpers: `getClient(channelId)`, `setupWebhook(id)`, `startBatchSync(id)`, `syncBatch(id)`, `transformItem(item, id, initialSync)`, `onWebhook(req, id)`. See `linear/` for the full pattern.

## Integrations (auth + channels)

Auth is handled in the Flutter edit modal — you declare `provider` and `scopes` as class properties, the runtime drives OAuth.

1. User clicks "Connect" → OAuth runs automatically.
2. Runtime calls your `getChannels()` to list resources.
3. User enables → `onChannelEnabled()`. User disables → `onChannelDisabled()`.
4. Read tokens via `this.tools.integrations.get(channelId)`.

`AuthProvider` values: `Google`, `Microsoft`, `Notion`, `Slack`, `Atlassian`, `Linear`, `Monday`, `GitHub`, `Asana`, `HubSpot`, `Todoist`, `Airtable`.

`scopes` may be a flat array (all required) or a `ScopeConfig` (`{ required, optional }`) whose optional scope groups render as connect-time toggles; detect declined groups via the granted `token.scopes` and degrade gracefully (see `slack/` and `google/`). Connectors without OAuth (API keys, CalDAV credentials) omit `provider` and collect credentials via the `Options` tool with `secure: true` fields (see `attio/`, `fellow/`, `apple-calendar/`).

### Per-user auth for write-backs

User-initiated changes are dispatched to the acting user's own connector
instance — only that instance has their OAuth token. Your callback runs
under that user's auth, so use the connector's normal token-fetch path
(`this.tools.integrations.get(channelId)` or your `getApi(channelId)` helper)
and the write-back will be attributed to the acting user automatically.

If the acting user has no connection of this type, the change lives in
Plot but is not dispatched — there is no instance to deliver to.

### Cross-connector auth sharing (Google)

Set `readonly scopes = Integrations.MergeScopes(MyGoogleConnector.SCOPES, GoogleContacts.SCOPES)` and add `googleContacts: build(GoogleContacts)` to your `build()` return (see `google-chat/`, `google-drive/`). Alternatively declare the contacts scopes as an optional `ScopeConfig` group so the user can decline them (see `google/`).

### Connect / enable-path performance contract

The connect and channel-enable paths are on the user's critical path. The
runtime keeps them fast, and connectors must not undo that:

- **`getChannels` runs synchronously during connect.** Keep it lean and
  **parallelize independent enumeration** — when you list resources across
  several products/APIs, run them with `Promise.all`, never a serial
  `for … await` loop (see `connectors/google/src/compose.ts`). A serial loop
  pays the sum of every round-trip while the user waits.
- **`onChannelEnabled` is dispatched OFF the user's critical path.** When a user
  activates a connection, the runtime persists the enabled-channel state
  synchronously and runs `onChannelEnabled` in the background. So: never assume
  `onChannelEnabled` has run by the time the user sees the connection, and keep
  using `runTask()` for webhook setup and initial sync — the background dispatch
  still has the normal per-execution budget. Heavy *inline* work in
  `onChannelEnabled` (or in `getChannels` on enable) is the recurring mistake;
  the activate path used to do an inline `getChannels` that paginated every
  Google Drive folder and blocked for seconds.

## Architecture

Connectors persist data directly via `integrations.saveLink()` (building `NewLinkWithNotes`). They do not push through a parent twist, and should not call `plot.createThread()`.

## Callback serialization (the #1 mistake)

Functions are not serializable across worker boundaries. Convert to tokens, store primitives.

```typescript
import { type Callback } from "@plotday/twister/tools/callbacks";

// ❌ WRONG — passing a function as a callback arg
await this.callback(this.syncBatch, this.onItem);
// Error: Found function at path "value[0]"

// ✅ CORRECT — callback args are serializable primitives only
const batch = await this.callback(this.syncBatch, resourceId);
await this.runTask(batch);

// To invoke something later (scheduled renewals, stored continuations),
// persist the token, not the function:
const token = await this.callback(this.renewWatch, resourceId);
await this.set(`renewal_${resourceId}`, token);

// Later:
const stored = await this.get<Callback>(`renewal_${resourceId}`);
if (!stored) throw new Error(`Callback not found for ${resourceId}`);
await this.run(stored);
```

Serializable: strings, numbers, booleans, `null`, plain objects, arrays, Dates (SuperJSON), callback tokens.  
Not serializable: functions, `undefined` (use `null`), symbols, RPC stubs, circular refs.

(`tools.callbacks.createFromParent()` exists for tokenizing a function handed in from a parent twist/tool — regular connectors don't need it.)

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

For breaking changes, do migration in `upgrade()` (called once per active instance when a new version deploys — e.g. clear stale locks, see `outlook/`).

## Storage key conventions

| Key | Purpose |
|---|---|
| `sync_state_<id>` | Current batch pagination state |
| `sync_enabled_<id>` | Boolean tracking enabled state |
| `webhook_id_<id>` | External webhook registration id |
| `webhook_secret_<id>` | Webhook signing secret |
| `watch_renewal_task_<id>` | Scheduled task for webhook renewal |

## `source` — idempotency + cross-user dedup (CRITICAL)

`link.source` is the upsert key AND the cross-user dedup key: two instances emitting the same `source` converge on a single shared thread across users (that's how two users on the same Gmail message share one thread).

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

**Cross-connector bundling:** `link.sources` (plural) carries additional canonical aliases — any element shared with another link's `sources` bundles the two onto one thread. E.g. calendar connectors emit an `icaluid:<iCalUID>` alias so meeting-notes connectors (Fellow, Granola) can attach to the event's thread.

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

Every synced link must carry provider and channel metadata:

```typescript
link.channelId = resourceId; // first-class field on NewLinkWithNotes — REQUIRED
link.meta = { ...link.meta, syncProvider: "myprovider" };
```

`channelId` is required on `NewLinkWithNotes` (the type `saveLink()`/`saveLinks()` accept) precisely because it's easy to set only inside `meta` and forget the top-level field — the type system will reject a link built that way. This isn't just about bulk operations like `integrations.archiveLinks({ channelId })` on disable: the platform persists `channelId` to the link's DB row and reads it back from there — not from `meta` — to populate `thread.meta.channelId` for connector callbacks like `onNoteCreated`. A link with `channelId` only inside `meta` will send replies to nobody: the connector's own `onNoteCreated` reads a channelId that was never actually saved, and typically no-ops silently (no error, nothing captured) because it can't resolve a client for the reply. Set `channelId` at the top level on every value you pass to `saveLink()`/`saveLinks()`.

`onCreateLink` is the one exception: its return type is `CreateLinkResult`, where `channelId` is optional — the platform auto-fills it from `draft.channelId` (the channel the user composed into) if you omit it.

## Classifier facets (optional)

Messaging-style connectors may set `link.facets` (`format` / `automation` / `reach` from `@plotday/twister/facets`) as internal classifier signal. Set a dimension only when a heuristic is confident; leave it `null`/omitted otherwise. See `google/src/mail/gmail-facets.ts` and `slack/src/slack-facets.ts`.

## Initial vs incremental sync (REQUIRED)

Missing this causes notification spam from bulk historical imports.

| Field | Initial | Incremental |
|---|---|---|
| `unread` | `false` | *omit* |
| `archived` | `false` | *omit* |

```typescript
const link = {
  ...(initialSync ? { unread: false, archived: false } : {}),
};
```

The flag must flow from entry point through every batch to the link-creation site.

- **Pattern A — store in SyncState**: include `initialSync: boolean` in your state type; set `true` in `startBatchSync`, preserve across batches, webhooks pass `false`.
- **Pattern B — pass as callback arg**: make it the last, optional param (for backward compat) and propagate: `async syncBatch(batch: number, mode: "full"|"incremental", channelId: string, initialSync?: boolean)`. Used by connectors like Gmail.

Entry points: `onChannelEnabled`/`startSync` → `true`; webhook/incremental → `false`; next batch → propagate current value.

## Webhooks

### Localhost guard (REQUIRED)

```typescript
const webhookUrl = await this.tools.network.createWebhook({}, this.onWebhook, resourceId);
if (webhookUrl.includes("localhost") || webhookUrl.includes("127.0.0.1")) return;
```

### Webhook-driven sync uses `scheduleDrain` (REQUIRED)

Providers that push one notification per item change (Gmail Pub/Sub, Microsoft
Graph, chat messages, etc.) can deliver many notifications per minute. Never
`runTask()` a sync pass per notification — the queued passes batch together,
run concurrently in one worker, and can multiply the working set past the
memory limit. Use the purpose-built drain primitive instead:

```typescript
async onWebhook(request: WebhookRequest): Promise<void> {
  const ids = parseChangedIds(request); // [] when the provider sends no ids
  await this.scheduleDrain("incremental-sync", this.drainChanges, { ids });
}

// Receives ≤ batchSize ids per pass (default 20); the platform persists the
// dirty set durably (at-least-once), coalesces notification bursts into one
// pass, schedules continuations for the backlog, and drops poison ids after
// maxAttempts. Teardown: `await this.cancelDrain("incremental-sync")`.
async drainChanges(ids: string[]): Promise<void> {
  for (const id of ids) await this.syncItem(id);
}
```

For cursor/window-based syncs where the notification carries no ids, omit
`ids` — the handler runs with `[]`, still coalesced. See "Webhook-Driven
Sync: `scheduleDrain`" in `twister/docs/TOOLS_GUIDE.md`.

### Signature verification

| Provider | Method |
|---|---|
| Linear | `LinearWebhookClient` from `@linear/sdk/webhooks` |
| Slack | Challenge response + event type filter |
| Google | UUID secret in channel token query |
| Microsoft | Subscription `clientState` |
| Asana | HMAC-SHA256 via `crypto.subtle` |

### Watch renewal (Calendar/Drive)

Use **`this.scheduleRecurring(key, callback, { intervalMs, firstRunAt? })`** for
watch renewals (and all other recurring/self-renewing jobs). The platform owns
the cadence: it re-arms the task every `intervalMs` (the safety ceiling)
automatically, so the chain survives a dropped queue message, a suspension, a
deploy, or a callback that throws before it could reschedule. The callback does
NOT need to reschedule itself.

`intervalMs` is the **maximum gap** between fires. For watch renewals the
ceiling should be at most half the provider-issued lifetime (e.g. 3.5 days for
a 7-day watch). Pass `firstRunAt` for the precise next fire (e.g. 24h before
expiry); the callback can re-register under the same key with a fresh `firstRunAt`
on each successful renewal to keep tightening the schedule. Re-scheduling under
the same key atomically replaces the pending occurrence.

```typescript
const renewalTime = new Date(expiresAt.getTime() - 24 * 60 * 60 * 1000);
const renewal = await this.callback(this.renewWatch, resourceId);
// Platform re-arms every intervalMs; firstRunAt fires earlier (at renewal time).
await this.scheduleRecurring(`watch-renewal:${resourceId}`, renewal, {
  intervalMs: 3.5 * 24 * 60 * 60 * 1000,  // ceiling: half the 7-day watch lifetime
  firstRunAt: renewalTime,
});

// On teardown (onChannelDisabled / stopSync):
await this.cancelScheduledTask(`watch-renewal:${resourceId}`);
```

> ⚠️ `scheduleTask` is for **one-shot** keyed deferred work. `scheduleRecurring`
> is the durable primitive for any recurring or self-renewing chain — the
> platform guarantees the chain re-fires even if a single run is lost.

## Bidirectional sync

```typescript
// Write back status/assignee changes the user makes in Plot on links this
// connector created (dispatched by the runtime)
async onLinkUpdated(link: Link): Promise<void> {
  const externalId = link.meta?.externalId as string;
  const client = await this.getClient(link.channelId ?? (link.meta?.resourceId as string));
  await client.updateItem(externalId, { title: link.title, status: /* map link.status */ });
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

### Surfacing send failures (`deliveryError`)

When an outbound write-back can't be delivered, tell the user instead of failing silently. Return a `deliveryError` from `onNoteCreated` / `onNoteUpdated` (or, for `onCreateLink`, set it on `originatingNote`): the runtime marks the note **Failed to send** in the app — with Retry / Discard — and flips the thread unread.

```typescript
async onNoteCreated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
  const result = await sendWithRetry(...); // your own bounded retry for transient blips
  if (!result.ok) {
    // Permanent / auth / retries-exhausted: RETURN the failure, don't throw.
    return { deliveryError: { code: "rejected", message: "Recipient address rejected" } };
  }
  return { key: result.id, deliveryError: null }; // success also clears any prior failure
}
```

- **Return, don't throw, for expected user-visible failures** (rejected recipient, message too large, quota): a thrown error pages error tracking, a returned `deliveryError` does not. Reserve throwing for genuinely unexpected errors.
- A connector that just throws on a failed write-back still gets a generic "Failed to send" surfaced by the runtime — adopting `deliveryError` only adds a specific reason and avoids the page.
- Retry transient errors **in-process** (short, bounded backoff): neither send path rides a retrying queue. See `google/src/mail/gmail-send-errors.ts` + `sendWithRetry` in `google/src/mail/sync.ts` for the reference classifier + retry.
- Leave the idempotency guard **unset** on failure so an explicit Retry re-sends.

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

Opt a link type in by adding a `compose` block to its `LinkTypeConfig`:

```typescript
{
  type: "issue",
  label: "Issue",
  statuses: [
    { status: "backlog", label: "Backlog", icon: "backlog" as StatusIcon },
    { status: "unstarted", label: "To Do", icon: "todo" as StatusIcon },
    { status: "completed", label: "Done", done: true, icon: "done" as StatusIcon },
  ],
  compose: { status: "unstarted" },        // targets defaults to "channels"
}
```

For closed-roster DM-style compose set `compose.targets: "contacts"`; for open address spaces (Gmail) use `"addresses"`. `compose.status` may be either a literal entry from `statuses[]` or a symbolic id the connector's `onCreateLink` resolves itself (Linear's per-team workflow-state UUIDs resolve from the category `"unstarted"`).

Then implement `onCreateLink` — return the link, do NOT call `integrations.saveLink()` (platform wires it to the originating thread):

```typescript
async onCreateLink(draft: CreateLinkDraft): Promise<CreateLinkResult | null> {
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

`CreateLinkDraft`: `channelId`, `type`, `status` (`null` for status-less link types), `title`, `noteContent`, `contacts: Actor[]`, plus — for `compose.targets: "contacts"`/`"addresses"` — `recipients?: ResolvedRecipient[]` (contacts pre-resolved to platform account IDs with their thread `role`) and `inviteEmails?: string[]` (free-form typed addresses). See `twister/src/connector.ts`.

Resolve category statuses (`"unstarted"`, etc.) to the provider's state id yourself — the draft's status is whatever the picker showed.

The returned link is written with `updated_by` set to the twist, so subsequent syncs of the same id won't re-fire `onCreateLink`/`onLinkUpdated` for the initial state.

## Authorship (REQUIRED)

**Every link and every note you save carries an `author`. If you omit it, the item is attributed to the connector itself** — the thread and its notes surface as authored by the integration's name ("Trello", "Slack", "Attio") instead of the real person. This is silent (no error, no warning in prod) and is the single most common connector attribution bug, precisely because omission is the failure mode. A connector is a conduit for other people's content; it is almost never the author.

Set the real external author in **three places**:

1. **The link** (`NewLinkWithNotes.author`) → the thread's author. Use the item's creator (issue/card creator, document owner, meeting owner) or, for a conversation, the first message's sender.
2. **The primary / description note** (the body note, `key: "description"` or equivalent) → the same author as the link. This is the note that's most often forgotten — the link author gets set but the description note falls through to the connector.
3. **Every comment / message / activity note** → that note's own author, resolved per-item.

```typescript
const author = creatorToContact(item.creator); // NewContact from the API's creator/sender
const link: NewLinkWithNotes = {
  author,                                       // 1. thread author
  notes: [
    { key: "description", content: item.body, author },        // 2. primary note
    ...comments.map((c) => ({                                  // 3. per-comment author
      key: `comment-${c.id}`, content: c.body, author: commentToContact(c.author),
    })),
  ],
};
```

Rules:

- **Actually fetch the author.** Several connectors were attributed to themselves only because the creator/sender field was never requested from the API (e.g. asking Trello for `actions=commentCard` but not `createCard`, so the card creator is never obtained). If your list/get call doesn't return a creator, add the field or a follow-up fetch.
- **Owner-sent messages → `note.authoredBySelf = true`.** For the connection owner's own messages (a reply you sent), many providers send an empty sender id and omit you from 1:1 rosters, so `author` can't identify you. Set `authoredBySelf: true` instead — the runtime credits your own contact deterministically. (See `slack/`, `libs/unipile`.)
- **Genuinely authorless items → `author: null`.** System-generated records with no human author (e.g. an analytics event, a "This event was cancelled." system note) should pass an explicit `null`. That documents the intent and suppresses the development-time "missing author" warning `integrations.saveLink()` logs when both a link and its primary note lack an author.
- **The author is the *creator*, not the *subject*.** For a CRM record about a person, the author is whoever created the record, not the person the record describes. Don't set the subject as the author.

Reference implementations that get this right: `linear/` (link + description + comment notes), `google-drive/` (file owner + per-comment/reply authors), `github/`, `jira/`, `apple-calendar/` (organizer), `google/src/mail` (thread author = originating sender).

> **Twists** are different: an item a twist creates is authored by the twist, so twists may leave `author` unset. This rule is about **connectors**, which relay content authored by real people.

## Contacts

Contacts are created implicitly when you save threads/links — no `addContacts()` call, no `ContactAccess.Write`.

```typescript
const author: NewContact | undefined = creator
  ? {
      ...(creator.email ? { email: creator.email } : {}),
      name: creator.name ?? "",
      avatar: creator.avatarUrl ?? undefined,
      source: { accountId: creator.id }, // platform identity, resolves without email
    }
  : undefined;

const link: NewLinkWithNotes = {
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
cd connectors/<name> && pnpm build
cd connectors/<name> && pnpm exec tsc --noEmit
pnpm install  # from repo root
```

Add to `pnpm-workspace.yaml` if not already covered by a glob.

## Checklist

- [ ] Extend `Connector<YourConnector>`; declare `readonly provider`, `readonly scopes`, `readonly linkTypes`
- [ ] `build()` declares Integrations and Network (plus GoogleContacts/Files if applicable) — `callbacks`/`store`/`tasks` are built-in
- [ ] Set `handleReplies = true` only if bidirectional
- [ ] For bidirectional note sync: `onNoteCreated` / `onNoteUpdated` return `NoteWriteBackResult` with `externalContent` matching what sync-in will emit for this note — no `Promise<string | void>` in new connectors
- [ ] For bidirectional note sync: implement `onNoteUpdated` if the external supports editing (document the gap if it doesn't)
- [ ] `onChannelEnabled` uses `runTask()` (NOT `run()`) for webhook setup and initial sync — blocks HTTP response otherwise
- [ ] `onChannelEnabled` is idempotent (overwrites state) — it re-fires on auto-enable and recovery (`context.recovering`)
- [ ] Call `integrations.channelSyncCompleted(channelId)` exactly once when the initial backfill finishes
- [ ] Never pass functions, RPC stubs, or `undefined` to `this.callback()` — use `null`
- [ ] Validate stored callback tokens exist before `this.run()`
- [ ] Localhost guard in webhook setup; verify webhook signatures
- [ ] Webhook handlers never enqueue an unkeyed task per notification — use `this.scheduleDrain(key, this.handler, { ids })` (or process the payload inline when it's self-contained); `cancelDrain(key)` on teardown
- [ ] Batch state writes use `this.setMany()`, never a per-item `set()` loop
- [ ] Canonical, globally-unique `source` using immutable ids; mutable keys in `meta` only
- [ ] `note.key` for note-level upserts
- [ ] Set `link.channelId` (top-level field, required) and inject `syncProvider` into `link.meta`
- [ ] `contentType: "html"` for HTML — never strip tags locally
- [ ] `created` on notes = external timestamp, not sync time
- [ ] `initialSync` propagated through every entry point and batch; set `unread: false, archived: false` on initial, omit on incremental
- [ ] Create `NewContact` for authors/assignees
- [ ] Set `author` on the LINK, its PRIMARY/description note, and every comment/message note (see "Authorship") — omitting it attributes the item to the connector. Use `authoredBySelf` for owner-sent messages; `author: null` only for genuinely authorless/system items
- [ ] Clean up callbacks, webhooks, stored state in `stopSync()` and `onChannelDisabled()`
- [ ] Recurring/self-renewing tasks (watch renewals, polling, periodic syncs, self-heal) use `this.scheduleRecurring(key, …)` — NOT `scheduleTask` or `runTask({ runAt })` + manual token bookkeeping — and `cancelScheduledTask(key)` on teardown
- [ ] For Plot-initiated creation: add a `compose` block to the `LinkTypeConfig` AND implement `onCreateLink` — don't call `saveLink` from inside it
- [ ] `pnpm build` succeeds

## Common pitfalls

1. Passing functions/`undefined`/RPC stubs to `this.callback()` → use tokens + `null`.
2. Setting `channelId` only inside `link.meta` instead of at the top level → `NewLinkWithNotes.channelId` is what the platform actually persists and reads back for connector callbacks (`thread.meta.channelId` in `onNoteCreated`, etc.) and for bulk operations like `integrations.archiveLinks({ channelId })` on disable. A `meta`-only channelId compiles fine structurally but leaves outbound replies (and disable-time cleanup) silently broken — no error, nothing captured. The type system now requires the top-level field on `NewLinkWithNotes`, so this fails to compile instead of failing silently in production.
3. Not propagating `initialSync` through the whole pipeline → notification spam.
4. Mutable ids in `source` (e.g. Jira issue key) → use immutable id, store key in `meta`.
5. `source` that's only unique within one user's account → breaks cross-user dedup; add workspace/tenant/mailbox qualifier.
6. Not breaking long loops into batches → each execution has ~1000 request limit.
7. Missing localhost guard → webhook registration fails silently.
8. Calling `plot.createThread()` from a connector → use `integrations.saveLink()`.
9. Breaking callback signatures → add optional params at end only; use `upgrade()` for breaking migrations.
10. Not cleaning up on disable → orphan callbacks, webhooks, state.
11. Two-way sync without metadata correlation → embed Plot id in external metadata to prevent race-condition duplicates (see SYNC_STRATEGIES.md §6).
12. Stripping HTML locally → breaks encoding + loses links; use `contentType: "html"`.
13. Placeholder titles in comment/update webhooks → `title` overwrites on upsert; fetch the real title if webhook doesn't carry it.
14. Omitting `created` on notes → everything appears "just now"; pass external timestamp.
15. `this.run()` in `onChannelEnabled` → blocks HTTP response until full sync completes; always `runTask()`.
16. Calling `integrations.saveLink()` inside `onCreateLink` → duplicate thread; just return the link.
17. Implementing `onCreateLink` without a `compose` block on the `LinkTypeConfig` → "Create new X" entry never appears.
18. Returning a bare `string` (key only) from `onNoteCreated` when the external stores content lossily (plain-text comments APIs, ADF, sanitised HTML) → next sync-in clobbers Plot's content with the round-tripped form (e.g. `1.` → `1\.`). Return a `NoteWriteBackResult` with `externalContent` matching sync-in's shape instead.
19. Returning `externalContent` that doesn't match what sync-in emits for the same note (e.g. post-write raw HTML when sync-in extracts plain text; pre-translation mentions when sync-in translates them) → baseline hash always mismatches and every sync clobbers. Inspect the sync-in `build*Note` path and return exactly what it produces.
20. Calling `integrations.saveLink()` inside `onNoteCreated` to set the note's `key` → legacy workaround, no longer needed. The runtime sets `key` automatically from the `NoteWriteBackResult` return.
21. Scheduling a recurring/self-renewing task with `scheduleTask` or `runTask({ runAt })` + manual token bookkeeping → `scheduleTask` is one-shot (the task fires once and is gone; a self-rescheduling callback leaks a new parallel chain on every redundant setup call). Use `this.scheduleRecurring(key, …)` — the durable recurring primitive where the platform owns the cadence and re-arms the task every `intervalMs`. The callback does NOT need to reschedule itself; re-scheduling under the same key with a new `firstRunAt` is safe and atomic (tightens the next fire without leaking a second chain).
22. `runTask()` per webhook notification → a notification burst floods the queue with duplicate sync passes that stack into one worker's memory. Use `this.scheduleDrain(key, this.handler, { ids })` — the platform coalesces bursts, bounds each pass, and owns the dirty-set bookkeeping (see "Webhook-driven sync uses `scheduleDrain`" above). Similarly, looping `this.set()` for per-item batch state → use `this.setMany()` (one round-trip, atomic).
23. Omitting `author` on a synced link or note → the item is silently attributed to the connector, so the thread surfaces as authored by the integration's name instead of the real person (see "Authorship (REQUIRED)"). The trap is that it's an omission, not a wrong value — the link author often gets set while the description note is forgotten, or the creator field was never fetched from the API at all. Set `author` on the link + primary note + every comment note; `authoredBySelf` for owner-sent; `author: null` only when genuinely authorless.

## Examples

Every directory under `connectors/` is a deployable connector. Shared code that isn't a connection
in its own right lives in `../libs/` — currently `@plotday/google-contacts` (contact enrichment
under a shared Google auth) and `@plotday/email-classifier`.

**Composite connectors** (`google/`, `outlook/`) offer several products under one OAuth grant. Each
product's sync lives in its own subdirectory of the connector's `src/` — `google/src/{mail,calendar,tasks}`,
`outlook/src/{mail,calendar}` — and is wired in through a per-product "host" adapter that namespaces
the product's storage keys and scheduling. Those subdirectories are the right place to look for the
per-product patterns below and to make product-specific fixes; they are modules of their connector,
not connectors themselves, so don't scaffold a new one from them.

| Connector | Category | Key patterns |
|---|---|---|
| `linear/` | ProjectConnector | Canonical reference; webhooks; bidirectional |
| `google/` | CompositeConnector | Deployed "Gmail & Calendar"; single OAuth wiring mail, calendar, tasks and contacts via a host-adapter pattern |
| `google/src/mail/` | Messaging product | PubSub webhooks; HTML contentType; callback-arg `initialSync` |
| `google/src/calendar/` | Calendar product | Recurring events; RSVP write-back; watch renewal |
| `outlook/` | CompositeConnector | Deployed "Outlook"; single OAuth wiring mail and calendar via a host-adapter pattern |
| `outlook/src/mail/` | Messaging product | Microsoft Graph; folder-based channels; delta-query self-heal |
| `outlook/src/calendar/` | Calendar product | Microsoft Graph; subscription management |
| `slack/` | MessagingConnector | Team-sharded webhooks; thread model |
| `google-drive/` | DocumentConnector | Document comments; reply threading; file watching; canonical `NoteWriteBackResult` + `onNoteUpdated` example |
| `jira/` | ProjectConnector | Immutable vs mutable ids; comment metadata dedup |
| `asana/` | ProjectConnector | HMAC webhook verification; section-based projects |
| `../libs/google-contacts/` | Supporting library | Contact sync; shared Google auth consumed by connectors via `MergeScopes` |
