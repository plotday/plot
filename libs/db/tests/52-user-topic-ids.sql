-- Effective topic stream membership: direct contact OR via an included group,
-- minus per-user opt-outs. Admins are a governance role and do NOT count as
-- stream members (change 5: admin path removed from user_topic_ids).
BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(6);

CREATE TEMP TABLE _t52 (
    u_direct uuid, u_viagroup uuid, u_optout uuid, u_none uuid, u_admin uuid,
    topic_id uuid
);

DO $$
DECLARE
    v_direct uuid := gen_random_uuid();
    v_viagroup uuid := gen_random_uuid();
    v_optout uuid := gen_random_uuid();
    v_none uuid := gen_random_uuid();
    v_admin uuid := gen_random_uuid();
    c_direct uuid; c_viagroup uuid; c_optout uuid; c_none uuid; c_admin uuid;
    v_group uuid := gen_random_uuid();
    v_topic uuid := gen_random_uuid();
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES
        (v_direct, 'd52@test.local'), (v_viagroup, 'g52@test.local'),
        (v_optout, 'o52@test.local'), (v_none, 'n52@test.local'),
        (v_admin, 'adm52@test.local');
    c_direct  := public.upsert_user_contact(v_direct, 'd52@test.local', 'D', NULL);
    c_viagroup:= public.upsert_user_contact(v_viagroup, 'g52@test.local', 'G', NULL);
    c_optout  := public.upsert_user_contact(v_optout, 'o52@test.local', 'O', NULL);
    c_none    := public.upsert_user_contact(v_none, 'n52@test.local', 'N', NULL);
    c_admin   := public.upsert_user_contact(v_admin, 'adm52@test.local', 'Adm', NULL);

    INSERT INTO public."group" (id, name, type, created_by) VALUES (v_group, 'G52', 'public', v_direct);
    INSERT INTO public.group_member (group_id, contact_id) VALUES
        (v_group, c_viagroup), (v_group, c_optout);

    INSERT INTO public.topic (id, name, created_by) VALUES (v_topic, 'T52', v_direct);
    INSERT INTO public.topic_contact (topic_id, contact_id) VALUES (v_topic, c_direct);
    INSERT INTO public.topic_group (topic_id, group_id) VALUES (v_topic, v_group);
    -- c_optout is a member via the group, but opts out.
    INSERT INTO public.topic_member_optout (topic_id, user_id) VALUES (v_topic, v_optout);
    -- v_admin is an admin only (not in topic_contact or any member group).
    INSERT INTO public.topic_admin (topic_id, user_id) VALUES (v_topic, v_admin);

    INSERT INTO _t52 VALUES (v_direct, v_viagroup, v_optout, v_none, v_admin, v_topic);
END $$;

SELECT ok((SELECT topic_id FROM _t52) = ANY("user".user_topic_ids((SELECT u_direct FROM _t52))),
    'direct contact member is in user_topic_ids');
SELECT ok((SELECT topic_id FROM _t52) = ANY("user".user_topic_ids((SELECT u_viagroup FROM _t52))),
    'group-derived member is in user_topic_ids');
SELECT ok(NOT ((SELECT topic_id FROM _t52) = ANY("user".user_topic_ids((SELECT u_optout FROM _t52)))),
    'opted-out user is excluded from user_topic_ids');
SELECT ok(NOT ((SELECT topic_id FROM _t52) = ANY("user".user_topic_ids((SELECT u_none FROM _t52)))),
    'non-member is excluded from user_topic_ids');
SELECT ok(cardinality("user".user_topic_ids(gen_random_uuid())) = 0,
    'unknown user yields empty array');
SELECT ok(NOT ((SELECT topic_id FROM _t52) = ANY("user".user_topic_ids((SELECT u_admin FROM _t52)))),
    'admin-only user is NOT a stream member (admins are governance, not auto-members)');

SELECT * FROM finish();
ROLLBACK;
