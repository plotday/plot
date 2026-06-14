-- priority_role_or_fyi: every focus must have a role unless it is the global
-- FYI focus. Also exercises default_role_id() and the creation-path defaulting
-- (upsert_priority and the role_id => default_role_id(user) pattern used by the
-- REST endpoint, twist focus creation, and the seed generator).
BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(5);

DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    v_root uuid;
    v_root_path ltree;
    v_role uuid;          -- the auto-created "Personal" role
    v_synced uuid := gen_random_uuid();
BEGIN
    -- Inserting a user fires accept_invitations_on_signup → activate_invited_user,
    -- which auto-creates the user's default "Personal" role, its root Inbox
    -- priority (role_id set), and the role-less FYI focus.
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'role-or-fyi@test.local');
    SELECT id, path, role_id INTO v_root, v_root_path, v_role
    FROM priority WHERE user_id = v_user AND nlevel(path) = 1;

    -- Main client path: upsert_priority with no role_id must default it to the
    -- user's default role (so the row satisfies the CHECK).
    PERFORM "user".upsert_priority(
        v_user,
        jsonb_build_object('id', v_synced::text, 'title', 'Synced focus',
                           'created_by', v_user::text, 'updated_by', 0));

    PERFORM set_config('test.user', v_user::text, true);
    PERFORM set_config('test.root_path', v_root_path::text, true);
    PERFORM set_config('test.role', v_role::text, true);
    PERFORM set_config('test.synced', v_synced::text, true);
END $$;

-- (a) A role-less, non-FYI focus is rejected by the CHECK (23514).
SELECT throws_ok(
  format($q$INSERT INTO public.priority (created_by, user_id, title, path, role_id, is_fyi)
            VALUES (%1$L, %1$L, 'Roleless', generate_path(%2$L::ltree), NULL, FALSE)$q$,
         current_setting('test.user'), current_setting('test.root_path')),
  '23514', NULL, 'role-less non-FYI focus is rejected by priority_role_or_fyi');

-- (b) The global FYI focus is role-less (role_id NULL) and is_fyi — permitted by
-- the CHECK. Its mere existence (auto-created above) proves the row passed.
SELECT ok(
  (SELECT role_id IS NULL AND is_fyi
   FROM public.priority
   WHERE user_id = current_setting('test.user')::uuid AND is_fyi AND archived_at IS NULL),
  'the global FYI focus is role-less (role_id NULL) and is_fyi — allowed by the CHECK');

-- (c) Creation paths set role_id. REST/twist/seed pattern: an insert that
-- defaults role_id => default_role_id(user) is accepted.
SELECT lives_ok(
  format($q$INSERT INTO public.priority (created_by, user_id, title, path, role_id)
            VALUES (%1$L, %1$L, 'Roled', generate_path(%2$L::ltree),
                    public.default_role_id(%1$L::uuid))$q$,
         current_setting('test.user'), current_setting('test.root_path')),
  'a focus created with role_id => default_role_id(user) is accepted (REST/twist/seed path)');

-- (c) Main client path: upsert_priority defaulted role_id for the new focus.
SELECT ok(
  (SELECT role_id IS NOT NULL
   FROM public.priority
   WHERE id = current_setting('test.synced')::uuid),
  'upsert_priority defaults role_id for a new focus when the client sends none');

-- default_role_id returns the user's oldest live role (their Personal role).
SELECT is(
  public.default_role_id(current_setting('test.user')::uuid),
  current_setting('test.role')::uuid,
  'default_role_id returns the user''s oldest live role (Personal)');

ROLLBACK;
