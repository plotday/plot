-- Leaving a topic (opt-out) revokes the stream but keeps the topic visible;
-- a future post does not re-add the opted-out user; rejoining restores access.
BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(4);

CREATE TEMP TABLE _t56 (member uuid, member_c uuid, topic_id uuid, thread1 uuid);

DO $$
DECLARE
    v_author uuid := gen_random_uuid();
    v_member uuid := gen_random_uuid();
    c_author uuid; c_member uuid;
    v_topic uuid := gen_random_uuid();
    v_thread thread;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES
        (v_author,'a56@test.local'),(v_member,'m56@test.local');
    c_author := public.upsert_user_contact(v_author,'a56@test.local','A',NULL);
    c_member := public.upsert_user_contact(v_member,'m56@test.local','M',NULL);

    INSERT INTO public.topic (id, name, created_by) VALUES (v_topic,'T56',v_author);
    INSERT INTO public.topic_contact (topic_id, contact_id) VALUES (v_topic, c_member);

    v_thread := "user".upsert_thread(v_author,
        jsonb_build_object('title','Optout thread 1','topic_id', v_topic::text));

    INSERT INTO _t56 VALUES (v_member, c_member, v_topic, v_thread.id);
END $$;

-- Member has access pre-optout.
SELECT ok(EXISTS (SELECT 1 FROM thread_priority tp, _t56
    WHERE tp.thread_id=_t56.thread1 AND tp.user_id=_t56.member AND tp.revoked_at IS NULL),
    'pre-optout: member has access');

-- Leave the topic.
INSERT INTO public.topic_member_optout (topic_id, user_id) SELECT topic_id, member FROM _t56;

SELECT ok(EXISTS (SELECT 1 FROM thread_priority tp, _t56
    WHERE tp.thread_id=_t56.thread1 AND tp.user_id=_t56.member AND tp.revoked_at IS NOT NULL),
    'post-optout: existing thread access revoked');

-- A new post to the topic must NOT re-add the opted-out member.
DO $$
DECLARE v_author uuid; v_t thread;
BEGIN
    SELECT created_by INTO v_author FROM public.topic WHERE id = (SELECT topic_id FROM _t56);
    v_t := "user".upsert_thread(v_author,
        jsonb_build_object('title','Optout thread 2','topic_id',(SELECT topic_id FROM _t56)::text));
END $$;

SELECT ok(NOT EXISTS (
    SELECT 1 FROM thread_priority tp, _t56, public.thread th
    WHERE th.topic_id=_t56.topic_id AND th.title='Optout thread 2'
      AND tp.thread_id=th.id AND tp.user_id=_t56.member AND tp.revoked_at IS NULL),
    'post-optout: new topic post does not reach the opted-out member');

-- Rejoin (clear opt-out) → access restored to the back-catalog.
DELETE FROM public.topic_member_optout WHERE topic_id=(SELECT topic_id FROM _t56) AND user_id=(SELECT member FROM _t56);

SELECT ok(EXISTS (SELECT 1 FROM thread_priority tp, _t56
    WHERE tp.thread_id=_t56.thread1 AND tp.user_id=_t56.member AND tp.revoked_at IS NULL),
    'post-rejoin: access restored');

SELECT * FROM finish();
ROLLBACK;
