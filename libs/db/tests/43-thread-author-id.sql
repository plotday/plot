-- thread.author_id derivation + immutability via user.upsert_thread.
--   (1) app user-created thread → author_id = user's primary contact
--   (2) connector thread with explicit author_id in p_defaults → that author
--   (3) twist thread without author → author_id = created_by (the twist)
--   (4) update never overwrites an already-set author_id (fill-only-when-NULL)
BEGIN;
SET LOCAL search_path = public, extensions;

SELECT plan(7);

DO $$
DECLARE
    v_user        uuid := gen_random_uuid();
    v_user_c      uuid;
    v_twist_owner uuid := gen_random_uuid();
    v_twist_id    bigint;
    v_ti          uuid := gen_random_uuid();   -- twist_instance id (acts as created_by)
    v_ext_c       uuid := gen_random_uuid();   -- external author contact
    v_t_app       uuid := gen_random_uuid();
    v_t_conn      uuid := gen_random_uuid();
    v_t_twist     uuid := gen_random_uuid();
BEGIN
    -- Users + the app user's primary contact (the twist owner needs no contact).
    INSERT INTO "public"."user" (id, email) VALUES
        (v_user, 'user@t.l'), (v_twist_owner, 'owner@t.l');
    v_user_c := public.upsert_user_contact(v_user, 'user@t.l', 'User', NULL);

    -- A twist definition + an owned twist_instance to act as created_by.
    -- twist requires NOT-NULL name/handle and a uuid twist_package_id; id is
    -- GENERATED ALWAYS AS IDENTITY. twist_instance requires a NOT-NULL name.
    INSERT INTO twist (twist_package_id, version, name, handle, user_id)
    VALUES (gen_random_uuid(), '1.0.0', 'Test Twist', 'test-twist-author-id', v_twist_owner)
        RETURNING id INTO v_twist_id;
    INSERT INTO twist_instance (id, twist_id, owner_id, name, draft)
        VALUES (v_ti, v_twist_id, v_twist_owner, 'Test Instance', false);

    -- An external-author contact (what a connector would resolve).
    INSERT INTO contact (id, email, name) VALUES (v_ext_c, 'ext@t.l', 'Ext Author');

    -- (1) App user-created thread (created_by defaults to user_id).
    PERFORM "user".upsert_thread(
        v_user,
        jsonb_build_object('id', v_t_app, 'title', 'App thread'),
        '{}'::jsonb);

    -- (2) Connector thread: created_by = twist_instance, explicit author_id.
    PERFORM "user".upsert_thread(
        v_twist_owner,
        jsonb_build_object('id', v_t_conn),
        jsonb_build_object('created_by', v_ti, 'title', 'Conn thread',
                           'author_id', v_ext_c));

    -- (3) Twist thread: created_by = twist_instance, NO author_id.
    PERFORM "user".upsert_thread(
        v_twist_owner,
        jsonb_build_object('id', v_t_twist),
        jsonb_build_object('created_by', v_ti, 'title', 'Twist thread'));

    -- (4) Update the connector thread again with a DIFFERENT author_id; must NOT change.
    PERFORM "user".upsert_thread(
        v_twist_owner,
        jsonb_build_object('id', v_t_conn, 'title', 'Conn thread edited'),
        jsonb_build_object('created_by', v_ti, 'author_id', v_user_c));

    -- Stash resolved author_ids and the raw ids/expected values for assertions.
    -- (_t_app / _t_twist hold thread ids so the backfill test in Task 5 can reach them.)
    CREATE TEMP TABLE _t (k text, author uuid);
    INSERT INTO _t SELECT 'app',   author_id FROM thread WHERE id = v_t_app;
    INSERT INTO _t SELECT 'conn',  author_id FROM thread WHERE id = v_t_conn;
    INSERT INTO _t SELECT 'twist', author_id FROM thread WHERE id = v_t_twist;
    INSERT INTO _t VALUES
        ('_user', v_user), ('_user_c', v_user_c), ('_ext_c', v_ext_c), ('_ti', v_ti),
        ('_t_app', v_t_app), ('_t_twist', v_t_twist);
END $$;

SELECT is((SELECT author FROM _t WHERE k='app'),
          (SELECT author FROM _t WHERE k='_user_c'),
          'app thread author_id = user primary contact');
SELECT is((SELECT author FROM _t WHERE k='conn'),
          (SELECT author FROM _t WHERE k='_ext_c'),
          'connector thread author_id = explicit external author');
SELECT is((SELECT author FROM _t WHERE k='twist'),
          (SELECT author FROM _t WHERE k='_ti'),
          'twist thread author_id = created_by (twist_instance)');
SELECT is((SELECT author FROM _t WHERE k='conn'),
          (SELECT author FROM _t WHERE k='_ext_c'),
          'update does not overwrite an already-set author_id');

-- (5) Backfill: a pre-existing USER thread with NULL author_id is backfilled to
-- the user's primary contact; a twist thread (created_by = twist_instance) stays
-- NULL because user_contact_id resolves to NULL for it. This runs the same
-- statement the Task 5 data migration ships to production.
UPDATE thread SET author_id = NULL WHERE id = (SELECT author FROM _t WHERE k='_t_app');

UPDATE thread t
   SET author_id = "user".user_contact_id(t.created_by)
 WHERE t.author_id IS NULL
   AND "user".user_contact_id(t.created_by) IS NOT NULL;

SELECT is((SELECT author_id FROM thread WHERE id = (SELECT author FROM _t WHERE k='_t_app')),
          (SELECT author FROM _t WHERE k='_user_c'),
          'backfill sets user thread author_id to primary contact');

-- (6) Authorization: a USER caller may not spoof author_id to a contact that
-- is not one of their own linked contacts. v_ext_c is an external contact not
-- linked to the user, so attributing the user's own thread to it must raise.
SELECT throws_ok(
    format($q$ SELECT "user".upsert_thread(%L::uuid,
        jsonb_build_object('title', 'Spoofed', 'author_id', %L::uuid),
        '{}'::jsonb) $q$,
        (SELECT author FROM _t WHERE k='_user'),
        (SELECT author FROM _t WHERE k='_ext_c')),
    'P0001',
    'author_id must be one of the caller''s linked contacts',
    'user cannot spoof author_id to a foreign contact');

-- (7) A USER caller MAY attribute a thread to one of their OWN linked contacts.
SELECT lives_ok(
    format($q$ SELECT "user".upsert_thread(%L::uuid,
        jsonb_build_object('id', gen_random_uuid(), 'title', 'Own author',
                           'author_id', %L::uuid),
        '{}'::jsonb) $q$,
        (SELECT author FROM _t WHERE k='_user'),
        (SELECT author FROM _t WHERE k='_user_c')),
    'user may attribute a thread to their own linked contact');

SELECT finish();
ROLLBACK;
