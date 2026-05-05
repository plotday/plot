BEGIN;
SET LOCAL search_path = public, extensions;

SELECT plan(6);

CREATE TEMP TABLE _ids (
    admin_id uuid,
    alice_id uuid,
    bob_id uuid,
    eve_id uuid,
    outsider_id uuid,
    public_user_id uuid,
    admin_c uuid,
    alice_c uuid,
    bob_c uuid,
    eve_c uuid,
    announce_id uuid,
    team_g_id uuid,
    pub_g_id uuid,
    thread_id uuid
);

DO $$
DECLARE
    v_admin uuid := gen_random_uuid();
    v_alice uuid := gen_random_uuid();
    v_bob   uuid := gen_random_uuid();
    v_eve   uuid := gen_random_uuid();
    v_outsider uuid := gen_random_uuid();
    v_pub_user uuid := gen_random_uuid();
    v_admin_c uuid;
    v_alice_c uuid;
    v_bob_c uuid;
    v_eve_c uuid;
    v_pub_user_c uuid;
    v_announce uuid;
    v_team_g uuid;
    v_pub_g uuid;
    v_thread uuid := gen_random_uuid();
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES
        (v_admin,    'admin@t.l'),
        (v_alice,    'alice@t.l'),
        (v_bob,      'bob@t.l'),
        (v_eve,      'eve@t.l'),
        (v_outsider, 'outsider@t.l'),
        (v_pub_user, 'pub@t.l');

    v_admin_c   := public.upsert_user_contact(v_admin,   'admin@t.l', 'A',  NULL);
    v_alice_c   := public.upsert_user_contact(v_alice,   'alice@t.l', 'Al', NULL);
    v_bob_c     := public.upsert_user_contact(v_bob,     'bob@t.l',   'B',  NULL);
    v_eve_c     := public.upsert_user_contact(v_eve,     'eve@t.l',   'E',  NULL);
    v_pub_user_c := public.upsert_user_contact(v_pub_user, 'pub@t.l', 'P', NULL);
    -- outsider gets a primary contact too, but is NOT a group member.
    PERFORM public.upsert_user_contact(v_outsider, 'outsider@t.l', 'O', NULL);

    -- Announce group with admin as group_admin and admin/alice/bob/eve/pub_user as members.
    INSERT INTO public."group" (id, name, type, created_by, auto_maintained)
    VALUES (gen_random_uuid(), 'announce', 'announce', v_admin, false)
    RETURNING id INTO v_announce;
    INSERT INTO public.group_admin (group_id, user_id) VALUES (v_announce, v_admin);
    INSERT INTO public.group_member (group_id, contact_id) VALUES
        (v_announce, v_admin_c),   (v_announce, v_alice_c),
        (v_announce, v_bob_c),     (v_announce, v_eve_c),
        (v_announce, v_pub_user_c);

    -- Team group with alice and bob as members (no admin link).
    INSERT INTO public."group" (id, name, type, created_by, auto_maintained)
    VALUES (gen_random_uuid(), 'team', 'team', v_admin, false)
    RETURNING id INTO v_team_g;
    INSERT INTO public.group_member (group_id, contact_id) VALUES
        (v_team_g, v_alice_c), (v_team_g, v_bob_c);

    -- Public group with pub_user as the only member (their ONLY access path to the thread).
    INSERT INTO public."group" (id, name, type, created_by, auto_maintained)
    VALUES (gen_random_uuid(), 'pub', 'public', v_admin, false)
    RETURNING id INTO v_pub_g;
    INSERT INTO public.group_member (group_id, contact_id) VALUES
        (v_pub_g, v_pub_user_c);

    -- A draft thread to all three groups, with eve in contacts.
    -- (Draft to bypass the title-required check; the predicate scoping doesn't care
    -- about draft status because thread_priority/group filing fires regardless.)
    INSERT INTO public.thread (id, created_by, draft, contacts, groups)
    VALUES (v_thread, v_admin, true, ARRAY[v_eve_c], ARRAY[v_announce, v_team_g, v_pub_g]);

    -- Manually file admin's thread_priority (raw INSERT skips author filing).
    INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
    SELECT v_thread, v_admin, p.id FROM public.priority p WHERE p.user_id = v_admin LIMIT 1;
    -- Re-fire the sync trigger now that admin's tp is in scope.
    UPDATE public.thread SET contacts = contacts WHERE id = v_thread;

    -- Manually file outsider's thread_priority too — simulating the buggy state where
    -- a user with no group membership somehow got a thread_priority row (the historical
    -- leak shape). We'll also seed an unjustified user_contact for them below.
    INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
    SELECT v_thread, v_outsider, p.id FROM public.priority p WHERE p.user_id = v_outsider LIMIT 1;

    -- Now seed legacy leak rows that the OLD trigger would have produced. We use
    -- direct INSERTs so we skip the new trigger's predicate guard. (The new trigger
    -- does fire on the UPDATE above, but it correctly excludes outsider — so we
    -- have to backfill outsider's leak row explicitly.)
    INSERT INTO user_contact (user_id, contact_id, linked, source)
    VALUES (v_outsider, v_eve_c, false, 'thread')
    ON CONFLICT DO NOTHING;

    -- Simulate the historical leak row for pub_user too: their only path to the
    -- thread is the public group, which must NOT count as "justification" for
    -- holding eve's user_contact. The cleanup predicate must archive this row.
    INSERT INTO user_contact (user_id, contact_id, linked, source)
    VALUES (v_pub_user, v_eve_c, false, 'thread')
    ON CONFLICT DO NOTHING;

    INSERT INTO _ids VALUES (
        v_admin, v_alice, v_bob, v_eve, v_outsider, v_pub_user,
        v_admin_c, v_alice_c, v_bob_c, v_eve_c,
        v_announce, v_team_g, v_pub_g, v_thread
    );
END $$;

-- Run the cleanup predicate (verbatim from the migration except for the
-- final UPDATE; we apply the same archive but keep it surgical for the test).
WITH unjustified AS (
    SELECT uc.user_id, uc.contact_id
    FROM public.user_contact uc
    WHERE uc.source = 'thread'
      AND uc.linked = false
      AND uc.archived_at IS NULL
      AND NOT EXISTS (
            SELECT 1
            FROM public.thread t
            JOIN public.thread_priority tp
                 ON tp.thread_id = t.id AND tp.user_id = uc.user_id
            WHERE uc.contact_id = ANY(t.contacts)
              AND t.archived_at IS NULL
              AND (
                    t.created_by = uc.user_id
                    OR EXISTS (
                        SELECT 1 FROM public.user_contact uc_self
                        WHERE uc_self.user_id = uc.user_id
                          AND uc_self.linked = TRUE
                          AND uc_self.archived_at IS NULL
                          AND uc_self.contact_id = ANY(t.contacts)
                    )
                    OR EXISTS (
                        SELECT 1
                        FROM unnest(COALESCE(t.groups, ARRAY[]::uuid[])) AS gid
                        JOIN public.group_admin ga
                             ON ga.group_id = gid AND ga.user_id = uc.user_id
                    )
                    OR EXISTS (
                        SELECT 1
                        FROM unnest(COALESCE(t.groups, ARRAY[]::uuid[])) AS gid
                        JOIN public."group" g
                             ON g.id = gid AND g.type IN ('private', 'team')
                        JOIN public.group_member gm ON gm.group_id = g.id
                        JOIN public.user_contact uc_grp
                             ON uc_grp.contact_id = gm.contact_id
                            AND uc_grp.linked = TRUE
                            AND uc_grp.archived_at IS NULL
                        WHERE uc_grp.user_id = uc.user_id
                    )
              )
      )
)
UPDATE public.user_contact uc
   SET archived_at = now(),
       updated_at  = now()
  FROM unjustified u
 WHERE uc.user_id = u.user_id
   AND uc.contact_id = u.contact_id
   AND uc.source = 'thread'
   AND uc.linked = false
   AND uc.archived_at IS NULL;

-- Assertions: who keeps user_contact for eve (justified), who loses it (unjustified).
SELECT ok(
    EXISTS (SELECT 1 FROM user_contact, _ids
             WHERE user_id = _ids.admin_id AND contact_id = _ids.eve_c AND archived_at IS NULL),
    'admin (group admin + author) keeps visibility into eve'
) FROM _ids LIMIT 1;

SELECT ok(
    EXISTS (SELECT 1 FROM user_contact, _ids
             WHERE user_id = _ids.alice_id AND contact_id = _ids.eve_c AND archived_at IS NULL),
    'alice (team group member) keeps visibility into eve'
) FROM _ids LIMIT 1;

SELECT ok(
    EXISTS (SELECT 1 FROM user_contact, _ids
             WHERE user_id = _ids.bob_id AND contact_id = _ids.eve_c AND archived_at IS NULL),
    'bob (team group member) keeps visibility into eve'
) FROM _ids LIMIT 1;

SELECT ok(
    NOT EXISTS (SELECT 1 FROM user_contact, _ids
                 WHERE user_id = _ids.outsider_id AND contact_id = _ids.eve_c AND archived_at IS NULL),
    'outsider (no group membership, simulated leak) loses visibility'
) FROM _ids LIMIT 1;

-- Eve's self-link is linked=TRUE, so the predicate's source='thread' AND linked=false filter
-- excludes it from consideration entirely.
SELECT ok(
    EXISTS (SELECT 1 FROM user_contact, _ids
             WHERE user_id = _ids.eve_id AND contact_id = _ids.eve_c
               AND linked = TRUE AND archived_at IS NULL),
    'eve self-link untouched'
) FROM _ids LIMIT 1;

-- Pin the public-group exclusion: the predicate restricts the group justification
-- to g.type IN ('private', 'team'). If anyone widens it back to g.type <> 'announce'
-- (the original bug shape), pub_user's leak row would be considered justified and
-- would NOT be archived — flipping this assertion to red.
SELECT ok(
    NOT EXISTS (SELECT 1 FROM user_contact, _ids
                 WHERE user_id = _ids.public_user_id AND contact_id = _ids.eve_c
                   AND archived_at IS NULL),
    'public group member (no other path) loses visibility — pins g.type IN (''private'', ''team'')'
) FROM _ids LIMIT 1;

SELECT * FROM finish();
ROLLBACK;
