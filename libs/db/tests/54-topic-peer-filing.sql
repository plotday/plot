-- When a thread gains a topic_id, every effective topic member (other than
-- the author) gets a pending thread_priority + thread_state row.
BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(3);

CREATE TEMP TABLE _t54 (member uuid, optout uuid, thread_id uuid);

DO $$
DECLARE
    v_author uuid := gen_random_uuid();
    v_member uuid := gen_random_uuid();
    v_optout uuid := gen_random_uuid();
    c_author uuid; c_member uuid; c_optout uuid;
    v_topic uuid := gen_random_uuid();
    v_thread thread;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES
        (v_author,'a54@test.local'),(v_member,'m54@test.local'),(v_optout,'o54@test.local');
    c_author := public.upsert_user_contact(v_author,'a54@test.local','A',NULL);
    c_member := public.upsert_user_contact(v_member,'m54@test.local','M',NULL);
    c_optout := public.upsert_user_contact(v_optout,'o54@test.local','O',NULL);

    INSERT INTO public.topic (id, name, created_by) VALUES (v_topic, 'T54', v_author);
    INSERT INTO public.topic_contact (topic_id, contact_id) VALUES
        (v_topic, c_member), (v_topic, c_optout);
    INSERT INTO public.topic_member_optout (topic_id, user_id) VALUES (v_topic, v_optout);

    v_thread := "user".upsert_thread(v_author,
        jsonb_build_object('title','Peer filing 54','topic_id', v_topic::text));

    INSERT INTO _t54 VALUES (v_member, v_optout, v_thread.id);
END $$;

SELECT ok(EXISTS (SELECT 1 FROM thread_priority tp, _t54
    WHERE tp.thread_id = _t54.thread_id AND tp.user_id = _t54.member),
    'effective topic member gets a thread_priority row');
SELECT ok(EXISTS (SELECT 1 FROM thread_state ts, _t54
    WHERE ts.thread_id = _t54.thread_id AND ts.user_id = _t54.member),
    'effective topic member gets a thread_state row');
SELECT ok(NOT EXISTS (SELECT 1 FROM thread_priority tp, _t54
    WHERE tp.thread_id = _t54.thread_id AND tp.user_id = _t54.optout),
    'opted-out user is NOT filed');

SELECT * FROM finish();
ROLLBACK;
