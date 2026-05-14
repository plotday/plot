-- Seed core Plot system data needed for onboarding threads and other
-- system-level content to work on a fresh dev reset.
--
-- Uses natural-key lookups so this is safe to run against a database
-- that already has these rows (e.g. production after a real deploy).
-- All inserts are guarded with ON CONFLICT DO NOTHING or NOT EXISTS.

DO $$
DECLARE
    v_publisher_id bigint;
    v_kris_id uuid;
BEGIN
    -- 1. Kris Braun — must exist before publisher INSERT so that
    --    auto_maintain_publisher_group trigger can seed the publisher group
    --    with a valid created_by. Let postgres assign the uuid so every
    --    fresh dev reset produces a new user.id — the Flutter client uses
    --    user.id as its local SQLite filename, so a stable uuid across
    --    resets would leave stale local data masquerading as fresh.
    INSERT INTO "public"."user" (email, name)
    VALUES ('kris@plot.day', 'Kris Braun')
    ON CONFLICT (email) DO NOTHING;

    SELECT id INTO v_kris_id
    FROM "public"."user" WHERE email = 'kris@plot.day' LIMIT 1;

    -- 2. Plot publisher (keyed by lowercased name)
    INSERT INTO "public"."publisher" (name, url, created_by)
    VALUES ('Plot', 'https://plot.day', v_kris_id)
    ON CONFLICT (lower(name)) DO NOTHING;

    SELECT id INTO v_publisher_id FROM "public"."publisher" WHERE lower(name) = 'plot' LIMIT 1;

    -- 3. Plot twist definitions (review + public environments, keyed on
    --    twist_package_id from twists/plot/package.json)
    INSERT INTO "public"."twist" (twist_package_id, publisher_id, environment, name, version, is_source, shared, logo_url, auto_approve)
    VALUES ('0199b6f4-ae64-7718-8a02-44716f30358f', v_publisher_id, 'review', 'Plot', '0.1.0', false, false, 'https://plot.day/assets/plot-icon.svg', true)
    ON CONFLICT (twist_package_id, environment) WHERE environment <> 'personal' DO NOTHING;

    INSERT INTO "public"."twist" (twist_package_id, publisher_id, environment, name, version, is_source, shared, logo_url, auto_approve)
    VALUES ('0199b6f4-ae64-7718-8a02-44716f30358f', v_publisher_id, 'public', 'Plot', '0.1.0', false, false, 'https://plot.day/assets/plot-icon.svg', false)
    ON CONFLICT (twist_package_id, environment) WHERE environment <> 'personal' DO NOTHING;

END $$;
