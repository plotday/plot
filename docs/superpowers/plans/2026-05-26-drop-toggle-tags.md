# Drop Toggle Tags Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Project convention:** per `AGENTS.md`, NEVER commit without explicit user permission. This plan deliberately omits `git commit` steps; the user will direct when to commit. Group changes naturally so a single commit at the end is sensible.

**Goal:** Retire the 10 user-facing toggle tags into per-user emoji reactions, reassign `Tag.twist` (109 → 12) into the compute range, drop `'toggle'` dispatch branches from the database functions.

**Architecture:** One DB migration (backfill into `note_reaction` / `thread_reaction`, reassign tag 109 → 12, archive source rows, regenerate function bodies via Atlas). Three Postgres functions updated to drop toggle branches and add a tag-12 exception to the compute-rejection gate. Flutter Tag enum loses 10 entries; `Tag.twist` moves to id 12 with `TagType.compute`. Drift schema bump mirrors the server migration locally. One API cron query updated.

**Tech Stack:** PostgreSQL 18.1, Atlas migrations, Kysely (TypeScript), Cloudflare Workers, Flutter / Dart, Drift (SQLite), pnpm workspaces.

**Spec:** `docs/superpowers/specs/2026-05-26-drop-toggle-tags-design.md`

---

## File Structure

**Modified — DB schema (changes generate into Atlas migration automatically):**
- `libs/db/schema/40-functions/30-tag.sql` — `get_tag_type` drops toggle + count branches.
- `libs/db/schema/90-user-schema/85-user-sync-upserts.sql` — `upsert_thread_tag` / `upsert_note_tag` allow `p_tag_id = 12` past the compute gate.
- `libs/db/schema/90-user-schema/10-update_thread_tags.sql` — drops toggle branch in the removal path; allows tag 12 past the compute gate.
- `libs/db/schema/90-user-schema/11-update_note_tags.sql` — same as above for notes.

**Created — Migration:**
- `libs/db/migrations/<atlas-timestamp>_drop_toggle_tags.sql` — Atlas-generated DDL + appended data-migration phases (reaction backfill, twist tag reassignment, source-row archive).
- `libs/db/migrations/atlas.sum` — Atlas updates this automatically on `pnpm apply-migrations`.

**Regenerated (do not edit by hand):**
- `libs/db/src/types.ts` — `pnpm types` runs automatically after migration apply.

**Modified — API worker:**
- `workers/api/src/index.ts:313` — cron `tag_id = 109` → `12`, comment update.

**Modified — Flutter app:**
- `apps/plot/lib/store/tag.dart` — delete 10 toggle entries; reposition `twist` as compute with id 12.
- `apps/plot/lib/store/store.dart` — bump `Store.schemaVersion`, add Drift migration arm.
- Drift `.g.dart` files — regenerated via `flutter pub run build_runner build`.

---

## Task 1: Rewrite `get_tag_type` to drop toggle and count branches

**Files:**
- Modify: `libs/db/schema/40-functions/30-tag.sql`

- [ ] **Step 1: Replace the function body**

Replace the entire contents of `libs/db/schema/40-functions/30-tag.sql` with:

```sql
-- Function to get tag type based on tag_id ranges.
-- After the toggle-tag retirement, the live ranges are:
--   1-99    → compute (system-managed indicators + the per-user writable
--             set: todo, done, twist)
--   1000+   → count   (per-user reactions; superseded by note_reaction
--             / thread_reaction tables but dispatch paths remain live
--             until the count-tag retirement follow-up lands)
-- The retired toggle range (100-999) raises — those rows were backfilled
-- into reactions and archived. The 'toggle' enum value is kept in the
-- tag_type type for backwards compatibility with old clients during the
-- rollout window; it will be dropped in a follow-up migration.
CREATE OR REPLACE FUNCTION get_tag_type (tag_id integer)
    RETURNS tag_type
    LANGUAGE plpgsql
    IMMUTABLE
    AS $$
BEGIN
    IF tag_id BETWEEN 1 AND 99 THEN
        RETURN 'compute'::tag_type;
    ELSIF tag_id >= 1000 THEN
        RETURN 'count'::tag_type;
    END IF;
    RAISE EXCEPTION 'invalid tag_id: %', tag_id;
END;
$$;
```

- [ ] **Step 2: Sanity-check by reading the file back**

Run: `head -20 libs/db/schema/40-functions/30-tag.sql`
Expected: the new function body, no leftover toggle/count branches.

---

## Task 2: Update `upsert_thread_tag` and `upsert_note_tag` to allow tag 12 past the compute gate

**Files:**
- Modify: `libs/db/schema/90-user-schema/85-user-sync-upserts.sql`

The two functions currently raise `'Cannot add computed tag (tag_id: %)'` for any tag with `v_tag_type = 'compute'`. We need to allow tag 12 (Twist), which is now in the compute range but is runtime-managed indicator state.

- [ ] **Step 1: Locate the `upsert_thread_tag` compute-gate check**

The relevant lines (around line 56-59 in current file):

```sql
    v_tag_type := get_tag_type(p_tag_id);
    IF v_tag_type = 'compute' THEN
        RAISE EXCEPTION 'Cannot add computed tag (tag_id: %)', p_tag_id;
    END IF;
```

- [ ] **Step 2: Edit `upsert_thread_tag` to allow tag 12**

Replace the block from Step 1 with:

```sql
    v_tag_type := get_tag_type(p_tag_id);
    -- Tag 12 (Twist) is runtime-managed indicator state. It lives in the
    -- compute range but is written by the twist runtime to mark a note as
    -- in-progress; it is not a user-set computed tag. Allow it through.
    IF v_tag_type = 'compute' AND p_tag_id != 12 THEN
        RAISE EXCEPTION 'Cannot add computed tag (tag_id: %)', p_tag_id;
    END IF;
```

- [ ] **Step 3: Locate and edit the same gate in `upsert_note_tag`**

The current block (around line 138-141):

```sql
    v_tag_type := get_tag_type(p_tag_id);
    IF v_tag_type = 'compute' THEN
        RAISE EXCEPTION 'Cannot add computed tag (tag_id: %)', p_tag_id;
    END IF;
```

Replace with the same tag-12 carve-out:

```sql
    v_tag_type := get_tag_type(p_tag_id);
    -- Tag 12 (Twist) is runtime-managed indicator state. It lives in the
    -- compute range but is written by the twist runtime to mark a note as
    -- in-progress; it is not a user-set computed tag. Allow it through.
    IF v_tag_type = 'compute' AND p_tag_id != 12 THEN
        RAISE EXCEPTION 'Cannot add computed tag (tag_id: %)', p_tag_id;
    END IF;
```

- [ ] **Step 4: Verify no other changes**

Run: `grep -n "v_tag_type = 'compute'" libs/db/schema/90-user-schema/85-user-sync-upserts.sql`
Expected: two matches, each followed by `AND p_tag_id != 12`.

---

## Task 3: Update `update_thread_tags` — allow tag 12, drop toggle removal branch

**Files:**
- Modify: `libs/db/schema/90-user-schema/10-update_thread_tags.sql`

- [ ] **Step 1: Allow tag 12 past the compute gate (around line 64-68)**

Current:

```sql
            -- Prevent insertion of computed tags (tag_id 1-99)
            -- Exception: 'done' (3) acts as a toggle tag on threads
            IF current_tag_type = 'compute' AND tag_id_int != 3 THEN
                RAISE EXCEPTION 'Cannot add computed tag (tag_id: %) - these tags are calculated from thread state', tag_id_int;
            END IF;
```

Replace with:

```sql
            -- Prevent insertion of computed tags (tag_id 1-99) except those
            -- whitelisted as writable:
            --   3  = 'done' (acts as a toggle on threads)
            --   12 = 'twist' (runtime-managed Twisting indicator)
            IF current_tag_type = 'compute' AND tag_id_int NOT IN (3, 12) THEN
                RAISE EXCEPTION 'Cannot add computed tag (tag_id: %) - these tags are calculated from thread state', tag_id_int;
            END IF;
```

- [ ] **Step 2: Drop the toggle branch in the removal path (around line 97-110)**

Current:

```sql
        ELSE
            -- Removing a tag - use update to soft delete existing records
            IF current_tag_type = 'toggle' OR tag_id_int = 3 THEN
                -- For toggle tags, remove all users' tags
                UPDATE
                    thread_tag
                SET
                    archived_at = now(),
                    updated_by = p_client_id
                WHERE
                    thread_id = p_thread_id
                    AND tag_id = tag_id_int
                    AND (occurrence IS NOT DISTINCT FROM p_occurrence)
                    AND archived_at IS NULL;
            ELSE
```

Replace with:

```sql
        ELSE
            -- Removing a tag - use update to soft delete existing records
            IF tag_id_int = 3 THEN
                -- 'done' acts as a toggle on threads: clearing it clears
                -- the row for every actor.
                UPDATE
                    thread_tag
                SET
                    archived_at = now(),
                    updated_by = p_client_id
                WHERE
                    thread_id = p_thread_id
                    AND tag_id = tag_id_int
                    AND (occurrence IS NOT DISTINCT FROM p_occurrence)
                    AND archived_at IS NULL;
            ELSE
```

The trailing `ELSE` block (per-actor sibling archive) is unchanged and now handles tag 12 clears via the actor's sibling set — appropriate because `Tag.twist` is keyed by `twist_instance_id` as the actor, not a user contact, and its sibling set is just itself.

- [ ] **Step 3: Verify**

Run: `grep -n "current_tag_type = 'toggle'" libs/db/schema/90-user-schema/10-update_thread_tags.sql`
Expected: no matches.

Run: `grep -n "NOT IN (3, 12)" libs/db/schema/90-user-schema/10-update_thread_tags.sql`
Expected: one match in the compute-gate block.

---

## Task 4: Update `update_note_tags` — allow tag 12, drop toggle removal branch

**Files:**
- Modify: `libs/db/schema/90-user-schema/11-update_note_tags.sql`

- [ ] **Step 1: Allow tag 12 past the compute gate (around line 76-78)**

Current:

```sql
            -- Validate computed tags for notes
            -- Notes can have 'todo' (1) and 'done' (3) tags for per-user assignment/completion
            -- But not 'archived' (4), 'attachment' (5), 'link' (6) - those are computed
            IF current_tag_type = 'compute' AND tag_id_int NOT IN (1, 3) THEN
                RAISE EXCEPTION 'Cannot add computed tag (tag_id: %) - this tag is calculated from note state', tag_id_int;
            END IF;
```

Replace with:

```sql
            -- Validate computed tags for notes. Writable compute tags:
            --   1  = 'todo' (per-user assignment)
            --   3  = 'done' (per-user completion)
            --   12 = 'twist' (runtime-managed Twisting indicator)
            -- Others (archived, attachment, link, private, unread, task, reading)
            -- are calculated from note state and cannot be written directly.
            IF current_tag_type = 'compute' AND tag_id_int NOT IN (1, 3, 12) THEN
                RAISE EXCEPTION 'Cannot add computed tag (tag_id: %) - this tag is calculated from note state', tag_id_int;
            END IF;
```

- [ ] **Step 2: Adjust cross-user targeting allowance for tag 12 (around line 82-85)**

Current:

```sql
            -- Validate cross-user targeting: only allow for compute tags 1, 3 (todo, done).
            -- Treat any of the caller's linked contacts as "self" — a target is
            -- another user iff none of its linked-contact siblings overlap the caller's.
            IF NOT (target_sibling_ids && caller_sibling_ids)
               AND (current_tag_type != 'compute' OR tag_id_int NOT IN (1, 3)) THEN
                RAISE EXCEPTION 'Cannot modify this tag for other users (tag_id: %)', tag_id_int;
            END IF;
```

Replace with:

```sql
            -- Validate cross-user targeting: only allow for the per-user compute
            -- tags 1 (todo), 3 (done), and 12 (twist — set with the twist_instance_id
            -- as the target actor, not a user contact).
            IF NOT (target_sibling_ids && caller_sibling_ids)
               AND (current_tag_type != 'compute' OR tag_id_int NOT IN (1, 3, 12)) THEN
                RAISE EXCEPTION 'Cannot modify this tag for other users (tag_id: %)', tag_id_int;
            END IF;
```

- [ ] **Step 3: Drop the toggle branch in the removal path (around line 129-156)**

Current:

```sql
            ELSE
                -- Removing a tag - use update to soft delete existing records
                IF current_tag_type = 'toggle' THEN
                    -- For toggle tags, remove all users' tags
                    UPDATE
                        note_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        note_id = p_note_id
                        AND tag_id = tag_id_int
                        AND archived_at IS NULL;
                ELSE
                    -- For count/compute tags, archive every row for the target
                    -- actor's linked-contact siblings — clearing one alias must
                    -- clear all of them.
                    UPDATE
                        note_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        note_id = p_note_id
                        AND tag_id = tag_id_int
                        AND actor_id = ANY(target_sibling_ids)
                        AND archived_at IS NULL;
                END IF;
```

Replace with:

```sql
            ELSE
                -- Removing a tag - archive every row for the target actor's
                -- linked-contact siblings. With toggle tags retired, every
                -- remaining tag (count + the per-user compute set) is
                -- per-actor, so this is the only branch we need.
                UPDATE
                    note_tag
                SET
                    archived_at = now(),
                    updated_by = p_client_id
                WHERE
                    note_id = p_note_id
                    AND tag_id = tag_id_int
                    AND actor_id = ANY(target_sibling_ids)
                    AND archived_at IS NULL;
```

(The `END IF` closing the inner toggle/else block also disappears — make sure the existing `END IF;` count is balanced after the edit. There were two `END IF;` around the toggle branch; one is now removed along with its `IF`.)

- [ ] **Step 4: Verify**

Run: `grep -n "current_tag_type = 'toggle'" libs/db/schema/90-user-schema/11-update_note_tags.sql`
Expected: no matches.

Run: `grep -n "NOT IN (1, 3, 12)" libs/db/schema/90-user-schema/11-update_note_tags.sql`
Expected: two matches (compute gate + cross-user targeting).

---

## Task 5: Generate the migration

**Files:**
- Create: `libs/db/migrations/<atlas-timestamp>_drop_toggle_tags.sql`

- [ ] **Step 1: Generate**

Run: `pnpm gen-migration -- drop_toggle_tags`

Expected: Atlas produces a new file in `libs/db/migrations/` with the function-replacement DDL derived from Tasks 1-4. The filename will be `<YYYYMMDDhhmmss>_drop_toggle_tags.sql`.

- [ ] **Step 2: Capture the new migration's path**

Run: `ls -t libs/db/migrations/*.sql | head -1`
Expected: prints the new migration path. Remember this path — subsequent tasks reference it.

- [ ] **Step 3: Open the migration and review the generated DDL**

The generated file should contain `CREATE OR REPLACE FUNCTION` statements for `get_tag_type`, `upsert_thread_tag`, `upsert_note_tag`, `update_thread_tags`, `update_note_tags`. If anything else appears (especially DROP statements on tables or columns), STOP and reconcile — only the four function bodies should change.

---

## Task 6: Append data-migration phases to the generated migration

**Files:**
- Modify: the migration file from Task 5

Append the following SQL to the end of the generated migration file (after the auto-generated DDL):

- [ ] **Step 1: Append the comment header and Phase 1 (note reaction backfill)**

```sql

-- ---------------------------------------------------------------------------
-- Data migration: retire toggle tags into per-user emoji reactions.
--
-- Mirrors the pattern in 20260526195200_backfill_count_tags_to_reactions.sql:
-- 1. INSERT mapped rows into note_reaction / thread_reaction.
-- 2. UPDATE Tag.twist (109) → 12 (reassigned into the compute range).
-- 3. UPDATE archived_at = now() on the 10 retired toggle-tag source rows.
--
-- Per libs/db/AGENTS.md "Removing Rows from Synced Tables" the source rows
-- are archived (archived_at = now()), never bare-deleted, so the seq cursor
-- surfaces the change to existing Flutter clients.
-- ---------------------------------------------------------------------------

-- Phase 1: Backfill note_reaction from note_tag rows for the 10 retired
-- toggle tags. Tag 109 (Twist) is intentionally NOT in this mapping — it
-- moves to id 12 in Phase 2 instead.
INSERT INTO public.note_reaction (
    actor_id, note_id, emoji, updated_at, archived_at, updated_by, sync_depth
)
SELECT
    nt.actor_id,
    nt.note_id,
    m.emoji,
    nt.updated_at,
    nt.archived_at,
    nt.updated_by,
    nt.sync_depth
FROM public.note_tag nt
JOIN (VALUES
    (100, '📌'),  -- Pinned
    (101, '🚨'),  -- Urgent
    (103, '🎯'),  -- Goal
    (104, '⚖️'),  -- Decision
    (105, '⏳'),  -- Waiting
    (106, '🚧'),  -- Blocked
    (107, '⚠️'),  -- Warning
    (108, '❓'),  -- Question
    (110, '⭐'),  -- Star
    (111, '💡')   -- Idea
) AS m(tag_id, emoji) ON m.tag_id = nt.tag_id
ON CONFLICT (actor_id, note_id, emoji)
    DO UPDATE SET
        archived_at = LEAST(public.note_reaction.archived_at, EXCLUDED.archived_at),
        updated_at = GREATEST(public.note_reaction.updated_at, EXCLUDED.updated_at);
```

- [ ] **Step 2: Append the thread_reaction backfill**

```sql

-- Phase 1 (cont.): Backfill thread_reaction. Mirrors the note_reaction
-- INSERT but includes the `occurrence` column on the unique constraint.
INSERT INTO public.thread_reaction (
    actor_id, thread_id, occurrence, emoji, updated_at, archived_at, updated_by, sync_depth
)
SELECT
    tt.actor_id,
    tt.thread_id,
    tt.occurrence,
    m.emoji,
    tt.updated_at,
    tt.archived_at,
    tt.updated_by,
    tt.sync_depth
FROM public.thread_tag tt
JOIN (VALUES
    (100, '📌'),
    (101, '🚨'),
    (103, '🎯'),
    (104, '⚖️'),
    (105, '⏳'),
    (106, '🚧'),
    (107, '⚠️'),
    (108, '❓'),
    (110, '⭐'),
    (111, '💡')
) AS m(tag_id, emoji) ON m.tag_id = tt.tag_id
ON CONFLICT (actor_id, thread_id, occurrence, emoji)
    DO UPDATE SET
        archived_at = LEAST(public.thread_reaction.archived_at, EXCLUDED.archived_at),
        updated_at = GREATEST(public.thread_reaction.updated_at, EXCLUDED.updated_at);
```

- [ ] **Step 3: Append Phase 2 (reassign Tag.twist 109 → 12)**

```sql

-- Phase 2: Reassign Tag.twist (109) into the compute range as id 12.
-- These are live runtime-state rows (the Twisting indicator); no archive.
-- The updated_at bump (implicit on UPDATE) drives sync to clients.
UPDATE public.note_tag   SET tag_id = 12, updated_at = now() WHERE tag_id = 109;
UPDATE public.thread_tag SET tag_id = 12, updated_at = now() WHERE tag_id = 109;
```

- [ ] **Step 4: Append Phase 3 (archive the 10 retired toggle-tag source rows)**

```sql

-- Phase 3: Archive (NOT delete) the source toggle-tag rows. The seq
-- cursor sync surfaces the archived_at flip to clients on next pull.
UPDATE public.note_tag
SET archived_at = now()
WHERE tag_id IN (100, 101, 103, 104, 105, 106, 107, 108, 110, 111)
  AND archived_at IS NULL;

UPDATE public.thread_tag
SET archived_at = now()
WHERE tag_id IN (100, 101, 103, 104, 105, 106, 107, 108, 110, 111)
  AND archived_at IS NULL;
```

- [ ] **Step 5: Update the Atlas checksum**

Run: `cd libs/db && pnpm exec atlas migrate hash --dir file://migrations`
Expected: `atlas.sum` updates. No error output.

(If `pnpm exec atlas` is not on PATH, use `atlas migrate hash --dir file://libs/db/migrations` from the repo root.)

---

## Task 7: Apply the migration locally

**Files:**
- Modifies: local Postgres database, `libs/db/src/types.ts` (auto-regenerated)

- [ ] **Step 1: Apply**

Run: `pnpm apply-migrations`

Expected: Atlas applies the new migration. After success, `pnpm types` runs automatically and updates `libs/db/src/types.ts` (unless `$CI=true`, which is not set locally).

If Atlas errors on a function body (syntax / missing reference), edit the schema file mentioned in the error, then re-run `pnpm apply-migrations`. Atlas wraps each migration in a transaction so a failed apply leaves the DB unchanged.

- [ ] **Step 2: Confirm schema is in sync with migrations**

Run: `pnpm diff-schema-migrations`
Expected: no output (no diff).

If diff appears, the function-body changes from Tasks 1-4 weren't fully captured. Inspect and regenerate.

- [ ] **Step 3: Confirm types are in sync**

Run: `pnpm --filter @plotday/db run lint`
Expected: exit code 0. The lint step runs `tsx scripts/gen-types.ts --check` which fails if `libs/db/src/types.ts` is out of date.

---

## Task 8: Verify database state with SQL

**Files:** none (read-only verification).

- [ ] **Step 1: Confirm only compute-range tag ids remain unarchived**

Run:

```bash
psql "$DATABASE_URL" -c "SELECT tag_id, COUNT(*) FROM note_tag WHERE archived_at IS NULL GROUP BY tag_id ORDER BY tag_id;"
psql "$DATABASE_URL" -c "SELECT tag_id, COUNT(*) FROM thread_tag WHERE archived_at IS NULL GROUP BY tag_id ORDER BY tag_id;"
```

Expected: only ids in the range 1-12 appear. If id 12 appears, that's the migrated Twist tag (good). No ids 100-111 should appear.

- [ ] **Step 2: Confirm reaction backfill populated**

Run:

```bash
psql "$DATABASE_URL" -c "SELECT emoji, COUNT(*) FROM note_reaction WHERE archived_at IS NULL GROUP BY emoji ORDER BY COUNT(*) DESC;"
psql "$DATABASE_URL" -c "SELECT emoji, COUNT(*) FROM thread_reaction WHERE archived_at IS NULL GROUP BY emoji ORDER BY COUNT(*) DESC;"
```

Expected: the 10 mapped emoji appear with row counts. If the local DB had no toggle-tag rows before the migration (clean dev DB) the counts may be zero — that's still success; the migration is a no-op on empty source data.

- [ ] **Step 3: Confirm `get_tag_type` behavior**

Run:

```bash
psql "$DATABASE_URL" -c "SELECT get_tag_type(12);"
psql "$DATABASE_URL" -c "SELECT get_tag_type(1019);"
```

Expected: `12` → `compute`; `1019` → `count` (count dispatch remains
live; only the toggle range was retired).

Run:

```bash
psql "$DATABASE_URL" -c "SELECT get_tag_type(100);" || echo "expected raise"
```

Expected: psql reports `ERROR: invalid tag_id: 100`. The `|| echo` shows the error is expected.

---

## Task 9: Update the API worker cron

**Files:**
- Modify: `workers/api/src/index.ts:300-332`

- [ ] **Step 1: Open and locate the block**

The block currently reads (lines ~300-332):

```ts
  // Fail-closed belt-and-suspenders: archive any stuck Twisting tag (tag_id
  // 109) whose row hasn't been touched in over an hour. The queue handler's
  // per-batch `finally` in workers/api/src/queue/updates.ts is the primary
  // cleanup path; this only fires when a worker crashed or a message was lost
  // mid-dispatch. 1 hour is well beyond any realistic twist runtime (including
  // long LLM / agentic chains) so we never prematurely clear a legitimate
  // "thinking" indicator.
  try {
    await withDb(env, async (db) => {
      const result = await db
        .updateTable("note_tag")
        .set({ archived_at: new Date() as any, updated_by: 0 })
        .where("tag_id", "=", 109)
        .where("archived_at", "is", null)
```

- [ ] **Step 2: Edit the comment and the WHERE clause**

Use the `Edit` tool to change two strings:

`"Twisting tag (tag_id 109)"` → `"Twisting tag (tag_id 12)"` (in the leading comment).

`.where("tag_id", "=", 109)` → `.where("tag_id", "=", 12)`.

- [ ] **Step 3: Verify no other references remain**

Run: `grep -rn "tag_id.*109\|tag_id = 109\|= 109" workers/ public/ apps/`
Expected: no matches (other than possibly comments in old migration files — those should be left alone as historical record).

---

## Task 10: Update the Flutter Tag enum

**Files:**
- Modify: `apps/plot/lib/store/tag.dart`

- [ ] **Step 1: Delete the 10 toggle entries**

Remove these enum entries from the `// Toggle tags` section (lines ~63-109 in current file): `pinned`, `urgent`, `goal`, `decision`, `waiting`, `blocked`, `warning`, `question`, `star`, `idea`. The entire `// Toggle tags` comment + its 10 entries goes away.

The `twist` entry (currently at id 109) stays for now — Step 2 moves it.

- [ ] **Step 2: Move `twist` into the compute section with new id 12**

Add into the `// Compute tags` section (after `reading` at id 11):

```dart
  /// Runtime-managed Twisting indicator — the twist runtime sets this on
  /// notes it's currently processing. Reassigned from legacy id 109 to 12
  /// (compute range) when toggle tags were retired.
  twist(
    12,
    PlotIcon.twist,
    'Twisting',
    type: TagType.compute,
    addable: false,
    shortcodes: ['twist', 'twisting'],
  ),
```

Delete the OLD `twist(109, ...)` entry from its prior location.

- [ ] **Step 3: Confirm the file still parses**

Run: `cd apps/plot && flutter analyze lib/store/tag.dart`
Expected: no errors specific to `tag.dart`.

(Other files referencing `Tag.pinned`/`Tag.star`/etc. will surface errors here — there should be none per the prior grep, but if any appear, address them by removing the dead reference.)

---

## Task 11: Add the Drift schema migration

**Files:**
- Modify: `apps/plot/lib/store/store.dart`

The local SQLite cache holds copies of `note_tag` and `thread_tag` rows that need to mirror the server-side migration.

- [ ] **Step 1: Locate the current `Store.schemaVersion` and `migration` definition**

Run: `grep -n "schemaVersion\|onUpgrade" apps/plot/lib/store/store.dart`

Note the current `schemaVersion` value. The next version is `current + 1`. The `onUpgrade` callback contains a sequence of `if (from < N) { ... }` arms; you will add one at the bottom for the new version.

- [ ] **Step 2: Bump `schemaVersion`**

If the current value is `N`, change it to `N + 1`. (For example, if `static const int schemaVersion = 247;` change to `248`.) Use the actual current value from Step 1.

- [ ] **Step 3: Add the migration arm at the end of `onUpgrade`**

After the last existing `if (from < ...)` block in `onUpgrade`, add:

```dart
        // Toggle tags retirement: archive local copies of the 10 retired
        // toggle-tag rows and reassign Tag.twist's id from 109 → 12 to
        // mirror the server migration.
        if (from < <NEW_VERSION>) {
          final nowIso = DateTime.now().toIso8601String();
          await m.database.customStatement(
            'UPDATE note_tags SET archived_at = ? '
            'WHERE tag_id IN (100, 101, 103, 104, 105, 106, 107, 108, 110, 111) '
            'AND archived_at IS NULL',
            [nowIso],
          );
          await m.database.customStatement(
            'UPDATE thread_tags SET archived_at = ? '
            'WHERE tag_id IN (100, 101, 103, 104, 105, 106, 107, 108, 110, 111) '
            'AND archived_at IS NULL',
            [nowIso],
          );
          await m.database.customStatement(
            'UPDATE note_tags SET tag_id = 12 WHERE tag_id = 109',
          );
          await m.database.customStatement(
            'UPDATE thread_tags SET tag_id = 12 WHERE tag_id = 109',
          );
        }
```

Replace `<NEW_VERSION>` with the value from Step 2.

If the existing migration arms use different SQL table names (e.g. `note_tag` instead of `note_tags`), match the existing convention. Confirm by running `grep -n "note_tag\|note_tags" apps/plot/lib/store/store.dart` and inspecting prior migration arms.

- [ ] **Step 4: Confirm migration arm parses**

Run: `cd apps/plot && flutter analyze lib/store/store.dart`
Expected: no errors specific to `store.dart`.

---

## Task 12: Regenerate Drift code and run analyzer

**Files:**
- Regenerates: `apps/plot/lib/**/*.g.dart`

- [ ] **Step 1: Run build_runner**

Run: `cd apps/plot && flutter pub run build_runner build --delete-conflicting-outputs`
Expected: completes without errors. Drift regenerates the schema files matching the new `schemaVersion`.

- [ ] **Step 2: Run flutter analyze across the app**

Run: `cd apps/plot && flutter analyze`
Expected: no new errors. The existing `pubspec.yaml:199` `app.env` asset warning is a pre-existing issue documented in `docs/emoji-reactions-followups.md` §8 — that's the only acceptable warning.

If errors surface for `Tag.pinned`/`Tag.star`/etc., they indicate callsites the spec's grep missed. Remove or replace each reference (those tags no longer exist).

---

## Task 13: End-to-end visual verification

**Files:** none (manual check via `run-app` skill).

- [ ] **Step 1: Launch the app via the `run-app` skill**

Follow the run-app skill's recipe. The launched app uses the isolated `agent` profile with its own local DB.

- [ ] **Step 2: Inspect a thread that previously had toggle tags**

If the agent profile's local DB is empty, skip to Step 4 — there's nothing pre-migration to compare against. Otherwise: open a thread that historically had any of Pinned/Urgent/Goal/Decision/Waiting/Blocked/Warning/Question/Star/Idea applied. Confirm the chip row now shows the migrated emoji (📌/🚨/etc.) and not the old toggle-tag icons.

- [ ] **Step 3: Confirm the reaction picker shows no duplicates**

Open the reaction picker on a note. Confirm Pinned/Star/etc. do NOT appear as selectable tag options (they're gone from the Tag enum); the equivalent emoji (📌/⭐) appear via the picker's emoji surface.

- [ ] **Step 4: Trigger a twist mention**

Mention a twist in a note. Confirm the Twisting indicator renders. (The widget code at `widget/note.dart:906, 1047` reads `Tag.twist`, which now resolves to id 12 — verify the indicator chip/icon shows.)

- [ ] **Step 5: Report results**

Capture screenshots if possible. Document any unexpected behavior. If the agent's local DB starts empty (no pre-migration rows to inspect), report that — the migration is still valid; only the visual-regression check has nothing to compare against.

---

## Task 14: Final sanity sweep

**Files:** none (read-only).

- [ ] **Step 1: Confirm no stranded toggle references**

Run:

```bash
grep -rEn "Tag\.(pinned|urgent|goal|decision|waiting|blocked|warning|question|star|idea)" apps/plot/lib --include="*.dart"
grep -rEn "tag_id.*= 109|tag_id = 109" workers/ apps/plot/lib --include="*.ts" --include="*.dart"
grep -n "current_tag_type = 'toggle'" libs/db/schema/90-user-schema/*.sql
```

Expected: all three return no matches.

- [ ] **Step 2: Confirm schema/migration final state**

Run: `pnpm diff-schema-migrations`
Expected: no output.

Run: `pnpm --filter @plotday/db run lint`
Expected: exit code 0.

- [ ] **Step 3: Confirm Flutter clean**

Run: `cd apps/plot && flutter analyze 2>&1 | grep -v "app.env"`
Expected: shows only "No issues found!" or similar success line; the filtered-out `app.env` warning is pre-existing per the followups doc.

- [ ] **Step 4: Hand off to user**

Report:
- Migration filename created
- `schemaVersion` bumped to (value)
- All grep sweeps clean
- DB SQL checks from Task 8 results
- E2E results from Task 13

The user will direct whether/how to commit (per the project's "never commit without explicit permission" rule).

---

## Risk recap

- **Atlas may emit unexpected DROP statements.** Task 5 Step 3 says STOP if any DROP appears. The function changes are CREATE OR REPLACE, so there should be none. If Atlas tries to drop the `'toggle'` enum value automatically, manually delete that statement from the migration — the spec keeps `'toggle'` in the enum for one more deploy cycle.
- **`pnpm types` skip when `$CI=true`.** Should not apply locally, but if it does, run `pnpm types` manually before Task 7 Step 3.
- **Drift table-name conventions.** Task 11 Step 3 assumes `note_tags` / `thread_tags` are the SQL names. Verify against the existing migration arms in `store.dart` — Drift's default mapping pluralizes Dart class names, but the project may override. Use what prior arms in the same file use.
- **In-flight twist runs at migration time.** Live `tag_id = 109` rows get rewritten to 12; this bumps `updated_at` and the cron/queue cleanup paths target the new id. Brief seq churn for in-progress twists is the only visible side effect.
