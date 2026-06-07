BEGIN;
SET LOCAL search_path = public, extensions;

SELECT plan(7);

CREATE TEMP TABLE _ids (
    u uuid,
    c_global uuid,
    c_peruser uuid
);

DO $$
DECLARE
    v_u uuid := gen_random_uuid();
    v_c_global uuid := gen_random_uuid();
    v_c_peruser uuid := gen_random_uuid();
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_u, 'u@t.l');

    -- Contact used to exercise the global upsert_contacts path.
    INSERT INTO public.contact (id, email, name)
        VALUES (v_c_global, 'beth@t.l', 'Beth');

    -- Contact used to exercise the per-user upsert_user_contact_name path.
    INSERT INTO public.contact (id, email, name)
        VALUES (v_c_peruser, 'pu@t.l', 'Global');

    INSERT INTO _ids VALUES (v_u, v_c_global, v_c_peruser);
END $$;

-- Mutations run in their own DO statement so each is committed (within the
-- test transaction) and visible to the following assertion. A read in the
-- same statement as the function call would use the statement-start snapshot
-- and miss the change.

-- 1: upsert_contacts upgrades the global name to a strictly longer one.
DO $$ BEGIN PERFORM public.upsert_contacts('[{"email":"beth@t.l","name":"Beth Round"}]'::jsonb); END $$;
SELECT is(
    (SELECT name FROM public.contact WHERE email = 'beth@t.l'),
    'Beth Round', 'upsert_contacts upgrades global name to a longer one'
);

-- 2: a shorter incoming name does not overwrite the (now longer) global name.
DO $$ BEGIN PERFORM public.upsert_contacts('[{"email":"beth@t.l","name":"B"}]'::jsonb); END $$;
SELECT is(
    (SELECT name FROM public.contact WHERE email = 'beth@t.l'),
    'Beth Round', 'upsert_contacts ignores a shorter incoming name'
);

-- 3: NULL incoming name never overwrites an existing global name.
DO $$ BEGIN PERFORM public.upsert_contacts('[{"email":"beth@t.l","avatar_url":"http://x/a.png"}]'::jsonb); END $$;
SELECT is(
    (SELECT name FROM public.contact WHERE email = 'beth@t.l'),
    'Beth Round', 'upsert_contacts ignores a NULL incoming name'
);

-- 4: per-user observed name first-fill.
DO $$ BEGIN PERFORM public.upsert_user_contact_name(
    (SELECT u FROM _ids), (SELECT c_peruser FROM _ids), 'Beth'); END $$;
SELECT is(
    (SELECT uc.name FROM public.user_contact uc, _ids
       WHERE uc.user_id = _ids.u AND uc.contact_id = _ids.c_peruser),
    'Beth', 'upsert_user_contact_name first-fill sets the observed name'
);

-- 5: per-user observed name upgrades to a strictly longer one.
DO $$ BEGIN PERFORM public.upsert_user_contact_name(
    (SELECT u FROM _ids), (SELECT c_peruser FROM _ids), 'Beth Round'); END $$;
SELECT is(
    (SELECT uc.name FROM public.user_contact uc, _ids
       WHERE uc.user_id = _ids.u AND uc.contact_id = _ids.c_peruser),
    'Beth Round', 'upsert_user_contact_name upgrades observed name to a longer one'
);

-- 6: a shorter observed name does not overwrite (regression: "Beth Round" -> "Beth").
DO $$ BEGIN PERFORM public.upsert_user_contact_name(
    (SELECT u FROM _ids), (SELECT c_peruser FROM _ids), 'Beth'); END $$;
SELECT is(
    (SELECT uc.name FROM public.user_contact uc, _ids
       WHERE uc.user_id = _ids.u AND uc.contact_id = _ids.c_peruser),
    'Beth Round', 'upsert_user_contact_name ignores a shorter observed name'
);

-- 7: a name the user set explicitly (source = 'user') is never clobbered by a
-- connector observation, even a longer one.
DO $$
BEGIN
    UPDATE public.user_contact SET source = 'user', name = 'Bee'
    WHERE user_id = (SELECT u FROM _ids) AND contact_id = (SELECT c_peruser FROM _ids);
    PERFORM public.upsert_user_contact_name(
        (SELECT u FROM _ids), (SELECT c_peruser FROM _ids), 'Beth Rounderson');
END $$;
SELECT is(
    (SELECT uc.name FROM public.user_contact uc, _ids
       WHERE uc.user_id = _ids.u AND uc.contact_id = _ids.c_peruser),
    'Bee', 'upsert_user_contact_name never overrides an explicit user rename'
);

SELECT * FROM finish();
ROLLBACK;
