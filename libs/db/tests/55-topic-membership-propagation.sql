-- Adding a contact/group to a topic grants access to all its threads;
-- removing revokes (when no other path remains). Leaving a member-group that
-- a topic includes revokes topic access transitively. Re-adding un-revokes.
BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(6);

CREATE TEMP TABLE _t55 (alice uuid, alice_c uuid, group_id uuid, topic_id uuid, thread_id uuid);

DO $$
DECLARE
    v_author uuid := gen_random_uuid();
    v_alice uuid := gen_random_uuid();
    c_author uuid; c_alice uuid;
    v_group uuid := gen_random_uuid();
    v_topic uuid := gen_random_uuid();
    v_thread thread;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES
        (v_author,'a55@test.local'),(v_alice,'al55@test.local');
    c_author := public.upsert_user_contact(v_author,'a55@test.local','A',NULL);
    c_alice  := public.upsert_user_contact(v_alice,'al55@test.local','Al',NULL);

    INSERT INTO public."group" (id, name, type, created_by) VALUES (v_group,'G55','public',v_author);
    INSERT INTO public.topic (id, name, created_by) VALUES (v_topic,'T55',v_author);

    -- Thread exists in the topic BEFORE Alice joins.
    v_thread := "user".upsert_thread(v_author,
        jsonb_build_object('title','Backfill 55','topic_id', v_topic::text));

    INSERT INTO _t55 VALUES (v_alice, c_alice, v_group, v_topic, v_thread.id);
END $$;

-- Alice not yet a member → no row.
SELECT ok(NOT EXISTS (SELECT 1 FROM thread_priority tp, _t55
    WHERE tp.thread_id=_t55.thread_id AND tp.user_id=_t55.alice),
    'pre-join: Alice has no thread_priority row');

-- Add the group to the topic, then Alice to the group → transitive grant.
INSERT INTO public.topic_group (topic_id, group_id) SELECT topic_id, group_id FROM _t55;
INSERT INTO public.group_member (group_id, contact_id) SELECT group_id, alice_c FROM _t55;

SELECT ok(EXISTS (SELECT 1 FROM thread_priority tp, _t55
    WHERE tp.thread_id=_t55.thread_id AND tp.user_id=_t55.alice AND tp.revoked_at IS NULL),
    'post-join via group: Alice gains access to the topic back-catalog');

-- Leave the group → transitive revoke (group was her only path).
DELETE FROM public.group_member WHERE group_id=(SELECT group_id FROM _t55) AND contact_id=(SELECT alice_c FROM _t55);

SELECT ok(EXISTS (SELECT 1 FROM thread_priority tp, _t55
    WHERE tp.thread_id=_t55.thread_id AND tp.user_id=_t55.alice AND tp.revoked_at IS NOT NULL),
    'post-leave group: Alice access revoked (no other path)');

-- Re-add to group → un-revoke.
INSERT INTO public.group_member (group_id, contact_id) SELECT group_id, alice_c FROM _t55;
SELECT ok(EXISTS (SELECT 1 FROM thread_priority tp, _t55
    WHERE tp.thread_id=_t55.thread_id AND tp.user_id=_t55.alice AND tp.revoked_at IS NULL),
    'post-rejoin group: Alice access restored');

-- Add Alice directly as a topic_contact too (second path), then remove the
-- group path → access retained because the direct path remains.
INSERT INTO public.topic_contact (topic_id, contact_id) SELECT topic_id, alice_c FROM _t55;
DELETE FROM public.group_member WHERE group_id=(SELECT group_id FROM _t55) AND contact_id=(SELECT alice_c FROM _t55);
SELECT ok(EXISTS (SELECT 1 FROM thread_priority tp, _t55
    WHERE tp.thread_id=_t55.thread_id AND tp.user_id=_t55.alice AND tp.revoked_at IS NULL),
    'second path (direct topic_contact) keeps access after group leave');

-- Remove the direct topic_contact too → now revoked.
DELETE FROM public.topic_contact WHERE topic_id=(SELECT topic_id FROM _t55) AND contact_id=(SELECT alice_c FROM _t55);
SELECT ok(EXISTS (SELECT 1 FROM thread_priority tp, _t55
    WHERE tp.thread_id=_t55.thread_id AND tp.user_id=_t55.alice AND tp.revoked_at IS NOT NULL),
    'removing last path (direct topic_contact) revokes access');

SELECT * FROM finish();
ROLLBACK;
