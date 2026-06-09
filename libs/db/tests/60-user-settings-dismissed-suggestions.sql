BEGIN;
SET LOCAL search_path = public, "user", extensions;
SELECT plan(6);

DO $$
DECLARE
    v_user uuid := gen_random_uuid();
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'dfs-60@example.test');
    -- Seed completion so we can prove it isn't clobbered later.
    PERFORM "user".upsert_user_settings(
        user_id => v_user,
        p_enter_behavior => NULL,
        p_onboarding_completed => true);
    CREATE TEMP TABLE _u (id uuid);
    INSERT INTO _u VALUES (v_user);
END $$;

-- 1. First dismissal records the key.
SELECT lives_ok($$
    SELECT "user".upsert_user_settings(
        user_id => (SELECT id FROM _u),
        p_enter_behavior => NULL,
        p_dismissed_focus_suggestions => '["project"]'::jsonb)
$$, 'first dismissal upsert succeeds');

SELECT ok(
    (SELECT dismissed_focus_suggestions FROM user_settings WHERE user_id = (SELECT id FROM _u))
        @> '["project"]'::jsonb,
    'project key is recorded');

-- 2. A second, different key unions in (both present, deduped).
SELECT lives_ok($$
    SELECT "user".upsert_user_settings(
        user_id => (SELECT id FROM _u),
        p_enter_behavior => NULL,
        p_dismissed_focus_suggestions => '["customers","project"]'::jsonb)
$$, 'second dismissal upsert succeeds');

SELECT ok(
    (SELECT dismissed_focus_suggestions FROM user_settings WHERE user_id = (SELECT id FROM _u))
        @> '["project","customers"]'::jsonb
    AND jsonb_array_length(
        (SELECT dismissed_focus_suggestions FROM user_settings WHERE user_id = (SELECT id FROM _u))) = 2,
    'union merges both keys with no duplicates');

-- 3. Omitting the field (NULL) leaves dismissals AND onboarding intact.
SELECT lives_ok($$
    SELECT "user".upsert_user_settings(
        user_id => (SELECT id FROM _u),
        p_enter_behavior => NULL)
$$, 'null-payload upsert succeeds');

SELECT ok(
    (SELECT onboarding_completed FROM user_settings WHERE user_id = (SELECT id FROM _u)) = true
    AND jsonb_array_length(
        (SELECT dismissed_focus_suggestions FROM user_settings WHERE user_id = (SELECT id FROM _u))) = 2,
    'a NULL dismissed payload changes neither the set nor onboarding_completed');

SELECT * FROM finish();
ROLLBACK;
