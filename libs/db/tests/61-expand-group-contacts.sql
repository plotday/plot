-- expand_group_contacts: open-group member gets the roster; private-group
-- non-admin member is rejected; admin always gets the roster.
BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(4);

CREATE TEMP TABLE _e61 (admin_u uuid, mem_u uuid, open_g uuid, priv_g uuid, member_count int);

DO $$
DECLARE
    v_admin uuid := gen_random_uuid();
    v_mem uuid := gen_random_uuid();
    c_admin uuid; c_mem uuid;
    v_open uuid := gen_random_uuid();
    v_priv uuid := gen_random_uuid();
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_admin,'ad61@test.local'),(v_mem,'me61@test.local');
    c_admin := public.upsert_user_contact(v_admin,'ad61@test.local','Ad',NULL);
    c_mem   := public.upsert_user_contact(v_mem,'me61@test.local','Me',NULL);
    -- open group (explicit privacy, since the derive trigger is gone)
    INSERT INTO public."group" (id,name,type,privacy,created_by) VALUES (v_open,'Open61','private','open',v_admin);
    INSERT INTO public.group_admin (group_id,user_id) VALUES (v_open,v_admin);
    INSERT INTO public.group_member (group_id,contact_id) VALUES (v_open,c_admin),(v_open,c_mem);
    -- private group
    INSERT INTO public."group" (id,name,type,privacy,created_by) VALUES (v_priv,'Priv61','announce','private',v_admin);
    INSERT INTO public.group_admin (group_id,user_id) VALUES (v_priv,v_admin);
    INSERT INTO public.group_member (group_id,contact_id) VALUES (v_priv,c_admin),(v_priv,c_mem);
    INSERT INTO _e61 VALUES (v_admin, v_mem, v_open, v_priv, 2);
END $$;

SELECT is(
    cardinality(public.expand_group_contacts((SELECT mem_u FROM _e61),(SELECT open_g FROM _e61))),
    2, 'open group: member gets the full roster');
SELECT is(
    cardinality(public.expand_group_contacts((SELECT admin_u FROM _e61),(SELECT priv_g FROM _e61))),
    2, 'private group: admin gets the full roster');
SELECT throws_ok(
    format('SELECT public.expand_group_contacts(%L::uuid, %L::uuid)', (SELECT mem_u FROM _e61), (SELECT priv_g FROM _e61)),
    'Insufficient permission to use this group',
    'private group: non-admin member is rejected');
SELECT throws_ok(
    format('SELECT public.expand_group_contacts(%L::uuid, %L::uuid)', (SELECT admin_u FROM _e61), gen_random_uuid()::text),
    'Group not found',
    'unknown group raises');

SELECT * FROM finish();
ROLLBACK;
