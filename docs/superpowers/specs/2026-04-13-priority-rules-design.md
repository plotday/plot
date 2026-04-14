# Priority Rules for Thread Classification

## Context

The current thread-to-priority matching system uses `pickPriority` / `PickPriorityConfig` in the Twister SDK, which lets connectors customize matching via embedding similarity on links. This is both too complex (connectors shouldn't tune matching) and insufficient (users can't express their own rules). The `refile_threads_like` function does heuristic batch moves when users relocate threads, but the heuristics are opaque and non-configurable.

**Problem:** Users have no control over how threads are classified into priorities. Connectors have too much control via `PickPriorityConfig`. The matching algorithm is implicit and unpredictable.

**Solution:** Replace with explicit, user-defined **priority rules** that are channel-scoped, evaluated in precedence order, and created via the MoveThreadToPriority modal. Move embeddings from the link table to the thread table. Remove `pickPriority` from the SDK entirely.

## 1. Database Schema

### 1.1 `thread` table — add embedding

Add `embedding halfvec(384)` to the thread table with an HNSW index. Generated at thread creation from title (if user-provided) + initial notes content. The `user.thread` view exposes `has_embedding boolean` (not the vector itself — too large to sync).

### 1.2 New `priority_rule` table

```sql
CREATE TABLE "public"."priority_rule" (
    "id" uuid PRIMARY KEY DEFAULT uuidv7() NOT NULL,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES public."user" (id) ON DELETE CASCADE,
    "priority_id" uuid NOT NULL REFERENCES public.priority (id) ON DELETE CASCADE,
    "channel_id" bigint REFERENCES public.channel (id) ON DELETE CASCADE,
    "type" text NOT NULL CHECK (type IN ('content', 'contact_topics', 'channel')),
    "embedding" halfvec(384),
    "criteria" jsonb,
    "label" text,
    "anchor_thread_id" uuid REFERENCES public.thread (id) ON DELETE SET NULL
);
```

| Column | Purpose |
|--------|---------|
| `channel_id` | FK to `channel.id` (bigint). NULL = user-created threads (no connector). |
| `type` | Rule type. Precedence: `content` > `contact_topics` > `channel`. |
| `embedding` | Frozen snapshot for content rules. Cosine similarity ≥ 0.7 threshold. |
| `criteria` | `{topics: [uuid], contacts: [uuid]}` for contact_topics rules. Match = any overlap. |
| `label` | Human-readable label (e.g. "Similar to 'Deploy pipeline fix'"). |
| `anchor_thread_id` | The thread that inspired this rule. ON DELETE SET NULL — rule survives. |

Indexes: `(user_id, channel_id)` for lookup, `(priority_id)` for reverse lookup, HNSW on `embedding`, `(updated_at)` for sync.

### 1.3 `thread_priority` — simplify

Remove `matched`, `refile_batch_id`, `previous_priority_id`. The table becomes:

```sql
(thread_id uuid, user_id uuid, priority_id uuid, created_at timestamptz, updated_at timestamptz)
```

The `matched` distinction is replaced by whether a `priority_rule` filed the thread. Undo = delete the rule + re-evaluate affected threads.

### 1.4 Remove from `link`

Drop `embedding halfvec(384)`, `match jsonb`, and the HNSW index on `link.embedding`. Data is migrated to `thread.embedding` first.

## 2. Classification Function

### `classify_thread_for_user`

Accepts either an existing thread ID (reads from DB) or raw parameters (for pre-insert classification):

```sql
classify_thread_for_user(
    p_user_id uuid,
    p_thread_id uuid DEFAULT NULL,
    p_embedding halfvec DEFAULT NULL,
    p_topics uuid[] DEFAULT NULL,
    p_contacts uuid[] DEFAULT NULL,
    p_channel_id bigint DEFAULT NULL
)
RETURNS uuid  -- the target priority_id
```

Evaluation order:

1. **Content rules** for the thread's channel — cosine similarity ≥ 0.7 against rule.embedding. Highest similarity wins.
2. **Contact/topics rules** for the thread's channel — any overlap between thread topics/contacts and rule criteria. Oldest rule wins ties.
3. **Channel rule** — catch-all default for the channel. Oldest rule wins.
4. **Fallback** — user's root priority (oldest non-archived root).

Channel resolution path: thread → link(channel_id text, created_by uuid) → channel(twist_instance_id, channel_id) → channel.id (bigint). `IS NOT DISTINCT FROM` handles NULL channel correctly.

### `apply_priority_rule`

Retroactively applies a newly created rule to existing threads:

```sql
apply_priority_rule(p_rule_id uuid, p_max_moves int DEFAULT 100)
RETURNS TABLE (thread_id uuid, old_priority_id uuid)
```

Finds threads matching the rule's type/criteria/channel that are currently filed in a different priority, and moves them. Only moves threads where no higher-precedence rule already applies (to avoid overriding content rules with a new channel rule).

### `match_priority_for_user` — backward compat wrapper

Kept as a thin wrapper that calls `classify_thread_for_user`. Existing callers (triggers, old code) continue to work during the transition.

## 3. Twister SDK Changes

Remove from `public/twister/src/plot.ts`:
- `PickPriorityConfig` type (lines 471-475)
- `pickPriority` from `NewThread` union type (line 508)
- `pickPriority` from `NewLink` type (line 1009)
- All JSDoc referencing pickPriority

Remove from `public/twists/message-tasks/src/index.ts`:
- `pickPriority: { content: 50, mentions: 50 }` (line 479)

Changeset: minor bump (breaking — removes exported type).

## 4. API Changes

### 4.1 `prepareThreadForDb` (thread-helpers.ts)

Remove the entire pickPriority branch (lines 794-858) and the fallback match_priority_for_user call (lines 860-886). Replace with:

1. Generate embedding from title + first note content using `@cf/baai/bge-small-en-v1.5`
2. Resolve channel_id (from link data if available)
3. Call `classify_thread_for_user` with the embedding, topics, contacts, channel_id
4. Return the classified priority_id + store embedding on the thread row

### 4.2 `POST /sync/threads` (threads.ts)

- Remove the `refile_threads_like` / `undo_refile_batch` calls (lines 201-221)
- Remove the `auto_file` block (lines 226-255)
- For new non-draft threads from the app: generate embedding, classify, update thread_priority if better match found
- For explicit moves: just move the thread. Rule creation is a separate API call.

### 4.3 New `POST /sync/priority-rules`

Standard sync push endpoint — receives rules from the app's local Drift table during sync.

```typescript
// Input: rule data (same shape as priority_rule table row)
// 1. Insert priority_rule row into server DB
// 2. Call apply_priority_rule(rule_id) in a transaction for retroactive moves
// 3. Return success (app deletes local row after successful sync)
```

### 4.4 `link.ts`

Remove `pickPriority` / `match` handling from link defaults and upsert (lines 57-58, 173-174, 402).

## 5. Flutter App Changes

### 5.1 Thread model

Add `hasEmbedding` boolean column to the Drift thread table (from `user.thread` view's `a.embedding IS NOT NULL AS has_embedding`). Bump Drift schema version.

### 5.2 MoveThreadToPriority modal

Replace the current flat priority list with a two-step flow:

**Step 1:** User picks a target priority (existing behavior).

**Step 2:** Show rule creation options based on thread context:

```
Move all [Linear > Issues] threads about something similar
  ↳ only if has_embedding AND channel exists

Move all [Linear > Issues] threads with the TOPIC topic
  ↳ only if thread has exactly one topic

Move all [Linear > Issues] threads with similar people
  ↳ only if thread has at least one contact OR multiple topics

Move all threads from [Linear > Issues]
  ↳ only if thread is from a connector channel

Move just this thread
  ↳ always shown
```

For user-created threads (no channel), options exclude channel context and the channel-default option.

**Implementation:** After `MoveToPriority` executes, return a `CommandShowCommands` that displays the rule options. Each option inserts a `priority_rule` row into the local Drift table. The thread's channel is resolved from synced link + channel data already available in the app.

### 5.3 Rule sync — ephemeral local storage

Priority rules are stored locally in a Drift `priority_rule` table and synced one-way to the server, like other sync entities. This ensures move-with-rule works offline.

**Lifecycle:**
1. User picks a rule option → app inserts row into local `priority_rule` table
2. Sync push sends the rule to `POST /sync/priority-rules` when online
3. Server inserts the rule and runs `apply_priority_rule` retroactively
4. After successful sync, the app **deletes the local row** — rules are ephemeral locally, only the server keeps them long-term

The immediate thread move (the one the user just triggered) is saved locally as a normal `thread_priority` change. The rule only needs to reach the server for retroactive moves and future classification. Threads arriving while offline aren't classified by rules (classification runs server-side), but will be reclassified on sync.

**Drift table:** Same columns as the server `priority_rule` table (id, user_id, priority_id, channel_id, type, embedding, criteria, label, anchor_thread_id). No `updated_at`/`created_at` needed locally since rows are deleted after sync.

## 6. Embedding Generation

Generated at thread creation using `@cf/baai/bge-small-en-v1.5` (384-dim, already in use):
- **Connector threads:** title + first note content (from `prepareThreadForDb`)
- **User-created threads:** user-provided title + preview content (from `POST /sync/threads`)
- **Content rules:** frozen snapshot from `thread.embedding` at rule creation time

Only generated at creation, not updated on edits (v1 simplification).

## 7. Migration Strategy

### Phase 1: Additive (single migration)

1. Add `thread.embedding halfvec(384)` + HNSW index
2. Create `priority_rule` table with all indexes
3. Create `classify_thread_for_user` function
4. Create `apply_priority_rule` function
5. Rewrite `match_priority_for_user` as wrapper around `classify_thread_for_user`
6. Update `user.thread` view to include `has_embedding`
7. Update `file_thread_priority_peers` trigger to call `classify_thread_for_user`
8. Data migration: backfill `thread.embedding` from `link.embedding`

### Phase 2: Contractional (after new workers deployed)

1. Remove `link.embedding`, `link.match` columns + HNSW index
2. Remove `thread_priority.matched`, `.refile_batch_id`, `.previous_priority_id` + refile_batch index
3. Drop `refile_threads_like`, `undo_refile_batch`, `find_matching_threads_scored` functions

## 8. Three Classification Scenarios

All use `classify_thread_for_user`:

1. **Connector creates a link** → thread created → `prepareThreadForDb` generates embedding → calls `classify_thread_for_user` with thread data → files thread under matched priority
2. **User creates/shares a thread** → `POST /sync/threads` → generates embedding → calls `classify_thread_for_user` → files thread (user may have specified explicit priority, which takes precedence)
3. **User moves a thread + creates rule** → rule saved locally in Drift → synced to `POST /sync/priority-rules` when online → `apply_priority_rule` retroactively moves matching threads → future threads classified by the rule via scenario 1/2 → local rule row deleted after sync

## 9. Verification Plan

- `pnpm gen-migration -- add_priority_rules_and_thread_embedding` + `pnpm apply-migrations` + `pnpm types`
- psql: verify `classify_thread_for_user` returns expected priority for test threads
- psql: verify `apply_priority_rule` moves correct threads
- curl: test `POST /sync/priority-rules` endpoint
- curl: test `POST /sync/threads` generates embedding and classifies
- Flutter: test MoveThreadToPriority modal shows correct options
- Flutter: test rule creation moves threads retroactively
- Verify connector-created threads still file correctly without pickPriority
- `pnpm lint` in all changed packages

## Critical Files

- `libs/db/schema/50-tables/24-thread.sql` — add embedding
- `libs/db/schema/50-tables/25-link.sql` — remove embedding, match
- `libs/db/schema/50-tables/27-thread_priority.sql` — simplify
- New: `libs/db/schema/50-tables/28-priority_rule.sql`
- `libs/db/schema/60-functions/match_priority_for_user.sql` — rewrite as wrapper
- New: `libs/db/schema/60-functions/classify_thread_for_user.sql`
- New: `libs/db/schema/60-functions/apply_priority_rule.sql`
- `libs/db/schema/60-functions/find_matching_threads_scored.sql` — remove
- `libs/db/schema/60-functions/refile_threads_like.sql` — remove
- `libs/db/schema/90-user-schema/30-thread.sql` — add has_embedding
- `libs/db/schema/95-triggers/22-thread_priority_peers.sql` — update
- `public/twister/src/plot.ts` — remove PickPriorityConfig
- `public/twists/message-tasks/src/index.ts` — remove pickPriority
- `workers/api/src/twist/tools/plot/thread-helpers.ts` — rewrite prepareThreadForDb
- `workers/api/src/twist/tools/plot/link.ts` — remove match handling
- `workers/api/src/app/sync/threads.ts` — remove auto_file/refile, add priority-rules endpoint
- `apps/plot/lib/command/thread.dart` — redesign MoveThreadToPriority
- `apps/plot/lib/store/thread.dart` — add hasEmbedding column
