-- A thread with topic_id is visible (via user.thread) to effective topic
-- members and NOT to opted-out users; user.topic shows the topic to members
-- AND opted-out users (so they can rejoin).
BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(5);

CREATE TEMP TABLE _t53 (member uuid, optout uuid, outsider uuid, topic_id uuid, thread_id uuid);

DO $$
DECLARE
    v_author uuid := gen_random_uuid();
    v_member uuid := gen_random_uuid();
    v_optout uuid := gen_random_uuid();
    v_outsider uuid := gen_random_uuid();
    c_author uuid; c_member uuid; c_optout uuid;
    v_topic uuid := gen_random_uuid();
    v_thread thread;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES
        (v_author,'a53@test.local'),(v_member,'m53@test.local'),
        (v_optout,'o53@test.local'),(v_outsider,'x53@test.local');
    c_author := public.upsert_user_contact(v_author,'a53@test.local','A',NULL);
    c_member := public.upsert_user_contact(v_member,'m53@test.local','M',NULL);
    c_optout := public.upsert_user_contact(v_optout,'o53@test.local','O',NULL);
    PERFORM public.upsert_user_contact(v_outsider,'x53@test.local','X',NULL);

    INSERT INTO public.topic (id, name, created_by) VALUES (v_topic, 'T53', v_author);
    INSERT INTO public.topic_contact (topic_id, contact_id) VALUES
        (v_topic, c_member), (v_topic, c_optout);
    INSERT INTO public.topic_member_optout (topic_id, user_id) VALUES (v_topic, v_optout);

    v_thread := "user".upsert_thread(v_author,
        jsonb_build_object('title','Topic thread 53','topic_id', v_topic::text));

    -- Settle the member's auto-filed peer row so the classify window passes.
    UPDATE public.thread_priority tp
       SET priority_id = (SELECT id FROM public.priority WHERE user_id = v_member LIMIT 1),
           classify_at = NULL
     WHERE thread_id = v_thread.id AND user_id = v_member;

    INSERT INTO _t53 VALUES (v_member, v_optout, v_outsider, v_topic, v_thread.id);
END $$;

SELECT ok(EXISTS (SELECT 1 FROM "user".thread ut, _t53
    WHERE ut.user_id = _t53.member AND ut.id = _t53.thread_id),
    'member sees the topic thread via user.thread');
SELECT ok(NOT EXISTS (SELECT 1 FROM "user".thread ut, _t53
    WHERE ut.user_id = _t53.optout AND ut.id = _t53.thread_id),
    'opted-out user does NOT see the topic thread');
SELECT ok(NOT EXISTS (SELECT 1 FROM "user".thread ut, _t53
    WHERE ut.user_id = _t53.outsider AND ut.id = _t53.thread_id),
    'outsider does NOT see the topic thread');
SELECT ok(EXISTS (SELECT 1 FROM "user".topic vt, _t53
    WHERE vt.user_id = _t53.member AND vt.id = _t53.topic_id AND vt.is_member),
    'member sees topic in user.topic with is_member=true');
SELECT ok(EXISTS (SELECT 1 FROM "user".topic vt, _t53
    WHERE vt.user_id = _t53.optout AND vt.id = _t53.topic_id AND vt.opted_out AND NOT vt.is_member),
    'opted-out user still sees topic (opted_out=true, is_member=false) to rejoin');

SELECT * FROM finish();
ROLLBACK;
