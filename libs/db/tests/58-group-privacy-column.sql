-- group.privacy: column defaults to 'open' on a raw insert (no trigger now);
-- create_group sets it from p_privacy (explicit) or derives from p_type
-- (announce -> private, else open) when omitted.
BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(5);

SELECT has_column('public'::name, 'group'::name, 'privacy'::name, 'group.privacy exists');

DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    v_raw uuid := gen_random_uuid();
    g_explicit uuid; g_announce uuid; g_public uuid;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'gp58@test.local');
    -- raw insert (no create_group) -> column default 'open' (trigger is gone)
    INSERT INTO public."group" (id, name, type, created_by) VALUES (v_raw, 'Raw 58', 'announce', v_user);
    -- create_group: explicit privacy wins over type
    g_explicit := public.create_group(v_user, 'Explicit58', 'public', 'member', NULL, ARRAY[]::uuid[], 'private');
    -- create_group: omitted privacy derives from type
    g_announce := public.create_group(v_user, 'Ann58', 'announce', 'member', NULL, ARRAY[]::uuid[], NULL);
    g_public   := public.create_group(v_user, 'Pub58', 'public', 'member', NULL, ARRAY[]::uuid[], NULL);

    CREATE TEMP TABLE _gp58 (raw_p text, explicit_p text, announce_p text, public_p text);
    INSERT INTO _gp58 SELECT
        (SELECT privacy::text FROM public."group" WHERE id = v_raw),
        (SELECT privacy::text FROM public."group" WHERE id = g_explicit),
        (SELECT privacy::text FROM public."group" WHERE id = g_announce),
        (SELECT privacy::text FROM public."group" WHERE id = g_public);
END $$;

SELECT is((SELECT raw_p FROM _gp58), 'open', 'raw insert -> column default open (no trigger)');
SELECT is((SELECT explicit_p FROM _gp58), 'private', 'create_group: explicit p_privacy wins over type');
SELECT is((SELECT announce_p FROM _gp58), 'private', 'create_group: omitted privacy derives announce->private');
SELECT is((SELECT public_p FROM _gp58), 'open', 'create_group: omitted privacy derives public->open');

SELECT * FROM finish();
ROLLBACK;
