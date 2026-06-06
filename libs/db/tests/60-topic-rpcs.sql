BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(10);

CREATE TEMP TABLE _t60 (creator uuid, other uuid, other_c uuid, topic_id uuid, grp uuid);

DO $$
DECLARE
    v_creator uuid := gen_random_uuid();
    v_other uuid := gen_random_uuid();
    c_creator uuid; c_other uuid;
    v_grp uuid := gen_random_uuid();
    v_topic uuid;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_creator,'c60@test.local'),(v_other,'o60@test.local');
    c_creator := public.upsert_user_contact(v_creator,'c60@test.local','C',NULL);
    c_other   := public.upsert_user_contact(v_other,'o60@test.local','O',NULL);
    INSERT INTO public."group" (id, name, type, created_by) VALUES (v_grp,'G60','public',v_creator);

    v_topic := public.create_topic(v_creator, 'T60', false, NULL, ARRAY[c_creator], ARRAY[v_grp]);
    INSERT INTO _t60 VALUES (v_creator, v_other, c_other, v_topic, v_grp);
END $$;

SELECT ok(EXISTS (SELECT 1 FROM topic_admin ta,_t60 WHERE ta.topic_id=_t60.topic_id AND ta.user_id=_t60.creator),
    'create_topic: creator is admin');
SELECT ok(EXISTS (SELECT 1 FROM topic_contact tc,_t60 WHERE tc.topic_id=_t60.topic_id AND tc.contact_id=_t60.other_c)=FALSE,
    'create_topic: other not yet a contact');
SELECT ok(EXISTS (SELECT 1 FROM topic_group tg,_t60 WHERE tg.topic_id=_t60.topic_id AND tg.group_id=_t60.grp),
    'create_topic: initial group added');

-- admin adds a contact
SELECT lives_ok($$ SELECT public.add_topic_contacts((SELECT creator FROM _t60),(SELECT topic_id FROM _t60),ARRAY[(SELECT other_c FROM _t60)]) $$,
    'admin can add a contact');
SELECT ok(EXISTS (SELECT 1 FROM topic_contact tc,_t60 WHERE tc.topic_id=_t60.topic_id AND tc.contact_id=_t60.other_c),
    'contact added');

-- leave (opt-out) then the row exists
SELECT lives_ok($$ SELECT public.leave_topic((SELECT other FROM _t60),(SELECT topic_id FROM _t60)) $$, 'other can leave');
SELECT ok(EXISTS (SELECT 1 FROM topic_member_optout o,_t60 WHERE o.topic_id=_t60.topic_id AND o.user_id=_t60.other),
    'leave inserts opt-out');

-- join clears the opt-out
DO $$ BEGIN PERFORM public.join_topic((SELECT other FROM _t60),(SELECT topic_id FROM _t60)); END $$;
SELECT ok(
    NOT EXISTS (SELECT 1 FROM topic_member_optout o,_t60 WHERE o.topic_id=_t60.topic_id AND o.user_id=_t60.other),
    'join clears the opt-out');

-- add_topic_groups: group-address gate
-- Set up a private group the creator is NOT a member of (only the open group
-- already set up in _t60 exists; we need a fresh private-only group).
DO $$
DECLARE
    v_priv_grp uuid := gen_random_uuid();
    v_open_grp uuid := gen_random_uuid();
    v_stranger uuid := gen_random_uuid();
    c_stranger uuid;
BEGIN
    -- create the stranger user first (needed for group FK)
    INSERT INTO "public"."user" (id, email) VALUES (v_stranger, 'str60@test.local');
    c_stranger := public.upsert_user_contact(v_stranger, 'str60@test.local', 'Str', NULL);
    -- private group: creator is NOT in it (stranger is creator, but topic creator is not)
    INSERT INTO public."group" (id, name, type, privacy, created_by)
        VALUES (v_priv_grp, 'Priv60', 'announce', 'private', v_stranger);
    -- open group: topic creator IS a member
    INSERT INTO public."group" (id, name, type, privacy, created_by)
        VALUES (v_open_grp, 'Open60b', 'private', 'open', (SELECT creator FROM _t60));
    INSERT INTO public.group_member (group_id, contact_id)
        SELECT v_open_grp, uc.contact_id
        FROM user_contact uc
        WHERE uc.user_id = (SELECT creator FROM _t60) AND uc.linked = TRUE AND uc.archived_at IS NULL
        LIMIT 1;
    -- store the new group ids into _t60 via a second temp table
    CREATE TEMP TABLE _t60b (priv_grp uuid, open_grp uuid);
    INSERT INTO _t60b VALUES (v_priv_grp, v_open_grp);
END $$;

SELECT throws_ok(
    format('SELECT public.add_topic_groups(%L::uuid, %L::uuid, ARRAY[%L::uuid])',
        (SELECT creator FROM _t60),
        (SELECT topic_id FROM _t60),
        (SELECT priv_grp FROM _t60b)),
    'Insufficient permission to use one of these groups',
    'add_topic_groups: topic admin cannot add a private group they cannot address');

SELECT lives_ok(
    format('SELECT public.add_topic_groups(%L::uuid, %L::uuid, ARRAY[%L::uuid])',
        (SELECT creator FROM _t60),
        (SELECT topic_id FROM _t60),
        (SELECT open_grp FROM _t60b)),
    'add_topic_groups: topic admin can add an open group they are a member of');

SELECT * FROM finish();
ROLLBACK;
