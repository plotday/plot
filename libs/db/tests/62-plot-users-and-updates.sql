-- After the Everyone→Plot Users + Plot Updates migration: the all-users group
-- is renamed/private, the Plot Updates announce topic exists over it, the global
-- onboarding threads are repointed, and a fresh Plot Users member sees an
-- onboarding thread via the topic and can leave it.
BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(7);

SELECT ok(EXISTS (
    SELECT 1 FROM "group"
    WHERE auto_maintained AND team_id IS NULL AND auto_publisher_id IS NULL
      AND name = 'Plot Users' AND privacy = 'private'
), 'all-users group renamed to Plot Users, private');

SELECT ok(EXISTS (SELECT 1 FROM topic WHERE key = '@plot.updates' AND announce AND auto_maintained),
    'Plot Updates announce topic exists');
SELECT ok(EXISTS (
    SELECT 1 FROM topic_group tg
    JOIN topic t ON t.id = tg.topic_id AND t.key = '@plot.updates'
    JOIN "group" g ON g.id = tg.group_id
        AND g.auto_maintained AND g.team_id IS NULL AND g.auto_publisher_id IS NULL
), 'Plot Updates includes the Plot Users group');

SELECT ok(
    NOT EXISTS (SELECT 1 FROM thread WHERE key IN ('welcome','priorities','connections',
        'getting-around','twists','notifications','clean-up'))
    OR EXISTS (
        SELECT 1 FROM thread t JOIN topic tp ON tp.id = t.topic_id AND tp.key = '@plot.updates'
        WHERE t.key IN ('welcome','priorities','connections','getting-around','twists','notifications','clean-up')
    ),
    'onboarding threads (if present) repointed onto Plot Updates');
SELECT ok(
    NOT EXISTS (SELECT 1 FROM thread WHERE key = 'welcome')
    OR NOT EXISTS (
        SELECT 1 FROM thread t, "group" g
        WHERE t.key = 'welcome' AND g.auto_maintained AND g.team_id IS NULL
          AND g.auto_publisher_id IS NULL AND g.id = ANY(t.groups)
    ),
    'Plot Users group dropped from onboarding thread groups');

DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    v_contact uuid;
    v_plot_users uuid;
    v_onboarding uuid;
BEGIN
    SELECT id INTO v_plot_users FROM "group"
    WHERE auto_maintained AND team_id IS NULL AND auto_publisher_id IS NULL;
    SELECT t.id INTO v_onboarding FROM thread t JOIN topic tp ON tp.id = t.topic_id AND tp.key='@plot.updates'
    WHERE t.key IN ('welcome','priorities','connections','getting-around','twists','notifications','clean-up')
      AND t.archived_at IS NULL LIMIT 1;

    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'pu62@test.local');
    v_contact := public.upsert_user_contact(v_user, 'pu62@test.local', 'PU', NULL);

    CREATE TEMP TABLE _t62 (onboarding uuid, sees_after_join boolean, sees_after_leave boolean);
    IF v_onboarding IS NULL OR v_plot_users IS NULL THEN
        INSERT INTO _t62 VALUES (v_onboarding, NULL, NULL);
        RETURN;
    END IF;

    INSERT INTO group_member (group_id, contact_id) VALUES (v_plot_users, v_contact)
    ON CONFLICT DO NOTHING;
    UPDATE thread_priority SET priority_id = (SELECT id FROM priority WHERE user_id = v_user LIMIT 1), classify_at = NULL
    WHERE thread_id = v_onboarding AND user_id = v_user;

    INSERT INTO _t62 VALUES (
        v_onboarding,
        EXISTS (SELECT 1 FROM "user".thread WHERE user_id = v_user AND id = v_onboarding),
        NULL
    );

    INSERT INTO topic_member_optout (topic_id, user_id)
    SELECT id, v_user FROM topic WHERE key = '@plot.updates';
    UPDATE _t62 SET sees_after_leave = EXISTS (SELECT 1 FROM "user".thread WHERE user_id = v_user AND id = v_onboarding);
END $$;

SELECT ok((SELECT onboarding IS NULL OR sees_after_join FROM _t62),
    'fresh Plot Users member sees an onboarding thread via the topic');
SELECT ok((SELECT onboarding IS NULL OR sees_after_leave = FALSE FROM _t62),
    'leaving Plot Updates revokes the onboarding thread');

SELECT * FROM finish();
ROLLBACK;
