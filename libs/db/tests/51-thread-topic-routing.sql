-- A user-authored thread created with topic_id gets topic_id set to that topic
-- and topic = 'topic:'||topic_id so the classifier's topic short-circuit groups
-- the whole stream.
BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(2);

DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    v_topic uuid := gen_random_uuid();
    v_thread thread;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'topic51@test.local');
    PERFORM public.upsert_user_contact(v_user, 'topic51@test.local', 'T51', NULL);
    INSERT INTO public.topic (id, name, created_by) VALUES (v_topic, 'Topic 51', v_user);

    v_thread := "user".upsert_thread(
        v_user,
        jsonb_build_object('title', 'Hello topic', 'topic_id', v_topic::text)
    );

    CREATE TEMP TABLE _t51 (input_topic uuid, topic_id uuid, topic text);
    INSERT INTO _t51 VALUES (v_topic, v_thread.topic_id, v_thread.topic);
END $$;

SELECT is((SELECT topic_id FROM _t51), (SELECT input_topic FROM _t51),
    'thread.topic_id equals the input topic');
SELECT is(
    (SELECT topic FROM _t51),
    'topic:' || (SELECT input_topic FROM _t51)::text,
    'thread.topic derived as topic:<id>'
);

SELECT * FROM finish();
ROLLBACK;
