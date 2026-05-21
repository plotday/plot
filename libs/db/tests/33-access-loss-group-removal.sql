-- Access-loss via group_member removal:
--   • file_thread_priority_on_group_member_change DELETE branch must
--     set thread_priority.revoked_at = now() instead of bare-deleting.
--   • user.thread stops emitting the row (revoked_at IS NOT NULL filter).
--   • user.thread_redacted emits a redacted stub with archived_at =
--     updated_at = revoked_at, sensitive fields NULLed, revoked = TRUE.
--   • thread_unread is cleaned up.
--   • Re-adding the user to the group clears revoked_at (un-revoke) and
--     restores visibility on user.thread.
-- See libs/db/AGENTS.md "Handling Access Loss to Synced Entities".
BEGIN;
SET LOCAL search_path = public, extensions;

SELECT plan(13);

CREATE TEMP TABLE _ids (
    admin_id uuid,
    alice_id uuid,
    admin_c uuid,
    alice_c uuid,
    group_id uuid,
    thread_id uuid
);

DO $$
DECLARE
    v_admin uuid := gen_random_uuid();
    v_alice uuid := gen_random_uuid();
    v_admin_contact uuid;
    v_alice_contact uuid;
    v_group uuid;
    v_thread uuid := gen_random_uuid();
    v_admin_priority uuid;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES
        (v_admin, 'admin33@test.local'),
        (v_alice, 'alice33@test.local');

    v_admin_contact := public.upsert_user_contact(v_admin, 'admin33@test.local', 'Admin', NULL);
    v_alice_contact := public.upsert_user_contact(v_alice, 'alice33@test.local', 'Alice', NULL);

    -- auto_maintained = false to keep this test simple; type 'public' so
    -- it's a normal sharing group rather than announce-only.
    INSERT INTO public."group" (id, name, type, created_by, auto_maintained)
    VALUES (gen_random_uuid(), 'Marketing 33', 'public', v_admin, false)
    RETURNING id INTO v_group;

    INSERT INTO public.group_admin (group_id, user_id) VALUES (v_group, v_admin);
    -- Alice's only access path is via this group. Critically, alice is
    -- NOT in thread.contacts — so revocation should kick in when she's
    -- removed from the group (no other path remains).
    INSERT INTO public.group_member (group_id, contact_id) VALUES
        (v_group, v_admin_contact),
        (v_group, v_alice_contact);

    -- Author's filing. Raw INSERT here matches test 30's pattern.
    INSERT INTO public.thread (id, created_by, title, preview, contacts, groups)
    VALUES (v_thread, v_admin, 'Group-only thread', 'preview text',
            ARRAY[v_admin_contact], ARRAY[v_group]);

    SELECT id INTO v_admin_priority FROM public.priority
     WHERE user_id = v_admin LIMIT 1;
    INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
    VALUES (v_thread, v_admin, v_admin_priority);
    UPDATE public.thread SET contacts = contacts WHERE id = v_thread;

    -- Settle Alice's auto-filed thread_priority into a real priority so
    -- the user.thread visibility filter passes the classify_at window.
    UPDATE public.thread_priority tp
       SET priority_id = (SELECT id FROM public.priority
                          WHERE user_id = v_alice LIMIT 1),
           classify_at = NULL
     WHERE thread_id = v_thread AND user_id = v_alice;

    INSERT INTO _ids VALUES (v_admin, v_alice, v_admin_contact, v_alice_contact, v_group, v_thread);
END $$;

-- Sanity: before revocation, Alice has a thread_priority row, a thread_unread
-- row, and user.thread emits the thread for her.
SELECT ok(
    EXISTS (
        SELECT 1 FROM thread_priority tp, _ids
         WHERE tp.thread_id = _ids.thread_id AND tp.user_id = _ids.alice_id
           AND tp.revoked_at IS NULL
    ),
    'pre-revoke: Alice has an unrevoked thread_priority row'
) FROM _ids LIMIT 1;

SELECT ok(
    EXISTS (
        SELECT 1 FROM thread_unread tu, _ids
         WHERE tu.thread_id = _ids.thread_id AND tu.user_id = _ids.alice_id
    ),
    'pre-revoke: Alice has a thread_unread row'
) FROM _ids LIMIT 1;

SELECT ok(
    EXISTS (
        SELECT 1 FROM "user".thread ut, _ids
         WHERE ut.user_id = _ids.alice_id AND ut.id = _ids.thread_id
    ),
    'pre-revoke: user.thread emits the thread for Alice'
) FROM _ids LIMIT 1;

-- Revoke: remove Alice from the group.
DELETE FROM public.group_member
 WHERE group_id = (SELECT group_id FROM _ids)
   AND contact_id = (SELECT alice_c FROM _ids);

-- thread_priority row must still exist (not bare-deleted) with revoked_at set.
SELECT ok(
    EXISTS (
        SELECT 1 FROM thread_priority tp, _ids
         WHERE tp.thread_id = _ids.thread_id AND tp.user_id = _ids.alice_id
           AND tp.revoked_at IS NOT NULL
    ),
    'post-revoke: thread_priority survives with revoked_at set (not bare-deleted)'
) FROM _ids LIMIT 1;

-- thread_unread is cleaned up (it feeds user.thread.unread via LEFT JOIN;
-- the redacted stub emits unread=false regardless, so the table can be
-- bare-deleted here without stranding the client).
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM thread_unread tu, _ids
         WHERE tu.thread_id = _ids.thread_id AND tu.user_id = _ids.alice_id
    ),
    'post-revoke: thread_unread for Alice is cleaned up'
) FROM _ids LIMIT 1;

-- user.thread no longer emits the row for Alice.
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM "user".thread ut, _ids
         WHERE ut.user_id = _ids.alice_id AND ut.id = _ids.thread_id
    ),
    'post-revoke: user.thread no longer emits the row for Alice'
) FROM _ids LIMIT 1;

-- user.thread_redacted emits the row with the right shape.
SELECT ok(
    EXISTS (
        SELECT 1 FROM "user".thread_redacted ut, _ids
         WHERE ut.user_id = _ids.alice_id AND ut.id = _ids.thread_id
           AND ut.revoked = TRUE
           AND ut.archived_at IS NOT NULL
           AND ut.updated_at = ut.archived_at
           AND ut.title IS NULL
           AND ut.preview IS NULL
           AND ut.unread = FALSE
           AND ut.importance = 0
           AND cardinality(ut.contacts) = 0
           AND cardinality(ut.groups) = 0
    ),
    'post-revoke: user.thread_redacted emits redacted stub (frozen ts, NULL fields, revoked=true)'
) FROM _ids LIMIT 1;

-- The stub's seq must NOT advance when the underlying thread is updated
-- after revocation. Capture seq, mutate thread, re-check.
DO $$
DECLARE
    v_seq_before xid8;
    v_seq_after xid8;
    v_ts_before timestamptz;
    v_ts_after timestamptz;
BEGIN
    SELECT seq, updated_at INTO v_seq_before, v_ts_before
      FROM "user".thread_redacted, _ids
     WHERE user_id = _ids.alice_id AND id = _ids.thread_id;

    UPDATE public.thread SET title = 'After-revoke title leak attempt'
     WHERE id = (SELECT thread_id FROM _ids);

    SELECT seq, updated_at INTO v_seq_after, v_ts_after
      FROM "user".thread_redacted, _ids
     WHERE user_id = _ids.alice_id AND id = _ids.thread_id;

    -- Stash for assertions below.
    CREATE TEMP TABLE _seq_check (
        seq_unchanged boolean,
        updated_at_unchanged boolean,
        title_still_null boolean
    );
    INSERT INTO _seq_check VALUES (
        v_seq_before = v_seq_after,
        v_ts_before = v_ts_after,
        (SELECT title IS NULL FROM "user".thread_redacted, _ids
          WHERE user_id = _ids.alice_id AND id = _ids.thread_id)
    );
END $$;

SELECT ok(
    (SELECT seq_unchanged FROM _seq_check),
    'post-revoke + thread update: redacted stub seq is frozen (no re-emit)'
);

SELECT ok(
    (SELECT updated_at_unchanged FROM _seq_check),
    'post-revoke + thread update: redacted stub updated_at is frozen'
);

SELECT ok(
    (SELECT title_still_null FROM _seq_check),
    'post-revoke + thread update: title stays NULL (no metadata leak)'
);

-- Re-join: add Alice back to the group. The INSERT branch un-revokes.
INSERT INTO public.group_member (group_id, contact_id)
VALUES ((SELECT group_id FROM _ids), (SELECT alice_c FROM _ids));

SELECT ok(
    EXISTS (
        SELECT 1 FROM thread_priority tp, _ids
         WHERE tp.thread_id = _ids.thread_id AND tp.user_id = _ids.alice_id
           AND tp.revoked_at IS NULL
    ),
    'post-rejoin: thread_priority.revoked_at is cleared'
) FROM _ids LIMIT 1;

SELECT ok(
    EXISTS (
        SELECT 1 FROM "user".thread ut, _ids
         WHERE ut.user_id = _ids.alice_id AND ut.id = _ids.thread_id
    ),
    'post-rejoin: user.thread emits the row for Alice again'
) FROM _ids LIMIT 1;

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM "user".thread_redacted ut, _ids
         WHERE ut.user_id = _ids.alice_id AND ut.id = _ids.thread_id
    ),
    'post-rejoin: user.thread_redacted no longer emits the row'
) FROM _ids LIMIT 1;

SELECT * FROM finish();
ROLLBACK;
