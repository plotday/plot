-- Topic-only members (not in thread.contacts, not in any thread.groups) see
-- notes via user.note, light the unread dot via user.priority_unread, and
-- obey write-access rules for announce vs. non-announce topics.
--
-- All assertions are scoped to a brand-new isolated sub-priority (v_iso_priority)
-- so we don't confuse them with the pre-existing Everyone-group threads that are
-- also filed under the member's root priority.
BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(5);

CREATE TEMP TABLE _t57 (
    member uuid, admin_user uuid,
    topic_id uuid, thread_id uuid, iso_priority_id uuid
);

DO $$
DECLARE
    v_author uuid := gen_random_uuid();
    v_member uuid := gen_random_uuid();
    v_admin  uuid := gen_random_uuid();
    c_author uuid; c_member uuid; c_admin uuid;
    v_topic  uuid := gen_random_uuid();
    v_thread thread;
    v_note   note;
    v_root_priority_id uuid;
    v_iso_priority_id  uuid;
BEGIN
    -- Create users and link their contacts.
    INSERT INTO "public"."user" (id, email) VALUES
        (v_author, 'a57@test.local'),
        (v_member, 'm57@test.local'),
        (v_admin,  'adm57@test.local');
    c_author := public.upsert_user_contact(v_author, 'a57@test.local', 'A57', NULL);
    c_member := public.upsert_user_contact(v_member, 'm57@test.local', 'M57', NULL);
    c_admin  := public.upsert_user_contact(v_admin,  'adm57@test.local', 'Adm57', NULL);

    -- Topic: member via topic_contact; admin via topic_admin only (not topic_contact).
    INSERT INTO public.topic (id, name, created_by) VALUES (v_topic, 'T57', v_author);
    INSERT INTO public.topic_contact (topic_id, contact_id) VALUES (v_topic, c_member);
    INSERT INTO public.topic_admin  (topic_id, user_id)    VALUES (v_topic, v_admin);

    -- Thread with topic_id. The author (NOT the member) is in thread.contacts.
    -- The member reaches the thread ONLY via the topic path.
    v_thread := "user".upsert_thread(v_author,
        jsonb_build_object('title', 'T57 thread', 'topic_id', v_topic::text));

    -- Insert a note authored by the thread author so the member can see it.
    INSERT INTO note (thread_id, author_id, created_by, content)
    VALUES (v_thread.id, c_author, v_author, 'hello from author')
    RETURNING * INTO v_note;

    -- Create an isolated sub-priority for the member dedicated to this thread.
    -- This prevents pre-existing "Everyone" group threads (filed under the root
    -- priority) from producing false-positive priority_unread hits.
    v_root_priority_id := (SELECT id FROM public.priority WHERE user_id = v_member LIMIT 1);
    INSERT INTO public.priority (user_id, created_by, title, path)
    VALUES (v_member, v_member, 'T57 topic',
            text2ltree(ltree2text((SELECT path FROM public.priority WHERE id = v_root_priority_id)) || '.t57iso'))
    RETURNING id INTO v_iso_priority_id;

    -- Settle the member's auto-filed thread_priority row under the isolated priority.
    UPDATE public.thread_priority
       SET priority_id = v_iso_priority_id,
           classify_at = NULL
     WHERE thread_id = v_thread.id AND user_id = v_member;

    -- Also settle admin's row if it exists (admin is NOT a stream member,
    -- so no row expected; this is a no-op guard).
    UPDATE public.thread_priority
       SET priority_id = (SELECT id FROM public.priority WHERE user_id = v_admin LIMIT 1),
           classify_at = NULL
     WHERE thread_id = v_thread.id AND user_id = v_admin;

    -- Seed an unread state for the member (importance >= 50) so priority_unread fires.
    INSERT INTO thread_state (user_id, thread_id, importance)
    VALUES (v_member, v_thread.id, 50)
    ON CONFLICT (user_id, thread_id) DO UPDATE SET importance = 50;

    INSERT INTO _t57 VALUES (v_member, v_admin, v_topic, v_thread.id, v_iso_priority_id);
END $$;

-- (1) Topic member sees the thread's note via user.note.
SELECT ok(
    EXISTS (
        SELECT 1 FROM "user".note un, _t57
        WHERE un.user_id = _t57.member
          AND un.thread_id = _t57.thread_id
    ),
    'topic-only member sees thread notes via user.note'
);

-- (2) Topic member's isolated priority lights the unread indicator via
--     user.priority_unread. Scoped to the isolated sub-priority so we
--     don't pick up Everyone-group threads filed under the root priority.
SELECT ok(
    EXISTS (
        SELECT 1 FROM "user".priority_unread pu, _t57
        WHERE pu.user_id    = _t57.member
          AND pu.priority_id = _t57.iso_priority_id
          AND pu.unread = TRUE
    ),
    'topic-only member gets unread indicator in user.priority_unread'
);

-- (3) Non-announce topic: member has write access.
SELECT ok(
    "user".user_has_thread_write_access(
        (SELECT member FROM _t57),
        (SELECT thread_id FROM _t57)
    ),
    'topic member can write to a non-announce topic thread'
);

-- (4) Announce topic: non-admin member CANNOT write.
UPDATE public.topic SET announce = TRUE WHERE id = (SELECT topic_id FROM _t57);

SELECT ok(
    NOT "user".user_has_thread_write_access(
        (SELECT member FROM _t57),
        (SELECT thread_id FROM _t57)
    ),
    'topic member CANNOT write to an announce topic thread'
);

-- (5) Announce topic: admin CAN write even though announce=true.
SELECT ok(
    "user".user_has_thread_write_access(
        (SELECT admin_user FROM _t57),
        (SELECT thread_id FROM _t57)
    ),
    'topic admin CAN write to an announce topic thread'
);

SELECT * FROM finish();
ROLLBACK;
