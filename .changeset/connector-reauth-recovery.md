---
"@plotday/twister": minor
---

Changed: connector re-auth recovery is now automatic. When a user re-authorizes a previously-broken connection (one with `needs_reauth_at` set), the framework dispatches `onChannelEnabled` for every channel that was already enabled, with a new `SyncContext.recovering = true` flag. Connectors should treat the same dispatch as initial-enable (overwrite stored state) but additionally drop persisted incremental cursors / sync tokens so the next pass re-walks history and picks up changes that occurred during the auth gap.

Removed: `Integrations.setInitialSyncing(channelId, syncing)`. The framework now auto-stamps the connection's `initial_sync_started_at` whenever it dispatches `onChannelEnabled` (initial enable, auto-enable, or recovery). Connectors call the new `Integrations.channelSyncCompleted(channelId)` once when initial backfill finishes. If `onChannelEnabled` throws an unhandled exception, the framework auto-clears the syncing state so the UI doesn't get stuck on "syncing" forever.
