# Sync Architecture

This document describes the sync system that delivers real-time updates to Plot apps and twists.

## Overview

The sync system has two main responsibilities:

1. **App Sync**: Notify connected app clients when data they can access has changed
2. **Twist Sync**: Notify twists when data in their scope has changed so they can process it

Both use a tracking-table approach where lightweight database triggers record pending updates, and Durable Objects debounce and deliver those updates efficiently.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              Supabase Database                               │
├──────────────────────────────────────────────────────────────────────────────┤
│  Tables with Triggers                                                        │
│  ┌──────────┐ ┌──────┐ ┌──────────┐ ┌─────────┐ ┌────────────────┐           │
│  │ activity │ │ note │ │ priority │ │ session │ │ priority_twist │ ...       │
│  └────┬─────┘ └──┬───┘ └────┬─────┘ └────┬────┘ └───────┬────────┘           │
│       │          │          │            │              │                    │
│       └──────────┴──────────┴────────────┴──────────────┘                    │
│                              │                                               │
│                    Lightweight Triggers                                      │
│                              │                                               │
│              ┌───────────────┴───────────────┐                               │
│              ▼                               ▼                               │
│     ┌─────────────┐                 ┌────────────────────┐                   │
│     │  user_sync  │                 │ priority_twist_sync│                   │
│     └──────┬──────┘                 └─────────┬──────────┘                   │
│            │                                  │                              │
└────────────┼──────────────────────────────────┼──────────────────────────────┘
             │                                  │
             │ HTTP POST (when condition met)   │ HTTP POST (when condition met)
             ▼                                  ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                              Cloudflare Workers                              │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────────────┐                    ┌───────────────────┐               │
│  │ POST /sync/users │                    │POST /sync/twists  │               │
│  └────────┬─────────┘                    └─────────┬─────────┘               │
│           │                                        │                         │
│           ▼                                        ▼                         │
│  ┌─────────────────┐                      ┌─────────────────┐                │
│  │   UserSync DO   │                      │  TwistSync DO   │                │
│  │   (per user)    │                      │ (per priority   │                │
│  │                 │                      │     twist)      │                │
│  │  - Debouncing   │                      │  - Debouncing   │                │
│  │  - Client check │                      │  - Query order  │                │
│  └────────┬────────┘                      └────────┬────────┘                │
│           │                                        │                         │
│           │ Query & Update                         │ Query & Queue           │
│           ▼                                        ▼                         │
│  ┌─────────────────┐                      ┌─────────────────┐                │
│  │  Broadcast DO   │                      │  UPDATES_QUEUE  │                │
│  │   (WebSocket)   │                      │                 │                │
│  └────────┬────────┘                      └────────┬────────┘                │
│           │                                        │                         │
└───────────┼────────────────────────────────────────┼─────────────────────────┘
            │                                        │
            ▼                                        ▼
     ┌─────────────┐                         ┌─────────────┐
     │  Plot Apps  │                         │   Twists    │
     └─────────────┘                         └─────────────┘
```

## Database Tables

### user_sync

Tracks pending sync updates for app clients.

```sql
CREATE TABLE user_sync (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
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

**API Call Condition:** The trigger calls the API when either:

1. `last_update_at > last_sync_at` becomes newly true (wasn't true before this update), OR
2. `last_update_at > last_sync_at` is already true and `last_sync_at` was just updated (indicating a new update arrived while the previous sync was being processed)

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

**API Call Condition:** Same as user_sync - call API when the pending condition becomes newly true, or when a new update arrives while processing.

### Twist Sync Database Views

These views pre-filter and enrich data for twist sync queries. Each view includes all necessary JOINed fields (author_name, tags, priority info, etc.) so the TwistSync DO can query them directly without additional transformations.

| View                                 | Purpose                                                    |
| ------------------------------------ | ---------------------------------------------------------- |
| `priority_twist_note_create`         | New notes on activities the twist created or was mentioned in |
| `priority_twist_note_update`         | Notes created by the twist that have been updated          |
| `priority_twist_activity_update`     | Activities created by the twist that have been updated     |
| `priority_twist_activity_tag_change` | Tag additions/removals on activities the twist created     |

Each view:
- Filters by `priority_twist_id` parameter
- Compares entity `updated_at` against `priority_twist_sync.last_sync_at`
- Excludes entities where `updated_by` equals the twist (prevents self-triggering)
- Excludes draft notes (only syncs published content)
- Includes enriched fields from JOINs (author info, priority info, etc.)

## Entity Types

The following entity types are tracked in the sync tables:

| Entity             | Description                             | Source Tables                 |
| ------------------ | --------------------------------------- | ----------------------------- |
| `activity`         | Tasks, events, and other activity items | `activity`, `activity_tag`    |
| `note`             | Notes attached to activities            | `note`, `note_tag`            |
| `priority`         | Priorities (projects/folders)           | `priority`                    |
| `session`          | User focus sessions                     | `session`                     |
| `priority_twist`   | Twist instances on priorities           | `priority_twist`              |
| `activity_read`    | Read status for activities              | `activity_read`               |
| `priority_contact` | Contacts associated with priorities     | `priority_contact`            |
| `actor`            | Combined view of contacts and twists    | `priority_contact`, `contact` |

## Database Triggers

### Trigger Design Principles

1. **Lightweight**: Triggers only update the sync tracking tables; they do not construct complex payloads
2. **Batched**: Use statement-level triggers with `NEW TABLE` references for efficiency
3. **Conditional API calls**: Only call the API when the pending condition transitions (see API Call Condition above)
4. **Filtered**: For twist sync, exclude the `updated_by` twist from notifications to prevent self-triggering
5. **No DELETE triggers**: Plot uses soft deletes (archived_at), so only INSERT and UPDATE triggers are needed

### User Sync Triggers

These triggers update `user_sync` to track which users need app sync updates.

| Trigger Name                        | Table              | Events | Function                           |
| ----------------------------------- | ------------------ | ------ | ---------------------------------- |
| `user_sync_activity_insert`         | `activity`         | INSERT | `sync_user_for_activity()`         |
| `user_sync_activity_update`         | `activity`         | UPDATE | `sync_user_for_activity()`         |
| `user_sync_note_insert`             | `note`             | INSERT | `sync_user_for_note()`             |
| `user_sync_note_update`             | `note`             | UPDATE | `sync_user_for_note()`             |
| `user_sync_priority_insert`         | `priority`         | INSERT | `sync_user_for_priority()`         |
| `user_sync_priority_update`         | `priority`         | UPDATE | `sync_user_for_priority()`         |
| `user_sync_session_insert`          | `session`          | INSERT | `sync_user_for_session()`          |
| `user_sync_session_update`          | `session`          | UPDATE | `sync_user_for_session()`          |
| `user_sync_priority_twist_insert`   | `priority_twist`   | INSERT | `sync_user_for_priority_twist()`   |
| `user_sync_priority_twist_update`   | `priority_twist`   | UPDATE | `sync_user_for_priority_twist()`   |
| `user_sync_activity_read_insert`    | `activity_read`    | INSERT | `sync_user_for_activity_read()`    |
| `user_sync_activity_read_update`    | `activity_read`    | UPDATE | `sync_user_for_activity_read()`    |
| `user_sync_priority_contact_insert` | `priority_contact` | INSERT | `sync_user_for_priority_contact()` |
| `user_sync_priority_contact_update` | `priority_contact` | UPDATE | `sync_user_for_priority_contact()` |
| `user_sync_activity_tag_insert`     | `activity_tag`     | INSERT | `sync_user_for_activity_tag()`     |
| `user_sync_activity_tag_update`     | `activity_tag`     | UPDATE | `sync_user_for_activity_tag()`     |
| `user_sync_note_tag_insert`         | `note_tag`         | INSERT | `sync_user_for_note_tag()`         |
| `user_sync_note_tag_update`         | `note_tag`         | UPDATE | `sync_user_for_note_tag()`         |
| `user_sync_contact_insert`          | `contact`          | INSERT | `sync_user_for_contact()`          |
| `user_sync_contact_update`          | `contact`          | UPDATE | `sync_user_for_contact()`          |

### Twist Sync Triggers

These triggers update `priority_twist_sync` to track which twists need to process updates.

| Trigger Name                       | Table            | Events | Function                          |
| ---------------------------------- | ---------------- | ------ | --------------------------------- |
| `twist_sync_activity_update`       | `activity`       | UPDATE | `sync_twist_for_activity()`       |
| `twist_sync_note_insert`           | `note`           | INSERT | `sync_twist_for_note()`           |
| `twist_sync_note_update`           | `note`           | UPDATE | `sync_twist_for_note()`           |
| `twist_sync_priority_twist_insert` | `priority_twist` | INSERT | `sync_twist_for_priority_twist()` |
| `twist_sync_priority_twist_update` | `priority_twist` | UPDATE | `sync_twist_for_priority_twist()` |
| `twist_sync_activity_tag_insert`   | `activity_tag`   | INSERT | `sync_twist_for_activity_tag()`   |
| `twist_sync_activity_tag_update`   | `activity_tag`   | UPDATE | `sync_twist_for_activity_tag()`   |
| `twist_sync_note_tag_insert`       | `note_tag`       | INSERT | `sync_twist_for_note_tag()`       |
| `twist_sync_note_tag_update`       | `note_tag`       | UPDATE | `sync_twist_for_note_tag()`       |

Note: There is no `twist_sync_activity_insert` trigger because twists don't listen for new activities - only updates to activities they created.

### Trigger Functions

#### User Sync Functions

Each function determines which users need to be notified and updates `user_sync`:

```sql
-- Example: sync_user_for_activity()
-- 1. Get all users with access to the affected priorities
-- 2. For each user, UPSERT into user_sync with max(updated_at)
-- 3. If the UPSERT made last_update_at > last_sync_at newly true, call API
```

**User Resolution:**

- `activity`, `note`: All users with access to the activity's priority
- `priority`: The priority creator only
- `session`: The session owner only
- `activity_read`: The reading user only
- `priority_twist`: All users with access to the priority
- `priority_contact`: All users with access to the priority
- `actor`: Derived from priority_contact and contact changes

#### Twist Sync Functions

Each function determines which twists need to process the update:

```sql
-- Example: sync_twist_for_activity()
-- 1. Get all priority_twists with access to the activity's priority
-- 2. EXCLUDE the twist identified by updated_by (if it's a twist)
-- 3. For each twist, UPSERT into priority_twist_sync with max(updated_at)
-- 4. If the UPSERT made last_update_at > last_sync_at newly true, call API
```

**Twist Resolution:**

Twists are notified for the following events in the priority they are installed and all descendant priorities:

- **Activity UPDATE**: Only the twist that created the activity (`activity.created_by = priority_twist.id`)
- **Activity tag changes**: Only the twist that created the activity
- **Note INSERT**: Twist that created the activity OR any twist mentioned in any note on that activity
- **Note UPDATE**: Only the twist that created the note (`note.created_by = priority_twist.id`)
- **Note tag changes**: Only the twist that created the note

Twists do not receive notifications for events they generated themselves, as identified by the `updated_by` field.

#### API Call Condition

The trigger calls the API when either condition is met:

```sql
-- Pseudocode for conditional API call
-- Track the previous state before update
WITH previous AS (
  SELECT last_update_at, last_sync_at
  FROM user_sync
  WHERE user_id = v_user_id AND entity = 'activity'
)
INSERT INTO user_sync (user_id, entity, last_update_at)
VALUES (v_user_id, 'activity', v_updated_at)
ON CONFLICT (user_id, entity) DO UPDATE
SET last_update_at = GREATEST(user_sync.last_update_at, EXCLUDED.last_update_at)
RETURNING
  -- Call API if:
  -- 1. Condition became newly true (wasn't pending before, now is)
  -- 2. OR condition was already true and last_sync_at changed (new update during processing)
  (last_update_at > last_sync_at) AND (
    (SELECT last_update_at <= last_sync_at FROM previous) OR
    (SELECT last_sync_at FROM previous) != last_sync_at
  ) AS needs_api_call;
```

## API Endpoints

### POST /sync/users

Notifies the system that one or more users have pending sync updates.

**Request:**

- Headers: `X-Plot-Signature` - HMAC-SHA256 signature
- Body: `{ "ids": ["user-uuid-1", "user-uuid-2", ...] }`

**Behavior:**

1. Validates HMAC signature
2. For each user ID, gets or creates the UserSync Durable Object
3. Calls each DO's `notify()` method to trigger debounced sync

### POST /sync/twists

Notifies the system that one or more priority_twists have pending updates to process.

**Request:**

- Headers: `X-Plot-Signature` - HMAC-SHA256 signature
- Body: `{ "ids": ["priority-twist-uuid-1", "priority-twist-uuid-2", ...] }`

**Behavior:**

1. Validates HMAC signature
2. For each priority_twist ID, gets or creates the TwistSync Durable Object
3. Calls each DO's `notify()` method to trigger debounced processing

## Durable Objects

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
notify(): void
```

Called when the API receives a sync notification. Schedules an alarm based on debouncing rules.

```typescript
alarm(): void
```

Called when the alarm fires. Performs the sync:

1. **Check for connected clients**: Call `Broadcast.hasConnectedClients(userId)`. If no clients are connected, skip the sync entirely (no database queries). The client will pull full updates when it connects.

2. **Query pending updates**:

   ```sql
   SELECT entity, last_update_at
   FROM user_sync
   WHERE user_id = :userId AND last_update_at > last_sync_at
   ```

3. **Send sync messages**: For each entity with pending updates, send a sync message via the Broadcast DO:

   ```typescript
   broadcast.send(userId, { type: "sync", table: entity });
   ```

4. **Update last_sync_at**:

   ```sql
   UPDATE user_sync
   SET last_sync_at = last_update_at
   WHERE user_id = :userId AND last_update_at > last_sync_at
   ```

### TwistSync DO

One instance per priority_twist. Handles debouncing and queuing of twist updates.

**Debouncing Parameters** (compile-time constants):

- `MIN_WAIT_MS` (200ms): Minimum time to wait
- `MAX_WAIT_MS` (5000ms): Maximum time to wait
- `MIN_INTERVAL_MS` (1000ms): Minimum gap between queue messages

**State:**

- `lastNotifyTime`: When the last `notify()` was received
- `lastSyncTime`: When the last update was queued
- `pendingAlarm`: Whether an alarm is scheduled

**Methods:**

```typescript
notify(): void
```

Called when the API receives a sync notification. Schedules an alarm.

```typescript
alarm(): void
```

Called when the alarm fires. Gathers and queues updates using database views that pre-filter and enrich data:

1. **Query pending updates via database views** (in this order to ensure consistency):

   a. **New notes** (from `priority_twist_note_create` view):
   Notes created on activities this twist created or was mentioned in.

   ```sql
   SELECT * FROM priority_twist_note_create
   WHERE priority_twist_id = :priorityTwistId
   ORDER BY updated_at ASC
   LIMIT 50
   ```

   b. **Updated notes** (from `priority_twist_note_update` view):
   Notes this twist created that have been updated.

   ```sql
   SELECT * FROM priority_twist_note_update
   WHERE priority_twist_id = :priorityTwistId
   ORDER BY updated_at ASC
   LIMIT 50
   ```

   c. **Updated activities** (from `priority_twist_activity_update` view):
   Activities this twist created that have been updated.

   ```sql
   SELECT * FROM priority_twist_activity_update
   WHERE priority_twist_id = :priorityTwistId
   ORDER BY updated_at ASC
   LIMIT 50
   ```

   d. **Activity tag changes** (from `priority_twist_activity_tag_change` view):
   Tag additions/removals on activities this twist created.

   ```sql
   SELECT * FROM priority_twist_activity_tag_change
   WHERE priority_twist_id = :priorityTwistId
   ```

   e. **Priority twist info**:

   ```sql
   SELECT pt.*
   FROM priority_twist pt
   WHERE pt.id = :priorityTwistId
     AND pt.updated_at > (SELECT last_sync_at FROM priority_twist_sync WHERE ...)
   ```

2. **Update last_sync_at immediately** (before queuing, to avoid duplicate processing):

   ```sql
   UPDATE priority_twist_sync
   SET last_sync_at = last_update_at
   WHERE priority_twist_id = :priorityTwistId AND last_update_at > last_sync_at
   ```

3. **Queue the message**:

   ```typescript
   await UPDATES_QUEUE.send({
     type: "twist_batch",
     priorityTwistId,
     twistId,
     environment,
     version,
     newNotes: [...],           // max 50
     updatedNotes: [...],       // max 50
     updatedActivities: [...],  // max 50
     activityTagChanges: [...],
     priorityTwist: {...} | null,
   })
   ```

4. **Schedule follow-up if more items remain**: If any query returned 50 items (the limit), schedule another alarm immediately to process the next batch.

### Broadcast DO Integration

The Broadcast DO manages WebSocket connections for real-time updates.

**New Method:**

```typescript
hasConnectedClients(): boolean
```

Returns true if any WebSocket clients are connected for this user. This is a simple in-memory check.

**Connection Open Hook:**

When a WebSocket connection opens, the Broadcast DO calls the UserSync DO:

```typescript
async webSocketOpen(ws: WebSocket, userId: string) {
  // ... existing auth logic ...

  // Trigger sync to update last_sync_at
  const userSync = env.USER_SYNC.get(env.USER_SYNC.idFromName(userId));
  await userSync.onClientConnected();
}
```

This ensures that `last_sync_at` gets updated when a client connects, even if updates accumulated while no clients were connected. The app manually syncs before connecting to the WebSocket, so it already has the latest data.

### SyncRecovery DO

One global instance that recovers missed sync notifications. Handles cases where database triggers fail to notify sync DOs or where DOs fail to process updates.

**Architecture:**

- **Cron trigger**: Runs every minute via scheduled event at `/sync/recovery`
- **Alarm-based execution**: Each cron trigger runs recovery immediately, then schedules 5 alarms at 10-second intervals
- **Total frequency**: 6 executions per minute (1 cron + 5 alarms)

**Stale Detection:**

Finds pending syncs that haven't been processed:

```sql
-- User syncs
SELECT DISTINCT user_id
FROM user_sync
WHERE last_update_at > last_sync_at  -- Has pending updates
  AND last_sync_at < :staleThreshold  -- Hasn't synced recently
LIMIT 50

-- Twist syncs
SELECT DISTINCT priority_twist_id
FROM priority_twist_sync
WHERE last_update_at > last_sync_at
  AND last_sync_at < :staleThreshold
LIMIT 50
```

**Configuration:**

- `STALE_THRESHOLD_MS` (30000ms): How long to wait before considering a sync "stale"
- `ALARM_INTERVAL_MS` (10000ms): Time between alarm executions
- `MAX_ALARMS_PER_CRON` (5): Number of alarms to schedule after each cron trigger
- `MAX_ITEMS_PER_QUERY` (50): Maximum users/twists to recover per execution

**Recovery Process:**

1. Query for stale user syncs using `get_stale_user_syncs()` RPC
2. For each stale user, call `UserSync.notify()` via DO fetch
3. Query for stale twist syncs using `get_stale_twist_syncs()` RPC
4. For each stale twist, call `TwistSync.notify()` via DO fetch
5. Schedule next alarm if under the limit

**Why This Works:**

- Catches missed notifications from HTTP failures in database triggers
- Recovers from DO failures that prevent alarm scheduling
- 30-second threshold balances rapid recovery vs avoiding false positives from normal debouncing
- Per-minute execution ensures consistent recovery without overwhelming the system

## Queue Processing

The UPDATES_QUEUE receives batched twist updates from TwistSync DOs.

**Message Format:**

```typescript
interface TwistBatchMessage {
  type: "twist_batch";
  priorityTwistId: string;
  twistId: number;
  environment: TwistEnvironment;
  version: string;
  // Notes created on activities this twist created or was mentioned in
  newNotes: NoteCreate[];           // from priority_twist_note_create view
  // Notes updated by this twist (for the update callback)
  updatedNotes: NoteUpdate[];       // from priority_twist_note_update view
  // Activities updated that this twist created (for the update callback)
  updatedActivities: ActivityUpdate[]; // from priority_twist_activity_update view
  // Tag changes for building tagsAdded/tagsRemoved per activity
  activityTagChanges: ActivityTagChange[]; // from priority_twist_activity_tag_change view
  // Priority twist config changes
  priorityTwist: PriorityTwist | null;
}

interface ActivityTagChange {
  activityId: string;
  tagId: number;
  actorId: string;
  changeType: "added" | "removed";
}
```

**Processing:**

1. Load the twist via the factory
2. For each new note (notes created on activities this twist created or was mentioned in):
   - Read `sync_depth` from the note (null means not from a sync chain)
   - If `sync_depth > 4`, skip and log warning
   - Otherwise, dispatch to Plot tool with `itemType: "note"` for note.created callback
3. For each updated note (notes this twist created):
   - Same sync_depth handling as new notes
   - Dispatch to Plot tool for note.updated callback
4. For each updated activity (activities this twist created):
   - Same sync_depth handling
   - Build `tagsAdded`/`tagsRemoved` from activityTagChanges for this activity
   - Dispatch to Plot tool with changes object for activity.updated callback
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
User creates activity (sync_depth = null)
  → Twist A processes it, creates note (sync_depth = 1)
    → Twist B processes note, updates activity (sync_depth = 2)
      → Twist A processes activity, creates note (sync_depth = 3)
        → Twist B processes note, updates activity (sync_depth = 4)
          → Twist A sees sync_depth = 4, processes it
            → If Twist A writes anything, sync_depth = 5
              → Next sync skips items with sync_depth > 4
```

**Key points:**

- `sync_depth` is stored on the entity tables (`activity.sync_depth`, `note.sync_depth`)
- It is NOT based on `updated_by` - a twist can update the same item many times over days
- Each individual sync chain is tracked independently
- Non-sync updates (app, webhooks) reset `sync_depth` to null, starting a fresh chain

**Storage:**

- `activity.sync_depth`: Set when activity is created/updated by a twist
- `note.sync_depth`: Set when note is created/updated by a twist
- `priority.sync_depth`: Set when priority is created/updated by a twist

## Error Handling

### Trigger Failures

- If the HTTP call to the API fails, the trigger logs the error but does not block the transaction
- The SyncRecovery DO will detect and recover the missed notification within 30 seconds

### DO Failures

- If the UserSync or TwistSync DO fails, the alarm is not rescheduled
- The SyncRecovery DO will detect and recover the missed sync within 30 seconds

### Queue Failures

- If queue processing fails, the message is retried according to queue retry policy
- This may result in items being processed out of order, but shouldn't result in duplicates

### Broadcast Failures

- If sending a WebSocket message fails, the connection is closed
- The client will reconnect and pull full updates

### Recovery System

The SyncRecovery DO provides a safety net for all failure scenarios:

- **Trigger HTTP failures**: If a database trigger fails to call the API, the pending update remains in the sync tracking table
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
