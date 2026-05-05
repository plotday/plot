BEGIN;

SET LOCAL search_path = public, extensions;

SELECT plan(4);

-- Stash seeded IDs in a temp table so top-level SELECT ok(...) calls see them.
CREATE TEMP TABLE _ids (
    admin_id uuid,
    alice_id uuid,
    bob_id uuid,
    admin_c uuid,
    alice_c uuid,
    bob_c uuid,
    group_id uuid,
    thread_id uuid
);

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
BEGIN
    -- public.user requires email NOT NULL; reuse the contact email.
    INSERT INTO "public"."user" (id, email) VALUES
        (v_admin, 'admin@test.local'),
        (v_alice, 'alice@test.local'),
        (v_bob,   'bob@test.local');

    v_admin_contact := public.upsert_user_contact(v_admin, 'admin@test.local', 'Admin', NULL);
    v_alice_contact := public.upsert_user_contact(v_alice, 'alice@test.local', 'Alice', NULL);
    v_bob_contact   := public.upsert_user_contact(v_bob,   'bob@test.local',   'Bob',   NULL);
    -- Root priority for each user is auto-created by the activate_invited_user trigger.

    -- Announce group with admin as the admin and all three as members.
    INSERT INTO public."group" (id, name, type, created_by, auto_maintained)
    VALUES (gen_random_uuid(), 'Announce Test', 'announce', v_admin, false)
    RETURNING id INTO v_group;

    INSERT INTO public.group_admin (group_id, user_id) VALUES (v_group, v_admin);
    INSERT INTO public.group_member (group_id, contact_id) VALUES
        (v_group, v_admin_contact),
        (v_group, v_alice_contact),
        (v_group, v_bob_contact);

    -- File the thread to the announce group with alice in thread.contacts.
    -- Raw INSERT fires file_thread_priority_for_group_members (alice, bob)
    -- and sync_user_contact_for_thread_contacts (the trigger we are auditing).
    INSERT INTO public.thread (id, created_by, title, contacts, groups)
    VALUES (v_thread, v_admin, 'Hello announce', ARRAY[v_alice_contact], ARRAY[v_group]);

    -- Mirror what upsert_thread does for the author. The sync trigger fires
    -- on INSERT OR UPDATE OF thread.contacts; on INSERT it ran before admin's
    -- thread_priority existed (FK constraint forces tp to follow thread), so
    -- file admin's tp now and re-fire the trigger via a no-op UPDATE so it
    -- sees the now-complete tp set.
    INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
    SELECT v_thread, v_admin, p.id
      FROM public.priority p
     WHERE p.user_id = v_admin
     LIMIT 1;
    UPDATE public.thread SET contacts = contacts WHERE id = v_thread;

    INSERT INTO _ids VALUES (v_admin, v_alice, v_bob, v_admin_contact, v_alice_contact, v_bob_contact, v_group, v_thread);
END $$;

-- _ids has exactly one row; FROM _ids LIMIT 1 makes the IDs visible to ok().
SELECT ok(
    EXISTS (
        SELECT 1 FROM user_contact uc, _ids
         WHERE uc.user_id = _ids.admin_id AND uc.contact_id = _ids.alice_c
    ),
    'admin (thread author) gets user_contact for alice via sync_user_contact_for_thread_contacts'
)
FROM _ids LIMIT 1;

SELECT ok(
    EXISTS (
        SELECT 1 FROM thread_priority tp, _ids
         WHERE tp.thread_id = _ids.thread_id AND tp.user_id = _ids.bob_id
    ),
    'bob still receives the announce thread (filing not blocked)'
)
FROM _ids LIMIT 1;

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM user_contact uc, _ids
         WHERE uc.user_id = _ids.bob_id AND uc.contact_id = _ids.alice_c
    ),
    'bob does NOT get a user_contact row for alice via announce-only membership'
)
FROM _ids LIMIT 1;

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM user_contact uc, _ids
         WHERE uc.user_id = _ids.alice_id
           AND uc.contact_id = _ids.alice_c
           AND uc.linked = false
    ),
    'alice does not get a redundant unlinked self-row'
)
FROM _ids LIMIT 1;

SELECT * FROM finish();

ROLLBACK;
