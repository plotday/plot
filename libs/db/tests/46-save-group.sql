BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(9);

CREATE TEMP TABLE _ids (k text PRIMARY KEY, v uuid);

DO $$
DECLARE
    v_admin uuid := gen_random_uuid();
    v_member uuid := gen_random_uuid();
    v_member_contact uuid;
    v_group uuid := gen_random_uuid();
    v_extra_contact uuid := gen_random_uuid();
    v_pgroup uuid := gen_random_uuid();
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_admin, 'admin-46@example.test');
    INSERT INTO "public"."user" (id, email) VALUES (v_member, 'member-46@example.test');
    PERFORM public.upsert_user_contact(v_admin, 'admin-46@example.test', 'Admin', NULL);
    v_member_contact := public.upsert_user_contact(v_member, 'member-46@example.test', 'Member', NULL);
    INSERT INTO public.contact (id, email, name)
        VALUES (v_extra_contact, 'extra-46@example.test', 'Extra');

    INSERT INTO _ids VALUES
        ('admin', v_admin), ('member', v_member),
        ('member_contact', v_member_contact),
        ('group', v_group), ('extra_contact', v_extra_contact),
        ('pgroup', v_pgroup);
END $$;

-- 1. CREATE with the client-provided id, seeding one member.
SELECT is(
    "user".save_group(
        (SELECT v FROM _ids WHERE k='admin'),
        jsonb_build_object(
            'id', (SELECT v FROM _ids WHERE k='group'),
            'name', 'My Group',
            'privacy', 'open',
            'member_contact_ids', jsonb_build_array((SELECT v FROM _ids WHERE k='member_contact'))
        )
    ),
    (SELECT v FROM _ids WHERE k='group'),
    'CREATE returns the client-provided group id'
);

-- 2. Creator is admin.
SELECT ok(
    EXISTS (SELECT 1 FROM group_admin
            WHERE group_id = (SELECT v FROM _ids WHERE k='group')
              AND user_id = (SELECT v FROM _ids WHERE k='admin')),
    'CREATE makes the creator an admin'
);

-- 3. Seeded member is present.
SELECT ok(
    EXISTS (SELECT 1 FROM group_member
            WHERE group_id = (SELECT v FROM _ids WHERE k='group')
              AND contact_id = (SELECT v FROM _ids WHERE k='member_contact')),
    'CREATE seeds the provided members'
);

-- 4. RENAME by a non-admin is rejected.
SELECT throws_ok(
    $$ SELECT "user".save_group(
         (SELECT v FROM _ids WHERE k='member'),
         jsonb_build_object(
            'id', (SELECT v FROM _ids WHERE k='group'),
            'name', 'Hijacked',
            'member_contact_ids', jsonb_build_array((SELECT v FROM _ids WHERE k='member_contact'))
         )) $$,
    'Only admins can rename this group',
    'RENAME by a non-admin is rejected'
);

-- 5. Admin adds a member via the full-set diff.
SELECT is(
    "user".save_group(
        (SELECT v FROM _ids WHERE k='admin'),
        jsonb_build_object(
            'id', (SELECT v FROM _ids WHERE k='group'),
            'name', 'My Group',
            'member_contact_ids', jsonb_build_array(
                (SELECT v FROM _ids WHERE k='member_contact'),
                (SELECT v FROM _ids WHERE k='extra_contact'))
        )
    ),
    (SELECT v FROM _ids WHERE k='group'),
    'membership diff add returns the group id'
);
SELECT ok(
    EXISTS (SELECT 1 FROM group_member
            WHERE group_id = (SELECT v FROM _ids WHERE k='group')
              AND contact_id = (SELECT v FROM _ids WHERE k='extra_contact')),
    'membership diff adds the new member'
);

-- 7. Create a PRIVATE group with the member as a member (admin creates it).
SELECT is(
    "user".save_group(
        (SELECT v FROM _ids WHERE k='admin'),
        jsonb_build_object(
            'id', (SELECT v FROM _ids WHERE k='pgroup'),
            'name', 'Private Group',
            'privacy', 'private',
            'member_contact_ids', jsonb_build_array((SELECT v FROM _ids WHERE k='member_contact'))
        )
    ),
    (SELECT v FROM _ids WHERE k='pgroup'),
    'CREATE private group returns id'
);

-- 8. A non-admin member of a PRIVATE group cannot drive the membership diff:
--    sending an empty roster must NOT remove existing members (roster-visibility guard).
SELECT lives_ok(
    $$ SELECT "user".save_group(
         (SELECT v FROM _ids WHERE k='member'),
         jsonb_build_object(
            'id', (SELECT v FROM _ids WHERE k='pgroup'),
            'member_contact_ids', jsonb_build_array()
         )) $$,
    'non-admin private-group save with empty roster does not error'
);

-- 9. The existing member is still present (guard skipped the diff).
SELECT ok(
    EXISTS (SELECT 1 FROM group_member
            WHERE group_id = (SELECT v FROM _ids WHERE k='pgroup')
              AND contact_id = (SELECT v FROM _ids WHERE k='member_contact')),
    'roster-visibility guard: non-admin private-group member is NOT removed'
);

SELECT * FROM finish();
ROLLBACK;
