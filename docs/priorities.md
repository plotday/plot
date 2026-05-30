# Priority System Architecture

This document explains how the priority system works in Plot.

## Flat "Focus" model (Phase A — current)

Priorities are being replaced by a **flat Focus** concept on the client, while
the server's stored data model stays nested during the transition:

- **Focus** = a flat priority: no parent, no children. A focus has a name, a
  color, and an `icon` (curated set; defaults to `bullseyePointer`).
- **Inbox** = the per-user root priority. It holds threads not sorted into any
  focus. The client scopes the Inbox feed to the root exactly (not a path
  roll-up). The server projects the root's title as "Inbox" for flat clients.
- **Everything** = a client-only view (no entity): the unscoped feed of all
  threads across the Inbox and every focus. The Flutter client drives it with a
  `NowBloc.everything` flag mirrored into `PriorityState.everything`; the feed
  query passes `priorityId = priorityPath = null`.
- **Archive releases threads**: `"user".effective_priority_id()` returns the
  root for an archived focus's threads at read time, so archiving a focus
  surfaces its threads in the Inbox without mutating `thread_priority.priority_id`
  (un-archive restores them for free).
- **Negative tracking**: `thread_priority_negative` records threads moved out of
  a focus or deselected during two-step creation; the matcher down-weights them.
- **Two-step creation**: `POST /sync/priorities/find-matching-threads` ranks the
  user's existing threads against a focus description (embeddings + LLM rerank);
  selected matches are filed (`/sync/priority-moves`), deselected ones recorded
  as negatives.

**Version-gated transition.** The transition is gated on `X-Plot-API-Version`:
clients `>= 4` get the flat projection (`user.priority.flat_title` as the title,
root → "Inbox", `path` retained but unused); clients `< 4` get today's nested
shape unchanged. The new Flutter client sends `4` and renders no nesting UI.

**Phase B (deferred until old clients age out)** bakes `flat_title` into `title`
and deletes the nesting machinery (`path`/ltree/GiST, `move_priority`,
`generate_path`/`parent_path`, ancestor inheritance, the version gate),
switching root-identification to the existing `root` boolean. Everything below
describes that still-present nested machinery.

## Overview

Priorities in Plot are hierarchical entities organized using PostgreSQL's ltree extension. Each priority is **owned by a single user** (`priority.user_id`). There are no shared priorities — each user has their own priority tree, and threads are filed independently per user via the `thread_priority` join table.

Thread visibility is determined by `thread.contacts` — a thread is visible to a user if any of their linked contacts (via `user_contact`) appear in the thread's contacts array.

## Core Data Model

### Tables

#### `priority`
The main priority table storing the user's hierarchy.

```sql
- id: uuid (primary key)
- user_id: uuid (owner — single source of truth for who sees this priority)
- path: ltree (hierarchical path, e.g., 'f9DWiBV2SUV7.Ow9Z')
- title: text
- color: integer (default color)
- key: text (nullable — for system priorities like 'using-plot')
- created_by: uuid
- created_at, updated_at, archived_at
```

**Key characteristics:**
- Each priority belongs to exactly one user
- Path determines hierarchy: `parent.path @> child.path` (parent contains child)
- The `key` column identifies system priorities (e.g. `key = 'using-plot'`), unique per `(user_id, key)`

#### `thread_priority`
Files a thread into a specific priority for a specific user.

```sql
- thread_id: uuid
- user_id: uuid
- priority_id: uuid
- matched: boolean (true if filed by matching algorithm)
- created_at, updated_at
- PRIMARY KEY (thread_id, user_id)
```

**Key characteristics:**
- Each user has at most one filing per thread
- Populated automatically by triggers (`populate_thread_priority_for_author`, `file_thread_priority_peers`)
- The matching algorithm scores existing threads to pick the best priority

#### `user_contact`
Dual-purpose join table for identity linking and contact visibility.

```sql
- user_id: uuid
- contact_id: uuid
- linked: boolean (true = contact IS the user, false = contact is visible to user)
- primary: boolean (only meaningful when linked = true)
- source: text (how the contact became visible)
- created_at, updated_at, archived_at
- PRIMARY KEY (user_id, contact_id)
```

**Key characteristics:**
- `linked = true`: this contact is one of the user's identities (used for thread visibility)
- `linked = false`: this contact is visible to the user (With picker, thread rendering)
- Replaces the removed `priority_contact` table for contact visibility

#### `priority_setting`
User-specific customization for priorities.

```sql
- user_id: uuid
- priority_id: uuid
- key: text (setting name, e.g. 'color', 'order')
- value: jsonb
```

### Views

#### `priority_child`
Maps each priority to all its descendants.

```sql
SELECT p.id AS priority_id, c.id AS child_id, c.archived_at
FROM priority p
JOIN priority c ON c.path <@ p.path
```

#### `user.priority_expanded`
Expands priorities to include all descendants for each user.

**Purpose**: Answers "which priorities does user X have?" Used in sync triggers and access checks.

#### `user.priority` (Main Client View)
The view that Flutter clients query. Returns all priorities owned by the user.

### Functions

#### `find_matching_threads_scored`
Scores existing threads to find the best priority for filing a new thread. Scoped per-user via `p_user_id` parameter — only considers threads the user has filed via `thread_priority`.

## Thread Visibility

Thread visibility is driven by two things:

1. **`thread_priority`**: the user has a filing for this thread (created by triggers on thread insert)
2. **`thread.contacts`**: at least one of the user's linked contacts appears in the thread's contacts array

The canonical visibility check (from `user.thread` view):

```sql
JOIN thread_priority tp ON tp.thread_id = t.id
WHERE t.archived_at IS NULL
  AND (t.draft = FALSE OR t.created_by = tp.user_id)
  AND t.contacts && "user".user_contact_ids(tp.user_id)
```

## Priority Creation Flow

1. **Flutter app sends request** to `user.priority` view with a path
2. **Trigger translates and inserts** the priority with `user_id` set from the current user
3. **New priority appears** in the user's tree immediately

## Access Control

Each priority belongs to exactly one user. Access is simply `priority.user_id = current_user_id`. No role-based access or shared membership.

## Sync Broadcasts

When priorities change, the owning user is notified via real-time sync:

1. **Change occurs** in `priority` table
2. **Trigger fires** `sync_user_for_priority()` function
3. **Find affected users** by joining with `user.priority_expanded`
4. **Update `user_sync` table** with latest update timestamp
5. **API worker queues WebSocket notifications** to connected clients

## Common Patterns

### Querying Priorities

```sql
-- Get all priorities for a user
SELECT * FROM "user".priority WHERE user_id = 'user-id-here';

-- Get all children of a priority
SELECT * FROM priority_child WHERE priority_id = 'parent-id';
```

### Filing a Thread

Thread filing happens automatically via database triggers:
- **Author**: `populate_thread_priority_for_author` fires on thread insert
- **Peers**: `file_thread_priority_peers` fires for contacts in `thread.contacts`

Both use `find_matching_threads_scored` to pick the best priority.

## Design Decisions

### Why Per-User Priorities?

The previous model conflated two concerns:
1. **Organization** — how each user wants their work filed (naturally per-user)
2. **Access** — who can see a thread (naturally per-thread via contacts)

Separating these into per-user priority trees and contact-based visibility simplifies the model and eliminates complex shared-priority access control.

### Why ltree?

PostgreSQL's ltree extension provides efficient hierarchical queries, path operations, and indexing for the priority tree structure.

## Related Components

### Database Schema (`libs/db/schema/`)

**Core Tables** (`50-tables/`)
- `priority` — per-user hierarchical priorities
- `thread_priority` — per-user thread filing
- `user_contact` — identity linking and contact visibility
- `priority_setting` — per-user priority customizations

**Views** (`70-views/`, `90-user-schema/`)
- `priority_child` — maps priorities to descendants
- `user.priority_expanded` — expands priorities for access checks
- `user.priority` — main client view with upsert trigger

**Functions** (`60-functions/`)
- `find_matching_threads_scored` — per-user priority matching
- Path generation functions for ltree operations

### Flutter Client (`apps/plot/`)

**Store Layer** (`lib/store/`)
- Priority entity definition and Drift schema
- Offline-first sync with `user.priority` view

### API Workers (`workers/api/src/`)

**Sync System**
- UserSync Durable Object for per-user sync coordination
- Broadcast Durable Object for WebSocket message delivery
