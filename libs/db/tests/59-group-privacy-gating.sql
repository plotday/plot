-- user.group: open group -> members see roster + can_address; private group ->
-- members get empty roster + cannot address; admins always see + can address.
BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(8);

CREATE TEMP TABLE _g59 (admin_u uuid, mem_u uuid, open_g uuid, priv_g uuid);

DO $$
DECLARE
    v_admin uuid := gen_random_uuid();
    v_mem uuid := gen_random_uuid();
    c_admin uuid; c_mem uuid;
    v_open uuid := gen_random_uuid();
    v_priv uuid := gen_random_uuid();
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES
        (v_admin,'ad59@test.local'),(v_mem,'me59@test.local');
    c_admin := public.upsert_user_contact(v_admin,'ad59@test.local','Ad',NULL);
    c_mem   := public.upsert_user_contact(v_mem,'me59@test.local','Me',NULL);

    -- open group (privacy=open explicit, no trigger): admin + member
    INSERT INTO public."group" (id, name, type, privacy, created_by) VALUES (v_open,'Open59','private','open',v_admin);
    INSERT INTO public.group_admin (group_id, user_id) VALUES (v_open, v_admin);
    INSERT INTO public.group_member (group_id, contact_id) VALUES (v_open, c_admin), (v_open, c_mem);

    -- private group (privacy=private explicit, no trigger): admin + member
    INSERT INTO public."group" (id, name, type, privacy, created_by) VALUES (v_priv,'Priv59','announce','private',v_admin);
    INSERT INTO public.group_admin (group_id, user_id) VALUES (v_priv, v_admin);
    INSERT INTO public.group_member (group_id, contact_id) VALUES (v_priv, c_admin), (v_priv, c_mem);

    INSERT INTO _g59 VALUES (v_admin, v_mem, v_open, v_priv);
END $$;

-- OPEN group
SELECT ok((SELECT can_address FROM "user".group, _g59 WHERE user_id=_g59.mem_u AND id=_g59.open_g),
    'open: member can_address');
SELECT ok(cardinality((SELECT member_contact_ids FROM "user".group, _g59 WHERE user_id=_g59.mem_u AND id=_g59.open_g)) = 2,
    'open: member sees full roster');
SELECT ok((SELECT can_address FROM "user".group, _g59 WHERE user_id=_g59.admin_u AND id=_g59.open_g),
    'open: admin can_address');

-- PRIVATE group
SELECT ok(NOT (SELECT can_address FROM "user".group, _g59 WHERE user_id=_g59.mem_u AND id=_g59.priv_g),
    'private: member canNOT address');
SELECT ok(cardinality((SELECT member_contact_ids FROM "user".group, _g59 WHERE user_id=_g59.mem_u AND id=_g59.priv_g)) = 0,
    'private: member gets empty roster');
SELECT ok((SELECT can_address FROM "user".group, _g59 WHERE user_id=_g59.admin_u AND id=_g59.priv_g),
    'private: admin can_address');
SELECT ok(cardinality((SELECT member_contact_ids FROM "user".group, _g59 WHERE user_id=_g59.admin_u AND id=_g59.priv_g)) = 2,
    'private: admin sees full roster');

-- can_post stays a same-valued alias of can_address (back-compat)
SELECT ok(
    (SELECT can_post FROM "user".group, _g59 WHERE user_id=_g59.mem_u AND id=_g59.open_g)
    = (SELECT can_address FROM "user".group, _g59 WHERE user_id=_g59.mem_u AND id=_g59.open_g),
    'can_post mirrors can_address');

SELECT * FROM finish();
ROLLBACK;
