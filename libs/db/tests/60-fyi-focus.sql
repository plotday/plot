BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(4);

DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    v_author uuid := gen_random_uuid();   -- a contact id
    v_role uuid;
    v_root uuid;
    v_root_path ltree;
    v_focus uuid;
    v_fyi uuid;
    v_thread uuid := gen_random_uuid();
BEGIN
    -- Inserting a user fires accept_invitations_on_signup → activate_invited_user,
    -- which auto-creates the user's default "Personal" role AND its root Inbox
    -- priority. We must NOT insert another nlevel=1 priority (validate_priority_root
    -- blocks it) — fetch the auto-created root + role and hang children from them.
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'fyi-test@local');
    SELECT id, path, role_id INTO v_root, v_root_path, v_role
    FROM priority WHERE user_id = v_user AND nlevel(path) = 1;

    INSERT INTO public.contact (id, email, name) VALUES (v_author, 'author@local', 'Author');

    INSERT INTO public.priority (created_by, user_id, title, path, color, role_id)
        VALUES (v_user, v_user, 'Reading', v_root_path || generate_path(NULL), 0, v_role)
        RETURNING id INTO v_focus;
    -- Activation already auto-creates the user's FYI focus; fetch it rather
    -- than inserting a duplicate (which would hit idx_priority_user_fyi).
    SELECT id INTO v_fyi FROM public.priority
     WHERE user_id = v_user AND is_fyi AND archived_at IS NULL;
    INSERT INTO public.thread (id, created_by, title, contacts)
        VALUES (v_thread, v_user, 'Newsletter', ARRAY[v_author]);
    INSERT INTO public.thread_priority (thread_id, user_id, priority_id, user_moved)
        VALUES (v_thread, v_user, v_focus, TRUE)
        ON CONFLICT ON CONSTRAINT thread_priority_pkey DO UPDATE SET user_moved = TRUE;
    PERFORM set_config('test.user', v_user::text, true);
    PERFORM set_config('test.author', v_author::text, true);
    PERFORM set_config('test.root_path', v_root_path::text, true);
END $$;

SELECT has_column('priority', 'is_fyi', 'priority.is_fyi exists');

SELECT throws_ok(
  format($q$INSERT INTO public.priority (created_by, user_id, title, path, color, role_id, is_fyi)
            VALUES (%1$L, %1$L, 'FYI2', generate_path(%2$L::ltree), 0, NULL, TRUE)$q$,
         current_setting('test.user'), current_setting('test.root_path')),
  '23505', NULL, 'second live FYI per user is rejected');

SELECT ok(
  public.author_has_real_focus_home(
    current_setting('test.user')::uuid, current_setting('test.author')::uuid),
  'author with a user_moved real-focus thread has a real-focus home');

SELECT ok(
  NOT public.author_has_real_focus_home(
    current_setting('test.user')::uuid, gen_random_uuid()),
  'unknown author has no real-focus home');

ROLLBACK;
