# Link-Level Mentions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move thread visibility mentions from fake "participants" notes to the link/thread level, eliminating empty notes that pollute the activity feed.

**Architecture:** Add a `mentions` uuid[] column to the `thread` table. Update `get_thread_mentions()` and `mentioned_in_thread()` to include thread-level mentions. Add `mentions` field to `NewLinkWithNotes` type, process it in `createLink` → `createThread` pipeline. Update Google Calendar and Outlook Calendar connectors to use link-level mentions instead of participants notes.

**Tech Stack:** PostgreSQL (schema + functions), TypeScript (Twister SDK types, API worker), Connector packages

---

### Task 1: Add `mentions` column to thread table

**Files:**
- Modify: `libs/db/schema/50-tables/24-thread.sql`

- [ ] **Step 1: Add mentions column to thread schema**

In `libs/db/schema/50-tables/24-thread.sql`, add after line 17 (`"icon" text`):

```sql
    "mentions" uuid[]
```

Add a comment after the existing comments:

```sql
COMMENT ON COLUMN "public"."thread"."mentions" IS 'Direct mentions on the thread itself (e.g. calendar attendees for private thread visibility). Aggregated with note mentions by get_thread_mentions().';
```

Add a GIN index for efficient array lookups:

```sql
CREATE INDEX idx_thread_mentions ON "public"."thread" USING gin ("mentions")
WHERE
    mentions IS NOT NULL;
```

- [ ] **Step 2: Commit**

```bash
git add libs/db/schema/50-tables/24-thread.sql
git commit -m "schema: add mentions column to thread table"
```

---

### Task 2: Update `get_thread_mentions()` to include thread-level mentions

**Files:**
- Modify: `libs/db/schema/60-functions/get_thread_mentions.sql`

- [ ] **Step 1: Update function to union thread.mentions**

Replace the full function in `libs/db/schema/60-functions/get_thread_mentions.sql`:

```sql
-- Retrieve all mentions for a thread.
-- Used by thread_x view to aggregate mentions from notes and direct thread mentions.
-- Also includes the thread creator when it's a priority_twist (source-created thread),
-- so the connector chip appears in the NoteEditor for replies.
CREATE OR REPLACE FUNCTION public.get_thread_mentions (p_thread_id uuid)
    RETURNS uuid[]
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        ARRAY_AGG(DISTINCT mention)
    FROM (
        -- Direct mentions on thread (e.g. calendar attendees)
        SELECT unnest(t.mentions) AS mention
        FROM thread t
        WHERE t.id = p_thread_id
            AND t.mentions IS NOT NULL
        UNION
        -- Mentions from notes
        SELECT unnest(n.mentions) AS mention
        FROM note n
        WHERE n.thread_id = p_thread_id
            AND n.archived_at IS NULL
            AND n.mentions IS NOT NULL
        UNION
        -- Include thread creator when it's a source (priority_twist)
        SELECT t.created_by AS mention
        FROM thread t
        WHERE t.id = p_thread_id
            AND EXISTS (SELECT 1 FROM priority_twist pt WHERE pt.id = t.created_by)
    ) sub;
$function$;
```

- [ ] **Step 2: Commit**

```bash
git add libs/db/schema/60-functions/get_thread_mentions.sql
git commit -m "schema: include thread.mentions in get_thread_mentions()"
```

---

### Task 3: Update `mentioned_in_thread()` to check thread-level mentions

**Files:**
- Modify: `libs/db/schema/90-user-schema/06-user_mentioned_in_thread.sql`

- [ ] **Step 1: Update function to also check thread.mentions**

Replace the full function in `libs/db/schema/90-user-schema/06-user_mentioned_in_thread.sql`:

```sql
-- Helper function to check if a user is mentioned in a thread.
-- Checks both direct thread mentions and note mentions.
-- Mentions store contact IDs (not user IDs), so we look up the user's
-- primary contact ID and check that.
CREATE OR REPLACE FUNCTION "user".mentioned_in_thread (user_id uuid, thread_id uuid)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        EXISTS (
            -- Check direct thread mentions
            SELECT 1
            FROM public.thread
            WHERE thread.id = mentioned_in_thread.thread_id
                AND "user".user_contact_id(mentioned_in_thread.user_id) = ANY (thread.mentions)
            UNION ALL
            -- Check note mentions
            SELECT 1
            FROM public.note
            WHERE note.thread_id = mentioned_in_thread.thread_id
                AND note.archived_at IS NULL
                AND "user".user_contact_id(mentioned_in_thread.user_id) = ANY (note.mentions)
        );
$function$;
```

- [ ] **Step 2: Commit**

```bash
git add libs/db/schema/90-user-schema/06-user_mentioned_in_thread.sql
git commit -m "schema: check thread.mentions in mentioned_in_thread()"
```

---

### Task 4: Update `upsert_thread` to handle mentions

**Files:**
- Modify: `libs/db/schema/90-user-schema/80-upsert_thread.sql`

- [ ] **Step 1: Add mentions to INSERT and ON CONFLICT clauses**

In `libs/db/schema/90-user-schema/80-upsert_thread.sql`, update the INSERT statement (line 126) to include `mentions` in the column list and values:

Change the INSERT column list from:
```sql
INSERT INTO thread (id, created_by, priority_id, title, preview, updated_by, sync_depth, private, draft, key, icon)
```
to:
```sql
INSERT INTO thread (id, created_by, priority_id, title, preview, updated_by, sync_depth, private, draft, key, icon, mentions)
```

Add the mentions value at the end of the VALUES clause (after the `icon` value):
```sql
, COALESCE(
    (SELECT array_agg(x::uuid) FROM jsonb_array_elements_text(p_thread -> 'mentions') AS x),
    (SELECT array_agg(x::uuid) FROM jsonb_array_elements_text(p_defaults -> 'mentions') AS x),
    NULL
  )
```

Note: JSONB arrays can't be directly cast to `uuid[]`, so we use `jsonb_array_elements_text()` to unwrap the array elements and `array_agg(x::uuid)` to reassemble as `uuid[]`. When the key is absent, `->` returns NULL and `jsonb_array_elements_text(NULL)` returns no rows, so `array_agg` returns NULL — correct fallback behavior.

Add the mentions upsert handling in the ON CONFLICT DO UPDATE SET block, after the `icon` case (before `archived_at`):

```sql
            mentions = CASE WHEN v_is_archived THEN
                COALESCE(
                    (SELECT array_agg(x::uuid) FROM jsonb_array_elements_text(p_thread -> 'mentions') AS x),
                    (SELECT array_agg(x::uuid) FROM jsonb_array_elements_text(p_defaults -> 'mentions') AS x),
                    thread.mentions
                )
            ELSE
                CASE WHEN p_thread ? 'mentions' THEN
                    (SELECT array_agg(x::uuid) FROM jsonb_array_elements_text(p_thread -> 'mentions') AS x)
                ELSE
                    thread.mentions
                END
            END,
```

- [ ] **Step 2: Commit**

```bash
git add libs/db/schema/90-user-schema/80-upsert_thread.sql
git commit -m "schema: handle mentions in upsert_thread"
```

---

### Task 5: Generate and apply migrations

- [ ] **Step 1: Generate migration**

```bash
pnpm gen-migration -- add_thread_mentions
```

- [ ] **Step 2: Apply migration to local database**

```bash
pnpm apply-migrations
```

- [ ] **Step 3: Verify schema is in sync**

```bash
pnpm diff-schema-migrations
```

Expected: No differences.

- [ ] **Step 4: Regenerate TypeScript types**

```bash
pnpm types
```

- [ ] **Step 5: Commit generated files**

```bash
git add libs/db/migrations/ libs/db/src/types.ts
git commit -m "migration: add thread mentions column and update functions"
```

---

### Task 6: Add `mentions` to Twister SDK types

**Files:**
- Modify: `public/twister/src/plot.ts`

- [ ] **Step 1: Add mentions field to NewLink type**

In `public/twister/src/plot.ts`, add `mentions` to the `NewLink` type. After the `private` field (line 950), add:

```typescript
    /**
     * Contacts mentioned on the thread for visibility in private threads.
     * Use this instead of creating notes solely for mentions (e.g. calendar attendees).
     * These mentions are set directly on the thread, not derived from notes.
     */
    mentions?: NewActor[];
```

Also update the JSDoc on the existing `private` field (line 946-949) to reference mentions:

```typescript
    /**
     * Whether the thread is private (only visible to creator and mentioned users).
     * When true, thread visibility is restricted to the twist that created it
     * and any users mentioned in the thread's notes or via the `mentions` field.
     */
```

- [ ] **Step 2: Build Twister to verify types compile**

```bash
cd public/twister && pnpm build
```

- [ ] **Step 3: Commit**

```bash
cd /Users/kris.braun/code/plot
git -C public add twister/src/plot.ts twister/dist/
git -C public commit -m "feat: add mentions field to NewLink type for thread-level visibility"
```

---

### Task 7: Create Twister changeset

**Files:**
- Create: `public/.changeset/thread-level-mentions.md`

- [ ] **Step 1: Create changeset**

Create `public/.changeset/thread-level-mentions.md`:

```markdown
---
"@plotday/twister": minor
---

Added: `mentions` field on `NewLink` / `NewLinkWithNotes` for setting thread-level mentions directly, without requiring a note. Useful for private thread visibility (e.g. calendar event attendees).
```

- [ ] **Step 2: Validate changeset**

```bash
cd public && pnpm validate-changesets
```

- [ ] **Step 3: Commit**

```bash
cd /Users/kris.braun/code/plot
git -C public add .changeset/thread-level-mentions.md
git -C public commit -m "changeset: add thread-level mentions"
```

---

### Task 8: Process link-level mentions in createLink

**Files:**
- Modify: `workers/api/src/twist/tools/plot/link.ts`
- Modify: `workers/api/src/twist/tools/plot/thread-helpers.ts`

- [ ] **Step 1: Pass mentions through createLink to threadData**

In `workers/api/src/twist/tools/plot/link.ts`, in the `createLink` function, add mentions to the `threadData` object (after line 51, the `private` spread):

```typescript
      ...(link.mentions ? { mentions: link.mentions } : {}),
```

- [ ] **Step 2: Process mentions in prepareThreadForDb**

In `workers/api/src/twist/tools/plot/thread-helpers.ts`, in the `prepareThreadForDb` function, add mentions processing after the author resolution block (after line 902). The mentions need to be resolved from `NewActor[]` to `ActorId[]` (uuid strings) before being stored in the DB:

```typescript
  // Process thread-level mentions (e.g. calendar attendees for private thread visibility)
  let mentionIds: string[] | null = null;
  if ("mentions" in activity && (activity as any).mentions) {
    const resolved = await processNewActorArray(
      plot,
      (activity as any).mentions,
      targetPriorityId
    );
    if (resolved.length > 0) {
      mentionIds = resolved as string[];
    }
  }
```

Then include `mentionIds` in the `defaults` object (after the `sync_depth` line, around line 913):

```typescript
    ...(mentionIds ? { mentions: mentionIds } : {}),
```

And in the upsert fields (after `icon` handling, around line 963):

```typescript
    if (mentionIds !== null) {
      upsertFields.mentions = mentionIds;
    }
```

Note: The mentions array flows through the `upsert_thread` RPC as part of the JSONB parameters (`p_thread`/`p_defaults`). The SQL function uses `(p_thread -> 'mentions')::uuid[]` to extract the JSONB array and cast it to `uuid[]`.

- [ ] **Step 3: Build API worker to verify compilation**

```bash
pnpm --filter @plotday/api build
```

- [ ] **Step 4: Commit**

```bash
git add workers/api/src/twist/tools/plot/link.ts workers/api/src/twist/tools/plot/thread-helpers.ts
git commit -m "feat: process link-level mentions in createLink pipeline"
```

---

### Task 9: Update Google Calendar connector

**Files:**
- Modify: `public/connectors/google-calendar/src/google-calendar.ts`

- [ ] **Step 1: Move mentions from notes to link level**

In `public/connectors/google-calendar/src/google-calendar.ts`, replace the notes/mentions block (lines 867-883) with:

```typescript
          // Add mentions to description note if it exists (for note-level visibility)
          if (descriptionNote && attendeeMentions.length > 0) {
            (descriptionNote as any).mentions = attendeeMentions;
          }

          // Build notes array: only include description note if it has content
          const notes = descriptionNote ? [descriptionNote] : [];
```

Then add `mentions` to the `link` object (around line 896, after `private: true`):

```typescript
            mentions: attendeeMentions.length > 0 ? attendeeMentions : undefined,
```

This removes the "participants" note entirely. When there IS a description note, it still carries mentions (for backward compat with existing threads). The link-level mentions handle the visibility case.

- [ ] **Step 2: Build connector to verify**

```bash
cd public/connectors/google-calendar && pnpm build
```

- [ ] **Step 3: Commit**

```bash
cd /Users/kris.braun/code/plot
git -C public add connectors/google-calendar/src/google-calendar.ts
git -C public commit -m "fix: use link-level mentions instead of empty participants notes"
```

---

### Task 10: Update Outlook Calendar connector

**Files:**
- Modify: `public/connectors/outlook-calendar/src/outlook-calendar.ts`

- [ ] **Step 1: Move mentions from notes to link level**

In `public/connectors/outlook-calendar/src/outlook-calendar.ts`, replace the notes/mentions block (lines 561-571) with:

```typescript
        // Add mentions to description note if it exists
        if (descriptionNote && attendeeMentions.length > 0) {
          (descriptionNote as any).mentions = attendeeMentions;
        }

        // Build notes array: only include description note if it has content
        const notes = descriptionNote ? [descriptionNote] : [];
```

Then add `mentions` to the `linkWithNotes` object (around line 578, after `private: true`):

```typescript
          mentions: attendeeMentions.length > 0 ? attendeeMentions : undefined,
```

- [ ] **Step 2: Build connector to verify**

```bash
cd public/connectors/outlook-calendar && pnpm build
```

- [ ] **Step 3: Commit**

```bash
cd /Users/kris.braun/code/plot
git -C public add connectors/outlook-calendar/src/outlook-calendar.ts
git -C public commit -m "fix: use link-level mentions instead of empty participants notes"
```

---

### Task 11: Lint and finalize

- [ ] **Step 1: Run lint across changed packages**

```bash
pnpm --filter @plotday/api lint
cd public && pnpm --filter @plotday/twister lint && pnpm --filter @plotday/connector-google-calendar lint && pnpm --filter @plotday/connector-outlook-calendar lint
```

- [ ] **Step 2: Build all changed packages**

```bash
cd public/twister && pnpm build
pnpm --filter @plotday/api build
cd public/connectors/google-calendar && pnpm build
cd public/connectors/outlook-calendar && pnpm build
```

- [ ] **Step 3: Run finalize checklist**

Use `/finalize` to verify all changes are complete and correct.
