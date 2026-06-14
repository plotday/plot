-- classification_decision: the SQL trigger paths log applied decisions;
-- pending peer rows, conflict-preserved filings (re-join un-revoke), and
-- previews do not log. Covers group-member add, topic grant, and
-- channel-default re-file.
BEGIN;
SET LOCAL search_path = public, extensions;

SELECT plan(8);

-- Setup: author + peer users, a group, a thread referencing the group
-- BEFORE the peer joins (so joining classifies the back-catalog inline).
DO $$
DECLARE
    v_author uuid := gen_random_uuid();
    v_peer   uuid := gen_random_uuid();
    v_peer_c uuid;
    v_group  uuid := gen_random_uuid();
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_author, 'cdl-author@test.plot');
    INSERT INTO "public"."user" (id, email) VALUES (v_peer, 'cdl-peer@test.plot');
    v_peer_c := public.upsert_user_contact(v_peer, 'cdl-peer@test.plot', 'CDL Peer', NULL);
    INSERT INTO "group" (id, name, created_by) VALUES (v_group, 'cdl-group', v_author);
    INSERT INTO thread (id, created_by, title, groups)
    VALUES (gen_random_uuid(), v_author, 'cdl thread pre-membership', ARRAY[v_group]);
    -- Peer joins: file_thread_priority_on_group_member_change classifies inline.
    INSERT INTO group_member (group_id, contact_id) VALUES (v_group, v_peer_c);
END $$;

-- Assertions are scoped to the thread created above, not broadly to the
-- peer: a freshly-created user is auto-joined to onboarding groups/topics
-- ("Everyone", "Plot Updates") during upsert_user_contact, and those inline
-- back-catalog classifications log their own (correct) decisions. Those are
-- real applied decisions for unrelated threads, so we look up by the
-- pre-membership thread we control.
SELECT is(
    (SELECT count(*)::int FROM classification_decision cd
      JOIN thread t ON t.id = cd.thread_id
     WHERE cd.user_id = (SELECT id FROM "user" WHERE email = 'cdl-peer@test.plot')
       AND t.title = 'cdl thread pre-membership'),
    1, 'group-member add logs exactly one decision for the peer thread');

SELECT is(
    (SELECT cd.stage || '|' || cd.classifier FROM classification_decision cd
      JOIN thread t ON t.id = cd.thread_id
     WHERE cd.user_id = (SELECT id FROM "user" WHERE email = 'cdl-peer@test.plot')
       AND t.title = 'cdl thread pre-membership'),
    'sql:applied|sql:classify_thread_for_user',
    'decision carries the sql stage + classifier markers');

SELECT is(
    (SELECT cd.priority_id FROM classification_decision cd
      JOIN thread t ON t.id = cd.thread_id
     WHERE cd.user_id = (SELECT id FROM "user" WHERE email = 'cdl-peer@test.plot')
       AND t.title = 'cdl thread pre-membership'),
    (SELECT id FROM priority
      WHERE user_id = (SELECT id FROM "user" WHERE email = 'cdl-peer@test.plot')
        AND nlevel(path) = 1),
    'decision priority is the peer root (root_fallback for an untrained peer)');

-- Re-join: leaving revokes; re-joining un-revokes and preserves the prior
-- filing — no new decision row.
DO $$
DECLARE
    v_g uuid := (SELECT id FROM "group" WHERE name = 'cdl-group');
    v_c uuid := (SELECT id FROM contact WHERE email = 'cdl-peer@test.plot');
BEGIN
    DELETE FROM group_member WHERE group_id = v_g AND contact_id = v_c;
    INSERT INTO group_member (group_id, contact_id) VALUES (v_g, v_c);
END $$;

SELECT is(
    (SELECT count(*)::int FROM classification_decision cd
      JOIN thread t ON t.id = cd.thread_id
     WHERE cd.user_id = (SELECT id FROM "user" WHERE email = 'cdl-peer@test.plot')
       AND t.title = 'cdl thread pre-membership'),
    1, 're-join un-revoke preserves filing and logs no new decision');

-- New thread into the group AFTER membership exists: the peer gets a
-- PENDING row (priority NULL, classify_at set) — no decision applied here.
DO $$
BEGIN
    INSERT INTO thread (id, created_by, title, groups)
    VALUES (gen_random_uuid(),
            (SELECT id FROM "user" WHERE email = 'cdl-author@test.plot'),
            'cdl thread post-membership',
            ARRAY[(SELECT id FROM "group" WHERE name = 'cdl-group')]);
END $$;

SELECT is(
    (SELECT count(*)::int FROM classification_decision cd
      JOIN thread t ON t.id = cd.thread_id
     WHERE t.title = 'cdl thread post-membership'),
    0, 'pending peer filings (new thread into group) log nothing');

-- Topic grant: adding a topic_contact classifies the topic back-catalog.
DO $$
DECLARE
    v_author uuid := (SELECT id FROM "user" WHERE email = 'cdl-author@test.plot');
    v_topic  uuid := gen_random_uuid();
    v_peer2  uuid := gen_random_uuid();
    v_peer2_c uuid;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_peer2, 'cdl-peer2@test.plot');
    v_peer2_c := public.upsert_user_contact(v_peer2, 'cdl-peer2@test.plot', 'CDL Peer2', NULL);
    INSERT INTO topic (id, name, created_by) VALUES (v_topic, 'cdl-topic', v_author);
    INSERT INTO thread (id, created_by, title, topic_id)
    VALUES (gen_random_uuid(), v_author, 'cdl topic thread', v_topic);
    INSERT INTO topic_contact (topic_id, contact_id) VALUES (v_topic, v_peer2_c);
END $$;

SELECT is(
    (SELECT count(*)::int FROM classification_decision cd
      JOIN thread t ON t.id = cd.thread_id
     WHERE cd.user_id = (SELECT id FROM "user" WHERE email = 'cdl-peer2@test.plot')
       AND t.title = 'cdl topic thread'),
    1, 'topic grant logs one decision');

-- Channel-default re-file: a root-filed thread with a matching channel
-- topic moves to the channel default and logs the move.
DO $$
DECLARE
    v_owner uuid := gen_random_uuid();
    v_owner_c uuid;
    v_twist bigint;
    v_ti    uuid := gen_random_uuid();
    v_ch    bigint;
    v_root  uuid;
    v_rootp ltree;
    v_focus uuid := gen_random_uuid();
    v_t     uuid := gen_random_uuid();
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_owner, 'cdl-owner@test.plot');
    v_owner_c := public.upsert_user_contact(v_owner, 'cdl-owner@test.plot', 'CDL Owner', NULL);
    SELECT id, path INTO v_root, v_rootp FROM priority WHERE user_id = v_owner AND nlevel(path) = 1;
    -- role_id required (priority_role_or_fyi CHECK); file under the owner's
    -- default role created by the activate_invited_user trigger above.
    INSERT INTO priority (id, created_by, user_id, title, path, role_id)
    VALUES (v_focus, v_owner, v_owner, 'cdl-channel-focus', v_rootp || 'cdlfocus', public.default_role_id(v_owner));
    INSERT INTO twist (twist_package_id, user_id, name, handle, version)
    VALUES (gen_random_uuid(), v_owner, 'CDL Twist', 'cdl-twist', '1.0') RETURNING id INTO v_twist;
    INSERT INTO twist_instance (id, twist_id, owner_id, name) VALUES (v_ti, v_twist, v_owner, 'CDL Conn');
    INSERT INTO channel (twist_instance_id, channel_id, title, default_priority_id)
    VALUES (v_ti, 'cdl-ch', 'CDL Channel', v_focus) RETURNING id INTO v_ch;
    INSERT INTO thread (id, created_by, twist_id, title, topic)
    VALUES (v_t, v_ti, v_twist, 'cdl channel thread', 'channel:' || v_ch::text);
    -- Normalize the owner filing to root/settled regardless of what the
    -- author-filing trigger did, putting the row in the initial-adoption shape.
    INSERT INTO thread_priority (thread_id, user_id, priority_id, user_moved)
    VALUES (v_t, v_owner, v_root, FALSE)
    ON CONFLICT ON CONSTRAINT thread_priority_pkey
    DO UPDATE SET priority_id = EXCLUDED.priority_id, user_moved = FALSE, classify_at = NULL;
    PERFORM public.apply_channel_default(v_ch);
END $$;

SELECT is(
    (SELECT count(*)::int FROM classification_decision cd
      JOIN thread t ON t.id = cd.thread_id
     WHERE t.title = 'cdl channel thread'),
    1, 'apply_channel_default logs one decision for the re-filed thread');

SELECT is(
    (SELECT cd.priority_id FROM classification_decision cd
      JOIN thread t ON t.id = cd.thread_id
     WHERE t.title = 'cdl channel thread'),
    (SELECT id FROM priority WHERE title = 'cdl-channel-focus'),
    'channel re-file decision targets the channel default focus');

SELECT * FROM finish();
ROLLBACK;
