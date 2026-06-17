BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(10);

DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    v_author uuid := gen_random_uuid();   -- a contact id
    v_role uuid;
    v_root uuid;
    v_root_path ltree;
    v_focus uuid;
    v_fyi uuid;
    v_work_role uuid;
    v_work_fyi uuid;
    v_thread uuid := gen_random_uuid();
BEGIN
    -- Inserting a user fires accept_invitations_on_signup → activate_invited_user,
    -- which auto-creates the user's default "Personal" role, its root Inbox
    -- priority, AND that role's FYI focus. We must NOT insert another nlevel=1
    -- priority (validate_priority_root blocks it) — fetch the auto-created root +
    -- role and hang children from them.
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'fyi-test@local');
    SELECT id, path, role_id INTO v_root, v_root_path, v_role
    FROM priority WHERE user_id = v_user AND nlevel(path) = 1;

    INSERT INTO public.contact (id, email, name) VALUES (v_author, 'author@local', 'Author');

    INSERT INTO public.priority (created_by, user_id, title, path, color, role_id)
        VALUES (v_user, v_user, 'Reading', v_root_path || generate_path(NULL), 0, v_role)
        RETURNING id INTO v_focus;
    -- Activation auto-creates the Personal role's FYI; fetch it.
    SELECT id INTO v_fyi FROM public.priority
     WHERE user_id = v_user AND is_fyi AND archived_at IS NULL;

    INSERT INTO public.thread (id, created_by, title, contacts)
        VALUES (v_thread, v_user, 'Newsletter', ARRAY[v_author]);
    INSERT INTO public.thread_priority (thread_id, user_id, priority_id, user_moved)
        VALUES (v_thread, v_user, v_focus, TRUE)
        ON CONFLICT ON CONSTRAINT thread_priority_pkey DO UPDATE SET user_moved = TRUE;

    -- A second role created via upsert_role should get its own muted FYI.
    v_work_role := "user".upsert_role(v_user, jsonb_build_object('name', 'Work', 'color', 1));
    SELECT id INTO v_work_fyi FROM public.priority
     WHERE user_id = v_user AND is_fyi AND role_id = v_work_role AND archived_at IS NULL;

    PERFORM set_config('test.user', v_user::text, true);
    PERFORM set_config('test.author', v_author::text, true);
    PERFORM set_config('test.root', v_root::text, true);
    PERFORM set_config('test.root_path', v_root_path::text, true);
    PERFORM set_config('test.role', v_role::text, true);
    PERFORM set_config('test.fyi', v_fyi::text, true);
    PERFORM set_config('test.work_role', v_work_role::text, true);
    PERFORM set_config('test.work_fyi', v_work_fyi::text, true);
END $$;

SELECT has_column('priority', 'is_fyi', 'priority.is_fyi exists');

SELECT ok(
  (SELECT role_id IS NOT NULL
            AND icon = 'newspaper'
            AND early_notifications_enabled = false
            AND key IS NULL
     FROM priority WHERE id = current_setting('test.fyi')::uuid),
  'activation FYI is role-bound, newspaper-iconed, muted, and keyless');

-- Uniqueness is now per-role: a second live FYI for the SAME role is rejected.
SELECT throws_ok(
  format($q$INSERT INTO public.priority (created_by, user_id, title, path, color, role_id, is_fyi, icon)
            VALUES (%1$L, %1$L, 'FYI2', %2$L::ltree || generate_path(NULL), 0, %3$L, TRUE, 'newspaper')$q$,
         current_setting('test.user'), current_setting('test.root_path'), current_setting('test.role')),
  '23505', NULL, 'second live FYI per role is rejected');

SELECT is(
  (SELECT (value#>>'{}')::float8 FROM priority_setting
     WHERE priority_id = current_setting('test.fyi')::uuid AND key = 'order'),
  2e15::float8, 'FYI is seeded with the sentinel order 2e15');

SELECT is(
  (SELECT (value#>>'{}')::float8 FROM priority_setting
     WHERE priority_id = current_setting('test.root')::uuid AND key = 'order'),
  1e15::float8, 'Inbox is seeded with the sentinel order 1e15');

SELECT ok(
  (SELECT is_fyi AND NOT early_notifications_enabled AND icon = 'newspaper'
            AND archived_at IS NULL
     FROM priority WHERE id = current_setting('test.work_fyi')::uuid),
  'upsert_role creates a muted, newspaper-iconed FYI for the new role');

-- Archiving a role is allowed even though it still owns its Inbox + FYI (the
-- archive-only-when-empty guard ignores both auto-managed focuses), and it
-- cascades archived_at onto the FYI.
SELECT lives_ok(
  format($q$SELECT "user".upsert_role(%1$L, jsonb_build_object('id', %2$L, 'archived_at', now()))$q$,
         current_setting('test.user'), current_setting('test.work_role')),
  'archiving a role with only its Inbox + FYI succeeds');

SELECT ok(
  (SELECT archived_at IS NOT NULL
     FROM priority WHERE id = current_setting('test.work_fyi')::uuid),
  'archiving a role cascades to archive its FYI');

SELECT ok(
  public.author_has_real_focus_home(
    current_setting('test.user')::uuid, current_setting('test.author')::uuid),
  'author with a user_moved real-focus thread has a real-focus home');

SELECT ok(
  NOT public.author_has_real_focus_home(
    current_setting('test.user')::uuid, gen_random_uuid()),
  'unknown author has no real-focus home');

ROLLBACK;
