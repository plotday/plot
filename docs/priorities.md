# Priority System Architecture

This document explains how the priority system works in Plot, including the implementation of shared priorities and the dual-path architecture.

## Overview

Priorities in Plot are hierarchical entities organized using PostgreSQL's ltree extension. They can be:
- **Personal**: Owned by a single user
- **Shared**: Accessible by multiple users with customizable visual organization per user

The system uses a **dual-path architecture** where priorities have both:
1. **Actual paths**: Real ltree paths in the database used for hierarchy and access control
2. **Visual paths**: User-specific paths that map shared priorities into each user's personal organization

## Core Data Model

### Tables

#### `priority`
The main priority table storing the actual hierarchy.

```sql
- id: uuid (primary key)
- path: ltree (actual hierarchical path, e.g., 'f9DWiBV2SUV7.Ow9Z')
- title: text
- color: integer (default color)
- created_by: uuid
- created_at, updated_at, archived_at
```

**Key characteristics:**
- The `path` column contains the **actual path** - this never changes after creation
- Path determines hierarchy: `parent.path @> child.path` (parent contains child)
- All access control decisions are based on actual paths

#### `priority_user`
Defines which users have access to which priority roots.

```sql
- user_id: uuid
- priority_id: uuid (references a root priority)
- personal: boolean (true for user's personal root)
- created_at, archived_at
```

**Key characteristics:**
- One row per user per accessible priority root
- If a user has access to a root, they have access to ALL descendants
- `personal = true` indicates the user's personal priority tree root
- Soft-delete via `archived_at` to remove access

#### `priority_contact`
Tracks sharing invitations and accepted shares.

```sql
- id: bigint
- priority_id: uuid (the shared priority)
- contact_id: uuid (references contact table)
- invited_by: uuid (user who shared)
- invited_at: timestamp (null = invitation cancelled)
```

**Key characteristics:**
- When sharing, creates `priority_contact` entry
- If contact is registered user, also creates `priority_user` entry
- If contact signs up later, trigger creates `priority_user` entry

#### `priority_settings`
User-specific visual customization for priorities.

```sql
- user_id: uuid
- priority_id: uuid
- path: ltree (user's visual path for this priority)
- color: integer (user's color override)
- order, top_order, pomodoro
```

**Key characteristics:**
- Stores where the user wants to see this priority in their tree
- `path` here is a **visual path**, not an actual path
- Only created when user customizes a priority's location or appearance

### Views

#### `priority_child`
Maps each priority to all its descendants.

```sql
SELECT
    p.id AS priority_id,
    c.id AS child_id,
    c.archived_at
FROM priority p
JOIN priority c ON c.path <@ p.path
```

**Purpose**: Efficiently query "what are all descendants of priority X?"

#### `user_priority_expanded`
Expands `priority_user` entries to include all accessible descendants.

```sql
SELECT
    pu.user_id,
    c.child_id AS priority_id,
    MIN(pu.created_at) AS joined_at,
    CASE WHEN bool_or(pu.archived_at IS NULL) THEN NULL
    ELSE LEAST(MIN(pu.archived_at), MIN(c.archived_at)) END AS archived_at
FROM priority_user pu
JOIN priority_child c ON pu.priority_id = c.priority_id
GROUP BY pu.user_id, c.child_id
```

**Purpose**: Answers "which users can access priority X?" Used extensively in:
- RLS policies
- Sync broadcast triggers
- Access control functions

#### `priority_settings_inherited`
Computes inherited settings from ancestors.

```sql
-- For each user+priority, finds the closest ancestor with settings
-- and inherits color, pomodoro, and visual path
```

**Purpose**: Settings cascade down the hierarchy. If a parent has custom color, children inherit it unless overridden.

#### `user_priority` (Main Client View)
The view that Flutter clients query. Returns all accessible priorities with visual paths.

**Key characteristics:**
- Returns **visual paths** computed per-user
- Joins with parent to compute hierarchical visual paths
- This is what Flutter syncs to local Drift database
- The `path` column here is a visual path, NOT the actual path from `priority` table

**Visual Path Computation Logic:**

The view uses a CASE statement to compute the visual path for each priority:

1. **If priority has explicit inherited settings** → use that path
   - User or ancestor has customized where this priority appears
   - Path from `priority_settings_inherited`

2. **If priority's actual path is already under user's personal root** → use actual path as-is
   - Priority created under user's personal tree
   - No translation needed

3. **If parent has inherited settings** → use parent's visual path + this priority's label
   - Parent is a shared priority with custom location
   - Child inherits parent's visual location
   - Extracts label from actual path, appends to parent's visual path

4. **Fallback** → concatenate user_root + actual path
   - For top-level shared priorities without custom location
   - Creates default visual location under user's root

## How Sharing Works

### Sharing Flow

1. **User A shares priority P with User B**
   ```sql
   -- Called via share_priority() function
   -- Creates entry in priority_contact
   INSERT INTO priority_contact (priority_id, contact_id, invited_by, invited_at)
   VALUES (P, contact_B, user_A, now());

   -- If User B exists, creates priority_user entry
   INSERT INTO priority_user (user_id, priority_id, personal)
   VALUES (user_B, P, false);
   ```

2. **Priority might be extracted from personal tree**
   - If P was nested under User A's personal root, it's extracted to a new top-level path
   - User A gets a `priority_settings` entry preserving the visual location
   - Other users see it at its actual (top-level) path location

3. **Access is hierarchical**
   - Creating `priority_user` entry for P grants access to P and ALL descendants
   - No need to create entries for children - they're automatically accessible

### Visual Organization

Each user can organize shared priorities differently:

**Example:**
- Actual hierarchy: `f9DWiBV2SUV7` (Test10) → `f9DWiBV2SUV7.Ow9Z` (10b)
- User A sees: `zmmuko6BmpY6.f9DWiBV2SUV7` → `zmmuko6BmpY6.f9DWiBV2SUV7.Ow9Z`
  - User A's personal root is `zmmuko6BmpY6`
  - Test10 appears nested in their personal tree via `priority_settings`
- User B sees: `2GlDC45wY2f0.1SFp` → `2GlDC45wY2f0.1SFp.Ow9Z`
  - User B's personal root is `2GlDC45wY2f0`
  - Test10 appears at custom location `1SFp` via `priority_settings`

Both users work with their own visual paths. The database translates between visual and actual paths transparently.

## Priority Creation Flow

### When a User Creates a New Priority

1. **Flutter app sends request** to `user_priority` view with visual path
   ```dart
   // Priority.dart - generates child path from parent
   path: Path.generate(parent: parent.path)
   // Uses parent's VISUAL path
   ```

2. **Trigger `handle_user_priority_upsert` translates to actual path**

   The trigger performs the following translation for new sub-priorities:

   a. **Extract parent path and label from visual path**
      ```sql
      _parent_visual_path := subpath(NEW.path, 0, nlevel(NEW.path) - 1);
      _label := text(subpath(NEW.path, nlevel(NEW.path) - 1, 1));
      ```

   b. **Look up parent priority ID using visual path**
      - Queries `user_priority` view (which has visual paths)
      - Finds the priority that matches the parent's visual path
      - Gets the parent's ID

   c. **Get parent's ACTUAL path from priority table**
      - Uses parent ID to query `priority` table
      - Retrieves the parent's actual ltree path

   d. **Compute actual path for new priority**
      ```sql
      _actual_path := _parent_actual_path || _label::ltree;
      ```

   e. **Store priority with actual path**
      - Inserts into `priority` table with translated actual path
      - Visual path translation is transparent to the client

4. **Other users automatically see it**
   - `user_priority_expanded` includes the new priority for all users with parent access
   - `user_priority` view computes correct visual path for each user
   - Sync broadcasts notify all affected users

### Why This Translation is Critical

Without translation, children of shared priorities would be stored with the creator's visual path, causing:
- Children stored with personal root prefix (e.g., `zmmuko6BmpY6.f9DWiBV2SUV7.child`)
- Other users can't access because they don't have access to that personal root
- Hierarchy breaks for all users except the creator

With translation:
- Children stored with actual parent path (e.g., `f9DWiBV2SUV7.child`)
- All users with parent access automatically get child access
- Each user sees their own visual hierarchy

## Access Control

### Authorization

RLS is disabled on all tables. Authorization is enforced at the API layer. All queries use `user_priority` view which enforces access via JOINs:
- Only returns priorities where user has `priority_user` entry for a root
- Flutter app never queries `priority` table directly
- The API layer checks access before returning data

### Access Check Functions

```sql
-- Check if user has access to a priority
CREATE FUNCTION user_has_priority_access(user_id uuid, priority_id uuid)
RETURNS boolean AS $$
    SELECT EXISTS (
        SELECT 1 FROM priority_user pu
        JOIN priority pp ON pu.priority_id = pp.id
        JOIN priority p ON p.path <@ pp.path
        WHERE pu.user_id = user_id
          AND pu.archived_at IS NULL
          AND p.id = priority_id
    )
$$;

-- Used in trigger functions (access control is enforced at the API layer, not via RLS)
CREATE FUNCTION can_access_priority(p_user_id uuid, priority_id uuid)
RETURNS boolean AS $$
    SELECT EXISTS (
        SELECT 1 FROM user_priority_expanded upe
        WHERE upe.user_id = p_user_id
          AND upe.priority_id = priority_id
    )
$$;
```

## Sync Broadcasts

When priorities change, affected users are notified via real-time sync.

### Sync Trigger Architecture

When priorities are inserted or updated, triggers fire to notify affected users:

**Trigger Flow:**
1. **Change occurs** in `priority` table (INSERT or UPDATE)
2. **Trigger fires** `sync_user_for_priority()` function
3. **Find affected users** by joining with `user_priority_expanded`
   - Includes all users with direct access
   - Includes users with access via parent priorities
4. **Update `user_sync` table** with latest update timestamp per user
5. **Notify API worker** with batched list of affected user IDs
6. **API worker queues WebSocket notifications** to connected clients

**Key characteristics:**
- Uses `user_priority_expanded` to find all users with access
- Includes users who have access via parent priorities (hierarchical)
- Batches notifications for efficiency
- Debounces rapid changes to prevent notification storms
- Delivers via WebSocket to connected clients with intelligent queuing

## Common Patterns

### Querying Priorities

```sql
-- Get all priorities for a user (what Flutter does via the API)
SELECT * FROM user_priority WHERE user_id = 'user-id-here';

-- Check if user can access specific priority
SELECT user_has_priority_access('user-id-here', 'priority-id-here');

-- Get all children of a priority
SELECT * FROM priority_child WHERE priority_id = 'parent-id';

-- Get all users who can access a priority
SELECT * FROM user_priority_expanded WHERE priority_id = 'priority-id';
```

### Sharing a Priority

```sql
-- Share priority with contact (via share_priority function)
SELECT share_priority(
    priority_id := 'priority-to-share',
    contact_ids := ARRAY['contact-1', 'contact-2'],
    user_id := 'user-id-here'
);
```

### Removing Access

```sql
-- Soft-delete priority_user entry
UPDATE priority_user
SET archived_at = now()
WHERE user_id = 'user-to-remove' AND priority_id = 'priority-id';

-- Cancel invitation (before user accepts)
UPDATE priority_contact
SET invited_at = NULL
WHERE priority_id = 'priority-id' AND contact_id = 'contact-id';
```

## Design Decisions & Trade-offs

### Why Dual-Path Architecture?

**Alternatives considered:**
1. Single path system where shared priorities appear at same location for everyone
   - ❌ Doesn't support personal organization
   - ❌ Forces rigid structure on all users

2. Separate table for user-specific paths
   - ❌ Complicates queries (always need join)
   - ❌ More storage (one row per user per priority)

**Chosen approach:**
- Actual paths in `priority` table for hierarchy and access
- Visual paths computed on-the-fly in `user_priority` view
- Custom paths only stored when user explicitly customizes (via `priority_settings`)

**Benefits:**
- Flexible: each user organizes shared priorities their way
- Efficient: no duplicate rows, computed paths cached by database
- Maintainable: single source of truth for hierarchy

### Why ltree?

PostgreSQL's ltree extension provides:
- Efficient hierarchical queries: `parent.path @> child.path`
- Path operations: `subpath()`, `nlevel()`, `||` (concatenation)
- Indexing: GiST and GIN indexes for fast path queries
- Built-in functions for path manipulation

Alternative: adjacency list (parent_id foreign key)
- ❌ Requires recursive queries (WITH RECURSIVE)
- ❌ Slower for "all descendants" queries
- ❌ More complex path operations

### Why View-Based Architecture?

Flutter syncs via `user_priority` view (not direct table access):
- ✅ Access control enforced at database level
- ✅ Visual path computation handled transparently
- ✅ Single query returns all data needed by client
- ✅ Changes to underlying structure don't affect client

The trigger `handle_user_priority_upsert` allows INSERT/UPDATE on the view:
- ✅ Maintains encapsulation (client unaware of actual vs visual paths)
- ✅ Translates visual paths to actual paths automatically
- ✅ Validates access during write operations

## Troubleshooting

### Priority not visible to shared user

**Check:**
1. Does `priority_user` entry exist?
   ```sql
   SELECT * FROM priority_user WHERE user_id = 'user-id' AND priority_id = 'priority-id';
   ```

2. Is the priority a descendant of an accessible root?
   ```sql
   SELECT * FROM user_priority_expanded WHERE user_id = 'user-id' AND priority_id = 'priority-id';
   ```

3. Is the priority archived?
   ```sql
   SELECT archived_at FROM priority WHERE id = 'priority-id';
   ```

### Sub-priority showing at wrong level

**Check visual path computation:**
```sql
SELECT
  id, title,
  path AS visual_path,
  (SELECT path FROM priority WHERE priority.id = user_priority.id) AS actual_path
FROM user_priority
WHERE user_id = 'user-id' AND id = 'priority-id';
```

Visual path should be parent's visual path + priority's label, not parent's actual path + label.

### Sync not working

**Check:**
1. Is user_sync entry created?
   ```sql
   SELECT * FROM user_sync WHERE user_id = 'user-id' AND entity = 'priority';
   ```

2. Are sync triggers enabled?
   ```sql
   SELECT tgname, tgenabled FROM pg_trigger WHERE tgname LIKE 'user_sync_priority%';
   ```

3. Check API worker logs for WebSocket delivery

## Related Components

### Database Schema (`libs/db/schema/`)

**Core Tables** (`50-tables/`)
- Priority table definition with ltree paths
- Priority-user relationship table for access grants
- Priority-contact table for sharing invitations
- Priority settings table for user customizations

**Views** (`70-views/`, `90-user-schema/`)
- `priority_child` - Maps priorities to all descendants
- `user.priority_expanded` - Expands access grants to include descendants
- `priority_settings_inherited` - Computes inherited settings from ancestors
- `user.priority` - Main client view with visual paths and upsert trigger

**Functions** (`40-functions/`, `60-functions/`)
- `share_priority()` - Handles priority sharing workflow including extraction
- Path generation functions for ltree operations

**Sync System** (`90-user-schema/`, `95-triggers/`)
- Sync broadcast functions to notify affected users
- Triggers on priority changes to fire sync notifications

### Flutter Client (`apps/plot/`)

**Store Layer** (`lib/store/`)
- Priority entity definition and Drift schema
- Priority queries and creation logic
- Offline-first sync with `user_priority` view

**State Management** (`lib/state/`)
- BLoC for priority state and reactive updates
- Stream-based priority hierarchy

### API Workers (`workers/api/src/`)

**SDK** (`sdk/`)
- Priority creation endpoint (rarely used due to offline-first approach)
- Validates access and generates paths server-side when needed

**Sync System** (`state/`)
- UserSync Durable Object for per-user sync coordination
- Broadcast Durable Object for WebSocket message delivery
- Debouncing and batching logic for efficient updates

## Priority Move Test Cases

This section documents test cases for priority moves. All moves are handled transparently by the `handle_user_priority_upsert` database trigger, which detects path changes and executes the appropriate action (actual move, visual alias, or block).

### Test Case 1: Personal Priority Move (Offline)

**Type**: Actual Move
**Purpose**: Verify offline moves work within personal tree

**Steps**:
1. Disconnect from internet
2. Create "Projects" and "Archive" in personal tree
3. Create "Old Project" with sub-priority "Task" under "Projects"
4. Move "Old Project" (with descendants) to "Archive"
5. Verify local Drift database updated
6. Reconnect to internet
7. Wait for sync

**Expected**:
- ✓ Move succeeds while offline
- ✓ Local visual paths: `personal_root.Archive.Old_Project` and `personal_root.Archive.Old_Project.Task`
- ✓ After sync: Database `priority.path` updated for priority and descendants
- ✓ Other users (if shared) see the change

**Verify in Database**:
```sql
SELECT id, path FROM priority WHERE id = '<old_project_id>';
-- Should show new actual path under Archive
```

### Test Case 2: Shared Priority Move Within Tree (Online)

**Type**: Actual Move
**Purpose**: Verify moves within shared tree update for all users

**Steps**:
1. User A shares "Team Work" with User B
2. User A creates "Active" and "Done" under "Team Work"
3. User A creates "Task 1" with sub-priority "Subtask" under "Active"
4. User A moves "Task 1" to "Done"
5. Check User B's view

**Expected**:
- ✓ Move succeeds
- ✓ Both users see "Task 1" under "Done"
- ✓ Database `priority.path` updated from `team_root.Active.Task_1` to `team_root.Done.Task_1`
- ✓ Subtask path also updated: `team_root.Done.Task_1.Subtask`

**Verify in Database**:
```sql
SELECT id, title, path FROM priority WHERE path <@ '<team_root>';
-- Should show Task 1 and Subtask under Done
```

### Test Case 3: Cross-Tree Move (Online)

**Type**: Actual Move
**Purpose**: Verify moving between different shared roots

**Steps**:
1. User A has access to shared "Design Docs" (root X) and shared "Client Work" (root Y)
2. Create "Mockups" under "Design Docs"
3. Move "Mockups" under "Client Work"
4. Check access for User B who only has access to "Client Work"

**Expected**:
- ✓ Move succeeds
- ✓ Database path changes from `X.Mockups` to `Y.Mockups`
- ✓ User A sees "Mockups" under "Client Work"
- ✓ User B (with "Client Work" access) now sees "Mockups"
- ✓ Users with only "Design Docs" access lose visibility

**Verify in Database**:
```sql
SELECT id, path FROM priority WHERE id = '<mockups_id>';
-- Should show path under Client Work root

SELECT user_id FROM user_priority_expanded WHERE priority_id = '<mockups_id>';
-- Should show users with Client Work access
```

### Test Case 4: Visual Move (Aliasing Shared Under Personal)

**Type**: Visual Move
**Purpose**: Verify aliasing creates visual organization without changing actual paths

**Steps**:
1. User A has shared "Team Docs" (actual path `X`, shared with User B)
2. User A creates personal folder "Clients"
3. User A moves "Team Docs" under "Clients" (visual path becomes `personal_root.Clients.Team_Docs`)
4. User A creates sub-priority "Meeting Notes" under "Team Docs"
5. Check User B's view

**Expected**:
- ✓ Move succeeds
- ✓ User A sees: `Personal Root > Clients > Team Docs`
- ✓ User B sees: `Team Docs` (at root, unchanged)
- ✓ Database: `priority.path` for "Team Docs" unchanged (still `X`)
- ✓ Database: `priority_settings.path` set for User A: `personal_root.Clients.X`
- ✓ "Meeting Notes" appears correctly under "Team Docs" for both users

**Verify in Database**:
```sql
SELECT path FROM priority WHERE id = '<team_docs_id>';
-- Should show original path X (unchanged)

SELECT path FROM priority_settings
WHERE user_id = '<user_a>' AND priority_id = '<team_docs_id>';
-- Should show personal_root.Clients.X

SELECT path FROM user_priority
WHERE user_id = '<user_a>' AND id = '<team_docs_id>';
-- Should show personal_root.Clients.X

SELECT path FROM user_priority
WHERE user_id = '<user_b>' AND id = '<team_docs_id>';
-- Should show X (no alias for User B)
```

### Test Case 5: Actual Move Within Aliased Tree

**Type**: Actual Move (Special Case)
**Purpose**: Verify moves within aliased tree are actual moves, not new aliases

**Setup**:
1. User A has shared "Team" (actual path `X.Y`, shared with User B)
2. User A aliases "Team" under personal "Clients" (visual: `personal_root.Clients.Y`)
3. Create "Team > Projects > Q1 > Task" (actual: `Y.Projects.Q1.Task`)
4. User A sees: `Clients > Y > Projects > Q1 > Task`

**Steps**:
1. User A moves "Task" from "Q1" to directly under "Projects"
   - Old visual path: `personal_root.Clients.Y.Projects.Q1.Task`
   - New visual path: `personal_root.Clients.Y.Projects.Task`
2. Check User B's view

**Expected**:
- ✓ Move succeeds
- ✓ Database: `priority.path` changes from `Y.Projects.Q1.Task` to `Y.Projects.Task` (actual move)
- ✓ User A sees: `Clients > Y > Projects > Task`
- ✓ User B sees: `Y > Projects > Task` (moved for User B too)
- ✓ No new `priority_settings` entry created (existing alias still applies)

**Verify in Database**:
```sql
SELECT path FROM priority WHERE id = '<task_id>';
-- Should show Y.Projects.Task (actual path changed)

SELECT path FROM priority_settings
WHERE user_id = '<user_a>' AND priority_id = '<task_id>';
-- Should return no row (no new alias created)
```

### Test Case 6: Blocked Move - Root Priority

**Type**: Blocked
**Purpose**: Verify root priorities cannot be moved

**Steps**:
1. Try to move personal root priority

**Expected**:
- ✓ Error from trigger: "Cannot move root priority"
- ✓ No database changes

### Test Case 7: Blocked Move - Circular Reference

**Type**: Blocked
**Purpose**: Verify circular references prevented

**Steps**:
1. Create A > B > C hierarchy
2. Try to move A under C

**Expected**:
- ✓ Error: "Cannot move priority to be a descendant of itself"
- ✓ No database changes

### Test Case 8: Blocked Move - Personal to Shared

**Type**: Blocked
**Purpose**: Verify personal priorities cannot be moved into shared trees

**Steps**:
1. User has personal priority "Personal Notes"
2. User has access to shared "Team Docs"
3. Try to move "Personal Notes" under "Team Docs"

**Expected**:
- ✓ Error: "Cannot move personal priority into shared tree"
- ✓ Hint: "Use Share dialog to share a personal priority"
- ✓ No database changes

### Test Case 9: Descendant Cascade in Actual Move

**Type**: Actual Move
**Purpose**: Verify all descendants updated in cascade

**Steps**:
1. Create A > B > C > D > E hierarchy (5 levels deep)
2. Move B to different parent X
3. Verify all paths updated

**Expected**:
- ✓ Database paths:
  - B: `X.B`
  - C: `X.B.C`
  - D: `X.B.C.D`
  - E: `X.B.C.D.E`
- ✓ All descendants maintain hierarchy
- ✓ Visual paths update accordingly for all users

### Test Case 10: Shared Priority Move (Offline then Online)

**Type**: Actual Move (Queued)
**Purpose**: Verify offline changes sync correctly

**Steps**:
1. Share "Team" with another user
2. Create "Team > Active" and "Team > Done"
3. Create "Team > Active > Task"
4. Disconnect from internet
5. Move "Task" to "Done" (local change)
6. Reconnect to internet
7. Wait for sync

**Expected**:
- ✓ Move succeeds locally while offline
- ✓ Local Drift database updated
- ✓ After sync: Trigger processes move
- ✓ Database `priority.path` updated
- ✓ Other user sees the move

### Test Case 11: Multiple Aliased Priorities

**Type**: Visual Move
**Purpose**: Verify multiple shared priorities can be aliased independently

**Steps**:
1. User has access to shared "Team A" and "Team B"
2. User creates personal folders "Client X" and "Client Y"
3. User aliases "Team A" under "Client X"
4. User aliases "Team B" under "Client Y"
5. Verify both aliases work independently

**Expected**:
- ✓ Two separate `priority_settings` entries created
- ✓ User sees proper visual organization
- ✓ Actual paths unchanged
- ✓ Other users unaffected

### Move Type Summary

The system supports three types of moves:

1. **Actual Move**: Updates `priority.path` in database via `move_priority()` function
   - Within personal tree
   - Within shared tree
   - Between different shared roots (cross-tree)
   - Within aliased tree (special case)

2. **Visual Move (Aliasing)**: Sets `priority_settings.path` for current user only
   - Moving shared priority under personal root
   - Creates visual organization without affecting actual hierarchy

3. **Blocked Move**: Operations that violate system constraints
   - Root priorities (cannot move)
   - Circular references (moving to own descendant)
   - Personal to shared (changes ownership model)
