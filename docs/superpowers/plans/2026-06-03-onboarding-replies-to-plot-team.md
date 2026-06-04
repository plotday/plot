# Onboarding replies to Plot Team — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a read-only recipient of an announce-group onboarding thread reply, with the reply scoped to Plot Team + the thread author only, and make note bump/unread/push respect note access scope so the broadcast audience isn't notified.

**Architecture:** Three layers. (1) DB: `upsert_note` enforces the read-only reply scope; `update_thread_on_note_change` becomes access-scope-aware (scoped notes never touch the shared `last_note_*` columns and instead bump `thread_state` only for the note-visible set); a data migration adds Kris (contact) and Plot Team (group) to the seven global onboarding threads. (2) API: the note POST background task bounds unread/push to the note-visible set for scoped notes. (3) Flutter: a read-only viewer's reply defaults to `access_groups = {non-announce thread groups}` and the recipient picker offers those groups.

**Tech Stack:** PostgreSQL (plpgsql, Atlas migrations, pgTAP via `pg_prove`), Cloudflare Workers (TypeScript, Hono, Kysely, vitest), Flutter/Dart (Drift, forui).

**Spec:** `docs/superpowers/specs/2026-06-03-onboarding-replies-to-plot-team-design.md`

---

## Conventions for every command below

- All paths are relative to the worktree root `/Users/kris.braun/code/plot/.claude/worktrees/onboarding-replies-to-plot-team`.
- **Database URL:** this worktree's DB port is in `.worktree-db`. Because the env may be stale, source it explicitly on every DB command:
  ```bash
  source .worktree-db
  export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
  psql "$DATABASE_URL" -tAc "show port;"   # MUST print $PORT, not 54322
  ```
- Commits in this Flutter-bearing worktree may trip husky; `pnpm install` already ran, so normal commits should work. If a commit aborts on `husky.sh: No such file`, re-run with `--no-verify`.

---

## Task 0: Set up the worktree database

**Files:** none (environment only)

- [ ] **Step 1: Provision the isolated Postgres for this worktree**

Run:
```bash
bash scripts/worktree-db
```
Expected: prints a `PORT="…"` and applies all existing migrations. (Per project notes, it may abort on a missing `tsx` during the type-gen step *after* writing `.worktree-db` and applying migrations — that's fine; the DB is up.)

- [ ] **Step 2: Export the correct DATABASE_URL and verify**

Run:
```bash
source .worktree-db
export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
psql "$DATABASE_URL" -tAc "show port;"
```
Expected: prints the worktree `PORT` (not `54322`).

- [ ] **Step 3: Confirm pgTAP is available**

Run:
```bash
psql "$DATABASE_URL" -tAc "SELECT extname FROM pg_extension WHERE extname='pgtap';"
```
Expected: prints `pgtap`. (Installed by `libs/db/schema/20-extensions/80-testing.sql`.) If empty, run `psql "$DATABASE_URL" -c "CREATE EXTENSION IF NOT EXISTS pgtap;"`.

---

## Task 1: pgTAP test — `upsert_note` rejects out-of-scope read-only replies

This test pins the §2 server rule: a read-only viewer may scope a reply to thread contacts and non-announce thread groups, but **not** to an announce group they don't admin.

**Files:**
- Create: `libs/db/tests/41-readonly-note-scope-enforcement.sql`

- [ ] **Step 1: Write the failing pgTAP test**

Create `libs/db/tests/41-readonly-note-scope-enforcement.sql`:
```sql
BEGIN;
SET LOCAL search_path = public, "user", extensions;
SELECT plan(4);

DO $$
DECLARE
    v_author      uuid := gen_random_uuid();   -- author user (Kris stand-in)
    v_viewer      uuid := gen_random_uuid();   -- read-only announce viewer
    v_author_c    uuid;
    v_viewer_c    uuid;
    v_announce    uuid := gen_random_uuid();   -- announce group (Everyone stand-in)
    v_team        uuid := gen_random_uuid();   -- non-announce group (Plot Team stand-in)
    v_thread      uuid := gen_random_uuid();
    v_root        uuid;
BEGIN
    -- Two users, each with a primary linked contact.
    INSERT INTO "user" (id) VALUES (v_author), (v_viewer);
    INSERT INTO contact (id, user_id, name) VALUES
        (gen_random_uuid(), v_author, 'Author') RETURNING id INTO v_author_c;
    INSERT INTO contact (id, user_id, name) VALUES
        (gen_random_uuid(), v_viewer, 'Viewer') RETURNING id INTO v_viewer_c;
    INSERT INTO user_contact (user_id, contact_id, linked, "primary") VALUES
        (v_author, v_author_c, TRUE, TRUE), (v_viewer, v_viewer_c, TRUE, TRUE);
    SELECT id INTO v_root FROM priority WHERE user_id = v_viewer AND nlevel(path) = 1 LIMIT 1;

    -- Groups: announce (no admins) + team (viewer is NOT a member).
    INSERT INTO "group" (id, name, type, created_by) VALUES
        (v_announce, 'Everyone', 'announce', v_author),
        (v_team, 'Plot Team', 'team', v_author);
    -- Author + viewer are members of the announce group; author is also team member.
    INSERT INTO group_member (group_id, contact_id) VALUES
        (v_announce, v_author_c), (v_announce, v_viewer_c), (v_team, v_author_c);

    -- Thread authored by author, addressed to [team, announce], contacts [author].
    INSERT INTO thread (id, created_by, title, contacts, groups)
        VALUES (v_thread, v_author, 'Welcome', ARRAY[v_author_c], ARRAY[v_team, v_announce]);
    -- Ensure the viewer has a thread_priority row (filed via announce membership).
    INSERT INTO thread_priority (thread_id, user_id, priority_id)
        VALUES (v_thread, v_viewer, v_root)
        ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;

    PERFORM set_config('test.viewer', v_viewer::text, false);
    PERFORM set_config('test.thread', v_thread::text, false);
    PERFORM set_config('test.team', v_team::text, false);
    PERFORM set_config('test.announce', v_announce::text, false);
    PERFORM set_config('test.author_c', v_author_c::text, false);
END $$;

-- 1. The viewer is a read-only viewer of this thread.
SELECT is(
    "user".user_has_thread_write_access(
        current_setting('test.viewer')::uuid,
        current_setting('test.thread')::uuid),
    FALSE, 'viewer has no write access');

-- 2. Scoping a reply to the team group (a non-announce thread group) is allowed.
SELECT lives_ok($$
    SELECT "user".upsert_note(
        current_setting('test.viewer')::uuid,  -- user_id
        NULL, current_setting('test.thread')::uuid, NULL, NULL, 0, NULL, FALSE,
        NULL,                                                   -- p_access_contacts
        ARRAY[current_setting('test.team')::uuid],              -- p_access_groups (team)
        'reply to plot team', NULL, NULL, NULL, now(), NULL)
$$, 'reply scoped to non-announce team group is accepted');

-- 3. Scoping a reply to a thread contact (the author) is allowed.
SELECT lives_ok($$
    SELECT "user".upsert_note(
        current_setting('test.viewer')::uuid,
        NULL, current_setting('test.thread')::uuid, NULL, NULL, 0, NULL, FALSE,
        ARRAY[current_setting('test.author_c')::uuid],          -- p_access_contacts (author)
        NULL, 'reply to author', NULL, NULL, NULL, now(), NULL)
$$, 'reply scoped to a thread contact is accepted');

-- 4. Scoping a reply to the announce group (not an admin) is rejected.
SELECT throws_ok($$
    SELECT "user".upsert_note(
        current_setting('test.viewer')::uuid,
        NULL, current_setting('test.thread')::uuid, NULL, NULL, 0, NULL, FALSE,
        NULL, ARRAY[current_setting('test.announce')::uuid],    -- p_access_groups (announce!)
        'broadcast back', NULL, NULL, NULL, now(), NULL)
$$, NULL, 'read-only viewer cannot scope a note to an announce group');

SELECT * FROM finish();
ROLLBACK;
```

(Note: `upsert_note`'s positional argument order is
`user_id, p_id, p_thread_id, p_created_by, p_author_id, p_updated_by, p_archived_at, p_draft, p_access_contacts, p_access_groups, p_content, p_actions, p_mentions, p_re_note_id, p_source_created_at, p_key, p_merged_from_thread_id` — see `libs/db/schema/90-user-schema/85-user-sync-upserts.sql`. If the local signature differs, fix the call sites here, not the function.)

- [ ] **Step 2: Run the test — expect failure**

Run:
```bash
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
pg_prove -d "$DATABASE_URL" libs/db/tests/41-readonly-note-scope-enforcement.sql
```
Expected: test 4 FAILS (no exception thrown — the announce scope is currently accepted because `upsert_note` only checks for non-null access).

- [ ] **Step 3: Commit the failing test**

```bash
git add libs/db/tests/41-readonly-note-scope-enforcement.sql
git commit -m "test(db): pin read-only note scope enforcement (failing)"
```

---

## Task 2: pgTAP test — scoped note does not bump the shared thread for non-visible users

Pins §3: a scoped reply must not advance the shared `last_note_*` columns; an unscoped note still does.

**Files:**
- Create: `libs/db/tests/42-scoped-note-bump-isolation.sql`

- [ ] **Step 1: Write the failing pgTAP test**

Create `libs/db/tests/42-scoped-note-bump-isolation.sql`:
```sql
BEGIN;
SET LOCAL search_path = public, "user", extensions;
SELECT plan(3);

DO $$
DECLARE
    v_author   uuid := gen_random_uuid();
    v_author_c uuid := gen_random_uuid();
    v_team     uuid := gen_random_uuid();
    v_thread   uuid := gen_random_uuid();
BEGIN
    INSERT INTO "user" (id) VALUES (v_author);
    INSERT INTO contact (id, user_id, name) VALUES (v_author_c, v_author, 'Author');
    INSERT INTO user_contact (user_id, contact_id, linked, "primary")
        VALUES (v_author, v_author_c, TRUE, TRUE);
    INSERT INTO "group" (id, name, type, created_by) VALUES (v_team, 'Plot Team', 'team', v_author);
    INSERT INTO group_member (group_id, contact_id) VALUES (v_team, v_author_c);
    INSERT INTO thread (id, created_by, title, contacts, groups, last_note_seq)
        VALUES (v_thread, v_author, 'T', ARRAY[v_author_c], ARRAY[v_team], '0'::xid8);
    PERFORM set_config('test.author', v_author::text, false);
    PERFORM set_config('test.thread', v_thread::text, false);
END $$;

-- Capture last_note_seq before any note.
CREATE TEMP TABLE _before AS
    SELECT last_note_seq FROM thread WHERE id = current_setting('test.thread')::uuid;

-- Insert a SCOPED note (access_groups = [team]).
INSERT INTO note (id, author_id, created_by, thread_id, draft, access_groups, content, source_created_at)
VALUES (gen_random_uuid(),
        (SELECT contact_id FROM user_contact WHERE user_id = current_setting('test.author')::uuid LIMIT 1),
        current_setting('test.author')::uuid,
        current_setting('test.thread')::uuid, FALSE,
        ARRAY[(SELECT id FROM "group" WHERE name='Plot Team' LIMIT 1)],
        'scoped', now());

-- 1. Scoped note must NOT advance shared last_note_seq.
SELECT is(
    (SELECT last_note_seq FROM thread WHERE id = current_setting('test.thread')::uuid),
    (SELECT last_note_seq FROM _before),
    'scoped note leaves shared last_note_seq unchanged');

-- Insert an UNSCOPED note (both access arrays NULL).
INSERT INTO note (id, author_id, created_by, thread_id, draft, content, source_created_at)
VALUES (gen_random_uuid(),
        (SELECT contact_id FROM user_contact WHERE user_id = current_setting('test.author')::uuid LIMIT 1),
        current_setting('test.author')::uuid,
        current_setting('test.thread')::uuid, FALSE, 'public', now());

-- 2. Unscoped note DOES advance shared last_note_seq.
SELECT cmp_ok(
    (SELECT last_note_seq FROM thread WHERE id = current_setting('test.thread')::uuid),
    '>',
    (SELECT last_note_seq FROM _before),
    'unscoped note advances shared last_note_seq');

-- 3. The author got a thread_state bump from the scoped note (re-emit for visible users).
SELECT ok(
    EXISTS (SELECT 1 FROM thread_state
            WHERE thread_id = current_setting('test.thread')::uuid
              AND user_id = current_setting('test.author')::uuid),
    'scoped note bumped thread_state for a visible user');

SELECT * FROM finish();
ROLLBACK;
```

- [ ] **Step 2: Run the test — expect failure**

Run:
```bash
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
pg_prove -d "$DATABASE_URL" libs/db/tests/42-scoped-note-bump-isolation.sql
```
Expected: tests 1 and 3 FAIL (today the scoped note advances `last_note_seq` and writes no `thread_state`).

- [ ] **Step 3: Commit the failing test**

```bash
git add libs/db/tests/42-scoped-note-bump-isolation.sql
git commit -m "test(db): pin scoped-note bump isolation (failing)"
```

---

## Task 3: Implement DB changes + migration + onboarding data

**Files:**
- Modify: `libs/db/schema/90-user-schema/85-user-sync-upserts.sql` (the `upsert_note` read-only gate, ~lines 262–279)
- Modify: `libs/db/schema/50-tables/25-note.sql` (`update_thread_on_note_change`, ~lines 143–182)
- Generate: `libs/db/migrations/<timestamp>_onboarding_reply_scoping.sql`
- Modify (append data migration to the generated file): same migration file
- Regenerate: `libs/db/src/types.ts`

- [ ] **Step 1: Tighten the `upsert_note` read-only gate**

In `libs/db/schema/90-user-schema/85-user-sync-upserts.sql`, replace the read-only viewer gate block (the `IF v_created_by = upsert_note.user_id AND NOT "user".user_has_thread_write_access(...)` block) with:
```sql
    -- Read-only viewer gate. A user who reaches the thread only via an
    -- announce group (no write access) may post only scoped notes they
    -- author, and the scope is bounded to the thread's contacts plus its
    -- non-announce groups (announce groups where they are not an admin are
    -- excluded). This is the server-side enforcement of the reply rule and
    -- prevents a viewer from broadcasting back to the announce audience.
    IF v_created_by = upsert_note.user_id
       AND NOT "user".user_has_thread_write_access(upsert_note.user_id, p_thread_id)
    THEN
        -- Must be scoped (no public notes).
        IF p_access_contacts IS NULL AND p_access_groups IS NULL THEN
            RAISE EXCEPTION 'Read-only viewers must scope notes via access_contacts or access_groups';
        END IF;

        -- access_contacts ⊆ thread.contacts ∪ caller's own linked contacts.
        IF p_access_contacts IS NOT NULL AND EXISTS (
            SELECT 1
            FROM unnest(p_access_contacts) AS c(id)
            WHERE c.id <> ALL (
                COALESCE((SELECT contacts FROM thread WHERE id = p_thread_id), ARRAY[]::uuid[])
                || "user".user_contact_ids(upsert_note.user_id)
            )
        ) THEN
            RAISE EXCEPTION 'Read-only viewers may only scope notes to thread contacts';
        END IF;

        -- access_groups ⊆ thread.groups, excluding announce groups where the
        -- caller is not an admin.
        IF p_access_groups IS NOT NULL AND EXISTS (
            SELECT 1
            FROM unnest(p_access_groups) AS g(id)
            JOIN "group" gr ON gr.id = g.id
            WHERE
                -- not a group on this thread
                g.id <> ALL (COALESCE((SELECT groups FROM thread WHERE id = p_thread_id), ARRAY[]::uuid[]))
                -- or an announce group the caller does not admin
                OR (
                    gr.type = 'announce'
                    AND NOT EXISTS (
                        SELECT 1 FROM group_admin ga
                        WHERE ga.group_id = g.id AND ga.user_id = upsert_note.user_id
                    )
                )
        ) THEN
            RAISE EXCEPTION 'Read-only viewers may only scope notes to non-announce thread groups';
        END IF;

        -- May not edit another author's note.
        IF p_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM note
            WHERE id = p_id
              AND author_id IS DISTINCT FROM v_author_id
        ) THEN
            RAISE EXCEPTION 'User cannot edit another author''s note';
        END IF;
    END IF;
```

- [ ] **Step 2: Make `update_thread_on_note_change` access-scope-aware**

In `libs/db/schema/50-tables/25-note.sql`, replace the body of `update_thread_on_note_change()` (keep the `CREATE OR REPLACE FUNCTION` header and the two `CREATE TRIGGER` statements below it unchanged) with:
```sql
BEGIN
    -- Only act on visible, non-draft notes.
    IF NEW.draft = FALSE AND NEW.archived_at IS NULL THEN
        PERFORM pg_advisory_xact_lock(hashtext(NEW.thread_id::text));

        IF NEW.access_contacts IS NULL AND NEW.access_groups IS NULL THEN
            -- UNSCOPED note: everyone who can see the thread can see it.
            -- Bump the shared last_note_* columns exactly as before so the
            -- thread re-emits / re-sorts for all recipients.
            UPDATE thread
            SET last_note_created_at = GREATEST (last_note_created_at, NEW.created_at),
                last_note_source_created_at = GREATEST (last_note_source_created_at, NEW.source_created_at),
                last_note_seq = GREATEST (last_note_seq, NEW.seq),
                updated_by = NEW.updated_by
            WHERE id = NEW.thread_id
              AND (last_note_created_at IS NULL
                  OR last_note_created_at < NEW.created_at
                  OR last_note_source_created_at IS NULL
                  OR last_note_source_created_at < NEW.source_created_at
                  OR last_note_seq < NEW.seq);
        ELSE
            -- SCOPED note: do NOT touch the shared last_note_* columns (that
            -- would re-emit the thread for the whole audience, leaking the
            -- existence of a private reply). Instead bump thread_state for
            -- exactly the users who can see this note, so the thread
            -- re-emits / re-sorts / unreads only for them. The author's row
            -- is bumped but kept read; other visible users get read_at = NULL.
            INSERT INTO thread_state (user_id, thread_id, read_at, bumped_at)
            SELECT v.user_id,
                   NEW.thread_id,
                   CASE WHEN v.user_id = NEW.created_by THEN now() ELSE NULL END,
                   now()
            FROM (
                SELECT tp.user_id
                FROM thread_priority tp
                WHERE tp.thread_id = NEW.thread_id
                  AND tp.revoked_at IS NULL
                  AND (
                      tp.user_id = NEW.created_by
                      OR (NEW.access_contacts IS NOT NULL
                          AND NEW.access_contacts && "user".user_contact_ids(tp.user_id))
                      OR (NEW.access_groups IS NOT NULL
                          AND NEW.access_groups && "user".user_group_ids(tp.user_id))
                  )
            ) v
            ON CONFLICT (user_id, thread_id) DO UPDATE
            SET bumped_at = now(),
                -- A non-author visible user must see the thread as unread
                -- again; never clobber the author's own read state.
                read_at = CASE
                    WHEN thread_state.user_id = NEW.created_by THEN thread_state.read_at
                    ELSE NULL
                END,
                updated_at = now();
        END IF;
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
```

- [ ] **Step 3: Generate the migration**

Run:
```bash
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
pnpm gen-migration -- onboarding_reply_scoping
```
Expected: a new file `libs/db/migrations/<timestamp>_onboarding_reply_scoping.sql` containing the `CREATE OR REPLACE FUNCTION` for both `upsert_note` and `update_thread_on_note_change`.

- [ ] **Step 4: Append the onboarding data migration to the generated file**

Open the new migration file and append (idempotent; safe where the threads/group/contact don't exist, e.g. fresh dev DBs):
```sql
-- ---------------------------------------------------------------------------
-- Data migration: address the seven global onboarding threads to the author
-- (as a contact) + Plot Team (non-announce group) so read-only recipients'
-- replies reach Plot Team + author only. Idempotent.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_team uuid;
    v_keys text[] := ARRAY['welcome','priorities','connections',
                           'getting-around','twists','notifications','clean-up'];
BEGIN
    SELECT id INTO v_team FROM "group" WHERE key = '@plot.team' AND archived_at IS NULL LIMIT 1;

    -- Snapshot existing thread_state keys for these threads so we can keep
    -- Plot Team dormant: any thread_state rows the group-file trigger newly
    -- creates below are removed, leaving only pre-existing (read) rows.
    CREATE TEMP TABLE _pre_ts ON COMMIT DROP AS
        SELECT ts.user_id, ts.thread_id
        FROM thread_state ts
        JOIN thread t ON t.id = ts.thread_id
        WHERE t.key = ANY(v_keys);

    -- 1. Add each thread's own note author (the Kris contact) to contacts.
    UPDATE thread t
    SET contacts = (
        SELECT COALESCE(array_agg(DISTINCT x), ARRAY[]::uuid[])
        FROM unnest(COALESCE(t.contacts, ARRAY[]::uuid[]) || ARRAY[a.author_id]) AS x
    )
    FROM (
        SELECT DISTINCT ON (n.thread_id) n.thread_id, n.author_id
        FROM note n JOIN thread t2 ON t2.id = n.thread_id
        WHERE t2.key = ANY(v_keys) AND n.author_id IS NOT NULL
        ORDER BY n.thread_id, n.source_created_at ASC
    ) a
    WHERE t.id = a.thread_id
      AND NOT (a.author_id = ANY(COALESCE(t.contacts, ARRAY[]::uuid[])));

    -- 2. Add Plot Team to groups (fires file_thread_priority_for_group_members).
    IF v_team IS NOT NULL THEN
        UPDATE thread
        SET groups = COALESCE(groups, ARRAY[]::uuid[]) || ARRAY[v_team]
        WHERE key = ANY(v_keys)
          AND NOT (v_team = ANY(COALESCE(groups, ARRAY[]::uuid[])));

        -- 3. Keep Plot Team dormant: delete any thread_state rows the trigger
        --    just created (not present before). thread_state is not directly
        --    synced (it feeds computed columns on user.thread), so a bare
        --    DELETE here is safe — see libs/db/AGENTS.md.
        DELETE FROM thread_state ts
        USING thread t
        WHERE ts.thread_id = t.id
          AND t.key = ANY(v_keys)
          AND NOT EXISTS (
              SELECT 1 FROM _pre_ts p
              WHERE p.user_id = ts.user_id AND p.thread_id = ts.thread_id
          );
    END IF;
END $$;
```

- [ ] **Step 5: Re-hash and apply**

Run:
```bash
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
atlas migrate hash --dir file://libs/db/migrations
pnpm apply-migrations
```
Expected: migration applies cleanly; `pnpm types` runs automatically (or run `pnpm types` manually if it was skipped).

- [ ] **Step 6: Verify schema/migration sync and regenerate types**

Run:
```bash
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
pnpm diff-schema-migrations   # expect: no differences
pnpm types
```
Expected: `diff-schema-migrations` reports no differences.

- [ ] **Step 7: Run the DB tests — expect all pass**

Run:
```bash
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
pg_prove -d "$DATABASE_URL" libs/db/tests/41-readonly-note-scope-enforcement.sql libs/db/tests/42-scoped-note-bump-isolation.sql
```
Expected: all assertions PASS.

- [ ] **Step 8: Run the full DB test suite (no regressions)**

Run:
```bash
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
pg_prove -d "$DATABASE_URL" libs/db/tests/*.sql
```
Expected: all files pass (in particular `30-announce-group-contact-isolation.sql`).

- [ ] **Step 9: Commit**

```bash
git add libs/db/schema/90-user-schema/85-user-sync-upserts.sql \
        libs/db/schema/50-tables/25-note.sql \
        libs/db/migrations/ libs/db/migrations/atlas.sum \
        libs/db/src/types.ts
git commit -m "feat(db): scope-enforce read-only replies and make note bump access-aware"
```

---

## Task 4: API — bound unread/push to the note-visible set for scoped notes

**Files:**
- Modify: `workers/api/src/app/sync/notes.ts` (the note POST background task, ~lines 385–489, and `markThreadUnreadForOthers`, ~line 507)
- Test: `workers/api/src/app/sync/notes.test.ts`

- [ ] **Step 1: Write the failing vitest test**

Add to `workers/api/src/app/sync/notes.test.ts` a test asserting that posting a note scoped to a group does not mark unread for a thread recipient outside that group. Mirror the existing setup/harness in that file (reuse its DB/user fixtures and the POST helper). The assertion shape:
```ts
it("scoped reply does not unread non-visible announce recipients", async () => {
  // Arrange: thread addressed to [announce(Everyone), team(Plot Team)],
  //   author = Kris (contact), viewer = announce-only member (read-only),
  //   bystander = another announce-only member.
  // (Use the file's existing seed helpers; create `team` as type 'team',
  //  `announce` as type 'announce', and put viewer + bystander in announce only.)

  // Act: viewer POSTs /sync/notes with access_groups = [teamId].
  const res = await postNote(app, viewer, {
    thread_id: threadId,
    access_groups: [teamId],
    content: "reply to plot team",
  });
  expect(res.status).toBe(200);
  await flushWaitUntil(); // let the background task run (see existing helper)

  // Assert: bystander's thread_state is NOT unread (no row, or read_at set).
  const bystanderState = await db
    .selectFrom("thread_state")
    .select(["read_at"])
    .where("thread_id", "=", threadId)
    .where("user_id", "=", bystanderUserId)
    .executeTakeFirst();
  expect(bystanderState?.read_at ?? "absent").not.toBeNull();

  // Assert: a Plot Team member IS unread (visible).
  const teamState = await db
    .selectFrom("thread_state")
    .select(["read_at"])
    .where("thread_id", "=", threadId)
    .where("user_id", "=", teamMemberUserId)
    .executeTakeFirst();
  expect(teamState).toBeDefined();
  expect(teamState!.read_at).toBeNull();
});
```
(If `notes.test.ts` lacks a `flushWaitUntil`/seed helper, use whatever the file already uses to await the post-response background work and to seed users/threads — do not invent a new harness.)

- [ ] **Step 2: Run the test — expect failure**

Run:
```bash
cd workers/api && pnpm vitest run src/app/sync/notes.test.ts -t "scoped reply does not unread"
```
Expected: FAIL — today `markThreadUnreadForOthers` resolves recipients by group membership and would mark the bystander unread.

- [ ] **Step 3: Add a note-visible-users helper**

In `workers/api/src/app/sync/notes.ts`, add (near `markThreadUnreadForOthers`):
```ts
/**
 * Users (other than `excludeUserId`) who can SEE a scoped note: filed on the
 * thread (thread_priority) AND matching the note's access scope (author, or
 * access_contacts overlaps their contacts, or access_groups overlaps their
 * groups). Mirrors the user.note view's visibility predicate.
 */
async function noteVisibleUserIds(
  db: Kysely<DB>,
  threadId: string,
  createdBy: string,
  accessContacts: string[] | null,
  accessGroups: string[] | null,
  excludeUserId: string,
): Promise<string[]> {
  const rows = await sql<{ user_id: string }>`
    SELECT DISTINCT tp.user_id
    FROM thread_priority tp
    WHERE tp.thread_id = ${threadId}::uuid
      AND tp.revoked_at IS NULL
      AND (
        tp.user_id = ${createdBy}::uuid
        OR (${accessContacts ? sql`${accessContacts}::uuid[] && "user".user_contact_ids(tp.user_id)` : sql`FALSE`})
        OR (${accessGroups ? sql`${accessGroups}::uuid[] && "user".user_group_ids(tp.user_id)` : sql`FALSE`})
      )
  `.execute(db);
  return rows.rows.map((r) => r.user_id).filter((id) => id !== excludeUserId);
}
```

- [ ] **Step 4: Branch the note POST background task on scope**

In the note POST handler's background block (the `if (!analysisHandledUnread) { … markThreadUnreadForOthers … }` region), wrap the unread/notify logic so scoped notes skip the API unread machinery (the DB trigger from Task 3 owns per-user unread) and only push to the visible set:
```ts
          // The DB trigger (update_thread_on_note_change) owns per-user
          // re-emit + unread for SCOPED notes; the API must only push, and
          // only to users who can see the note. Unscoped notes keep the
          // existing analyze/mark-unread fan-out.
          //
          // IMPORTANT: derive scoped-ness from the RESOLVED access values that
          // were passed to upsert_note (the handler resolves body access for
          // the message-mode invariant ~lines 246–267), NOT from raw body —
          // otherwise the API and the DB trigger could disagree on "scoped".
          // Name them as the locals this handler already computes:
          //   resolvedAccessContacts / resolvedAccessGroups (uuid[] | null).
          const isScoped =
            (resolvedAccessContacts != null) || (resolvedAccessGroups != null);

          let affectedUserIds: string[] = [];
          if (isScoped) {
            affectedUserIds = await noteVisibleUserIds(
              db,
              body.thread_id,
              c.var.user.id,            // created_by for a user-authored note
              resolvedAccessContacts ?? null,
              resolvedAccessGroups ?? null,
              c.var.user.id,
            );
          } else if (!analysisHandledUnread) {
            try {
              affectedUserIds = await markThreadUnreadForOthers(
                c.env, db, body.thread_id, c.var.user.id, new Date().toISOString(),
              );
            } catch (error) {
              const logger = createLogger({ operation: "sync:notes:markUnread" });
              logger.error("Failed to mark thread unread for others", error as Error);
              c.var.tracker.captureException(error as Error);
            }
          } else {
            // analyze handled unread; collect thread-contact users for notify
            // (existing behavior, unchanged) …
          }
```
Keep the existing `else` branch body (the analyze-path user collection at ~lines 438–466) intact for the unscoped case. The subsequent DO-notify loop (`for (const userId of affectedUserIds) …`) is unchanged and now naturally pushes only to `affectedUserIds`.

- [ ] **Step 5: Run the test — expect pass**

Run:
```bash
cd workers/api && pnpm vitest run src/app/sync/notes.test.ts -t "scoped reply does not unread"
```
Expected: PASS.

- [ ] **Step 6: Run the notes test file + lint**

Run:
```bash
cd workers/api && pnpm vitest run src/app/sync/notes.test.ts && pnpm lint
```
Expected: all notes tests pass; lint reports no NEW `error TS` (two pre-existing errors may remain — see project notes).

- [ ] **Step 7: Commit**

```bash
git add workers/api/src/app/sync/notes.ts workers/api/src/app/sync/notes.test.ts
git commit -m "feat(api): bound scoped-note unread/push to the note-visible set"
```

---

## Task 5: Flutter — read-only reply defaults to non-announce groups via access_groups

**Files:**
- Modify: `apps/plot/lib/widget/note_editor.dart` (`_finalizeNoteDraft` ~1843–1865, `_readOnlyDefaultShareTargets` ~1880–1895)

- [ ] **Step 1: Split the read-only default into contacts + groups**

Replace `_readOnlyDefaultShareTargets` with a contacts-only helper plus a groups helper:
```dart
  /// Contacts a read-only viewer's note defaults to: every active contact on
  /// the thread. (Group recipients are handled via access_groups, see
  /// [_readOnlyDefaultShareGroups], so new group members see past replies.)
  List<ActorId> _readOnlyDefaultShareContacts(Thread thread) {
    final result = <ActorId>{};
    for (final contactId in thread.activeContacts) {
      result.add(ActorId.fromUuid(contactId));
    }
    return result.toList();
  }

  /// Groups a read-only viewer's note defaults to: every non-announce group on
  /// the thread. Announce groups (the broadcast audience) are excluded so a
  /// reply never goes back to other read-only viewers. Referencing the group
  /// (not a member snapshot) means members added later still see the reply.
  List<ActorId> _readOnlyDefaultShareGroups(Thread thread) {
    final result = <ActorId>[];
    for (final groupId in thread.groups) {
      final group = Group.fromCache(groupId);
      if (group == null || group.type == 'announce') continue;
      result.add(ActorId.fromUuid(groupId));
    }
    return result;
  }
```

- [ ] **Step 2: Set both accessContacts and accessGroups on the reply**

In `_finalizeNoteDraft`, replace the `readOnlyThreadShare` / `accessContactsValue` block and the `copyWith` so the note carries `accessGroups`:
```dart
    final bool readOnlyViewer = widget.viewerMode && thread.isReadOnly;

    final readOnlyShareContacts =
        readOnlyViewer ? _readOnlyDefaultShareContacts(thread) : <ActorId>[];
    final readOnlyShareGroups =
        readOnlyViewer ? _readOnlyDefaultShareGroups(thread) : <ActorId>[];

    final Value<List<ActorId>?> accessContactsValue =
        (widget.viewerMode || replyRestricted)
        ? Value(
            <ActorId>{...replyAccessContacts, ...readOnlyShareContacts}.toList(),
          )
        : const Value.absent();

    final Value<List<ActorId>?> accessGroupsValue = readOnlyViewer
        ? Value(readOnlyShareGroups)
        : const Value.absent();

    Note note = widget.draft.copyWith(
      content: body.isEmpty ? null : body,
      draft: false,
      reNoteId: replyTo?.id,
      addMentions: allAddMentions.isNotEmpty ? allAddMentions : null,
      accessContacts: accessContactsValue,
      accessGroups: accessGroupsValue,
    );
```

- [ ] **Step 3: Analyze**

Run:
```bash
cd apps/plot && flutter analyze lib/widget/note_editor.dart
```
Expected: no new errors (info-level lints tolerated).

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/widget/note_editor.dart
git commit -m "feat(app): read-only replies default to non-announce groups via access_groups"
```

---

## Task 6: Flutter — recipient picker offers the thread's non-announce groups for read-only replies

**Files:**
- Modify: `apps/plot/lib/store/group.dart` (`getPostable` ~line 132) and/or the `RecipientPickerModal` call site in `apps/plot/lib/widget/note_editor.dart` (`_openRecipientPicker` ~1054)

- [ ] **Step 1: Allow the picker to include explicit extra group ids**

In `apps/plot/lib/store/group.dart`, extend `getPostable` to optionally include specific group ids (the thread's non-announce groups) even when the user isn't a member:
```dart
  /// Groups the user can post to. `includeIds` forces specific groups to be
  /// included (e.g. a read-only viewer replying to a thread addressed to a
  /// group they don't belong to), still excluding announce groups.
  static Future<List<GroupRow>> getPostable({
    String? search,
    List<String> includeIds = const [],
  }) async {
    final query = Store.get.select(table)
      ..where(
        (t) =>
            t.archivedAt.isNull() &
            (t.isAdmin.equals(true) |
                (t.isMember.equals(true) & t.type.isNotIn(const ['announce'])) |
                (t.id.isIn(includeIds) & t.type.isNotIn(const ['announce']))),
      );
    if (search != null && search.isNotEmpty) {
      final lower = search.toLowerCase();
      query.where((t) => t.name.like('$lower%') | t.name.like('% $lower%'));
    }
    query.orderBy([(t) => OrderingTerm(expression: t.name)]);
    return query.get();
  }
```

- [ ] **Step 2: Pass the thread's non-announce groups into the picker for read-only replies**

In `_openRecipientPicker` (`apps/plot/lib/widget/note_editor.dart`), compute the thread's non-announce group ids and pass them to the picker so a read-only viewer can narrow within Kris + Plot Team. Locate where `RecipientPickerModal` is constructed and thread the include-ids through to its `getPostable` call. Concretely, where the thread's groups are known:
```dart
    final includeGroupIds = (widget.viewerMode && (widget.thread?.isReadOnly ?? false))
        ? [
            for (final g in widget.thread!.groups)
              if (Group.fromCache(g)?.type != 'announce') g.toString(),
          ]
        : const <String>[];
```
and pass `includeGroupIds` to the `RecipientPickerModal` (add a constructor field that forwards to `Group.getPostable(includeIds: includeGroupIds)`). If `RecipientPickerModal` builds its group list internally, add an `includeGroupIds` parameter to it and forward it to `getPostable`.

- [ ] **Step 3: Analyze**

Run:
```bash
cd apps/plot && flutter analyze lib/store/group.dart lib/widget/note_editor.dart
```
Expected: no new errors.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/store/group.dart apps/plot/lib/widget/note_editor.dart
git commit -m "feat(app): recipient picker includes a read-only thread's non-announce groups"
```

---

## Task 7: Integration verification & finalize

**Files:** none (verification) + `docs/updates.md`

- [ ] **Step 1: Manual end-to-end (run-app skill)**

Using the `run-app` skill, with three accounts (a non-Plot-Team user A, a Plot Team member, and another non-Plot-Team user B):
- As A, open "Welcome to Plot!" and post a reply.
- Verify the Plot Team member sees A's reply and the thread surfaces for them.
- Verify B does **not** see the reply and "Welcome to Plot!" does **not** re-surface for B.
- Verify A sees their own reply.

- [ ] **Step 2: Update user-facing docs**

Add a bullet to the top section of `docs/updates.md`:
```markdown
- You can now reply to onboarding messages — your reply goes privately to the Plot team, not to everyone who received the welcome.
```
Commit:
```bash
git add docs/updates.md && git commit -m "docs: note onboarding reply-to-Plot-Team in updates"
```

- [ ] **Step 3: Finalize**

Run the `/finalize` checklist (lint changed packages, backwards-compat, error capture, docs). Resolve any findings, then the branch is ready for PR.

---

## Self-review notes (for the executor)

- **Migration safety:** all DDL is `CREATE OR REPLACE` + a data `UPDATE`/`DELETE`; no destructive schema change → single expand migration in `migrations/`. The `thread_state` `DELETE` in the data migration is safe (not directly synced; see `libs/db/AGENTS.md`).
- **Backwards compat:** old clients that don't send `access_groups` are unaffected; read-only viewers' notes were already required to be scoped, so the stricter check only rejects payloads that were previously a latent leak.
- **Author identity (requirement 1):** handled purely by the data migration adding the existing note `author_id` (the Kris contact) to `thread.contacts`; no actor-model change.
- **If `notes.test.ts` has no waitUntil flush helper:** the post-response work runs in `c.executionCtx.waitUntil`; await it via the test harness's existing mechanism (e.g. the miniflare `waitUntil` drain) rather than adding `sleep`.
