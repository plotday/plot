# Per-user scoped-note source-time Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the displayed "source time" of a thread match its latest note for access-scoped notes, server-side only (no Flutter/Drift changes), by denormalizing `MAX(note.source_created_at)` per-user onto `thread_state` and projecting it through `user.thread`.

**Architecture:** The note trigger already writes `thread_state` per audience member for scoped notes (the `bumped_at` bump). We add one nullable column to that same write, project `GREATEST(thread.col, thread_state.col)` in `user.thread`, and move the `clear_thread_state` read guard to the identical formula. The client's existing synced `last_note_source_created_at` column receives the corrected value with zero client changes. One-time backfill re-syncs affected threads.

**Tech Stack:** PostgreSQL 18 (schema in `libs/db/schema/`, source of truth), Atlas migrations, pgTAP tests via `pg_prove`, Kysely type generation (`pnpm types`).

**Spec:** `docs/superpowers/specs/2026-06-16-per-user-scoped-note-source-time-design.md`

---

## ⚠️ Worktree DB command convention (READ FIRST — applies to EVERY DB command below)

This worktree's Postgres is provisioned **after** the session started, so the
ambient `$DATABASE_URL` is **stale** (points at the main repo's `54322`). Every
DB command (`psql`, `pnpm gen-migration`, `pnpm apply-migrations`,
`pnpm diff-schema-migrations`, `pnpm types`, `pg_prove`) MUST source the real
port and override `DATABASE_URL` inline. The canonical prefix used throughout
this plan (run from the worktree root
`/Users/kris.braun/code/plot/.claude/worktrees/scoped-note-source-time`):

```bash
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
```

`export` only lasts for that single Bash invocation (shell state does not persist
between calls), so prepend it to each command block. After provisioning (Task 1),
sanity-check before any migration/destructive command:

```bash
psql "$DATABASE_URL" -tAc "show port;"   # MUST print the worktree PORT, not 54322
```

---

## File Structure

- `libs/db/schema/50-tables/27-thread_state.sql` — **modify**: add nullable
  `last_note_source_created_at timestamptz` column + comment.
- `libs/db/schema/50-tables/25-note.sql` — **modify**: `update_thread_on_note_change`
  scoped (`ELSE`) branch writes the new column.
- `libs/db/schema/90-user-schema/30-thread.sql` — **modify**: `user.thread`
  projects `GREATEST(a.last_note_source_created_at, ts.last_note_source_created_at)`.
- `libs/db/schema/90-user-schema/85-user-sync-upserts.sql` — **modify**:
  `clear_thread_state` read guard (2 occurrences) uses the GREATEST formula.
- `libs/db/migrations/<generated>.sql` — **generated + hand-appended backfill**.
- `libs/db/src/types.ts` — **regenerated** (`thread_state` gains the column).
- `libs/db/tests/72-scoped-note-source-time.sql` — **create**: pgTAP tests.
- `docs/updates.md` — **modify**: user-facing fix note.

---

## Task 1: Provision the worktree database and verify a clean baseline

**Files:** none (environment setup)

- [ ] **Step 1: Provision the isolated Postgres for this worktree**

Run from the worktree root:
```bash
bash scripts/worktree-db
```
Expected: script starts a Docker Postgres on a unique port, applies all
migrations, and writes `.worktree-db` (containing `PORT="..."`).

- [ ] **Step 2: Confirm the resolved port is NOT 54322**

```bash
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
echo "PORT=$PORT"
psql "$DATABASE_URL" -tAc "show port;"
```
Expected: `show port;` prints the same value as `$PORT` (e.g. `54337`), **not** `54322`.

- [ ] **Step 3: Verify a clean pgTAP baseline**

```bash
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
cd libs/db && pg_prove -d "$DATABASE_URL" tests/*.sql; cd ../..
```
Expected: all existing test files report `ok` / `Result: PASS`. If any fail,
STOP and report — do not proceed onto a broken baseline.

---

## Task 2: Write the failing pgTAP test

**Files:**
- Create: `libs/db/tests/72-scoped-note-source-time.sql`

This test is written first and must be RED (it references a column that does not
exist yet). It models the fixture on `libs/db/tests/42-scoped-note-bump-isolation.sql`.

- [ ] **Step 1: Create the test file**

Create `libs/db/tests/72-scoped-note-source-time.sql` with exactly:

```sql
-- Per-user scoped-note source time (spec 2026-06-16):
--   A scoped note must NOT advance the shared thread.last_note_source_created_at
--   (no leak), but MUST record its source_created_at on thread_state for each
--   visible user. user.thread then projects GREATEST(shared, per-user) so the
--   client's displayed source time is correct, and clear_thread_state's read
--   guard uses the same formula so reads still stick when source < created_at.
--
-- Notes are inserted directly (not via upsert_note) to exercise the
-- update_thread_on_note_change trigger in isolation, matching test 42.
BEGIN;
SET LOCAL search_path = public, "user", extensions;
SELECT plan(6);

DO $$
DECLARE
    v_author   uuid := gen_random_uuid();
    v_author_c uuid;
    v_thread   uuid := gen_random_uuid();
BEGIN
    INSERT INTO "user" (id, email) VALUES (v_author, 'srctime-author@test.local');
    SELECT contact_id INTO v_author_c FROM user_contact
        WHERE user_id = v_author AND "primary" = TRUE AND linked = TRUE LIMIT 1;

    -- Thread created "now"; its notes' source times are deliberately earlier
    -- (mirrors a synced email that predates ingestion).
    INSERT INTO thread (id, created_by, title, contacts, last_note_seq, created_at)
        VALUES (v_thread, v_author, 'T', ARRAY[v_author_c], '0'::xid8, now());

    -- Settle the author's thread_priority filing (raw INSERT does not).
    INSERT INTO thread_priority (thread_id, user_id, priority_id)
    SELECT v_thread, v_author, p.id FROM priority p
        WHERE p.user_id = v_author AND nlevel(p.path) = 1 LIMIT 1
    ON CONFLICT ON CONSTRAINT thread_priority_pkey
        DO UPDATE SET priority_id = EXCLUDED.priority_id, classify_at = NULL;

    PERFORM set_config('test.author',   v_author::text,   false);
    PERFORM set_config('test.author_c', v_author_c::text, false);
    PERFORM set_config('test.thread',   v_thread::text,   false);
END $$;

-- Insert a SCOPED note (access_contacts = [author]) dated 5 days before now.
INSERT INTO note (id, author_id, created_by, thread_id, draft, access_contacts, content, source_created_at)
VALUES (gen_random_uuid(),
        current_setting('test.author_c')::uuid,
        current_setting('test.author')::uuid,
        current_setting('test.thread')::uuid, FALSE,
        ARRAY[current_setting('test.author_c')::uuid],
        'scoped', now() - interval '5 days');

-- 1. Scoped note must NOT advance the shared thread column (no leak).
SELECT is(
    (SELECT last_note_source_created_at FROM thread WHERE id = current_setting('test.thread')::uuid),
    NULL::timestamptz,
    'scoped note leaves shared thread.last_note_source_created_at NULL');

-- 2. Scoped note records its source time on the author's thread_state row.
SELECT is(
    (SELECT last_note_source_created_at FROM thread_state
        WHERE thread_id = current_setting('test.thread')::uuid
          AND user_id = current_setting('test.author')::uuid),
    (now() - interval '5 days')::timestamptz,
    'scoped note sets thread_state.last_note_source_created_at for the visible user');

-- 3. user.thread projects the per-user value (GREATEST picks the ts column).
SELECT is(
    (SELECT last_note_source_created_at FROM "user".thread
        WHERE id = current_setting('test.thread')::uuid
          AND user_id = current_setting('test.author')::uuid),
    (now() - interval '5 days')::timestamptz,
    'user.thread projects the scoped per-user source time');

-- Insert a NEWER scoped note (3 days before now) — projection must advance.
INSERT INTO note (id, author_id, created_by, thread_id, draft, access_contacts, content, source_created_at)
VALUES (gen_random_uuid(),
        current_setting('test.author_c')::uuid,
        current_setting('test.author')::uuid,
        current_setting('test.thread')::uuid, FALSE,
        ARRAY[current_setting('test.author_c')::uuid],
        'scoped-newer', now() - interval '3 days');

-- 4. GREATEST advances to the newer scoped source time.
SELECT is(
    (SELECT last_note_source_created_at FROM "user".thread
        WHERE id = current_setting('test.thread')::uuid
          AND user_id = current_setting('test.author')::uuid),
    (now() - interval '3 days')::timestamptz,
    'a newer scoped note advances the per-user projected source time');

-- 5. Read-stick: the trigger auto-read the author's row (author-match branch),
--    so reset it to UNREAD first to genuinely exercise the guard (otherwise this
--    passes vacuously). Marking read with p_read_at = the projected source time
--    (which is BEFORE thread.created_at = now) must be ACCEPTED. Regression
--    guard: a wrong formula (GREATEST(..., created_at)) would reject it and the
--    thread would stick unread forever.
UPDATE thread_state SET read_at = NULL
 WHERE thread_id = current_setting('test.thread')::uuid
   AND user_id = current_setting('test.author')::uuid;

SELECT "user".clear_thread_state(
    current_setting('test.author')::uuid,
    current_setting('test.thread')::uuid,
    (now() - interval '3 days')::timestamptz,   -- p_read_at == projected source time
    NULL);

SELECT is(
    (SELECT read_at FROM thread_state
        WHERE thread_id = current_setting('test.thread')::uuid
          AND user_id = current_setting('test.author')::uuid),
    (now() - interval '3 days')::timestamptz,
    'read at the projected source time sticks even though source < created_at');

-- 6. An UNSCOPED note still bumps the shared column (per-user column untouched
--    by the unscoped branch) and the projection still works via the shared side.
INSERT INTO note (id, author_id, created_by, thread_id, draft, content, source_created_at)
VALUES (gen_random_uuid(),
        current_setting('test.author_c')::uuid,
        current_setting('test.author')::uuid,
        current_setting('test.thread')::uuid, FALSE,
        'public', now() - interval '1 day');

SELECT is(
    (SELECT last_note_source_created_at FROM thread WHERE id = current_setting('test.thread')::uuid),
    (now() - interval '1 day')::timestamptz,
    'unscoped note advances the shared thread.last_note_source_created_at');

SELECT * FROM finish();
ROLLBACK;
```

- [ ] **Step 2: Run the test and confirm it is RED**

```bash
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
cd libs/db && pg_prove -d "$DATABASE_URL" tests/72-scoped-note-source-time.sql; cd ../..
```
Expected: FAIL — error like `column "last_note_source_created_at" of relation
"thread_state" does not exist`. Do NOT commit yet (a red test would break a
fresh checkout's `pg_prove tests/*.sql`).

---

## Task 3: Author the schema changes

**Files:**
- Modify: `libs/db/schema/50-tables/27-thread_state.sql`
- Modify: `libs/db/schema/50-tables/25-note.sql`
- Modify: `libs/db/schema/90-user-schema/30-thread.sql`
- Modify: `libs/db/schema/90-user-schema/85-user-sync-upserts.sql`

- [ ] **Step 1: Add the column to `thread_state`**

In `libs/db/schema/50-tables/27-thread_state.sql`, in the `CREATE TABLE
"public"."thread_state"` body, add the column immediately after the `"bumped_at"`
line.

Find:
```sql
    "bumped_at" timestamptz,        -- for manual bumps
    "order" double precision,       -- drag-to-reorder within Doing / Scheduled
```
Replace with:
```sql
    "bumped_at" timestamptz,        -- for manual bumps
    "last_note_source_created_at" timestamptz, -- per-user MAX(source_created_at) over SCOPED visible notes; projected via GREATEST in user.thread (see 25-note.sql scoped branch). NULL for users with no scoped note (shared thread column carries it).
    "order" double precision,       -- drag-to-reorder within Doing / Scheduled
```

- [ ] **Step 2: Write the new column in the trigger's scoped branch**

In `libs/db/schema/50-tables/25-note.sql`, inside `update_thread_on_note_change`,
the `ELSE` (scoped) branch has an `INSERT INTO thread_state … ON CONFLICT … DO
UPDATE`. Make two edits to that statement.

Edit 2a — add the column + value to the INSERT/SELECT. Find:
```sql
            INSERT INTO thread_state (user_id, thread_id, read_at, bumped_at)
            SELECT v.user_id,
                   NEW.thread_id,
                   CASE
                       WHEN v.user_id = NEW.created_by
                            OR NEW.author_id = ANY("user".user_contact_ids(v.user_id))
                       THEN now()
                       ELSE NULL
                   END,
                   now()
            FROM (
```
Replace with:
```sql
            INSERT INTO thread_state (user_id, thread_id, read_at, bumped_at, last_note_source_created_at)
            SELECT v.user_id,
                   NEW.thread_id,
                   CASE
                       WHEN v.user_id = NEW.created_by
                            OR NEW.author_id = ANY("user".user_contact_ids(v.user_id))
                       THEN now()
                       ELSE NULL
                   END,
                   now(),
                   NEW.source_created_at
            FROM (
```

Edit 2b — advance the column on conflict. Find:
```sql
            ON CONFLICT (user_id, thread_id) DO UPDATE
            SET bumped_at = now(),
```
Replace with:
```sql
            ON CONFLICT (user_id, thread_id) DO UPDATE
            SET bumped_at = now(),
                last_note_source_created_at =
                    GREATEST(thread_state.last_note_source_created_at, NEW.source_created_at),
```

(The unscoped `IF` branch and the audience subquery `( … ) v` are unchanged.)

- [ ] **Step 3: Project the per-user value in `user.thread`**

In `libs/db/schema/90-user-schema/30-thread.sql`, find the projection in the
`user.thread` view (NOT `user.thread_redacted`):
```sql
    a.last_note_source_created_at,
```
Replace with:
```sql
    GREATEST(a.last_note_source_created_at, ts.last_note_source_created_at) AS last_note_source_created_at,
```
Leave `user.thread_redacted`'s `NULL::timestamptz AS last_note_source_created_at`
unchanged (redaction).

- [ ] **Step 4: Move the `clear_thread_state` read guard in lockstep**

In `libs/db/schema/90-user-schema/85-user-sync-upserts.sql`, the
`clear_thread_state` function has the guard subquery in **two** places (the
`read_at = CASE …` and the trailing `WHERE …`). Replace **both** occurrences.

Find (appears twice):
```sql
                        SELECT COALESCE(t.last_note_source_created_at, t.created_at)
                        FROM thread t
                        WHERE t.id = p_thread_id
```
Replace each with:
```sql
                        SELECT COALESCE(
                                   GREATEST(t.last_note_source_created_at,
                                            thread_state.last_note_source_created_at),
                                   t.created_at)
                        FROM thread t
                        WHERE t.id = p_thread_id
```
(`created_at` stays the COALESCE fallback — never a GREATEST term — so a source
time earlier than ingest does not raise the threshold above the client's
`read_at`. `thread_state` is the conflicting row, in scope inside the
`ON CONFLICT DO UPDATE`. Note both occurrences may be indented differently — the
second is inside the `WHERE`; match each in place and keep its indentation.)

---

## Task 4: Generate the migration, append the backfill, apply, regenerate types

**Files:**
- Generate: `libs/db/migrations/<timestamp>_per_user_scoped_note_source_time.sql`
- Regenerate: `libs/db/src/types.ts`

- [ ] **Step 1: Generate the migration from the schema diff**

```bash
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
psql "$DATABASE_URL" -tAc "show port;"   # confirm worktree port first
pnpm gen-migration -- per_user_scoped_note_source_time
```
Expected: a new file in `libs/db/migrations/` containing the
`ALTER TABLE "thread_state" ADD COLUMN "last_note_source_created_at"` plus
`CREATE OR REPLACE` for the trigger function, `user.thread` view, and
`clear_thread_state`.

- [ ] **Step 2: Append the backfill data migration**

Open the generated migration file and append this at the END (after the
generated DDL):

```sql
-- Backfill: populate the new per-user column for existing scoped-note threads.
-- UPDATE-only (never INSERT) so we don't create thread_state rows that would
-- flip unread state. The trigger already created rows for each scoped note's
-- audience, so the rows we need exist. This UPDATE bumps thread_state.seq via
-- update_seq_and_updated_at, which re-syncs exactly the affected threads so
-- clients pick up the corrected source time (no global seq bump needed:
-- unscoped/unchanged threads keep their seq).
UPDATE thread_state ts
SET last_note_source_created_at = sub.max_src
FROM (
    SELECT tp.user_id, n.thread_id, MAX(n.source_created_at) AS max_src
    FROM note n
    JOIN thread_priority tp ON tp.thread_id = n.thread_id
    WHERE n.draft = FALSE
      AND n.archived_at IS NULL
      AND (n.access_contacts IS NOT NULL OR n.access_groups IS NOT NULL)
      AND ( tp.user_id = n.created_by
         OR (n.access_contacts IS NOT NULL AND n.access_contacts && "user".user_contact_ids(tp.user_id))
         OR (n.access_groups  IS NOT NULL AND n.access_groups  && "user".user_group_ids(tp.user_id)) )
    GROUP BY tp.user_id, n.thread_id
) sub
WHERE ts.user_id = sub.user_id
  AND ts.thread_id = sub.thread_id
  AND ts.last_note_source_created_at IS DISTINCT FROM sub.max_src;
```

- [ ] **Step 3: Re-hash the migration directory (required after manual edit)**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/scoped-note-source-time
atlas migrate hash --dir file://libs/db/migrations
```
Expected: updates `libs/db/migrations/atlas.sum` with no error.

- [ ] **Step 4: Apply the migration (also regenerates types)**

```bash
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
psql "$DATABASE_URL" -tAc "show port;"   # confirm worktree port
pnpm apply-migrations
```
Expected: migration applies cleanly and `libs/db/src/types.ts` is regenerated
(`thread_state` gains `last_note_source_created_at: Timestamp | null`).

- [ ] **Step 5: Confirm schema and migrations are in sync**

```bash
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
pnpm diff-schema-migrations
```
Expected: no differences reported. If it reports a diff, the schema files and
generated migration disagree — fix and regenerate (see libs/db/AGENTS.md
"Squashing Development Migrations" if you need to redo the migration).

---

## Task 5: Make the test pass and verify

**Files:** none (verification)

- [ ] **Step 1: Run the new test — expect GREEN**

```bash
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
cd libs/db && pg_prove -d "$DATABASE_URL" tests/72-scoped-note-source-time.sql; cd ../..
```
Expected: `Result: PASS`, 6/6 ok. If any assertion fails, debug the
corresponding schema edit (Task 3) — do not edit the test to match a wrong
result.

- [ ] **Step 2: Run the FULL pgTAP suite (no regressions)**

```bash
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
cd libs/db && pg_prove -d "$DATABASE_URL" tests/*.sql; cd ../..
```
Expected: all files PASS. Pay attention to `42-scoped-note-bump-isolation.sql`
(its "no leak" assertion 4 must still pass — our change only adds a column to the
same per-user write) and `69-thread-read-clears-unread.sql` (read-guard behavior).

- [ ] **Step 3: Run the db lint (same check CI runs — types must match DB)**

```bash
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
pnpm --filter @plotday/db run lint
```
Expected: passes. If it reports "Type definitions are out of date", run
`pnpm types` and re-stage `libs/db/src/types.ts`.

- [ ] **Step 4: Commit the implementation**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/scoped-note-source-time
git add libs/db/schema/50-tables/27-thread_state.sql \
        libs/db/schema/50-tables/25-note.sql \
        libs/db/schema/90-user-schema/30-thread.sql \
        libs/db/schema/90-user-schema/85-user-sync-upserts.sql \
        libs/db/migrations/ \
        libs/db/src/types.ts \
        libs/db/tests/72-scoped-note-source-time.sql
git commit -m "fix(db): correct displayed source time for scoped-note threads

Denormalize MAX(note.source_created_at) per-user onto thread_state in the
note trigger's scoped branch, project GREATEST(thread, thread_state) in
user.thread, and move the clear_thread_state read guard to the same formula.
Backfills existing scoped-note threads. Server-only; no client changes.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: User-facing changelog + finalize

**Files:**
- Modify: `docs/updates.md`

- [ ] **Step 1: Add a fix note under `## Next release` → `### Fixes`**

Open `docs/updates.md`. If there is a `## Next release` heading at the top with a
`### Fixes` subsection, add the bullet there. If `### Fixes` does not exist under
`## Next release`, create it as the last `###` section. If there is no
`## Next release` heading at all, create one at the very top (above the most
recent `## <version>` heading) with a `### Fixes` subsection. Add:

```markdown
- Thread times now reflect the message's original time (e.g. when an email was sent) instead of when Plot received it.
```

- [ ] **Step 2: Commit the changelog**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/scoped-note-source-time
git add docs/updates.md
git commit -m "docs(updates): note corrected thread source-time display

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 3: Final sync check**

```bash
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
pnpm diff-schema-migrations && echo "SCHEMA IN SYNC"
git status --short   # expect only the intended files committed; 'M public' submodule pointer left untouched
```
Expected: "SCHEMA IN SYNC" and a clean tree apart from the pre-existing
unstaged `M public` submodule pointer (leave it; it is not part of this change).

---

## Out of scope (do NOT change)

- `activity_at` feed ordering (stays on `bumped_at`).
- `last_note_created_at` (ingest-time sibling).
- `upsert_thread_state`'s `p_note_created_at` guard (separate re-unread mechanism).
- Any Flutter / Drift code — the client's existing `last_note_source_created_at`
  column receives the corrected projection unchanged.

## Self-review notes

- **Spec coverage:** §1 data model → Task 3.1; §2 trigger → Task 3.2; §3
  projection → Task 3.3; §4 read guard → Task 3.4; §5 backfill → Task 4.2;
  testing → Tasks 2 & 5; migration safety/types → Task 4; docs → Task 6.
- **Guard formula** matches the client's `contentTimestamp =
  lastNoteSourceCreatedAt ?? createdAt` exactly (COALESCE(GREATEST(...),
  created_at)).
- **Backfill** is UPDATE-only and idempotent (`IS DISTINCT FROM` guard); re-running
  changes nothing.
