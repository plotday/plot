-- Facet gate: intrinsic violation, fail-open, per-focus sender exception,
-- org-domain trust (incl. freemail exclusion), and end-to-end gating through
-- classify_thread_for_user.
BEGIN;
SET LOCAL search_path = public, extensions;

SELECT plan(10);

DO $$
DECLARE
    v_user    uuid := gen_random_uuid();
    v_user_c  uuid;
    v_root    uuid;   -- auto-created by INSERT INTO "user" trigger
    v_root_path ltree;
    v_focus   uuid := gen_random_uuid();
    v_trust   uuid := gen_random_uuid();
    v_a       uuid := gen_random_uuid();
    v_b       uuid := gen_random_uuid();
    v_moved   uuid := gen_random_uuid();
    v_t_notif uuid := gen_random_uuid();
    v_t_msg   uuid := gen_random_uuid();
BEGIN
    -- Inserting a user fires accept_invitations_on_signup → activate_invited_user,
    -- which auto-creates the user's root priority. We must NOT insert another
    -- nlevel=1 priority (validate_priority_root trigger blocks it).
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'me@acme.com');
    v_user_c := public.upsert_user_contact(v_user, 'me@acme.com', 'Me', NULL);

    -- Fetch the auto-created root so we can hang children from it.
    SELECT id, path INTO v_root, v_root_path
    FROM priority WHERE user_id = v_user AND nlevel(path) = 1;

    INSERT INTO contact (id, email, name) VALUES
        (v_a, 'sender@acme.com', 'A Sender'),
        (v_b, 'b@elsewhere.com', 'B Recipient');

    -- Insert child priorities under the auto-created root path. role_id is
    -- required (priority_role_or_fyi CHECK); file them under the user's default
    -- role (created by the activate_invited_user trigger above).
    INSERT INTO priority (id, created_by, user_id, title, path, role_id) VALUES
        (v_focus, v_user, v_user, 'Reading', v_root_path || 'reading', public.default_role_id(v_user)),
        (v_trust, v_user, v_user, 'People',  v_root_path || 'people',  public.default_role_id(v_user));
    UPDATE priority SET facet_filters = '{"format":{"exclude":["notification"]}}'::jsonb WHERE id = v_focus;
    UPDATE priority SET facet_filters = '{"trustedSendersOnly":true}'::jsonb WHERE id = v_trust;

    INSERT INTO thread (id, created_by, title, contacts) VALUES
        (v_moved, v_user, 'Old reading', ARRAY[v_b]);
    INSERT INTO thread_priority (thread_id, user_id, priority_id, user_moved)
        VALUES (v_moved, v_user, v_focus, TRUE);

    INSERT INTO thread (id, created_by, title, contacts, author_id, facets) VALUES
        (v_t_notif, v_user, 'New notif', ARRAY[v_b], v_a, '{"format":"notification"}'::jsonb),
        (v_t_msg,   v_user, 'New msg',   ARRAY[v_b], v_a, '{"format":"message"}'::jsonb);
END $$;

-- (1) intrinsic_facets_violate: notification excluded → violates.
SELECT ok(public.intrinsic_facets_violate('{"format":"notification"}'::jsonb,
                                          '{"format":{"exclude":["notification"]}}'::jsonb),
          'notification violates an exclude filter');

-- (2) fail-open: null facet value never violates an include filter.
SELECT ok(NOT public.intrinsic_facets_violate('{"format":null}'::jsonb,
                                              '{"format":{"include":["reading"]}}'::jsonb),
          'null facet value fails open against include');

-- (3) author_matches_org_domain: A (acme.com) matches the user's org domain.
SELECT ok((SELECT public.author_matches_org_domain(u, a)
           FROM (SELECT id u FROM "user" WHERE email='me@acme.com') uu,
                (SELECT id a FROM contact WHERE email='sender@acme.com') aa),
          'org-domain match for same-domain non-freemail sender');

-- (4) is_trusted_for_focus: A is NOT yet trusted (no moved/created thread in
-- the focus contains A).
SELECT ok(NOT (SELECT public.is_trusted_for_focus(u, a, f)
               FROM (SELECT id u FROM "user" WHERE email='me@acme.com') uu,
                    (SELECT id a FROM contact WHERE email='sender@acme.com') aa,
                    (SELECT id f FROM priority WHERE title='Reading'
                                                AND user_id = (SELECT id FROM "user" WHERE email='me@acme.com')) ff),
          'A not yet trusted for the focus');

-- (5) thread_facets_gated: notification from A is gated out of the focus.
SELECT ok((SELECT public.thread_facets_gated(u, '{"format":"notification"}'::jsonb, a, f)
           FROM (SELECT id u FROM "user" WHERE email='me@acme.com') uu,
                (SELECT id a FROM contact WHERE email='sender@acme.com') aa,
                (SELECT id f FROM priority WHERE title='Reading'
                                            AND user_id = (SELECT id FROM "user" WHERE email='me@acme.com')) ff),
          'notification gated out of the focus');

-- (6) end-to-end: classify the notification candidate → NOT the focus (gated).
SELECT isnt(
    (SELECT priority_id FROM public.classify_thread_for_user_explain(
        (SELECT id FROM "user" WHERE email='me@acme.com'),
        (SELECT id FROM thread WHERE title='New notif'
                                 AND created_by = (SELECT id FROM "user" WHERE email='me@acme.com')))),
    (SELECT id FROM priority WHERE title='Reading'
                               AND user_id = (SELECT id FROM "user" WHERE email='me@acme.com')),
    'gated notification does not classify into the focus');

-- (7) end-to-end: the non-excluded message candidate DOES classify into focus.
SELECT is(
    (SELECT priority_id FROM public.classify_thread_for_user_explain(
        (SELECT id FROM "user" WHERE email='me@acme.com'),
        (SELECT id FROM thread WHERE title='New msg'
                                 AND created_by = (SELECT id FROM "user" WHERE email='me@acme.com')))),
    (SELECT id FROM priority WHERE title='Reading'
                               AND user_id = (SELECT id FROM "user" WHERE email='me@acme.com')),
    'non-excluded message classifies into the focus');

-- (8) sender exception: move a thread authored by A into the focus, making A
-- trusted-for-focus. Now the notification candidate bypasses the gate.
DO $$
DECLARE v_x uuid := gen_random_uuid();
BEGIN
    INSERT INTO thread (id, created_by, title, contacts, author_id)
    VALUES (v_x, (SELECT id FROM "user" WHERE email='me@acme.com'), 'A thread',
            ARRAY[(SELECT id FROM contact WHERE email='sender@acme.com')],
            (SELECT id FROM contact WHERE email='sender@acme.com'));
    INSERT INTO thread_priority (thread_id, user_id, priority_id, user_moved)
    VALUES (v_x, (SELECT id FROM "user" WHERE email='me@acme.com'),
            (SELECT id FROM priority WHERE title='Reading'
                                       AND user_id = (SELECT id FROM "user" WHERE email='me@acme.com')), TRUE);
END $$;

SELECT is(
    (SELECT priority_id FROM public.classify_thread_for_user_explain(
        (SELECT id FROM "user" WHERE email='me@acme.com'),
        (SELECT id FROM thread WHERE title='New notif'
                                 AND created_by = (SELECT id FROM "user" WHERE email='me@acme.com')))),
    (SELECT id FROM priority WHERE title='Reading'
                               AND user_id = (SELECT id FROM "user" WHERE email='me@acme.com')),
    'sender exception: trusted-for-focus author bypasses the gate');

-- (9) trustedSendersOnly: thread_facets_gated admits A via org-domain even with
-- no per-focus history (the People focus has trustedSendersOnly + A is org).
SELECT ok(NOT (SELECT public.thread_facets_gated(u, '{"format":"message"}'::jsonb, a, t)
               FROM (SELECT id u FROM "user" WHERE email='me@acme.com') uu,
                    (SELECT id a FROM contact WHERE email='sender@acme.com') aa,
                    (SELECT id t FROM priority WHERE title='People'
                                                AND user_id = (SELECT id FROM "user" WHERE email='me@acme.com')) tt),
          'trustedSendersOnly admits an org-domain author');

-- (10) freemail exclusion: a user and author sharing a FREEMAIL domain
-- (gmail.com, flagged domain.freemail=true) do NOT org-match.
DO $$
DECLARE
    v_u2  uuid := gen_random_uuid();
    v_u2c uuid;
    v_au  uuid := gen_random_uuid();
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_u2, 'me2@gmail.com');
    v_u2c := public.upsert_user_contact(v_u2, 'me2@gmail.com', 'Me2', NULL);
    INSERT INTO contact (id, email, name) VALUES (v_au, 'someone@gmail.com', 'Gmail Sender');
END $$;

SELECT ok(NOT (SELECT public.author_matches_org_domain(u, a)
               FROM (SELECT id u FROM "user" WHERE email='me2@gmail.com') uu,
                    (SELECT id a FROM contact WHERE email='someone@gmail.com') aa),
          'freemail domain (gmail.com) is excluded from org-domain trust');

SELECT finish();
ROLLBACK;
