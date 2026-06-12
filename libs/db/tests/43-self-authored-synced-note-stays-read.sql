-- Self-authored synced note must not mark the author unread (§ notifications):
--   When a user replies OUTSIDE Plot (e.g. in Gmail) and a connector syncs the
--   reply back as a SCOPED note, the note carries:
--     created_by = the connector's twist_instance_id (NOT the user), and
--     author_id  = the user's own linked contact (the real author).
--   The scoped branch of update_thread_on_note_change marks the thread unread
--   (read_at = NULL) for every visible user except the AUTHOR. The author must
--   be identified by author_id (resolved to the owning user via its linked
--   contact), not only by created_by — otherwise a user gets notified about
--   their own reply made outside Plot.
--
-- These tests insert into note directly (not via upsert_note) so they exercise
-- the update_thread_on_note_change trigger in isolation, with created_by set to
-- a synthetic connector id distinct from the author user.
BEGIN;
SET LOCAL search_path = public, "user", extensions;
SELECT plan(3);

DO $$
DECLARE
    v_user      uuid := gen_random_uuid();
    v_user_c    uuid;
    v_other     uuid := gen_random_uuid();    -- a genuine other sender
    v_other_c   uuid;
    v_connector uuid := gen_random_uuid();     -- synthetic connector twist_instance_id
    v_thread1   uuid := gen_random_uuid();     -- fresh thread (INSERT branch)
    v_thread2   uuid := gen_random_uuid();     -- already-read thread (ON CONFLICT branch)
    v_user_root uuid;
BEGIN
    INSERT INTO "user" (id, email) VALUES
        (v_user, 'me@test.local'), (v_other, 'other@test.local');
    SELECT contact_id INTO v_user_c FROM user_contact
        WHERE user_id = v_user AND "primary" = TRUE AND linked = TRUE LIMIT 1;
    SELECT contact_id INTO v_other_c FROM user_contact
        WHERE user_id = v_other AND "primary" = TRUE AND linked = TRUE LIMIT 1;
    SELECT id INTO v_user_root FROM priority
        WHERE user_id = v_user AND nlevel(path) = 1 LIMIT 1;

    -- Two threads visible to the user (contacts = [me, other]).
    INSERT INTO thread (id, created_by, title, contacts, last_note_seq) VALUES
        (v_thread1, v_user, 'T1', ARRAY[v_user_c, v_other_c], '0'::xid8),
        (v_thread2, v_user, 'T2', ARRAY[v_user_c, v_other_c], '0'::xid8);

    -- The scoped-note trigger only bumps thread_state for users with a settled
    -- thread_priority filing; file the user on both threads (a raw thread
    -- INSERT does not settle the author into a priority).
    INSERT INTO thread_priority (thread_id, user_id, priority_id) VALUES
        (v_thread1, v_user, v_user_root),
        (v_thread2, v_user, v_user_root)
    ON CONFLICT ON CONSTRAINT thread_priority_pkey
        DO UPDATE SET priority_id = EXCLUDED.priority_id, classify_at = NULL;

    -- Thread2: the user has ALREADY read it (pre-existing read thread_state row),
    -- exercising the ON CONFLICT DO UPDATE branch.
    INSERT INTO thread_state (user_id, thread_id, read_at)
        VALUES (v_user, v_thread2, now() - interval '1 hour');

    PERFORM set_config('test.user', v_user::text, false);
    PERFORM set_config('test.user_c', v_user_c::text, false);
    PERFORM set_config('test.other_c', v_other_c::text, false);
    PERFORM set_config('test.connector', v_connector::text, false);
    PERFORM set_config('test.thread1', v_thread1::text, false);
    PERFORM set_config('test.thread2', v_thread2::text, false);
END $$;

-- 1. INSERT branch: a SCOPED note the user authored OUTSIDE Plot
--    (created_by = connector, author_id = the user's own contact) must create
--    the author's thread_state as READ — never unread.
INSERT INTO note (id, author_id, created_by, thread_id, draft, access_contacts, content, source_created_at)
VALUES (gen_random_uuid(),
        current_setting('test.user_c')::uuid,
        current_setting('test.connector')::uuid,
        current_setting('test.thread1')::uuid, FALSE,
        ARRAY[current_setting('test.user_c')::uuid, current_setting('test.other_c')::uuid],
        'my own reply', now());

SELECT isnt(
    (SELECT read_at FROM thread_state
      WHERE user_id = current_setting('test.user')::uuid
        AND thread_id = current_setting('test.thread1')::uuid),
    NULL,
    'self-authored synced note (created_by=connector, author_id=my contact) leaves the author READ (INSERT branch)');

-- 2. ON CONFLICT branch: the same scenario on a thread the author had ALREADY
--    read must NOT clear their read_at.
INSERT INTO note (id, author_id, created_by, thread_id, draft, access_contacts, content, source_created_at)
VALUES (gen_random_uuid(),
        current_setting('test.user_c')::uuid,
        current_setting('test.connector')::uuid,
        current_setting('test.thread2')::uuid, FALSE,
        ARRAY[current_setting('test.user_c')::uuid, current_setting('test.other_c')::uuid],
        'my own reply 2', now());

SELECT isnt(
    (SELECT read_at FROM thread_state
      WHERE user_id = current_setting('test.user')::uuid
        AND thread_id = current_setting('test.thread2')::uuid),
    NULL,
    'self-authored synced note leaves an already-read thread READ (ON CONFLICT branch)');

-- 3. NEGATIVE CONTROL: a SCOPED note authored by SOMEONE ELSE
--    (author_id = the other contact) DOES mark the user unread, proving the fix
--    does not blanket-suppress unread marking.
INSERT INTO note (id, author_id, created_by, thread_id, draft, access_contacts, content, source_created_at)
VALUES (gen_random_uuid(),
        current_setting('test.other_c')::uuid,
        current_setting('test.connector')::uuid,
        current_setting('test.thread2')::uuid, FALSE,
        ARRAY[current_setting('test.user_c')::uuid, current_setting('test.other_c')::uuid],
        'their reply', now());

SELECT is(
    (SELECT read_at FROM thread_state
      WHERE user_id = current_setting('test.user')::uuid
        AND thread_id = current_setting('test.thread2')::uuid),
    NULL,
    'negative control: a scoped note authored by someone else marks the user unread');

SELECT * FROM finish();
ROLLBACK;
