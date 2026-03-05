# Sync Architecture

This document describes the sync system that delivers real-time updates to Plot apps and twists.

## Overview

The sync system has two main responsibilities:

1. **App Sync**: Notify connected app clients when data they can access has changed, and provide REST endpoints for pulling and pushing entity data
2. **Twist Sync**: Notify twists when data in their scope has changed so they can process it

Both use a tracking-table approach where lightweight database triggers record pending updates in `user_sync` and `priority_twist_sync` tables. API handlers trigger notification Durable Objects after processing writes, which debounce and deliver those updates efficiently.

App clients use a REST API (`GET /sync/{entity}` for pull, `POST /sync/{entity}` for push) with WebSocket notifications to know when to pull.

## Architecture

```
App Client ←→ REST API (/sync/{entity}) ←→ PostgreSQL
                  │
                  │ notifySync(priorityId)
                  ▼
            SyncNotify DO (per priority, 100ms batch)
                  │
          ┌───────┴───────┐
          ▼               ▼
    UserSync DO     TwistSync DO
    (per user)      (per priority_twist)
          │               │
          ▼               ▼
    Broadcast DO    UPDATES_QUEUE
    (WebSocket)     (→ Twists)
          │
          ▼
    App Client
```

For user-only entities (`thread_read`, `user_settings`), the API calls `notifyUserSync(userId)` directly, bypassing SyncNotify:

```
REST API → notifyUserSync(userId) → UserSync DO → Broadcast DO → App Client
```

## Database Tables

### user_sync

Tracks pending sync updates for app clients.

```sql
CREATE TABLE user_sync (
  user_id uuid NOT NULL REFERENCES public."user"(id) ON DELETE CASCADE,
  entity text NOT NULL,
  last_update_at timestamptz NOT NULL,
  last_sync_at timestamptz NOT NULL DEFAULT '1970-01-01'::timestamptz,
  PRIMARY KEY (user_id, entity)
);
```

**Columns:**

- `user_id`: The user who needs to receive this sync update
- `entity`: The entity type that changed (see Entity Types below)
- `last_update_at`: Timestamp of the most recent change affecting this entity
- `last_sync_at`: Timestamp of the most recent change that was delivered to the client

### priority_twist_sync

Tracks pending sync updates for twist processing.

```sql
CREATE TABLE priority_twist_sync (
  priority_twist_id uuid NOT NULL REFERENCES priority_twist(id) ON DELETE CASCADE,
  entity text NOT NULL,
  last_update_at timestamptz NOT NULL,
  last_sync_at timestamptz NOT NULL DEFAULT '1970-01-01'::timestamptz,
  PRIMARY KEY (priority_twist_id, entity)
);
```

**Columns:**

- `priority_twist_id`: The priority_twist instance that needs to process this update
- `entity`: The entity type that changed
- `last_update_at`: Timestamp of the most recent change
- `last_sync_at`: Timestamp of the most recent change that was queued for processing

### Twist Sync Database Views

These views pre-filter and enrich data for twist sync queries. Each view includes all necessary JOINed fields (author_name, tags, priority info, etc.) so the TwistSync DO can query them directly without additional transformations.

| View                                   | Purpose                                                            |
| -------------------------------------- | ------------------------------------------------------------------ |
| `priority_twist_thread_update`         | Threads created by the twist that have been updated                |
| `priority_twist_note_create`           | New notes on threads the twist created or was mentioned in         |
| `priority_twist_note_update`           | Notes created by the twist that have been updated                  |
| `priority_twist_channel_link_create`   | New links on threads matching channel source criteria              |
| `priority_twist_channel_link_update`   | Updated links on channel-linked threads                            |
| `priority_twist_channel_note_create`   | Notes on threads linked via channels                               |
| `priority_twist_thread_read`           | Read status changes on threads the twist created                   |
| `priority_twist_thread_schedule`       | Schedule changes on threads the twist created                      |
| `priority_twist_thread_tag_change`     | Tag additions/removals on threads the twist created                |

Each view:
- Filters by `priority_twist_id` parameter
- Compares entity `updated_at` against `priority_twist_sync.last_sync_at`
- Excludes entities where `updated_by` equals the twist (prevents self-triggering)
- Excludes draft notes (only syncs published content)
- Includes enriched fields from JOINs (author info, priority info, etc.)

## Entity Types

### User Sync Entities

Entities tracked in `user_sync` for app client notifications:

| Entity             | Description                                     | Source Tables                        |
| ------------------ | ----------------------------------------------- | ------------------------------------ |
| `thread`           | Tasks, events, and other thread items           | `thread`, `thread_tag`               |
| `note`             | Notes attached to threads                       | `note`, `note_tag`                   |
| `priority`         | Priorities (projects/folders)                   | `priority`, `priority_user`          |
| `session`          | User focus sessions                             | `session`                            |
| `priority_twist`   | Twist instances on priorities                   | `priority_twist`                     |
| `thread_read`      | Read status for threads                         | `thread_read`                        |
| `actor`            | Combined view of contacts and twists            | `priority_contact`, `contact`        |
| `priority_member`  | Priority membership and invitations             | `priority_contact`, `priority_user`  |
| `source_channel`   | Source channels for twist integrations          | `source_channel`                     |
| `schedule`         | Thread schedules                                | `schedule`                           |
| `user_settings`    | Per-user settings                               | `user_settings`                      |

### REST Sync Endpoints

All 17 entity types with REST sync endpoints:

| Entity               | Endpoint                  | Methods                       |
| -------------------- | ------------------------- | ----------------------------- |
| `actors`             | `/sync/actors`            | GET                           |
| `priorities`         | `/sync/priorities`        | GET, POST                     |
| `priority-actors`    | `/sync/priority-actors`   | GET                           |
| `priority-members`   | `/sync/priority-members`  | GET, POST                     |
| `priority-users`     | `/sync/priority-users`    | GET, POST                     |
| `priority-twists`    | `/sync/priority-twists`   | GET, POST                     |
| `source-channels`    | `/sync/source-channels`   | GET                           |
| `threads`            | `/sync/threads`           | GET, POST                     |
| `links`              | `/sync/links`             | GET, POST                     |
| `notes`              | `/sync/notes`             | GET, POST                     |
| `thread-tags`        | `/sync/thread-tags`       | GET, POST, POST `/update`     |
| `note-tags`          | `/sync/note-tags`         | GET, POST, POST `/update`     |
| `schedules`          | `/sync/schedules`         | GET, POST                     |
| `sessions`           | `/sync/sessions`          | GET, POST                     |
| `thread-read`        | `/sync/thread-read`       | POST, DELETE                  |
| `thread-exceptions`  | `/sync/thread-exceptions` | GET, POST                     |
| `user-settings`      | `/sync/user-settings`     | GET, POST                     |

Read-only: `actors`, `priority-actors`, `source-channels`. Write-only: `thread-read`.

## Database Triggers

### Trigger Design Principles

1. **Lightweight**: Triggers only upsert into the sync tracking tables; they do not construct payloads or call external services
2. **Batched**: Use statement-level triggers with `REFERENCING NEW TABLE AS new_table` for efficiency
3. **Filtered**: For twist sync, exclude the `updated_by` twist from notifications to prevent self-triggering
4. **No DELETE triggers**: Plot uses soft deletes (`archived_at`), so only INSERT and UPDATE triggers are needed

### User Sync Triggers

These triggers update `user_sync` to track which users need app sync updates.

| Trigger Table        | Events         | Function                          | Entity Written       |
| -------------------- | -------------- | --------------------------------- | -------------------- |
| `thread`             | INSERT, UPDATE | `sync_user_for_thread()`          | `thread`             |
| `note`               | INSERT, UPDATE | `sync_user_for_note()`            | `note`               |
| `priority`           | INSERT, UPDATE | `sync_user_for_priority()`        | `priority`           |
| `session`            | INSERT, UPDATE | `sync_user_for_session()`         | `session`            |
| `priority_twist`     | INSERT, UPDATE | `sync_user_for_priority_twist()`  | `priority_twist`     |
| `thread_read`        | INSERT, UPDATE | `sync_user_for_thread_read()`     | `thread_read`        |
| `priority_contact`   | INSERT, UPDATE | `sync_user_for_priority_contact()`| `actor` + `priority_member` |
| `thread_tag`         | INSERT, UPDATE | `sync_user_for_thread_tag()`      | `thread`             |
| `note_tag`           | INSERT, UPDATE | `sync_user_for_note_tag()`        | `note`               |
| `contact`            | INSERT, UPDATE | `sync_user_for_contact()`         | `actor`              |
| `priority_user`      | INSERT, UPDATE | `sync_user_for_priority_user()`   | `priority_member` + `priority` |
| `source_channel`     | INSERT, UPDATE | `sync_user_for_source_channel()`  | `source_channel`     |
| `schedule`           | INSERT, UPDATE | `sync_user_for_schedule()`        | `schedule`           |

### Twist Sync Triggers

These triggers update `priority_twist_sync` to track which twists need to process updates.

| Trigger Table    | Events         | Function                        |
| ---------------- | -------------- | ------------------------------- |
| `thread`         | INSERT, UPDATE | `sync_twist_for_thread()`       |
| `note`           | INSERT, UPDATE | `sync_twist_for_note()`         |
| `thread_tag`     | INSERT, UPDATE | `sync_twist_for_thread_tag()`   |
| `note_tag`       | INSERT, UPDATE | `sync_twist_for_note_tag()`     |
| `link`           | INSERT, UPDATE | `sync_twist_for_link()`         |

### Trigger Functions

#### User Sync Functions

Each function determines which users need to be notified and upserts into `user_sync`:

```sql
-- Pattern: sync_user_for_{entity}()
-- 1. Get max(updated_at) from the batch of changed rows
-- 2. Determine which users are affected
-- 3. UPSERT into user_sync with GREATEST(existing, new) timestamp
```

**User Resolution:**

- `thread`, `note`, `thread_tag`, `note_tag`: All users with access to the affected thread's priority (via `user.priority_expanded`)
- `priority`: All users with access to the priority itself
- `session`: The session owner only
- `thread_read`: The reading user only
- `priority_twist`: All users with access to the priority, plus owner directly (for source accounts with NULL priority_id)
- `priority_contact`: All users with access to the priority; also writes `priority_member` entity if `invited_by IS NOT NULL`
- `contact`: Users with access to priorities where the contact is linked via `priority_contact`
- `priority_user`: All users with access to the priority (writes both `priority_member` and `priority` entities)
- `source_channel`: Owner of the source account (`priority_twist.owner_id`)
- `schedule`: Users with access to the thread's priority, plus per-user schedule owners directly

#### Twist Sync Functions

Each function determines which twists need to process the update:

```sql
-- Pattern: sync_twist_for_{entity}()
-- 1. Get all priority_twists with access to the affected priority
-- 2. EXCLUDE the twist identified by updated_by (if it's a twist)
-- 3. For each twist, UPSERT into priority_twist_sync with max(updated_at)
```

**Twist Resolution:**

Twists are notified for events in the priority they are installed and all descendant priorities:

- **Thread UPDATE**: Only the twist that created the thread (`thread.created_by = priority_twist.id`)
- **Thread tag changes**: Only the twist that created the thread
- **Note INSERT**: Twist that created the thread OR any twist mentioned in any note on that thread
- **Note UPDATE**: Only the twist that created the note (`note.created_by = priority_twist.id`)
- **Note tag changes**: Only the twist that created the note
- **Link changes**: Twists with matching channel source criteria

Twists do not receive notifications for events they generated themselves, as identified by the `updated_by` field.

## API Notification System

### notifySync(priorityId)

Called by API handlers after processing writes that affect priority-scoped data. Fire-and-forget via `waitUntil` to avoid blocking the response.

```typescript
// workers/api/src/app/sync/notify.ts
export function notifySync(c: Context, priorityId: string) {
  c.executionCtx.waitUntil(async () => {
    const syncNotifyId = c.env.SYNC_NOTIFY.idFromName(priorityId);
    const syncNotifyDO = c.env.SYNC_NOTIFY.get(syncNotifyId);
    await syncNotifyDO.fetch(new Request("http://do/notify", {
      method: "POST",
      body: JSON.stringify({ priorityId }),
    }));
  });
}
```

### notifyUserSync(userId)

Called for user-only entities (`thread_read`, `user_settings`) that don't need priority-scoped fan-out. Directly notifies the user's UserSync DO.

```typescript
export function notifyUserSync(c: Context, userId: string) {
  c.executionCtx.waitUntil(async () => {
    const userSyncId = c.env.USER_SYNC.idFromName(userId);
    const userSyncDO = c.env.USER_SYNC.get(userSyncId);
    await userSyncDO.fetch(new Request("http://do/notify", {
      method: "POST",
      body: JSON.stringify({ id: userId }),
    }));
  });
}
```

### Helper Functions

- `getPriorityForThread(db, threadId)` — looks up `priority_id` from the `thread` table
- `getPriorityForNote(db, noteId)` — joins `note` → `thread` to get `priority_id`

## API Sync Endpoints

### GET /sync/{entity}

Pull endpoint for app clients. All GET endpoints share common query parameters:

**Query Parameters** (from `parseReadParams()`):

| Parameter        | Type    | Default      | Description                                     |
| ---------------- | ------- | ------------ | ----------------------------------------------- |
| `updated_since`  | string  | null         | ISO timestamp cursor for incremental pull        |
| `cursor_id`      | string  | null         | Secondary cursor (entity ID) for deterministic ordering |
| `archived`       | boolean | undefined    | Filter by archived state                         |
| `limit`          | number  | 200          | Max rows (capped at 1000)                        |
| `priority_id`    | string  | null         | Filter to priority and descendants               |
| `priority_path`  | string  | null         | Filter by ltree path (fallback)                  |
| `thread_id`      | string  | null         | Filter by parent thread                          |
| `range_start`    | string  | null         | Lower bound for sort column                      |
| `range_end`      | string  | null         | Upper bound for sort column                      |
| `initial`        | boolean | false        | Initial pull mode (special filtering)            |
| `id`             | string  | null         | Fetch single row by ID                           |
| `sort_by`        | string  | `updated_at` | Sort column (allowed: `created_at`, `updated_at`, `activity_at`, `agenda_at`) |
| `sort_dir`       | string  | `asc`        | Sort direction (`asc` or `desc`)                 |

**Cursor-Based Pagination:**

Uses `date_trunc('milliseconds', ...)` because JavaScript Date has only millisecond precision. Without truncation, PostgreSQL's microsecond-precision timestamps cause infinite sync loops. Pagination uses a dual cursor on `(updated_at, id)` for deterministic ordering:

```sql
-- With cursorId:
(date_trunc('milliseconds', updated_at) > :updatedSince
 OR (date_trunc('milliseconds', updated_at) = :updatedSince AND id > :cursorId))
-- Without cursorId:
date_trunc('milliseconds', updated_at) > :updatedSince
```

**Initial Pull vs Incremental Pull:**

- **Initial pull** (`initial=true`): Fetches unread, non-archived, non-draft threads. No limit applied. Used on first sync.
- **Incremental pull**: Uses `updated_since` cursor to fetch only changes since last pull. Limit applied.

When doing cursor pagination (`updated_since` is set), sort is always `updated_at ASC, id ASC` regardless of `sort_by`/`sort_dir` parameters.

### POST /sync/{entity}

Push endpoint for app clients. Upserts data via RPC functions (e.g., `upsert_thread()`, `upsert_note()`). After a successful upsert, calls `notifySync(priorityId)` to trigger real-time notifications.

Example (threads):

```typescript
threads.post("/sync/threads", async (c) => {
  const body = await c.req.json();
  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    return rpcUser(trx, "upsert_thread", {
      user_id: c.var.user.id,
      p_thread: body.thread || body,
      p_defaults: body.defaults || {},
    });
  });
  notifySync(c, threadData.priority_id);
  return c.json(result);
});
```

## Durable Objects

### SyncNotify DO

One instance per priority. Batches notifications with a 100ms window, then fans out to UserSync and TwistSync DOs.

**Configuration:**

- `BATCH_WINDOW_MS` (100ms): Deduplication window for notifications to the same priority

**Behavior:**

1. On `/notify` POST: stores `priorityId` in memory and durable storage, schedules alarm at `now + 100ms` if no alarm is already pending (natural deduplication — same priority = same DO)
2. On alarm:
   - Queries `get_users_with_priority_access(priorityId)` RPC to find all users with access
   - Fans out to each user's `UserSync` DO via `/notify` POST
   - Queries `priority_twist` table for active (non-archived) twists on the priority
   - Fans out to each twist's `TwistSync` DO via `/notify` POST
   - All fan-out calls use `Promise.allSettled` for fault isolation

### UserSync DO

One instance per user. Handles debouncing and delivery of app sync updates.

**Debouncing Parameters** (compile-time constants):

- `MIN_WAIT_MS` (100ms): Minimum time to wait before sending, allowing batching
- `MAX_WAIT_MS` (2000ms): Maximum time to wait if updates keep arriving
- `MIN_INTERVAL_MS` (500ms): Minimum gap between sync deliveries

**State:**

- `lastNotifyTime`: When the last `notify()` was received
- `lastSyncTime`: When the last sync was delivered
- `pendingAlarm`: Whether an alarm is scheduled

**Methods:**

```typescript
notify(userId: string): void
```

Called when a notification is received. Schedules an alarm based on debouncing rules: waits `MIN_WAIT_MS` for batching, or until `MIN_INTERVAL_MS` has passed since last sync.

```typescript
alarm(): void
```

Called when the alarm fires. Performs the sync:

1. **Check for connected clients**: Call `Broadcast.hasConnectedClients(userId)`. If no clients are connected, skip the sync entirely (no database queries). The client will pull full updates when it connects.

2. **Query pending updates** via `get_pending_user_sync(userId)` RPC:

   ```sql
   SELECT entity, last_update_at
   FROM user_sync
   WHERE user_id = :userId AND last_update_at > last_sync_at
   ```

3. **Send sync messages**: For each entity with pending updates, send a sync message via the Broadcast DO:

   ```typescript
   broadcast.send({ type: "sync", table: entity });
   ```

4. **Update last_sync_at** using the max `last_update_at` from query results (database timestamps, not local server time):

   ```sql
   UPDATE user_sync
   SET last_sync_at = :syncUpTo
   WHERE user_id = :userId AND entity IN (:entities)
   ```

   Entities are sorted alphabetically before update to ensure consistent lock order. Includes deadlock retry logic (3 retries with exponential backoff: 50-100ms, 100-200ms, 200-400ms, with jitter).

```typescript
onClientConnected(userId: string): void
```

Called when a WebSocket connection opens via the Broadcast DO. Calls `sync_user_on_connect()` RPC to align `last_sync_at` with `last_update_at`, ensuring incremental updates work correctly after reconnection. The app manually syncs before connecting to the WebSocket, so it already has the latest data.

### TwistSync DO

One instance per priority_twist. Handles debouncing and queuing of twist updates.

**Debouncing Parameters** (compile-time constants):

- `MIN_WAIT_MS` (100ms): Minimum time to wait before processing
- `MIN_INTERVAL_MS` (100ms): Minimum gap between queue messages
- `MAX_JITTER_MS` (2000ms): Random jitter to stagger concurrent alarms (thundering herd prevention)
- `MAX_ITEMS_PER_BATCH` (12): Maximum items per queue message
- `MAX_BATCH_BYTES` (120,000): Maximum batch size (128KB CF queue limit minus 8KB headroom)

**State:**

- `lastNotifyTime`: When the last `notify()` was received
- `lastSyncTime`: When the last update was queued
- `pendingAlarm`: Whether an alarm is scheduled

**Methods:**

```typescript
notify(priorityTwistId: string): void
```

Called when the API receives a sync notification. Schedules an alarm with random jitter (0 to 2000ms) added to the delay. This prevents thundering herd when many TwistSync DOs are notified simultaneously from a change on a shared priority.

```typescript
alarm(): void
```

Called when the alarm fires. Gathers and queues updates:

1. **Skip if archived or suspended**: Checks twist status before processing.

2. **Query pending updates** via 8 database views in parallel (`Promise.allSettled`):

   | View                                 | Content                                |
   | ------------------------------------ | -------------------------------------- |
   | `priority_twist_thread_update`       | Threads created by twist, now updated  |
   | `priority_twist_note_create`         | New notes on twist's threads/mentions  |
   | `priority_twist_note_update`         | Notes created by twist, now updated    |
   | `priority_twist_channel_link_create` | New channel links                      |
   | `priority_twist_channel_link_update` | Updated channel links                  |
   | `priority_twist_channel_note_create` | Notes on channel-linked threads        |
   | `priority_twist_thread_read`         | Read status changes                    |
   | `priority_twist_thread_schedule`     | Schedule changes                       |

   All queries limited to 100 rows, ordered by timestamp ascending. Uses `MAX(ts) OVER()::text` window function for max timestamp extraction with microsecond precision.

3. **Query tag changes** from `priority_twist_thread_tag_change` view for tag add/remove data.

4. **Build size-aware batches**: Max 12 items or 120KB per queue message.

5. **Advance sync cursors** via UPSERT with full-precision text timestamps cast to `timestamptz`.

6. **Queue the messages**:

   ```typescript
   await UPDATES_QUEUE.send({
     type: "twist_batch",
     priorityTwistId,
     twistId,
     environment,
     version,
     newNotes,
     updatedNotes,
     updatedThreads,
     threadTagChanges,
     channelLinks,
     channelNotes,
     readChanges,
     scheduleChanges,
     priorityTwist,
   });
   ```

7. **Schedule follow-up** if any query returned the maximum number of rows (indicating more items remain).

### Broadcast DO

Manages WebSocket connections for real-time updates to app clients.

**Key Methods:**

```typescript
hasConnectedClients(): boolean
```

Returns true if any WebSocket clients are connected for this user. Used by UserSync DO to skip sync when no clients are listening.

**Connection Open Hook:**

When a WebSocket connection opens, the Broadcast DO calls the UserSync DO's `onClientConnected()` method to align sync state:

```typescript
async webSocketOpen(ws: WebSocket, userId: string) {
  const userSync = env.USER_SYNC.get(env.USER_SYNC.idFromName(userId));
  await userSync.onClientConnected();
}
```

### SyncRecovery DO

One global instance that recovers missed sync notifications. Handles cases where notification DOs fail to process updates.

**Architecture:**

- **Cron trigger**: Runs every minute via scheduled event at `/sync/recovery`
- **Alarm-based execution**: Each cron trigger runs recovery immediately, then schedules 5 alarms at 10-second intervals
- **Total frequency**: 6 executions per minute (1 cron + 5 alarms)

**Configuration:**

- `STALE_THRESHOLD_MS` (30,000ms): How long to wait before considering a sync "stale"
- `ALARM_INTERVAL_MS` (10,000ms): Time between alarm executions
- `MAX_ALARMS_PER_CRON` (5): Number of alarms to schedule after each cron trigger
- `MAX_ITEMS_PER_QUERY` (50): Maximum users/twists to recover per execution

**Stale Detection:**

```sql
-- User syncs
SELECT DISTINCT user_id FROM user_sync
WHERE last_update_at > last_sync_at AND last_sync_at < :staleThreshold
LIMIT 50

-- Twist syncs
SELECT DISTINCT priority_twist_id FROM priority_twist_sync
WHERE last_update_at > last_sync_at AND last_sync_at < :staleThreshold
LIMIT 50
```

**Recovery Process:**

1. Query for stale user syncs using `get_stale_user_syncs()` RPC
2. For each stale user, call `UserSync.notify()` via DO fetch (parallelized with `Promise.allSettled`)
3. Query for stale twist syncs using `get_stale_twist_syncs()` RPC
4. For each stale twist, call `TwistSync.notify()` via DO fetch (parallelized with `Promise.allSettled`)
5. Schedule next alarm if under the limit

## App Sync Protocol

### SyncOrchestrator

The `SyncOrchestrator` (`apps/plot/lib/store/sync_orchestrator.dart`) manages client-side sync with dependency awareness. It uses Kahn's algorithm for topological sorting to determine execution order.

**Entity Definitions:**

11 entities with their dependencies:

| Entity           | Dependencies                          | Push | Pull |
| ---------------- | ------------------------------------- | ---- | ---- |
| `actor`          | (none)                                | skip | yes  |
| `userSettings`   | (none)                                | yes  | yes  |
| `priority`       | actor                                 | yes  | yes  |
| `priorityUser`   | priority, actor                       | yes  | yes  |
| `priorityMember` | priority, actor, priorityUser         | yes  | yes  |
| `priorityActor`  | priority, actor                       | skip | yes  |
| `priorityTwist`  | priority                              | yes  | yes  |
| `sourceChannel`  | priorityTwist                         | skip | yes  |
| `thread`         | priority, actor                       | yes  | yes  |
| `session`        | priority                              | yes  | yes  |
| `note`           | thread, actor                         | yes  | yes  |

Read-only entities (push = skip): `actor`, `priorityActor`, `sourceChannel`.

**Sync Flow (`syncAll()`):**

1. **Pull phase** (parents → children): Entities are grouped into levels via topological sort. Each level executes in parallel. Dependencies are guaranteed to be in earlier levels.
2. **Push phase** (parents → children): Same ordering as pull — parents must exist before children can reference them.

**In-flight Deduplication:**

Uses `Completer<T>` maps (`_pushCompleters`, `_pullCompleters`) to prevent concurrent sync of the same entity. If an entity is already being synced, subsequent requests wait on the existing completer.

**Entity Resolution by Table Name:**

`getEntityByTableName()` maps both local Drift table names (e.g., `user_thread`) and broadcast entity names (e.g., `thread`) to `SyncEntity` instances. This allows the same handler to process both local saves and WebSocket sync notifications.

### Pull Flow

**Initial Pull:**

On first sync (or after sign-in), the client pulls each entity with `initial=true`. For threads, this fetches only unread, non-archived, non-draft items (no limit). Other entities pull all rows.

**Incremental Pull:**

After initial sync, the client stores the `updated_at` cursor from the last row received. Subsequent pulls pass `updated_since` to fetch only changes. The dual cursor `(updated_at, cursor_id)` ensures deterministic ordering even when multiple rows share the same timestamp.

**Lazy-Loaded Notes:**

Thread sync (`Thread.pull()`) handles threads, links, schedules, and thread tags together. Notes are synced separately and can be pulled per-thread for lazy loading.

### Push Flow

When the user modifies data locally:

1. Changes are saved to the local SQLite database immediately
2. The entity is marked as pending push
3. `SyncOrchestrator.push(entity)` is called, which ensures dependencies are pushed first
4. The push endpoint (`POST /sync/{entity}`) upserts the data
5. On success, the pending flag is cleared

### WebSocket Connection

The `BroadcastClient` (`apps/plot/lib/api/broadcast.dart`) maintains a WebSocket connection for real-time sync notifications.

**Connection URL:** `wss://{apiRoot}/updates/{userId}`

**Protocols:** `['plot-v1', sessionToken]`

**Query Parameters:** `clientId`, `clientVersion`, `clientPlatform`

**Keepalive:** Sends `ping` every 30 seconds, expects `pong` responses.

**Reconnection:**

- Exponential backoff: 1s base, 30s max, with 0-1000ms random jitter
- Resets backoff on connectivity change (offline → online) or app resume
- No maximum retry count — reconnects indefinitely
- Connectivity-aware: only attempts connection when network is available

**Offline Indicator:**

- Connection state is debounced for UI: shows "offline" only after 10 seconds of sustained disconnection
- Returns to "online" immediately on reconnection

**Auth Error Handling:**

- Detects 401/unauthorized errors and custom close codes (4401, 1008)
- Schedules reconnect to retry with fresh token (Clerk handles token refresh)

### Error Handling

**Expected Errors (not reported to PostHog):**

- Network errors (expected during offline periods)
- Auth errors (handled by automatic sign-out flow)

**Unexpected Errors (reported to PostHog):**

- API errors, RLS violations, unknown exceptions

## Queue Processing

The UPDATES_QUEUE receives batched twist updates from TwistSync DOs.

**Processing:**

1. Load the twist via the factory
2. For each new note (notes created on threads this twist created or was mentioned in):
   - Read `sync_depth` from the note (null means not from a sync chain)
   - If `sync_depth > 4`, skip and log warning
   - Otherwise, dispatch to Plot tool with `itemType: "note"` for note.created callback
3. For each updated note (notes this twist created):
   - Same sync_depth handling
   - Dispatch to Plot tool for note.updated callback
4. For each updated thread (threads this twist created):
   - Same sync_depth handling
   - Build `tagsAdded`/`tagsRemoved` from tag changes for this thread
   - Dispatch to Plot tool with changes object for thread.updated callback
5. If priority_twist changed, dispatch to Plot tool for config callback
6. All items are processed in a single twist instance (efficient)

## sync_depth

The `sync_depth` field prevents infinite loops when twists trigger updates that trigger other twists.

**How it works:**

1. **Initial updates** (from app, webhooks, timers): `sync_depth = null`

2. **When a twist processes an entity**:

   - The entity's current `sync_depth` is read (null treated as 0)
   - This value is stored in the twist's execution context

3. **When a twist writes entities via the Plot tool**:

   - The Plot tool reads the stored `sync_depth` from context
   - It increments it: `new_depth = (stored_depth ?? 0) + 1`
   - All entities written by this twist get `sync_depth = new_depth`

4. **Depth limit**: If `sync_depth > 4`, the entity is skipped during sync processing

**Example chain:**

```
User creates thread (sync_depth = null)
  → Twist A processes it, creates note (sync_depth = 1)
    → Twist B processes note, updates thread (sync_depth = 2)
      → Twist A processes thread, creates note (sync_depth = 3)
        → Twist B processes note, updates thread (sync_depth = 4)
          → Twist A sees sync_depth = 4, processes it
            → If Twist A writes anything, sync_depth = 5
              → Next sync skips items with sync_depth > 4
```

**Key points:**

- `sync_depth` is stored on the entity tables (`thread.sync_depth`, `note.sync_depth`)
- It is NOT based on `updated_by` — a twist can update the same item many times over days
- Each individual sync chain is tracked independently
- Non-sync updates (app, webhooks) reset `sync_depth` to null, starting a fresh chain

**Storage:**

- `thread.sync_depth`: Set when thread is created/updated by a twist
- `note.sync_depth`: Set when note is created/updated by a twist
- `priority.sync_depth`: Set when priority is created/updated by a twist

## Error Handling

### Server-Side

**Notification Failures:**

- If `notifySync()` or `notifyUserSync()` fails, the error is logged but does not block the API response (fire-and-forget via `waitUntil`)
- The SyncRecovery DO will detect and recover the missed notification within 30 seconds

**DO Failures:**

- If SyncNotify, UserSync, or TwistSync DOs fail, the alarm is not rescheduled
- The SyncRecovery DO will detect and recover the missed sync within 30 seconds
- TwistSync reports exceptions to PostHog

**Queue Failures:**

- If queue processing fails, the message is retried according to queue retry policy
- This may result in items being processed out of order, but shouldn't result in duplicates

**Broadcast Failures:**

- If sending a WebSocket message fails, the connection is closed
- The client will reconnect and pull full updates

### Client-Side

**Network Errors:**

- Expected during offline periods, not reported to PostHog
- Client continues operating with local data and retries on reconnection

**Auth Errors:**

- Handled by automatic sign-out flow, tracked separately
- WebSocket reconnects with fresh token after auth errors

**API Errors and RLS Violations:**

- Reported to PostHog as unexpected errors for investigation

### Recovery System

The SyncRecovery DO provides a safety net for all server-side failure scenarios:

- **Notification failures**: If `notifySync()` fails, the pending update remains in the tracking table
- **DO alarm failures**: If a DO fails to schedule its next alarm, the update remains pending
- **Transient errors**: Network issues, service unavailability, etc. are all recovered
- **Detection**: Runs 6 times per minute, checking for updates pending >30 seconds
- **Recovery latency**: Worst case ~40 seconds (30s stale threshold + up to 10s until next check)
- **No duplicates**: Recovered syncs go through the same debouncing logic as fresh notifications

## Monitoring

Key metrics to track:

- **Sync latency**: Time from database change to client delivery
- **Queue depth**: Number of pending twist update messages
- **Skipped syncs**: Syncs skipped due to no connected clients
- **Debounce effectiveness**: Ratio of notifications received to syncs delivered
- **sync_depth warnings**: Count of items skipped due to depth limit
- **Recovery triggers**: Number of SyncRecovery executions per minute (should be ~6)
- **Stale syncs recovered**: Count of user and twist syncs recovered by the recovery system
- **Recovery rate**: Percentage of syncs that required recovery (should be very low in healthy system)
- **Recovery latency**: Time from when a sync becomes stale to when it's recovered
