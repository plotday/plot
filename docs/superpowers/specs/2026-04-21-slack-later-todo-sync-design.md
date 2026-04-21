# Slack "Later" ⇄ Plot To-Do Sync

## Goal

Give the Slack connector the same two-way star/to-do sync that the Gmail
connector has. A user who marks a Slack message "Later" gets a to-do on the
corresponding Plot thread; a user who marks a Plot thread as a to-do (via the
Star tag / to-do toggle) gets the corresponding Slack message saved for later.

This preserves the user's mental model across Plot's messaging connectors:
the Plot "to-do" state is the canonical signal, and the connector keeps the
external system's "saved for later" flag in step.

## Context

Slack's "Later" list is exposed via the `stars.*` Web API methods. The name
"stars" is legacy; Slack's product surface has rebranded the feature as
"Later / Saved for later", but the API name has not changed.

- `stars.list` — list the current user's saved items (paginated)
- `stars.add` — save a message (per-message, not per-thread)
- `stars.remove` — unsave a message
- Events API: `star_added`, `star_removed`

All three require **user scopes** (`stars:read`, `stars:write`), not bot
scopes. Plot's OAuth provider already captures `authed_user.access_token`
(the `xoxp-` user token) alongside the bot token — see
`workers/api/src/provider.ts:19` — so this is a scopes-only change, not a
new auth flow.

The existing Slack connector is a close analogue of the Gmail connector in
layout: per-channel enable, initial history backfill, incremental sync via
webhooks, and bidirectional reply sync (`onNoteCreated`). The Gmail
star-↔-to-do flow lives in `public/connectors/gmail/src/gmail.ts` and we
reuse its echo-suppression pattern in full.

## Design

### 1. OAuth scopes & Slack app config

Add two user scopes to `Slack.SCOPES`:

```ts
"stars:read",
"stars:write",
```

(Keep all existing bot scopes; both sets can be requested in the same OAuth
call.)

Add two event subscriptions to the Plot Slack app manifest so that webhooks
deliver them to `onSlackWebhook`:

- `star_added`
- `star_removed`

**Re-auth**: existing Slack connections won't have the new scopes. The
integrations tool already re-prompts when a connector's declared scopes
widen, so no migration code is required. Call out the one-time re-auth in
`docs/updates.md` on release.

### 2. Link-type status config

Extend the single link type in `slack.ts` so Plot knows about the "Later"
status and renders it as a to-do with the Star tag:

```ts
readonly linkTypes = [{
  type: "message",
  label: "Message",
  logo: "...",      // unchanged
  logoMono: "...",  // unchanged
  statuses: [
    { status: "inbox", label: "Inbox" },
    { status: "later", label: "Later", tag: Tag.Star, todo: true },
  ],
}];
```

This parallels Gmail's `starred` status. The `todo: true` flag is what wires
the status to Plot's to-do UI.

### 3. Token selection

Today `SlackApi` wraps a single token and `getApi(channelId)` returns an
instance initialised from `this.tools.integrations.get(channelId)` (the bot
token).

The new `stars.*` calls require the user token. Add a parallel accessor:

```ts
private async getUserApi(channelId: string): Promise<SlackApi> { ... }
```

that reads `authed_user.access_token` from the stored provider data for the
connection. The exact Integrations-tool surface for this is determined in
the implementation plan; options are:

- expose a `getUserToken(channelId)` method on the `Integrations` tool and
  consume it here, or
- extend the token returned by `integrations.get()` with an optional
  `userToken` field.

Either way, `getApi()` (bot token) remains for history sync and
`chat.postMessage`, and `getUserApi()` (user token) is used only for `stars.*`
calls and any other user-scoped endpoints we add later.

### 4. State keys

Mirror Gmail's echo-suppression, keyed on `${channelId}:${threadTs}` because
Slack message timestamps are only unique within a channel:

| Key | Purpose |
|---|---|
| `auth_actor_id` | Set in a new `activate()` override, matches Gmail's pattern; needed to call `setThreadToDo()` |
| `starred:${channelId}:${threadTs}` | Current known star state for the thread parent |
| `skip_todo_writeback:${channelId}:${threadTs}` | One-shot flag set before a Plot→Slack write, consumed (and cleared) by the webhook echo |

### 5. Sync flow

#### 5a. Slack → Plot (incoming star)

1. A `star_added` or `star_removed` event arrives at `onSlackWebhook`.
2. Event payload carries `item.type`, `item.channel`, `item.message.ts`, and
   `item.message.thread_ts?`. We only handle `item.type === "message"`; stars
   on files, channels, etc. are ignored.
3. Resolve the thread parent ts: `threadTs = message.thread_ts ?? message.ts`.
   **Stars on replies count as a star on the parent thread.** This is
   simpler than per-message to-do state and matches "save this conversation
   for later" as a mental model.
4. Gate on `sync_enabled_${channel.id}`. If the stared message is in a
   non-enabled channel, ignore it. (Out of scope for v1: creating brand-new
   Plot threads from stars in channels the user hasn't enabled in Plot.)
5. Look up `starred:${channelId}:${threadTs}`. If the stored state already
   matches the incoming state, return — this is our own echo.
6. Compute the canonical URL the connector uses for this thread
   (`https://slack.com/app_redirect?channel=...&message_ts=...`, already
   emitted by `transformSlackThread`). Read the stored `actorId` from
   `auth_actor_id` (set in `activate()`). Call
   `this.tools.integrations.setThreadToDo(canonicalUrl, actorId, isStarred)`.
7. Set `skip_todo_writeback:${channelId}:${threadTs}` to `true` so the
   `onThreadToDo` callback that Plot will queue as a result of step 6
   short-circuits instead of round-tripping back to Slack.
8. Update `starred:${channelId}:${threadTs}` to the new state.

Ordering matters: `setThreadToDo` queues `onThreadToDo` as a later
callback rather than invoking it synchronously, so setting
`skip_todo_writeback` after the call is correct. Steps 5–8 mirror
`gmail.ts:484-504` line-for-line.

#### 5b. Plot → Slack (outgoing to-do)

Add two handlers that mirror `Gmail.onThreadToDo` and `Gmail.onLinkUpdated`:

```ts
async onThreadToDo(thread: Thread, _actor: Actor, todo: boolean): Promise<void>
async onLinkUpdated(link: Link): Promise<void>
```

Both:

1. Extract `channelId` and `threadTs` from `thread.meta` / `link.meta`.
2. If `skip_todo_writeback:${channelId}:${threadTs}` is set, clear it and
   return (this change originated from a Slack webhook).
3. Update `starred:${channelId}:${threadTs}` to the intended state **before**
   calling the Slack API, so the `star_added`/`star_removed` echo that
   Slack will send us sees equal state and short-circuits at step 5 above.
4. Call `stars.add` (todo=true) or `stars.remove` (todo=false) on the thread
   parent via the user-token `SlackApi`.

`onLinkUpdated` keys on `link.status === "later"` — anything else is treated
as unstarred.

#### 5c. Initial backfill on channel enable

Inside `onChannelEnabled`, after the existing history sync callback is
queued, queue one more task callback that:

1. Calls `stars.list` with pagination.
2. Filters `items[]` to those where `item.type === "message"` and
   `item.channel === channel.id`.
3. For each, computes `threadTs` and the canonical URL, then calls
   `setThreadToDo(canonicalUrl, actorId, true)` and sets
   `starred:${channelId}:${threadTs}` to `true`.

This runs once per channel-enable via `runTask` so it doesn't block the HTTP
response. It's idempotent: the stored `starred:` state and Plot's own
to-do-set call both tolerate repetition.

### 6. `SlackApi` additions

In `slack-api.ts`, add:

```ts
async addStar(channelId: string, ts: string): Promise<void> {
  await this.call("stars.add", { channel: channelId, timestamp: ts });
}
async removeStar(channelId: string, ts: string): Promise<void> {
  await this.call("stars.remove", { channel: channelId, timestamp: ts });
}
async listStars(cursor?: string): Promise<{
  items: Array<{
    type: string;
    channel: string;
    message?: { ts: string; thread_ts?: string };
  }>;
  nextCursor?: string;
}> {
  const data = await this.call("stars.list", {
    limit: 100,
    ...(cursor ? { cursor } : {}),
  });
  return {
    items: data.items ?? [],
    nextCursor: data.response_metadata?.next_cursor,
  };
}
```

### 7. Cleanup

In `stopSync(channelId)` / `onChannelDisabled(channel)`, clear any keys
scoped to the channel: `starred:${channelId}:*` and
`skip_todo_writeback:${channelId}:*`. This prevents stale state from
re-appearing if the user disables and re-enables the same channel.

### 8. Edge cases handled

- **Star on a reply** — promoted to the thread parent. Plot→Slack writeback
  stars/unstars the parent only; reply-level stars are untouched.
- **Star in a non-enabled channel** — ignored in v1. (Future: could backfill
  as a new thread, but requires full message fetch + contact resolution.)
- **Star on a message older than `syncHistoryMin`** — `setThreadToDo`
  returns null (thread doesn't exist in Plot). We still update `starred:`
  state so we don't re-process the same event.
- **Duplicate star events** — `stars.add`/`stars.remove` are idempotent on
  Slack's side; our `starred:` check short-circuits before we'd call them
  again.
- **Bot-posted messages starred by the user** — `stars.*` works on any
  message the user can see; no special handling.
- **Bot token vs user token** — `stars.*` always uses the user token via
  `getUserApi`; history and `chat.postMessage` keep using the bot token.

### 9. What's out of scope

- Stars in channels the user hasn't enabled for Plot sync (no thread exists
  to toggle to-do on).
- Stars on non-message items (files, channels, etc.).
- Per-reply to-do state (a reply's own star isn't tracked as a separate
  to-do).
- Propagating `stars.add` from Plot to multiple message ts when a Plot
  thread's parent message is unknown — we always operate on the parent ts
  stored in `thread.meta.threadTs`.

## Files touched

- `public/connectors/slack/src/slack.ts` — scopes, `linkTypes.statuses`,
  `activate()`, `onThreadToDo`, `onLinkUpdated`, `onSlackWebhook`
  (`star_added` / `star_removed` branches), initial-backfill callback,
  cleanup in `stopSync`/`onChannelDisabled`.
- `public/connectors/slack/src/slack-api.ts` — `addStar`, `removeStar`,
  `listStars`.
- `public/twister/src/tools/integrations.ts` — (maybe) expose user-token
  accessor, depending on which option from §3 is chosen.
- Slack app manifest (config surface, out of repo) — subscribe to
  `star_added` and `star_removed`.
- `docs/updates.md` — user-facing note about Slack re-auth and the new
  "Later ⇄ to-do" behavior.
- `public/.changeset/*.md` — changeset if the Twister integrations tool
  surface changes.

## Testing

Manual verification on a development Slack workspace:

1. Connect Slack (with new scopes). Enable a test channel with a few
   existing saved-for-later messages. Verify those threads appear as
   to-dos in Plot after `onChannelEnabled` completes.
2. In Slack, save a new message for later. Verify the Plot thread flips
   to to-do within a few seconds. Unsave; verify it flips back.
3. In Plot, toggle the Star/to-do on a synced Slack thread. Verify the
   corresponding Slack message shows "Saved for later". Untoggle; verify
   Slack shows it unsaved.
4. Star a reply (not the thread parent) in Slack. Verify the parent
   thread goes to-do in Plot; unstarring the reply leaves Plot to-do
   still set if the parent is starred, clears it otherwise.
5. Rapid flip-flop in Slack — star, unstar, star within a second.
   Verify Plot converges to the correct terminal state and no duplicate
   round-trips occur (echo suppression holds).
