-- Seed core Plot system data needed for onboarding threads and other
-- system-level content to work on a fresh dev reset.
--
-- Uses natural-key lookups so this is safe to run against a database
-- that already has these rows (e.g. production after a real deploy).
-- All inserts are guarded with ON CONFLICT DO NOTHING or NOT EXISTS.

DO $$
DECLARE
    v_publisher_id bigint;
    v_twist_admin_id bigint;
BEGIN
    -- 1. Kris Braun — must exist before twist_admin INSERT so that the
    --    auto_maintain_twist_admin_topic trigger can use a valid created_by.
    --    Fixed UUID matches production; clerk_id left NULL for dev-only seed.
    INSERT INTO "public"."user" (id, email, name)
    VALUES ('019d8efd-12e2-7ba9-98f1-ec08152ea427', 'kris@plot.day', 'Kris Braun')
    ON CONFLICT (email) DO NOTHING;

    -- 2. Plot publisher
    INSERT INTO "public"."publisher" (name, url)
    VALUES ('Plot', 'https://plot.day')
    ON CONFLICT DO NOTHING;

    SELECT id INTO v_publisher_id FROM "public"."publisher" WHERE name = 'Plot' LIMIT 1;

    -- 2. Plot twist admin (keyed by twist_package_id from twists/plot/package.json)
    INSERT INTO "public"."twist_admin" (twist_package_id, publisher_id, auto_approve)
    VALUES ('0199b6f4-ae64-7718-8a02-44716f30358f', v_publisher_id, false)
    ON CONFLICT (twist_package_id, user_id) DO NOTHING;

    SELECT id INTO v_twist_admin_id
    FROM "public"."twist_admin"
    WHERE twist_package_id = '0199b6f4-ae64-7718-8a02-44716f30358f'
    LIMIT 1;

    -- 3. Plot twist definitions (review + public environments)
    INSERT INTO "public"."twist" (twist_admin_id, environment, name, version, is_source, shared, logo_url)
    VALUES (v_twist_admin_id, 'review', 'Plot', '0.1.0', false, false, 'https://plot.day/assets/plot-icon.svg')
    ON CONFLICT (twist_admin_id, environment) DO NOTHING;

    INSERT INTO "public"."twist" (twist_admin_id, environment, name, version, is_source, shared, logo_url)
    VALUES (v_twist_admin_id, 'public', 'Plot', '0.1.0', false, false, 'https://plot.day/assets/plot-icon.svg')
    ON CONFLICT (twist_admin_id, environment) DO NOTHING;

END $$;
