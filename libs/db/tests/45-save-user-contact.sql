BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(8);

CREATE TEMP TABLE _ids (k text PRIMARY KEY, v uuid);

DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    v_user2 uuid := gen_random_uuid();
    v_new_contact uuid := gen_random_uuid();
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'owner-45@example.test');
    INSERT INTO "public"."user" (id, email) VALUES (v_user2, 'other-45@example.test');
    PERFORM public.upsert_user_contact(v_user, 'owner-45@example.test', 'Owner', NULL);
    PERFORM public.upsert_user_contact(v_user2, 'other-45@example.test', 'Other', NULL);

    INSERT INTO _ids VALUES ('user', v_user), ('user2', v_user2), ('new_contact', v_new_contact);
END $$;

-- 1. ADD: brand-new email uses the client-provided id.
SELECT is(
    (SELECT (save_user_contact).id
     FROM "user".save_user_contact(
        (SELECT v FROM _ids WHERE k='user'),
        (SELECT v FROM _ids WHERE k='new_contact'),
        'newperson-45@example.test',
        'New Person'
     ) AS save_user_contact
     LIMIT 1),
    (SELECT v FROM _ids WHERE k='new_contact'),
    'ADD with a new email keeps the client-provided contact id'
);

-- 2. The contact is now visible in user.actor for the owner, with the per-user name.
SELECT is(
    (SELECT name FROM "user".actor
     WHERE user_id = (SELECT v FROM _ids WHERE k='user')
       AND id = (SELECT v FROM _ids WHERE k='new_contact')),
    'New Person',
    'ADD surfaces the contact in user.actor with the chosen name'
);

-- 3. The global contact.name was NOT written (per-user only).
SELECT is(
    (SELECT name FROM public.contact WHERE id = (SELECT v FROM _ids WHERE k='new_contact')),
    NULL,
    'ADD never writes the global contact.name'
);

-- 4. The other user does NOT see the contact (per-user address book).
SELECT is(
    (SELECT count(*)::int FROM "user".actor
     WHERE user_id = (SELECT v FROM _ids WHERE k='user2')
       AND id = (SELECT v FROM _ids WHERE k='new_contact')),
    0,
    'ADD is scoped to the calling user'
);

-- 5. ADD with an EXISTING email returns the existing contact id, not the client one.
DO $$
DECLARE
    v_existing uuid := gen_random_uuid();
BEGIN
    INSERT INTO public.contact (id, email, name)
        VALUES (v_existing, 'existing-45@example.test', 'Existing Global');
    INSERT INTO _ids VALUES ('existing', v_existing);
END $$;

SELECT is(
    (SELECT (save_user_contact).id
     FROM "user".save_user_contact(
        (SELECT v FROM _ids WHERE k='user'),
        gen_random_uuid(),
        'existing-45@example.test',
        'My Name For Them'
     ) AS save_user_contact
     LIMIT 1),
    (SELECT v FROM _ids WHERE k='existing'),
    'ADD with an existing email resolves to the existing contact id'
);

-- 6. RENAME (p_email NULL) sets the per-user override.
SELECT lives_ok(
    $$ SELECT "user".save_user_contact(
         (SELECT v FROM _ids WHERE k='user'),
         (SELECT v FROM _ids WHERE k='existing'),
         NULL,
         'Renamed' ) $$,
    'RENAME with NULL email succeeds'
);

-- 7. RENAME updated the per-user name.
SELECT is(
    (SELECT name FROM "user".actor
     WHERE user_id = (SELECT v FROM _ids WHERE k='user')
       AND id = (SELECT v FROM _ids WHERE k='existing')),
    'Renamed',
    'RENAME updates the per-user name override'
);

-- 8. A connector longest-wins write must NOT override the explicit user name.
SELECT public.upsert_user_contact_name(
    (SELECT v FROM _ids WHERE k='user'),
    (SELECT v FROM _ids WHERE k='existing'),
    'A Much Longer Connector Name'
);
SELECT is(
    (SELECT name FROM "user".actor
     WHERE user_id = (SELECT v FROM _ids WHERE k='user')
       AND id = (SELECT v FROM _ids WHERE k='existing')),
    'Renamed',
    'A connector longest-wins write does not override source=user'
);

SELECT * FROM finish();
ROLLBACK;
