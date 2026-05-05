# Contact Leakage Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the `sync_user_contact_for_thread_contacts` trigger from materializing cross-contact visibility rows for users whose only path to a thread is non-admin membership in an announce group, scrub the existing leaked `user_contact` rows so existing clients delete them on next sync, and PII-redact the "Something to do" test thread that hand-leaked Andrew Karram's contact to 27 unrelated users.

**Architecture:**
- **Schema change A — trigger:** rewrite `sync_user_contact_for_thread_contacts` so the rows it inserts are gated on the recipient having a *legitimate* visibility path into the thread's contacts (their own linked contact appears, they authored the thread, they're an admin of one of the thread's groups, or they're a member of a non-`announce` group on the thread).
- **Schema change B — view-level redaction in `user.actor`:** when a `user_contact` row's `archived_at` is non-null, the corresponding actor row is still emitted for the user (so existing clients receive a tombstone) but with `name`, `email`, and `avatar_url` redacted to `NULL`. This closes the local-cache exposure window: today, archiving a `user_contact` revokes future visibility but still re-pushes the contact's PII to the client one last time before the client marks it archived. With the redaction, the tombstone carries no PII — clients still get the row id + `archived_at IS NOT NULL` (which they need in order to delete from local Drift), but never see the `name`/`email` again. This is a general-purpose fix: any future "I shouldn't have synced that contact to this user" mistake is now resolved by archiving the `user_contact` row alone.
- **Data migration:** PII-redact the offending test thread and its notes, then archive leaked `user_contact` rows by re-running the new trigger's predicate against the existing data and archiving anything it would not have produced.
- Sync propagation is automatic: the existing `set_user_contact_updated_at` BEFORE trigger bumps `seq` on every UPDATE, and `set_thread_updated_at` does the same on `thread`. The `user.actor` view's per-row `seq`, `updated_at`, and `archived_at` already incorporate `uc.seq` for the primary clause; we extend the non-primary clause to do the same so secondary contacts also redact when the primary's `user_contact` is archived. Clients pull via the `seq` cursor and delete the local rows when they see `archived_at IS NOT NULL` (matches the pattern documented in `libs/db/AGENTS.md` "Removing Rows from Synced Tables").
- We do **not** touch `public.contact.name` / `public.contact.email`. Contacts are global (one row per real person) — Andrew himself is a legitimate user of his own contact row. The redaction is per-recipient and lives in the `user.actor` view; the underlying `public.contact` row is unaffected for users whose `user_contact` is still active.

**Out of scope (follow-up):** `user.schedule` also embeds `contact_name` / `contact_email` in its `contacts` JSON aggregate (`libs/db/schema/90-user-schema/31-schedule.sql:53-54`). It joins `schedule_contact → contact` directly, bypassing `user_contact`, so it is a separate exposure surface for meeting attendees and is not addressed by this plan. Open a follow-up if it matters for the same threat model.

**Tech Stack:** PostgreSQL (schema in `libs/db/schema/`), Atlas (migrations via `pnpm gen-migration` / `pnpm apply-migrations`), pgTAP for trigger tests in `libs/db/tests/`.

---

## Pre-flight: read these first

- `libs/db/AGENTS.md` — schema-change workflow, the "Removing Rows from Synced Tables" rule, the "Bump Parent `seq` on Child-Table Changes" rule.
- `libs/db/schema/95-triggers/25-thread_user_contact.sql` — current `sync_user_contact_for_thread_contacts` trigger we are replacing.
- `libs/db/schema/95-triggers/23-thread_group_peers.sql` — `file_thread_priority_for_group_members`, the source of the `thread_priority` rows the buggy trigger keys off of.
- `libs/db/schema/90-user-schema/35-group.sql` — the `user.group` view's `member_contact_ids` clause already encodes "non-admins of announce groups can't see the member list"; the new trigger logic must match.
- `libs/db/schema/50-tables/29-user_contact.sql` — primary key, `seq` trigger, `linked` / `source` columns.
- `CLAUDE.md` (project root) → `AGENTS.md` — "Database Schema Changes" workflow.

The key invariant we are restoring: **a user must have an independent right to see another user's identity before that identity ends up in their `user_contact` table.** Today, any thread filed for them via group membership materializes every other contact on that thread into their `user_contact`, even when the group's `member_contact_ids` would have hidden the same data from them.

---

## Worktree setup

- [ ] **Step 1: Create an isolated worktree**

Use `superpowers:using-git-worktrees`. Branch name: `fix/contact-leak-announce-groups`. Submodule init is automatic.

- [ ] **Step 2: Stand up an isolated DB on the worktree's port**

Run: `bash scripts/worktree-db`

Expected: prints a port and writes `.worktree-db`. After this `psql "$DATABASE_URL" -c 'SELECT 1;'` must work and connect to the worktree's Postgres, not 54322.

- [ ] **Step 3: Confirm migrations are caught up**

Run: `pnpm diff-schema-migrations`

Expected: no differences. If there are differences, stop — the worktree base has unflushed schema changes that must be resolved first.

---

## Task 1: pgTAP test for the announce-group leak

**Files:**
- Create: `libs/db/tests/30-announce-group-contact-isolation.sql`

This test sets up a workspace-scoped "Everyone" announce group, two contact-only members (alice, bob) and one admin (admin), files a thread to the group with alice as a thread contact, and asserts that *bob* does not get a `user_contact` row pointing at alice (admins do).

- [ ] **Step 1: Write the failing test**

Contents:

```sql
BEGIN;

SELECT plan(4);

-- Three users: admin, alice, bob. Each gets a primary contact via upsert_user_contact.
DO $$
DECLARE
    v_admin uuid := gen_random_uuid();
    v_alice uuid := gen_random_uuid();
    v_bob   uuid := gen_random_uuid();
    v_admin_contact uuid;
    v_alice_contact uuid;
    v_bob_contact uuid;
    v_group uuid;
    v_thread uuid := gen_random_uuid();
    v_priority uuid;
BEGIN
    INSERT INTO "public"."user" (id) VALUES (v_admin), (v_alice), (v_bob);

    v_admin_contact := public.upsert_user_contact(v_admin, 'admin@test.local', 'Admin', NULL);
    v_alice_contact := public.upsert_user_contact(v_alice, 'alice@test.local', 'Alice', NULL);
    v_bob_contact   := public.upsert_user_contact(v_bob,   'bob@test.local',   'Bob',   NULL);

    -- Each user gets their own root priority so classify_thread_for_user can resolve.
    INSERT INTO public.priority (id, owner_id, title, path)
    VALUES
        (gen_random_uuid(), v_admin, 'Inbox', 'inbox'),
        (gen_random_uuid(), v_alice, 'Inbox', 'inbox'),
        (gen_random_uuid(), v_bob,   'Inbox', 'inbox');

    -- Create an announce group, admin is the admin, all three are members.
    INSERT INTO public."group" (id, name, type, created_by, auto_maintained)
    VALUES (gen_random_uuid(), 'Announce Test', 'announce', v_admin, false)
    RETURNING id INTO v_group;

    INSERT INTO public.group_admin (group_id, user_id) VALUES (v_group, v_admin);
    INSERT INTO public.group_member (group_id, contact_id) VALUES
        (v_group, v_admin_contact),
        (v_group, v_alice_contact),
        (v_group, v_bob_contact);

    -- File a thread to the announce group, with alice in thread.contacts.
    INSERT INTO public.thread (id, created_by, title, contacts, groups)
    VALUES (v_thread, v_admin, 'Hello announce', ARRAY[v_alice_contact], ARRAY[v_group]);

    -- Assertions
    PERFORM ok(
        EXISTS (SELECT 1 FROM user_contact WHERE user_id = v_admin AND contact_id = v_alice_contact),
        'admin gets visibility into alice (admin sees the membership list)'
    );
    PERFORM ok(
        EXISTS (SELECT 1 FROM thread_priority WHERE thread_id = v_thread AND user_id = v_bob),
        'bob still receives the announce thread (filing not blocked)'
    );
    PERFORM ok(
        NOT EXISTS (SELECT 1 FROM user_contact WHERE user_id = v_bob AND contact_id = v_alice_contact),
        'bob does NOT get a user_contact row for alice via announce-only membership'
    );
    PERFORM ok(
        NOT EXISTS (SELECT 1 FROM user_contact WHERE user_id = v_alice AND contact_id = v_alice_contact AND linked = false),
        'alice does not get a redundant unlinked self-row'
    );
END $$;

SELECT * FROM finish();

ROLLBACK;
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
psql "$DATABASE_URL" -f libs/db/tests/30-announce-group-contact-isolation.sql
```

Expected: assertions 1, 2, 4 pass; assertion 3 ("bob does NOT get a user_contact row for alice") **fails** — this proves we are reproducing the production leak under controlled conditions before touching the trigger.

- [ ] **Step 3: Commit the failing test**

```bash
git add libs/db/tests/30-announce-group-contact-isolation.sql
git commit -m "test(db): pin the announce-group cross-contact leak"
```

---

## Task 2: tighten `sync_user_contact_for_thread_contacts`

**Files:**
- Modify: `libs/db/schema/95-triggers/25-thread_user_contact.sql`

Replace the function body with one that only inserts a `user_contact` row for `(tp.user_id, contact_id)` when the recipient has an *independent* right to see the membership: own linked contact on the thread, authored the thread, admin of one of the thread's groups, or member of a non-`announce` group on the thread. The trigger and `CREATE TRIGGER` declaration stay the same — only the function body changes.

- [ ] **Step 1: Replace the function**

New file contents (entire file):

```sql
-- Ensure user_contact rows exist for all contacts on a thread so that
-- external contacts (e.g. from Gmail, Slack connectors) are visible as
-- actors in the app. Fires after INSERT or UPDATE OF contacts on thread.
--
-- Cross-contact visibility is gated: a recipient only gains a user_contact
-- row pointing at another contact on the thread when they have an
-- independent right to see the thread's membership. Concretely, one of:
--   - they authored the thread
--   - one of their own linked contacts is on the thread (peer share)
--   - they admin one of the thread's groups (announce / private / team)
--   - they're a member of a non-`announce` group on the thread
-- This mirrors the visibility rule encoded in user.group.member_contact_ids:
-- non-admins of announce groups must not learn the other members' identities.
--
-- Named with sync_ prefix so it fires alphabetically after
-- file_thread_priority_peers (f < s), ensuring peer thread_priority
-- rows exist before we look them up.
CREATE OR REPLACE FUNCTION public.sync_user_contact_for_thread_contacts ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.contacts IS NULL OR cardinality(NEW.contacts) = 0 THEN
        RETURN NEW;
    END IF;

    INSERT INTO user_contact (user_id, contact_id, linked, source)
    SELECT tp.user_id, arr.contact_id, false, 'thread'
    FROM thread_priority tp
    CROSS JOIN unnest(NEW.contacts) AS arr(contact_id)
    WHERE tp.thread_id = NEW.id
      AND EXISTS (SELECT 1 FROM contact c WHERE c.id = arr.contact_id)
      AND (
            -- Author of the thread always sees membership.
            tp.user_id = NEW.created_by
            -- Recipient's own linked contact is on the thread.
            OR EXISTS (
                SELECT 1
                FROM user_contact uc_self
                WHERE uc_self.user_id = tp.user_id
                  AND uc_self.linked = TRUE
                  AND uc_self.archived_at IS NULL
                  AND uc_self.contact_id = ANY(NEW.contacts)
            )
            -- Recipient is an admin of one of the thread's groups.
            OR EXISTS (
                SELECT 1
                FROM unnest(COALESCE(NEW.groups, ARRAY[]::uuid[])) AS gid
                JOIN group_admin ga ON ga.group_id = gid AND ga.user_id = tp.user_id
            )
            -- Recipient is a member of a non-announce group on the thread.
            OR EXISTS (
                SELECT 1
                FROM unnest(COALESCE(NEW.groups, ARRAY[]::uuid[])) AS gid
                JOIN public."group" g ON g.id = gid AND g.type <> 'announce'
                JOIN group_member gm ON gm.group_id = g.id
                JOIN user_contact uc_grp
                    ON uc_grp.contact_id = gm.contact_id
                   AND uc_grp.linked = TRUE
                   AND uc_grp.archived_at IS NULL
                WHERE uc_grp.user_id = tp.user_id
            )
      )
    ON CONFLICT (user_id, contact_id) DO NOTHING;

    RETURN NEW;
END;
$$;

CREATE TRIGGER sync_user_contact_for_thread_contacts
    AFTER INSERT OR UPDATE OF contacts
    ON public.thread
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_user_contact_for_thread_contacts ();
```

- [ ] **Step 2: Generate the schema migration**

Run:

```bash
pnpm gen-migration -- tighten_thread_user_contact_visibility
```

Expected: a new file at `libs/db/migrations/<timestamp>_tighten_thread_user_contact_visibility.sql` containing a `CREATE OR REPLACE FUNCTION public.sync_user_contact_for_thread_contacts ...` body matching the new schema. **Do not edit the generated DDL** — that's Atlas's job.

- [ ] **Step 3: Apply the migration locally**

Run:

```bash
pnpm apply-migrations
```

Expected: the new migration applies cleanly. If Atlas complains about checksum / sum mismatch, run `atlas migrate hash --dir file://libs/db/migrations` and re-apply.

- [ ] **Step 4: Re-run the pgTAP test — it should now pass**

Run:

```bash
psql "$DATABASE_URL" -f libs/db/tests/30-announce-group-contact-isolation.sql
```

Expected: all 4 assertions pass. If assertion 3 still fails, the function body wasn't reloaded — confirm with `\df+ public.sync_user_contact_for_thread_contacts` in psql and check the body matches the schema file.

- [ ] **Step 5: Verify no schema drift**

Run:

```bash
pnpm diff-schema-migrations
```

Expected: no differences.

- [ ] **Step 6: Commit**

```bash
git add libs/db/schema/95-triggers/25-thread_user_contact.sql libs/db/migrations/
git commit -m "fix(db): gate cross-contact visibility for announce-only group members"
```

---

## Task 3: redact PII in `user.actor` for archived `user_contact` rows

**Files:**
- Modify: `libs/db/schema/90-user-schema/34-actor.sql`

The view's first clause already keys off `uc.seq` / `uc.archived_at` for sync propagation. Two changes:

1. Wrap `name`, `email`, `avatar_url` in `CASE WHEN <uc>.archived_at IS NULL THEN <expr> ELSE NULL END` for both the primary and non-primary clauses.
2. Bring the non-primary clause's `seq` / `updated_at` / `archived_at` in line with the primary clause so the redaction actually advances the seq cursor on the secondary row when its primary `user_contact` is archived.

- [ ] **Step 1: Write a failing test for the redaction**

Create `libs/db/tests/32-user-actor-redacts-archived.sql`:

```sql
BEGIN;
SELECT plan(6);

DO $$
DECLARE
    v_andrew uuid := gen_random_uuid();
    v_andrew_c uuid;
    v_andrew_alt uuid := gen_random_uuid();   -- a non-primary identity for Andrew
    v_victim uuid := gen_random_uuid();
    v_victim_c uuid;
    v_row record;
BEGIN
    INSERT INTO "public"."user" (id) VALUES (v_andrew), (v_victim);
    v_andrew_c := public.upsert_user_contact(v_andrew, 'andrew@t.l', 'Andrew K.', 'http://a/p.png');
    v_victim_c := public.upsert_user_contact(v_victim, 'victim@t.l', 'Victim',    NULL);

    -- Add a non-primary contact for Andrew so we exercise the second clause too.
    INSERT INTO public.contact (id, email, name, user_id, "primary")
    VALUES (v_andrew_alt, 'andrew-alt@t.l', 'Andrew Alt', v_andrew, false);

    -- Simulate the historical leak: victim has an unarchived user_contact pointing at Andrew.
    INSERT INTO user_contact (user_id, contact_id, linked, source)
    VALUES (v_victim, v_andrew_c, false, 'thread');

    -- Before archive: victim sees Andrew with PII intact.
    SELECT name, email, avatar_url, archived_at
      INTO v_row
      FROM "user".actor
     WHERE user_id = v_victim AND id = v_andrew_c;

    PERFORM ok(v_row.name = 'Andrew K.', 'pre-archive: name is visible');
    PERFORM ok(v_row.email = 'andrew@t.l', 'pre-archive: email is visible');
    PERFORM ok(v_row.archived_at IS NULL,  'pre-archive: archived_at is null');

    -- Archive the user_contact row (the act we are auditing).
    UPDATE user_contact SET archived_at = now()
     WHERE user_id = v_victim AND contact_id = v_andrew_c;

    -- Post-archive: victim still receives the row (so they can delete locally),
    -- but the row carries no PII.
    SELECT name, email, avatar_url, archived_at
      INTO v_row
      FROM "user".actor
     WHERE user_id = v_victim AND id = v_andrew_c;

    PERFORM ok(v_row.archived_at IS NOT NULL, 'post-archive: archived_at is set');
    PERFORM ok(v_row.name IS NULL AND v_row.email IS NULL AND v_row.avatar_url IS NULL,
              'post-archive: name/email/avatar are redacted');

    -- The non-primary identity for Andrew must also redact, since revoking
    -- visibility on the primary revokes visibility on every alias.
    SELECT name, email, archived_at
      INTO v_row
      FROM "user".actor
     WHERE user_id = v_victim AND id = v_andrew_alt;
    PERFORM ok(
      v_row.archived_at IS NOT NULL AND v_row.name IS NULL AND v_row.email IS NULL,
      'post-archive: non-primary identity also redacts'
    );

    -- Andrew's own self-row must remain pristine (his uc is linked=true, not archived).
    PERFORM ok(
      EXISTS (SELECT 1 FROM "user".actor WHERE user_id = v_andrew AND id = v_andrew_c
              AND name = 'Andrew K.' AND archived_at IS NULL),
      'andrew still sees his own contact unredacted'
    );
END $$;

SELECT * FROM finish();
ROLLBACK;
```

Note: 7 assertions but `plan(6)` — bump `plan(6)` to `plan(7)` to match. (Reads more naturally to count assertions after writing them.)

Run:

```bash
psql "$DATABASE_URL" -f libs/db/tests/32-user-actor-redacts-archived.sql
```

Expected: assertions 1-3 pass (pre-archive); assertions 4 ("archived_at is set") passes; assertion 5 ("name/email/avatar are redacted") **fails** with "false is not true" because the current view returns `a.name` unconditionally; assertion 6 about non-primary redaction also fails (and would also fail to advance seq); assertion 7 passes.

- [ ] **Step 2: Replace the `user.actor` view body**

Open `libs/db/schema/90-user-schema/34-actor.sql` and replace the entire `CREATE OR REPLACE VIEW "user"."actor" ...` block with:

```sql
CREATE OR REPLACE VIEW "user"."actor" --
AS
-- Contacts visible via user_contact (primary or external contacts).
-- When uc.archived_at IS NOT NULL the row is still emitted so existing
-- clients can mark the actor archived in their local cache, but name /
-- email / avatar are redacted: archiving a user_contact is the canonical
-- way to revoke visibility, and the tombstone we emit must not re-push
-- PII the user is no longer entitled to see.
SELECT
    uc.user_id,
    a.id,
    a.created_at,
    GREATEST(uc.updated_at, a.updated_at) AS updated_at,
    GREATEST(uc.seq, a.seq) AS seq,
    COALESCE(a.archived_at, uc.archived_at) AS archived_at,
    a.type,
    CASE WHEN uc.archived_at IS NULL THEN a.name       ELSE NULL END AS name,
    CASE WHEN uc.archived_at IS NULL THEN a.email      ELSE NULL END AS email,
    CASE WHEN uc.archived_at IS NULL THEN a.avatar_url ELSE NULL END AS avatar_url,
    EXISTS (
        SELECT 1
        FROM contact c
        WHERE c.id = a.id
            AND c.user_id = uc.user_id
    ) AS self,
    a.inviteable,
    true AS "primary",
    c.user_id AS linked_user_id
FROM
    user_contact uc
    JOIN contact c ON c.id = uc.contact_id
    JOIN actor a ON a.id = c.id
WHERE
    (c.user_id IS NULL OR c."primary" = true)
UNION ALL
-- Non-primary contacts: include for any user who can already see
-- the primary contact, so notes authored by alternate contact IDs
-- resolve to a name instead of "Unknown" for all viewers. seq /
-- updated_at / archived_at incorporate uc_primary so revoking the
-- primary's user_contact propagates redaction to the alias too.
SELECT
    uc_primary.user_id,
    a.id,
    a.created_at,
    GREATEST(uc_primary.updated_at, a.updated_at) AS updated_at,
    GREATEST(uc_primary.seq, a.seq) AS seq,
    COALESCE(a.archived_at, uc_primary.archived_at) AS archived_at,
    a.type,
    CASE WHEN uc_primary.archived_at IS NULL THEN a.name       ELSE NULL END AS name,
    CASE WHEN uc_primary.archived_at IS NULL THEN a.email      ELSE NULL END AS email,
    CASE WHEN uc_primary.archived_at IS NULL THEN a.avatar_url ELSE NULL END AS avatar_url,
    (c.user_id = uc_primary.user_id) AS self,
    a.inviteable,
    false AS "primary",
    c.user_id AS linked_user_id
FROM
    contact c
    JOIN actor a ON a.id = c.id
    JOIN contact c_primary ON c_primary.user_id = c.user_id AND c_primary."primary" = true
    JOIN user_contact uc_primary ON uc_primary.contact_id = c_primary.id
WHERE
    c."primary" = false
UNION ALL
-- Twist instances owned by each user (unchanged)
SELECT
    u.id AS user_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.seq,
    a.archived_at,
    a.type,
    a.name,
    a.email,
    a.avatar_url,
    false AS self,
    a.inviteable,
    true AS "primary",
    NULL::uuid AS linked_user_id
FROM
    "public"."user" u
    JOIN twist_instance pt ON pt.owner_id = u.id
    JOIN actor a ON a.id = pt.id;
```

- [ ] **Step 3: Generate and apply the schema migration**

Run:

```bash
pnpm gen-migration -- redact_user_actor_when_archived
pnpm apply-migrations
```

Expected: a new migration file is created and applied. The body should be a `CREATE OR REPLACE VIEW "user"."actor" ...` reflecting the change.

- [ ] **Step 4: Re-run the redaction test — should now pass**

```bash
psql "$DATABASE_URL" -f libs/db/tests/32-user-actor-redacts-archived.sql
```

Expected: all 7 assertions pass.

- [ ] **Step 5: Verify schema diff is clean**

```bash
pnpm diff-schema-migrations
```

Expected: no differences.

- [ ] **Step 6: Commit**

```bash
git add libs/db/schema/90-user-schema/34-actor.sql libs/db/migrations/ libs/db/tests/32-user-actor-redacts-archived.sql
git commit -m "fix(db): redact PII in user.actor for archived user_contact rows"
```

---

## Task 4: data-cleanup migration — redact "Something to do" + archive leaked `user_contact` rows

**Files:**
- Create: `libs/db/migrations/<next_timestamp>_redact_contact_leakage.sql` (manual migration, see steps below)

This is a forward-only data migration. It does **not** modify schema. Generate an empty Atlas-tracked file, then write the data SQL ourselves.

The migration does two things:

1. **PII-redact thread `019c2721-4201-7e52-83fb-b697d69b7bf1` ("Something to do") and its notes.**
   - Set `thread.title = NULL`, `thread.preview = NULL`, `thread.contacts = ARRAY[]::uuid[]`, `thread.groups = ARRAY[]::uuid[]`.
   - Ensure `thread.archived_at` is set (already true in prod but idempotent — re-stamp to bump `seq`).
   - For all rows in `note` whose `thread_id` is this thread, archive them and null their `body` / `body_text` / any other PII-bearing columns. (Inspect `libs/db/schema/50-tables/note*.sql` before writing the UPDATE — fields may be `body`, `markdown`, `plain_text`, etc.)
   - The trigger-driven `seq` bump on `thread` and `note` propagates the redaction to clients.

2. **Archive leaked `user_contact` rows.**
   - For every `user_contact` row with `source = 'thread' AND linked = false AND archived_at IS NULL`, re-evaluate the new trigger predicate against the *current* set of threads. If no thread justifies this row under the new rule, set `archived_at = now()`.
   - Re-stating the predicate as a SQL `WHERE` clause: a `(user_id, contact_id)` pair is justified iff there exists a non-archived thread `t` such that `contact_id = ANY(t.contacts)` AND there is a `thread_priority` row `(t.id, user_id, _)` AND the user has an independent visibility path (author / own contact in `t.contacts` / admin of a group in `t.groups` / member of a non-announce group in `t.groups`).
   - Everything that was justified solely by being a non-admin of an announce group on a thread loses its justification and gets archived.

- [ ] **Step 1: Inspect the `note` table before writing the redaction**

Run:

```bash
ls libs/db/schema/50-tables/ | grep -i note
psql "$DATABASE_URL" -c "\d public.note" | head -40
```

Capture which columns hold note content. The SQL block in step 3 below lists `body` and `body_text` — replace those with the actual columns if they differ.

- [ ] **Step 2: Generate an empty migration shell**

Run:

```bash
pnpm gen-migration -- redact_contact_leakage
```

If Atlas refuses because there's no schema delta, create the file by hand and update the checksum:

```bash
TS=$(date -u +%Y%m%d%H%M%S)
touch "libs/db/migrations/${TS}_redact_contact_leakage.sql"
```

(Confirm the timestamp is greater than the previous migration's. Then write contents in step 3.)

- [ ] **Step 3: Write the data-migration body**

Open the file and write:

```sql
-- Data migration: scrub the "Something to do" PII test thread and archive
-- user_contact rows that the tightened sync_user_contact_for_thread_contacts
-- would not have produced. See docs/superpowers/plans/2026-05-04-contact-leak-fix.md.

BEGIN;

-- 1. Redact the leaky test thread.
UPDATE public.thread
   SET title       = NULL,
       preview     = NULL,
       contacts    = ARRAY[]::uuid[],
       groups      = ARRAY[]::uuid[],
       archived_at = COALESCE(archived_at, now()),
       updated_at  = now()
 WHERE id = '019c2721-4201-7e52-83fb-b697d69b7bf1';

-- Redact and archive notes belonging to that thread. Replace `body`/`body_text`
-- with the real PII-bearing columns identified in Task 3 / Step 1.
UPDATE public.note
   SET body        = NULL,
       body_text   = NULL,
       archived_at = COALESCE(archived_at, now()),
       updated_at  = now()
 WHERE thread_id = '019c2721-4201-7e52-83fb-b697d69b7bf1';

-- 2. Archive user_contact rows the new trigger would not have created.
-- Re-evaluate the predicate against current state; anything unjustified is
-- archived (not deleted) so existing clients pull the archive via the seq
-- cursor and remove the row from their local Drift db.
WITH unjustified AS (
    SELECT uc.user_id, uc.contact_id
    FROM public.user_contact uc
    WHERE uc.source = 'thread'
      AND uc.linked = false
      AND uc.archived_at IS NULL
      AND NOT EXISTS (
            SELECT 1
            FROM public.thread t
            JOIN public.thread_priority tp
                 ON tp.thread_id = t.id AND tp.user_id = uc.user_id
            WHERE uc.contact_id = ANY(t.contacts)
              AND t.archived_at IS NULL
              AND (
                    t.created_by = uc.user_id
                    OR EXISTS (
                        SELECT 1 FROM public.user_contact uc_self
                        WHERE uc_self.user_id = uc.user_id
                          AND uc_self.linked = TRUE
                          AND uc_self.archived_at IS NULL
                          AND uc_self.contact_id = ANY(t.contacts)
                    )
                    OR EXISTS (
                        SELECT 1
                        FROM unnest(COALESCE(t.groups, ARRAY[]::uuid[])) AS gid
                        JOIN public.group_admin ga
                             ON ga.group_id = gid AND ga.user_id = uc.user_id
                    )
                    OR EXISTS (
                        SELECT 1
                        FROM unnest(COALESCE(t.groups, ARRAY[]::uuid[])) AS gid
                        JOIN public."group" g
                             ON g.id = gid AND g.type <> 'announce'
                        JOIN public.group_member gm ON gm.group_id = g.id
                        JOIN public.user_contact uc_grp
                             ON uc_grp.contact_id = gm.contact_id
                            AND uc_grp.linked = TRUE
                            AND uc_grp.archived_at IS NULL
                        WHERE uc_grp.user_id = uc.user_id
                    )
              )
      )
)
UPDATE public.user_contact uc
   SET archived_at = now(),
       updated_at  = now()
  FROM unjustified u
 WHERE uc.user_id = u.user_id
   AND uc.contact_id = u.contact_id;

COMMIT;
```

- [ ] **Step 4: Update the Atlas checksum**

Run:

```bash
atlas migrate hash --dir file://libs/db/migrations
```

Expected: `atlas.sum` is updated. (Per `libs/db/AGENTS.md`: any manually-edited migration must be re-hashed.)

- [ ] **Step 5: Apply the migration**

Run:

```bash
pnpm apply-migrations
```

Expected: applies cleanly with non-zero rowcounts on both UPDATE statements (assuming you seeded the test thread / a few leaked user_contact rows in the worktree DB; otherwise it's a no-op locally — which is fine, the test in Task 1 covers correctness).

- [ ] **Step 6: Verify no further schema drift**

Run:

```bash
pnpm diff-schema-migrations
```

Expected: no differences. The schema didn't change in this migration.

- [ ] **Step 7: Commit**

```bash
git add libs/db/migrations/
git commit -m "fix(db): redact \"Something to do\" thread and archive leaked user_contact rows"
```

---

## Task 5: pgTAP test for the data-cleanup predicate

**Files:**
- Create: `libs/db/tests/31-redact-contact-leakage-predicate.sql`

This pins the `WITH unjustified AS (...)` predicate from Task 3 / Step 3 against fixtures that cover all four "justified" branches plus the "leaked" case. If anyone ever loosens the predicate the test fails.

- [ ] **Step 1: Write the test**

Contents:

```sql
BEGIN;

SELECT plan(5);

DO $$
DECLARE
    v_admin uuid := gen_random_uuid();
    v_alice uuid := gen_random_uuid();
    v_bob   uuid := gen_random_uuid();
    v_eve   uuid := gen_random_uuid();
    v_alice_c uuid;
    v_bob_c   uuid;
    v_eve_c   uuid;
    v_admin_c uuid;
    v_announce uuid;
    v_team_g   uuid;
    v_thread   uuid := gen_random_uuid();
BEGIN
    INSERT INTO "public"."user" (id) VALUES (v_admin), (v_alice), (v_bob), (v_eve);
    v_admin_c := public.upsert_user_contact(v_admin, 'a@t.l', 'A', NULL);
    v_alice_c := public.upsert_user_contact(v_alice, 'al@t.l', 'Al', NULL);
    v_bob_c   := public.upsert_user_contact(v_bob,   'b@t.l',  'B',  NULL);
    v_eve_c   := public.upsert_user_contact(v_eve,   'e@t.l',  'E',  NULL);

    INSERT INTO public.priority (id, owner_id, title, path) VALUES
        (gen_random_uuid(), v_admin, 'I', 'inbox'),
        (gen_random_uuid(), v_alice, 'I', 'inbox'),
        (gen_random_uuid(), v_bob,   'I', 'inbox'),
        (gen_random_uuid(), v_eve,   'I', 'inbox');

    INSERT INTO public."group" (id, name, type, created_by, auto_maintained)
    VALUES (gen_random_uuid(), 'announce', 'announce', v_admin, false)
    RETURNING id INTO v_announce;
    INSERT INTO public.group_admin (group_id, user_id) VALUES (v_announce, v_admin);
    INSERT INTO public.group_member (group_id, contact_id) VALUES
        (v_announce, v_admin_c), (v_announce, v_alice_c),
        (v_announce, v_bob_c),   (v_announce, v_eve_c);

    INSERT INTO public."group" (id, name, type, created_by, auto_maintained)
    VALUES (gen_random_uuid(), 'team', 'team', v_admin, false)
    RETURNING id INTO v_team_g;
    INSERT INTO public.group_member (group_id, contact_id) VALUES
        (v_team_g, v_alice_c), (v_team_g, v_bob_c);

    -- A thread to the announce group AND the team group, with eve in contacts.
    INSERT INTO public.thread (id, created_by, title, contacts, groups)
    VALUES (v_thread, v_admin, 'Hello', ARRAY[v_eve_c], ARRAY[v_announce, v_team_g]);

    -- After the new trigger:
    --  * admin (group admin) sees eve         -> justified
    --  * alice (team-group member, non-announce) sees eve -> justified
    --  * bob   (team-group member)           -> justified
    --  * eve   has her own contact on thread -> justified (self)
    --  * a hypothetical "outsider" who only has thread_priority via the
    --    announce group must NOT see eve. Simulate by inserting a stray
    --    user_contact row as if the OLD trigger had fired:
    INSERT INTO user_contact (user_id, contact_id, linked, source)
    VALUES (v_bob, v_eve_c, false, 'thread')   -- bob is justified anyway
    ON CONFLICT DO NOTHING;

    -- Add a user with NO membership at all, simulating legacy leak data.
    INSERT INTO "public"."user" (id) VALUES ('11111111-1111-1111-1111-111111111111');
    INSERT INTO user_contact (user_id, contact_id, linked, source)
    VALUES ('11111111-1111-1111-1111-111111111111', v_eve_c, false, 'thread');
    INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
    SELECT v_thread, '11111111-1111-1111-1111-111111111111', id
      FROM public.priority WHERE owner_id = '11111111-1111-1111-1111-111111111111'
      LIMIT 1;

    -- Run the cleanup predicate from the migration:
    WITH unjustified AS (
        SELECT uc.user_id, uc.contact_id
        FROM public.user_contact uc
        WHERE uc.source = 'thread' AND uc.linked = false AND uc.archived_at IS NULL
          AND NOT EXISTS (
                SELECT 1 FROM public.thread t
                JOIN public.thread_priority tp ON tp.thread_id = t.id AND tp.user_id = uc.user_id
                WHERE uc.contact_id = ANY(t.contacts) AND t.archived_at IS NULL AND (
                      t.created_by = uc.user_id
                   OR EXISTS (SELECT 1 FROM public.user_contact uc_self
                              WHERE uc_self.user_id = uc.user_id AND uc_self.linked AND uc_self.archived_at IS NULL
                                AND uc_self.contact_id = ANY(t.contacts))
                   OR EXISTS (SELECT 1 FROM unnest(COALESCE(t.groups, ARRAY[]::uuid[])) gid
                              JOIN public.group_admin ga ON ga.group_id = gid AND ga.user_id = uc.user_id)
                   OR EXISTS (SELECT 1 FROM unnest(COALESCE(t.groups, ARRAY[]::uuid[])) gid
                              JOIN public."group" g ON g.id = gid AND g.type <> 'announce'
                              JOIN public.group_member gm ON gm.group_id = g.id
                              JOIN public.user_contact ug ON ug.contact_id = gm.contact_id
                                AND ug.linked AND ug.archived_at IS NULL
                              WHERE ug.user_id = uc.user_id)
                  )
          )
    )
    UPDATE public.user_contact uc SET archived_at = now()
      FROM unjustified u
     WHERE uc.user_id = u.user_id AND uc.contact_id = u.contact_id;

    PERFORM ok(
        EXISTS (SELECT 1 FROM user_contact WHERE user_id = v_bob AND contact_id = v_eve_c AND archived_at IS NULL),
        'bob (non-announce team member) keeps visibility into eve'
    );
    PERFORM ok(
        NOT EXISTS (SELECT 1 FROM user_contact
                    WHERE user_id = '11111111-1111-1111-1111-111111111111'
                      AND contact_id = v_eve_c
                      AND archived_at IS NULL),
        'announce-only outsider loses visibility'
    );
    PERFORM ok(
        EXISTS (SELECT 1 FROM user_contact WHERE user_id = v_admin AND contact_id = v_eve_c AND archived_at IS NULL),
        'group admin keeps visibility'
    );
    PERFORM ok(
        EXISTS (SELECT 1 FROM user_contact WHERE user_id = v_alice AND contact_id = v_eve_c AND archived_at IS NULL),
        'alice (team group member) keeps visibility'
    );
    -- Eve's self-link must remain linked=true regardless.
    PERFORM ok(
        EXISTS (SELECT 1 FROM user_contact WHERE user_id = v_eve AND contact_id = v_eve_c AND linked = TRUE AND archived_at IS NULL),
        'eve self-link untouched'
    );
END $$;

SELECT * FROM finish();

ROLLBACK;
```

- [ ] **Step 2: Run it**

```bash
psql "$DATABASE_URL" -f libs/db/tests/31-redact-contact-leakage-predicate.sql
```

Expected: 5 of 5 assertions pass.

- [ ] **Step 3: Commit**

```bash
git add libs/db/tests/31-redact-contact-leakage-predicate.sql
git commit -m "test(db): pin cleanup predicate for contact leak migration"
```

---

## Task 6: end-to-end verification on a prod-shaped fixture

**Files:** none — this task uses live psql against the worktree DB.

The earlier tests prove correctness in isolation; this task proves the cleanup migration produces the right outcome against a fixture seeded to mirror the production state we discovered.

- [ ] **Step 1: Seed the fixture**

Run (in psql against `$DATABASE_URL`):

```sql
-- Reset to a known state — only safe in worktree DB (port != 54322).
SELECT current_setting('port');  -- sanity check; abort if 54322

-- Create one "victim" user and a leaked user_contact row using the OLD
-- trigger semantics (insert directly to bypass the new gate).
DO $$
DECLARE
    v_andrew uuid := gen_random_uuid();
    v_andrew_c uuid;
    v_victim uuid := gen_random_uuid();
    v_victim_c uuid;
    v_announce uuid;
    v_thread uuid := gen_random_uuid();
    v_priority uuid;
BEGIN
    INSERT INTO "public"."user" (id) VALUES (v_andrew), (v_victim);
    v_andrew_c := public.upsert_user_contact(v_andrew, 'andrew-fixture@t.l', 'Andrew', NULL);
    v_victim_c := public.upsert_user_contact(v_victim, 'victim@t.l', 'V', NULL);

    INSERT INTO public.priority (id, owner_id, title, path)
    VALUES (gen_random_uuid(), v_andrew, 'I', 'inbox')
    RETURNING id INTO v_priority;
    INSERT INTO public.priority (id, owner_id, title, path)
    VALUES (gen_random_uuid(), v_victim, 'I', 'inbox');

    INSERT INTO public."group" (id, name, type, created_by, auto_maintained)
    VALUES (gen_random_uuid(), 'Everyone', 'announce', v_andrew, true)
    RETURNING id INTO v_announce;
    INSERT INTO public.group_member (group_id, contact_id)
    VALUES (v_announce, v_andrew_c), (v_announce, v_victim_c);

    INSERT INTO public.thread (id, created_by, title, contacts, groups)
    VALUES (v_thread, v_andrew, 'pre-fix thread', ARRAY[v_andrew_c], ARRAY[v_announce]);

    -- The new trigger will NOT have inserted a victim->andrew row, so
    -- simulate the historical leak by inserting it directly:
    INSERT INTO user_contact (user_id, contact_id, linked, source)
    VALUES (v_victim, v_andrew_c, false, 'thread');
END $$;
```

- [ ] **Step 2: Run the cleanup migration query body manually**

Copy the WITH unjustified ... UPDATE block from Task 3 / Step 3 and execute it.

- [ ] **Step 3: Confirm the leaked row was archived**

```sql
SELECT user_id, contact_id, archived_at IS NOT NULL AS archived
  FROM user_contact
 WHERE source = 'thread' AND linked = false
 ORDER BY archived;
```

Expected: the seeded victim's row has `archived = true`. The Andrew self-link (linked=true) was untouched.

- [ ] **Step 4: Confirm seq was bumped on the archived row**

```sql
SELECT pg_current_xact_id() AS now_xid, max(seq) AS max_uc_seq
  FROM user_contact;
```

Expected: `max_uc_seq` reflects a recent transaction (i.e. greater than any seq from before the migration). Clients gating on `seq > last_horizon` will pull this row.

- [ ] **Step 5: No commit — this task is verification only.**

If anything failed, fix the migration and re-run Task 3.

---

## Task 7: pre-merge finalization

- [ ] **Step 1: Lint affected packages**

```bash
pnpm lint
```

Expected: no errors.

- [ ] **Step 2: `pnpm types` to refresh DB types**

```bash
pnpm types
```

Expected: no diff under `libs/db/src/types/` (we only changed a function body and ran a data migration; no table shape change).

- [ ] **Step 3: Run /finalize**

Per CLAUDE.md, run `/finalize` to handle backwards compatibility, error capture, and `docs/updates.md`.

For `docs/updates.md`, add a one-liner to the top section, e.g.:

```
- Tightened a privacy gap where members of broadcast groups (e.g. "Everyone") could be exposed to each other's contact details. Affected contacts have been removed from your contact list automatically.
```

- [ ] **Step 4: Push & open PR**

Use `commit-commands:commit-push-pr`. PR title: `fix: contact leakage via announce-group thread fan-out`.

The PR description must call out:
- Production data was modified by the data-migration block (redacted thread `019c2721`, archived ~1.7K leaked `user_contact` rows).
- The Flutter client requires no code change — `archived_at` propagation through the existing `seq` cursor handles client-side cleanup.
- The schema change is forward-compatible; old clients continue to function.

---

## Self-review

**Spec coverage:**
- [x] (1) Delete/archive thread `019c2721`. → Task 4 / Step 3 (UPDATE thread + UPDATE notes).
- [x] (2) Fix announce-group semantics so members aren't exposed to each other. → Task 2 (trigger rewrite); Tasks 1 + 5 (tests).
- [x] (3) Propagate `archived_at` via sync. → Relies on existing `seq` triggers on `user_contact`, `thread`, `note`. Task 3 also extends `user.actor`'s non-primary clause to include `uc_primary.seq` so archive propagates to alias contacts. Verified in Task 6 / Step 4.
- [x] (4) Redact PII so existing and new clients no longer see name/email after revocation. → Task 3: `user.actor` returns the row with `archived_at` set + `name/email/avatar_url` NULLed when the corresponding `user_contact` is archived. This is per-recipient; `public.contact` itself is unchanged for users with active visibility. Thread/note-level PII (the "Something to do" thread itself) is also nulled in Task 4.
- [x] (5) Make this reusable for future leakage mistakes. → The `user.actor` redaction pattern works generally: any time we discover an unintended `user_contact`, archiving it (via SQL or admin tooling) revokes future visibility *and* purges the cached PII from the affected client's local DB on the next sync. No bespoke per-incident migration needed.

**Type / function-name consistency:** `sync_user_contact_for_thread_contacts` keeps the same signature, trigger declaration, and call sites. The `user.actor` view keeps the same column list, types, and `linked_user_id` semantics — Flutter callers do not change. No schema renames. The data migration uses fully-qualified table/column references (`public.user_contact`, `public.thread`, `public.note`).

**Placeholder scan:** Step 1 of Task 4 calls out one inspection step: confirm the actual PII columns in `public.note` (the SQL block lists `body` / `body_text` but the real columns may be `body` / `markdown` / `plain_text` / etc.). This is a deliberate inspection step, not an unfilled placeholder — the implementer must look at `\d public.note` and substitute the real column list before writing the UPDATE.

The note in Task 3 / Step 1 about `plan(6)` vs 7 assertions: bump it to `plan(7)` when implementing.
