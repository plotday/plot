-- user.twist surfaces the connector-type reaction_capabilities (from the twist
-- table, NOT per-instance), so the Flutter client can drive reaction sync UI.
--   (1) the column exists on the user.twist view
--   (2) it round-trips: a twist row's reaction_capabilities jsonb is returned
--       for an owned twist_instance via user.twist
BEGIN;
SET LOCAL search_path = public, extensions;

SELECT plan(2);

SELECT has_column('user', 'twist', 'reaction_capabilities',
    'user.twist exposes reaction_capabilities');

DO $$
DECLARE
    v_owner    uuid := gen_random_uuid();
    v_twist_id bigint;
    v_ti       uuid := gen_random_uuid();
BEGIN
    -- Owner user. twist requires NOT-NULL name/handle/version and a uuid
    -- twist_package_id (id is GENERATED ALWAYS AS IDENTITY). twist_instance
    -- requires a NOT-NULL name. Mirrors tests/43-thread-author-id.sql.
    INSERT INTO "public"."user" (id, email) VALUES (v_owner, 'rc-owner@t.l');

    INSERT INTO twist (twist_package_id, version, name, handle, user_id, reaction_capabilities)
    VALUES (gen_random_uuid(), '1.0.0', 'Reaction Twist', 'reaction-twist',
            v_owner, '{"mode":"fixed","allowed":["👍"]}'::jsonb)
        RETURNING id INTO v_twist_id;

    INSERT INTO twist_instance (id, twist_id, owner_id, name, draft)
        VALUES (v_ti, v_twist_id, v_owner, 'Reaction Instance', false);

    CREATE TEMP TABLE _t63 (instance uuid);
    INSERT INTO _t63 VALUES (v_ti);
END $$;

SELECT is(
    (SELECT reaction_capabilities FROM "user".twist WHERE id = (SELECT instance FROM _t63)),
    '{"mode":"fixed","allowed":["👍"]}'::jsonb,
    'user.twist returns the twist''s reaction_capabilities jsonb for an owned instance');

SELECT * FROM finish();
ROLLBACK;
