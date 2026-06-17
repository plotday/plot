-- The scoring stage's contact (con) signal compares the candidate's contacts
-- against each user_moved example's contacts, with BOTH sides expanded to
-- include linked aliases (work + personal email of the same human). This is
-- the behaviour public.expand_contacts provides; classify_thread_for_user
-- batches that expansion (one alias lookup, expanded in SQL) instead of calling
-- the non-inlinable expand_contacts() per training row. These tests pin that
-- the alias-aware overlap still drives scoring after the batched rewrite.
BEGIN;
SET LOCAL search_path = public, extensions;

SELECT plan(3);

DO $$
DECLARE
    v_user   uuid := gen_random_uuid();
    v_root   ltree;
    v_rootid uuid;
    v_c_work uuid;
    v_c_pers uuid;
    v_focus  uuid := gen_random_uuid();
    v_moved  uuid := gen_random_uuid();
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'me@work.com');
    -- Two LINKED aliases of the same human (the user): work + personal email.
    -- upsert_user_contact -> sync_user_contact_from_contact links both
    -- (user_contact.linked = TRUE), so expand_contacts maps either alias to the
    -- full {work, personal} set.
    v_c_work := public.upsert_user_contact(v_user, 'me@work.com', 'Me Work', NULL);
    v_c_pers := public.upsert_user_contact(v_user, 'me@personal.com', 'Me Personal', NULL);

    SELECT id, path INTO v_rootid, v_root
    FROM priority WHERE user_id = v_user AND nlevel(path) = 1;

    INSERT INTO priority (id, created_by, user_id, title, path, role_id) VALUES
        (v_focus, v_user, v_user, 'Receipts', v_root || 'receipts',
         public.default_role_id(v_user));

    -- A user_moved example in Receipts whose ONLY contact is the WORK alias.
    INSERT INTO thread (id, created_by, title, contacts) VALUES
        (v_moved, v_user, 'Old receipt (work email)', ARRAY[v_c_work]);
    INSERT INTO thread_priority (thread_id, user_id, priority_id, user_moved) VALUES
        (v_moved, v_user, v_focus, TRUE);
END $$;

-- A candidate whose only contact is the PERSONAL alias. It shares NO contact
-- directly with the moved example — they overlap only after linked-alias
-- expansion. No topic / embedding, so the scoring stage's con signal is the
-- sole driver (topic short-circuit, keyed, channel-default all skipped).
DO $$
DECLARE
    v_cand uuid := gen_random_uuid();
    v_u    uuid := (SELECT id FROM "user" WHERE email = 'me@work.com');
    v_pers uuid := (SELECT uc.contact_id FROM user_contact uc
                    JOIN contact c ON c.id = uc.contact_id
                    WHERE uc.user_id = v_u AND c.email = 'me@personal.com');
BEGIN
    INSERT INTO thread (id, created_by, title, contacts)
        VALUES (v_cand, v_u, 'New receipt (personal email)', ARRAY[v_pers]);
END $$;

-- (1) The candidate routes to the trained focus purely via alias-expanded
--     contact overlap. Without expansion con would be 0 and it would fall
--     through to the root priority instead.
SELECT is(
    (SELECT priority_id FROM public.classify_thread_for_user_explain(
        (SELECT id FROM "user" WHERE email = 'me@work.com'),
        (SELECT id FROM thread WHERE title = 'New receipt (personal email)'))),
    (SELECT id FROM priority WHERE title = 'Receipts'
        AND user_id = (SELECT id FROM "user" WHERE email = 'me@work.com')),
    'linked-alias contact overlap routes the candidate to the trained focus');

-- (2) ...and it gets there via the SCORING stage specifically (con), not a
--     structural short-circuit.
SELECT is(
    (SELECT stage FROM public.classify_thread_for_user_explain(
        (SELECT id FROM "user" WHERE email = 'me@work.com'),
        (SELECT id FROM thread WHERE title = 'New receipt (personal email)'))),
    'scoring',
    'alias-expanded contact overlap is resolved in the scoring stage');

-- (3) Control: a candidate referencing an UNRELATED contact (no shared human,
--     no alias path) has no con overlap and must NOT route to Receipts — it
--     falls back to the user's root priority. Guards against the expansion
--     over-matching.
DO $$
DECLARE
    v_cand uuid := gen_random_uuid();
    v_u    uuid := (SELECT id FROM "user" WHERE email = 'me@work.com');
    v_other uuid := gen_random_uuid();
BEGIN
    INSERT INTO contact (id, email, name) VALUES (v_other, 'stranger@elsewhere.com', 'Stranger');
    INSERT INTO thread (id, created_by, title, contacts)
        VALUES (v_cand, v_u, 'Unrelated note', ARRAY[v_other]);
END $$;

SELECT isnt(
    (SELECT priority_id FROM public.classify_thread_for_user_explain(
        (SELECT id FROM "user" WHERE email = 'me@work.com'),
        (SELECT id FROM thread WHERE title = 'Unrelated note'))),
    (SELECT id FROM priority WHERE title = 'Receipts'
        AND user_id = (SELECT id FROM "user" WHERE email = 'me@work.com')),
    'an unrelated-contact candidate does not match the focus via expansion');

SELECT finish();
ROLLBACK;
