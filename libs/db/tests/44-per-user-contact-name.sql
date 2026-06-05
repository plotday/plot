BEGIN;
SET LOCAL search_path = public, extensions;

SELECT plan(8);

CREATE TEMP TABLE _ids (
    a1 uuid,
    a2 uuid,
    shared uuid,
    a1_self uuid
);

DO $$
DECLARE
    v_a1 uuid := gen_random_uuid();
    v_a2 uuid := gen_random_uuid();
    v_shared uuid := gen_random_uuid();
    v_a1_self uuid;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_a1, 'a1@t.l'), (v_a2, 'a2@t.l');

    -- a1's own linked identity contact.
    v_a1_self := public.upsert_user_contact(v_a1, 'a1@t.l', 'A1 Real Name', NULL);

    -- One shared, non-user contact both users can see.
    INSERT INTO public.contact (id, email, name) VALUES (v_shared, 'shared@t.l', 'Global Name');

    -- a1 has a per-user override; a2 has a visibility row with no override.
    INSERT INTO user_contact (user_id, contact_id, linked, source, name)
        VALUES (v_a1, v_shared, false, 'thread', 'A1 Name');
    INSERT INTO user_contact (user_id, contact_id, linked, source, name)
        VALUES (v_a2, v_shared, false, 'thread', NULL);

    INSERT INTO _ids VALUES (v_a1, v_a2, v_shared, v_a1_self);
END $$;

-- 1-3: per-viewer name resolution.
SELECT is(
    (SELECT name FROM "user".actor a, _ids WHERE a.user_id = _ids.a1 AND a.id = _ids.shared),
    'A1 Name', 'viewer with override sees their own name'
) FROM _ids LIMIT 1;

SELECT is(
    (SELECT name FROM "user".actor a, _ids WHERE a.user_id = _ids.a2 AND a.id = _ids.shared),
    'Global Name', 'viewer without override falls back to contact.name'
) FROM _ids LIMIT 1;

SELECT is(
    (SELECT count(DISTINCT name)::int FROM "user".actor a, _ids WHERE a.id = _ids.shared),
    2, 'the two viewers see different names for the same contact'
) FROM _ids LIMIT 1;

-- 4-5: upsert_user_contact_name sets/updates only the calling user's override.
SELECT lives_ok(
    $$ SELECT public.upsert_user_contact_name(
        (SELECT a2 FROM _ids), (SELECT shared FROM _ids), 'A2 New') $$,
    'upsert_user_contact_name runs'
);
SELECT is(
    (SELECT name FROM "user".actor a, _ids WHERE a.user_id = _ids.a2 AND a.id = _ids.shared),
    'A2 New', 'a2 now sees its own override'
) FROM _ids LIMIT 1;
-- a1 is unaffected by a2's write.
SELECT is(
    (SELECT name FROM "user".actor a, _ids WHERE a.user_id = _ids.a1 AND a.id = _ids.shared),
    'A1 Name', 'a1 override is untouched by a2 write'
) FROM _ids LIMIT 1;

-- 7: upsert_contacts is first-touch-only — a later observation must not
-- overwrite an already-populated global contact.name.
SELECT is(
    (WITH x AS (
        SELECT public.upsert_contacts('[{"email":"shared@t.l","name":"Churned"}]'::jsonb)
    ) SELECT name FROM public.contact WHERE email = 'shared@t.l'),
    'Global Name', 'upsert_contacts does not overwrite an existing global name'
);

-- 8: upsert_user_contact_name must NOT override a user's own linked identity.
SELECT is(
    (WITH x AS (
        SELECT public.upsert_user_contact_name(
            (SELECT a1 FROM _ids), (SELECT a1_self FROM _ids), 'Hacked Name')
    ) SELECT name FROM "user".actor a, _ids
       WHERE a.user_id = _ids.a1 AND a.id = _ids.a1_self),
    'A1 Real Name', 'observed name never overrides a linked self-identity'
) FROM _ids LIMIT 1;

SELECT * FROM finish();
ROLLBACK;
