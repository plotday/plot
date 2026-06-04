-- Scoped-note bump isolation (§3):
--   A scoped note (either access array non-NULL) must NOT advance the shared
--   thread.last_note_* columns (that would re-emit / re-sort the thread for
--   the whole audience). Its per-user effect rides on thread_state, restricted
--   to the note-visible set. An UNSCOPED note still bumps the shared columns.
--
-- These tests insert into note directly (not via upsert_note) so they exercise
-- the update_thread_on_note_change trigger in isolation.
BEGIN;
SET LOCAL search_path = public, "user", extensions;
SELECT plan(5);

DO $$
DECLARE
    v_author    uuid := gen_random_uuid();
    v_author_c  uuid;
    v_bystander uuid := gen_random_uuid();   -- announce-only viewer (NOT in team)
    v_bystdr_c  uuid;
    v_team      uuid := gen_random_uuid();
    v_announce  uuid := gen_random_uuid();   -- announce group the bystander is in
    v_thread    uuid := gen_random_uuid();
    v_bystdr_root uuid;
BEGIN
    -- public.user.email is NOT NULL; the signup trigger creates each user's
    -- root priority and a primary linked user_contact. Reuse that auto-created
    -- primary contact (avoids the one-primary-per-user unique index).
    INSERT INTO "user" (id, email) VALUES
        (v_author, 'author@test.local'), (v_bystander, 'bystander@test.local');
    SELECT contact_id INTO v_author_c FROM user_contact
        WHERE user_id = v_author AND "primary" = TRUE AND linked = TRUE LIMIT 1;
    SELECT contact_id INTO v_bystdr_c FROM user_contact
        WHERE user_id = v_bystander AND "primary" = TRUE AND linked = TRUE LIMIT 1;
    SELECT id INTO v_bystdr_root FROM priority
        WHERE user_id = v_bystander AND nlevel(path) = 1 LIMIT 1;

    -- team (author is a member) + announce (bystander is a member; author too,
    -- so the announce filing exists). The bystander is in the announce group
    -- ONLY, never the team group, so a note scoped to [team] is invisible to it.
    INSERT INTO "group" (id, name, type, created_by) VALUES
        (v_team, 'Plot Team', 'team', v_author),
        (v_announce, 'Everyone', 'announce', v_author);
    INSERT INTO group_member (group_id, contact_id) VALUES
        (v_team, v_author_c), (v_announce, v_author_c), (v_announce, v_bystdr_c);

    -- Thread addressed to BOTH groups so the bystander is filed via announce.
    INSERT INTO thread (id, created_by, title, contacts, groups, last_note_seq)
        VALUES (v_thread, v_author, 'T', ARRAY[v_author_c], ARRAY[v_team, v_announce], '0'::xid8);
    -- A raw thread INSERT does not settle the author into a priority (that is
    -- the upsert_thread RPC's job). The scoped-note trigger only bumps
    -- thread_state for users with a settled thread_priority filing, so file
    -- both users here (mirrors 30-announce-group-contact-isolation.sql).
    INSERT INTO thread_priority (thread_id, user_id, priority_id)
    SELECT v_thread, v_author, p.id
      FROM priority p
     WHERE p.user_id = v_author AND nlevel(p.path) = 1
     LIMIT 1
    ON CONFLICT ON CONSTRAINT thread_priority_pkey
        DO UPDATE SET priority_id = EXCLUDED.priority_id, classify_at = NULL;
    -- Settle the bystander's filing (announce membership filed it with a NULL
    -- priority_id pending classification; give it a concrete root priority).
    INSERT INTO thread_priority (thread_id, user_id, priority_id)
        VALUES (v_thread, v_bystander, v_bystdr_root)
        ON CONFLICT ON CONSTRAINT thread_priority_pkey
        DO UPDATE SET priority_id = EXCLUDED.priority_id, classify_at = NULL;
    PERFORM set_config('test.author', v_author::text, false);
    PERFORM set_config('test.bystander', v_bystander::text, false);
    PERFORM set_config('test.thread', v_thread::text, false);
END $$;

-- Capture last_note_seq before any note.
CREATE TEMP TABLE _before AS
    SELECT last_note_seq FROM thread WHERE id = current_setting('test.thread')::uuid;

-- Snapshot the bystander's thread_state BEFORE the scoped note. Addressing the
-- thread to the announce group filed the bystander as a recipient, so a
-- thread_state row already exists from the broadcast — "no leak" means the
-- SCOPED note must leave that row byte-for-byte untouched (no bumped_at
-- advance, no read_at clear), not that no row exists. row_to_json captures the
-- whole row so any field the scoped-note trigger might mutate is compared.
CREATE TEMP TABLE _bystander_before AS
    SELECT row_to_json(ts.*) AS row
    FROM thread_state ts
    WHERE ts.thread_id = current_setting('test.thread')::uuid
      AND ts.user_id = current_setting('test.bystander')::uuid;

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

-- 4. The no-leak invariant: a note scoped to [team] must NOT touch the
--    thread_state of the bystander, who can see the thread only via the
--    announce group and is NOT in the team. This is the core security
--    guarantee — a scoped reply leaves non-visible users untouched. The
--    bystander already has a thread_state row from the announce broadcast, so
--    we assert the row is IDENTICAL before/after (no bumped_at advance, no
--    read_at clear). The unscoped note above never writes thread_state, so any
--    difference here would come from the scoped note leaking to a non-visible
--    user. (Note neither array literal &&'s the bystander's group set: it is in
--    the announce group, not the team the note is scoped to.)
SELECT is(
    (SELECT row::text FROM thread_state ts
       CROSS JOIN LATERAL (SELECT row_to_json(ts.*) AS row) j
     WHERE ts.thread_id = current_setting('test.thread')::uuid
       AND ts.user_id = current_setting('test.bystander')::uuid),
    (SELECT row::text FROM _bystander_before),
    'scoped note leaves a non-visible user''s thread_state untouched');

-- 5. NEGATIVE CONTROL: a note scoped to the announce group (which the bystander
--    IS a member of) MUST change the bystander's thread_state. This proves the
--    snapshot comparison mechanism actually detects changes; if this assertion
--    failed, assertion 4 could pass vacuously even if the trigger were broken.
CREATE TEMP TABLE _bystander_before2 AS
    SELECT row_to_json(ts.*) AS row
    FROM thread_state ts
    WHERE ts.thread_id = current_setting('test.thread')::uuid
      AND ts.user_id = current_setting('test.bystander')::uuid;

INSERT INTO note (id, author_id, created_by, thread_id, draft, access_groups, content, source_created_at)
VALUES (gen_random_uuid(),
        (SELECT contact_id FROM user_contact WHERE user_id = current_setting('test.author')::uuid LIMIT 1),
        current_setting('test.author')::uuid,
        current_setting('test.thread')::uuid, FALSE,
        ARRAY[(SELECT id FROM "group" WHERE name='Everyone' LIMIT 1)],
        'announce-scoped', now());

SELECT ok(
    (SELECT row::text FROM thread_state ts
       CROSS JOIN LATERAL (SELECT row_to_json(ts.*) AS row) j
     WHERE ts.thread_id = current_setting('test.thread')::uuid
       AND ts.user_id = current_setting('test.bystander')::uuid)
    IS DISTINCT FROM
    (SELECT row::text FROM _bystander_before2),
    'negative control: announce-scoped note DOES touch the announce bystander');

SELECT * FROM finish();
ROLLBACK;
