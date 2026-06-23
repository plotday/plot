-- 75-dynamic-link-types: user.twist.link_types branches on _dynamic_link_types flag.
--
-- Static connector  → link_types from _providers aggregation (unchanged).
-- Dynamic connector → link_types from ENABLED channels' link_types (unioned).
-- Dynamic + disabled channel → excluded from union.
-- Dynamic + no enabled channels → NULL (NOT the static set).
BEGIN;
SET LOCAL search_path = public, extensions;

SELECT plan(6);

DO $$
DECLARE
    v_user        uuid := gen_random_uuid();
    v_pkg_static  uuid := gen_random_uuid();
    v_pkg_dynamic uuid := gen_random_uuid();

    -- static twist: no _dynamic_link_types flag
    v_twist_static bigint;
    -- dynamic twist: _dynamic_link_types = true
    v_twist_dynamic bigint;

    -- instances
    v_inst_static  uuid := gen_random_uuid();
    v_inst_dynamic uuid := gen_random_uuid();
BEGIN
    -- Minimal user (no contacts needed — user.twist is owner-scoped only)
    INSERT INTO "public"."user" (id, email)
        VALUES (v_user, 'dyntest_' || v_user || '@example.invalid');

    -- Static twist: permissions has _providers with link types
    INSERT INTO twist (twist_package_id, user_id, name, handle, version, permissions)
        VALUES (
            v_pkg_static,
            v_user,
            'StaticConn',
            'staticconn',
            '1.0',
            '{"_providers": [{"linkTypes": [{"type": "x"}]}]}'
        )
        RETURNING id INTO v_twist_static;

    -- Dynamic twist: permissions has _dynamic_link_types=true AND _providers
    -- (the _providers set must NOT appear in dynamic output).
    INSERT INTO twist (twist_package_id, user_id, name, handle, version, permissions)
        VALUES (
            v_pkg_dynamic,
            v_user,
            'DynamicConn',
            'dynconn',
            '1.0',
            '{"_dynamic_link_types": true, "_providers": [{"linkTypes": [{"type": "static_fallback"}]}]}'
        )
        RETURNING id INTO v_twist_dynamic;

    -- twist_instances
    INSERT INTO twist_instance (id, twist_id, owner_id, name)
        VALUES (v_inst_static,  v_twist_static,  v_user, 'StaticConn');
    INSERT INTO twist_instance (id, twist_id, owner_id, name)
        VALUES (v_inst_dynamic, v_twist_dynamic, v_user, 'DynamicConn');

    -- Channels for the dynamic instance:
    --   calendar channel ENABLED with event + schedule link type
    --   mail channel    ENABLED with email link type
    --   disabled channel with a bogus type (must not appear)
    INSERT INTO channel (twist_instance_id, channel_id, title, enabled, link_types) VALUES
        (v_inst_dynamic, 'cal-1', 'Calendar', true,
         '[{"type":"event","includesSchedules":true}]'),
        (v_inst_dynamic, 'mail-1', 'Mail', true,
         '[{"type":"email"}]'),
        (v_inst_dynamic, 'disabled-1', 'Disabled', false,
         '[{"type":"should_not_appear"}]');
END $$;

-- (1) Static connector: link_types == the _providers aggregation.
SELECT is(
    (SELECT link_types
       FROM "user"."twist"
      WHERE id = (
          SELECT id FROM twist_instance WHERE name = 'StaticConn'
            AND owner_id = (SELECT id FROM "public"."user"
                             WHERE email LIKE 'dyntest_%@example.invalid')
      )),
    '[{"type": "x"}]'::jsonb,
    'static connector: link_types equals the _providers aggregation');

-- (2) Dynamic connector, calendar+mail ENABLED: both types present.
SELECT ok(
    (SELECT link_types
       FROM "user"."twist"
      WHERE id = (
          SELECT id FROM twist_instance WHERE name = 'DynamicConn'
            AND owner_id = (SELECT id FROM "public"."user"
                             WHERE email LIKE 'dyntest_%@example.invalid')
      ))
    @> '[{"type":"event","includesSchedules":true}]'::jsonb,
    'dynamic connector: enabled calendar channel link type present (includesSchedules:true)');

-- (3) Dynamic connector: mail type also present.
SELECT ok(
    (SELECT link_types
       FROM "user"."twist"
      WHERE id = (
          SELECT id FROM twist_instance WHERE name = 'DynamicConn'
            AND owner_id = (SELECT id FROM "public"."user"
                             WHERE email LIKE 'dyntest_%@example.invalid')
      ))
    @> '[{"type":"email"}]'::jsonb,
    'dynamic connector: enabled mail channel link type present');

-- (3b) Dynamic connector with channels enabled: the static _providers type
--      ("static_fallback") must NOT leak into the union — proves the dynamic
--      branch never falls back to the static set while channels are enabled.
SELECT ok(
    NOT (
        (SELECT link_types
           FROM "user"."twist"
          WHERE id = (
              SELECT id FROM twist_instance WHERE name = 'DynamicConn'
                AND owner_id = (SELECT id FROM "public"."user"
                                 WHERE email LIKE 'dyntest_%@example.invalid')
          ))
        @> '[{"type":"static_fallback"}]'::jsonb
    ),
    'dynamic connector: static _providers type excluded (no fallback when channels enabled)');

-- (4) Dynamic connector: disabled channel type must NOT appear.
SELECT ok(
    NOT (
        (SELECT link_types
           FROM "user"."twist"
          WHERE id = (
              SELECT id FROM twist_instance WHERE name = 'DynamicConn'
                AND owner_id = (SELECT id FROM "public"."user"
                                 WHERE email LIKE 'dyntest_%@example.invalid')
          ))
        @> '[{"type":"should_not_appear"}]'::jsonb
    ),
    'dynamic connector: disabled channel link type excluded');

-- (5) Dynamic connector, NO enabled channels → link_types is NULL (not the
--     static fallback). We test this by inserting a new instance with only
--     a disabled channel, then asserting link_types IS NULL.
DO $$
DECLARE
    v_user         uuid;
    v_twist_dynamic bigint;
    v_inst_empty   uuid := gen_random_uuid();
BEGIN
    SELECT id INTO v_user FROM "public"."user" WHERE email LIKE 'dyntest_%@example.invalid';
    SELECT twist_id INTO v_twist_dynamic
      FROM twist_instance WHERE name = 'DynamicConn'
        AND owner_id = v_user;

    INSERT INTO twist_instance (id, twist_id, owner_id, name)
        VALUES (v_inst_empty, v_twist_dynamic, v_user, 'DynConnEmpty');

    INSERT INTO channel (twist_instance_id, channel_id, title, enabled, link_types) VALUES
        (v_inst_empty, 'dis-only', 'OnlyDisabled', false,
         '[{"type":"would_be_static_fallback"}]');
END $$;

SELECT is(
    (SELECT link_types
       FROM "user"."twist"
      WHERE id = (
          SELECT id FROM twist_instance WHERE name = 'DynConnEmpty'
            AND owner_id = (SELECT id FROM "public"."user"
                             WHERE email LIKE 'dyntest_%@example.invalid')
      )),
    NULL::jsonb,
    'dynamic connector with no enabled channels: link_types is NULL (not the static fallback)');

SELECT * FROM finish();
ROLLBACK;
