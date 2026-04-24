# Sync new channels — design

## Goal

For multi-channel connectors, let users opt in to "auto-enable any new channels we discover."
When the toggle is on:

1. The connector's discovered channel list is refreshed periodically.
2. Any channel that appears for the first time is enabled automatically (no user action).

Default is **off** — a future change will let connectors set the default.

## UX

In the connector edit modal (`apps/plot/lib/widget/setup_source.dart`), at the end of the
channel list (one entry per provider+account, excluding `singleChannel` connectors), show a
toggle row:

- **Title:** "Sync new channels"
- **Description:** "When a new channel is added, enable it automatically."
- **Default:** off

Toggling the switch immediately persists via API call. No batching; this is a per-connection
preference, not part of the per-channel batch.

## Storage

Per-connection setting lives in the `Integrations` Durable Object KV store (same place as
`enabled_scope_groups`):

```
auto_enable_new_channels:${provider}:${actorId}  →  boolean
```

`twist_instance_connection` is the canonical (twist_instance_id, user_id, provider, actor_id)
list; the DO already keys by twist_instance_id, so the KV namespace is naturally scoped.

## API

### GET `/twist/:id/integrations`

Add `autoEnableNewChannels: boolean` to each entry in the `accounts` array.

### POST `/twist/:id/syncables/:provider/auto-enable`

Body: `{ "actorId": "...", "enabled": true | false }`

Sets the per-connection KV flag. Returns 204 on success.

## `Integrations.setChannels` change

`setChannels(provider, actorId, channels)` is the choke point for "list of channels we know
about." Modify it to:

1. Read existing channel IDs for this twist_instance from `public.channel`.
2. Mirror the new list to KV + DB as today (new rows land with `enabled=false`).
3. If `auto_enable_new_channels:${provider}:${actorId}` is true, diff: any channel ID in the
   input that wasn't in the pre-mirror set is "new."
4. For each new channel, run the same logic `enableSync` runs (write `channel_config:` KV,
   update `public.channel` row to `enabled=true`, fire `onChannelEnabled` callback).
5. Return `{ __dispatch: [...] }` aggregating all `onChannelEnabled` callbacks so the
   entrypoint fires them after this method returns.

This works for both the user-triggered refresh path and the periodic cron path because both
go through `setChannels`.

### Helper extraction

`enableSync` already does steps 1, 2, and dispatch-construction. Extract a private helper
`buildEnableSyncDispatchEntry(provider, actorId, channelObj)` returning the
`onChannelEnabled` dispatch entry. Use it from both `enableSync` and the new branch in
`setChannels`.

## Periodic refresh (cron)

The API worker already runs cron every 5 minutes (`workers/api/wrangler.jsonc`) and dispatches
in `workers/api/src/index.ts:scheduled()`. Add a step:

- **Cadence:** once per day, gated to a single 5-minute window (e.g. `getUTCHours() === 5 &&
  getUTCMinutes() < 5`) — reuses the same gating pattern as the daily twist stats sweep.
- **Scope:** every row in `twist_instance_connection` whose `twist_instance` is non-archived,
  non-suspended, and `draft = false`.
- **Action:** for each row, invoke `Integrations.refreshChannels(provider, actorId)` via the
  twist runtime. `refreshChannels` already builds and dispatches the `getChannels →
  setChannels` chain via `buildRefreshDispatch`. The new logic in `setChannels` handles the
  auto-enable.
- **Error handling:** wrap each row in try/catch — log + continue. Don't let one bad token
  block the rest. `captureException` for unexpected errors only (token expiry is expected).

### Side benefit

This also fixes a long-standing UX gap: today, newly-created Airtable bases / Slack channels /
Linear projects don't appear in the user's edit modal until they manually re-auth or hit
refresh. After this, they show up daily without user action.

## Flutter

`apps/plot/lib/widget/setup_source.dart`:

- For each provider+account group, after the channel rows, render a `_AutoEnableNewChannelsRow`.
- Skip when `data.singleChannel` is true.
- Wire to a new `TwistApi.setAutoEnableNewChannels({ twistInstanceId, provider, actorId,
  enabled })` method.
- Seed the toggle's local state from the new `account.autoEnableNewChannels` field exposed
  by the API.
- Optimistic UI: flip locally on tap, fire-and-await the API, revert + toast on failure.

## Out of scope

- Letting the connector set a different default (spec note: separate change).
- Soft-deleting channels that disappear from `getChannels` (current behavior is intentional).
- Auto-disabling channels that were once auto-enabled but are no longer in the list.
