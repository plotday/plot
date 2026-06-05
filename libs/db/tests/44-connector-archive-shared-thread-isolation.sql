-- Connector archive on a shared thread is per-user only.
--
-- Scenario: two users (A and B) each run their own connector instance, and
-- both instances created a LIVE link pointing at the SAME shared thread
-- (cross-user dedup by (twist_id, key)). When A removes/uninstalls their
-- connector, archive_links() retires A's per-user filing — but the shared
-- thread must NOT become globally archived, because B still has an active
-- filing and a live link.
--
-- Guards maybe_archive_thread_last_holder(): it globally archives a thread
-- only when NO active thread_priority rows AND NO live links remain. With B
-- still active on both counts, the thread stays visible to B.
BEGIN;
SET LOCAL search_path = public, extensions;

SELECT plan(5);

CREATE TEMP TABLE _ids (
    a_id uuid,
    b_id uuid,
    ti_a uuid,
    ti_b uuid,
    thread_id uuid
);

DO $$
DECLARE
    v_a uuid := gen_random_uuid();
    v_b uuid := gen_random_uuid();
    v_a_c uuid;
    v_b_c uuid;
    v_a_root uuid;
    v_b_root uuid;
    v_twist bigint;
    v_ti_a uuid;
    v_ti_b uuid;
    v_thread uuid := gen_random_uuid();
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES
        (v_a, 'a44@test.local'),
        (v_b, 'b44@test.local');

    v_a_c := public.upsert_user_contact(v_a, 'a44@test.local', 'User A', NULL);
    v_b_c := public.upsert_user_contact(v_b, 'b44@test.local', 'User B', NULL);

    SELECT id INTO v_a_root FROM public.priority
      WHERE user_id = v_a AND nlevel(path) = 1 LIMIT 1;
    SELECT id INTO v_b_root FROM public.priority
      WHERE user_id = v_b AND nlevel(path) = 1 LIMIT 1;

    -- One connector type (twist), two instances — one owned by each user.
    -- environment defaults to 'personal', so twist_owner_check needs user_id
    -- set; archive_links only resolves twist_instance.owner_id, so the twist's
    -- own owner is immaterial to the behaviour under test.
    INSERT INTO public.twist (name, version, twist_package_id, handle, user_id)
    VALUES ('Test Connector 44', '1.0', gen_random_uuid(), 'test-connector-44', v_a)
    RETURNING id INTO v_twist;

    INSERT INTO public.twist_instance (twist_id, owner_id, name)
    VALUES (v_twist, v_a, 'A instance') RETURNING id INTO v_ti_a;
    INSERT INTO public.twist_instance (twist_id, owner_id, name)
    VALUES (v_twist, v_b, 'B instance') RETURNING id INTO v_ti_b;

    -- Shared connector thread, both users in contacts. The
    -- file_thread_priority_peers trigger files pending rows for A and B;
    -- settle them so both are active, visible filings.
    INSERT INTO public.thread (id, created_by, twist_id, key, title, preview, contacts, groups)
    VALUES (v_thread, v_ti_a, v_twist, 'shared-item-44', 'Shared item',
            'shared preview', ARRAY[v_a_c, v_b_c], ARRAY[]::uuid[]);

    INSERT INTO public.thread_priority (thread_id, user_id, priority_id, classify_at)
    VALUES (v_thread, v_a, v_a_root, NULL)
    ON CONFLICT ON CONSTRAINT thread_priority_pkey
    DO UPDATE SET priority_id = EXCLUDED.priority_id, classify_at = NULL, archived_at = NULL;
    INSERT INTO public.thread_priority (thread_id, user_id, priority_id, classify_at)
    VALUES (v_thread, v_b, v_b_root, NULL)
    ON CONFLICT ON CONSTRAINT thread_priority_pkey
    DO UPDATE SET priority_id = EXCLUDED.priority_id, classify_at = NULL, archived_at = NULL;

    -- One live link per connector instance, both on the shared thread.
    INSERT INTO public.link (created_by, thread_id, source)
    VALUES (v_ti_a, v_thread, 'link-a-44');
    INSERT INTO public.link (created_by, thread_id, source)
    VALUES (v_ti_b, v_thread, 'link-b-44');

    INSERT INTO _ids VALUES (v_a, v_b, v_ti_a, v_ti_b, v_thread);

    -- A uninstalls their connector: empty filter + hard delete (the uninstall
    -- path), scoped to A's twist_instance.
    PERFORM public.archive_links(v_ti_a, '{}'::jsonb, TRUE);
END $$;

-- 1. The shared thread is NOT globally archived (the core guarantee).
SELECT ok(
    (SELECT archived_at IS NULL FROM public.thread WHERE id = _ids.thread_id),
    'shared thread is NOT globally archived after A removes their connector'
) FROM _ids LIMIT 1;

-- 2. A's own filing was retired (per-user archive).
SELECT ok(
    (SELECT archived_at IS NOT NULL FROM public.thread_priority
      WHERE thread_id = _ids.thread_id AND user_id = _ids.a_id),
    'A''s per-user filing is archived'
) FROM _ids LIMIT 1;

-- 3. B's filing is untouched.
SELECT ok(
    (SELECT archived_at IS NULL FROM public.thread_priority
      WHERE thread_id = _ids.thread_id AND user_id = _ids.b_id),
    'B''s per-user filing is left active'
) FROM _ids LIMIT 1;

-- 4. B's link is still live.
SELECT ok(
    EXISTS (SELECT 1 FROM public.link
      WHERE thread_id = _ids.thread_id AND created_by = _ids.ti_b
        AND archived_at IS NULL),
    'B''s connector link is still live'
) FROM _ids LIMIT 1;

-- 5. B still sees the shared thread as active in user.thread.
SELECT ok(
    EXISTS (SELECT 1 FROM "user".thread
      WHERE user_id = _ids.b_id AND id = _ids.thread_id
        AND archived_at IS NULL),
    'B still sees the shared thread as active'
) FROM _ids LIMIT 1;

SELECT * FROM finish();
ROLLBACK;
