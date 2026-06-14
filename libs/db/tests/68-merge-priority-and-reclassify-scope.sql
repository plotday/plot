-- user.merge_priority + mark_reclassify_candidates scoping.
--
-- Guards the fixes for the June 2026 mass-reclassify incident, where a focus
-- merge re-filed threads one by one and each re-file fired an anchored
-- mark_reclassify_candidates sweep whose contact-overlap branch matched the
-- user's ENTIRE workspace (every visible thread contains the user's own
-- contact):
--   • mark_reclassify_candidates strips the user's own linked contacts from
--     the anchor's contacts before the overlap match, and skips rows already
--     pending re-classification.
--   • user.merge_priority re-files a whole focus in one statement (no
--     user_moved flips, no classify_at changes) and archives the source.
BEGIN;
SET LOCAL search_path = public, "user", extensions;

SELECT plan(12);

DO $$
DECLARE
    v_user uuid := '00000000-0000-0000-0000-00000000e0a1';
    v_own uuid;
    v_sender_x uuid := '00000000-0000-0000-0000-00000000e0c2';
    v_sender_y uuid := '00000000-0000-0000-0000-00000000e0c3';
    v_root uuid;
    v_focus_r uuid := '00000000-0000-0000-0000-00000000e0f1';
    v_focus_a uuid := '00000000-0000-0000-0000-00000000e0f2';
    v_focus_b uuid := '00000000-0000-0000-0000-00000000e0f3';
    v_root_path ltree;
BEGIN
    INSERT INTO "public"."user" (id, email)
    VALUES (v_user, 'merge-reclassify@test.local');

    -- The user's primary contact is auto-provisioned with the user; reuse it.
    SELECT id INTO v_own
    FROM public.contact
    WHERE user_id = v_user AND "primary" = TRUE;

    INSERT INTO public.contact (id, name) VALUES
        (v_sender_x, 'Sender X'),
        (v_sender_y, 'Sender Y');
    INSERT INTO public.user_contact (user_id, contact_id, linked, "primary")
    VALUES (v_user, v_own, TRUE, TRUE)
    ON CONFLICT (user_id, contact_id) DO UPDATE
        SET linked = TRUE, "primary" = TRUE, archived_at = NULL;

    -- Root priority is auto-provisioned with the user.
    SELECT id, path INTO v_root, v_root_path
    FROM public.priority
    WHERE user_id = v_user AND nlevel(path) = 1
    ORDER BY created_at ASC
    LIMIT 1;

    -- role_id required (priority_role_or_fyi CHECK); file under the user's
    -- default role created by the activate_invited_user trigger above.
    INSERT INTO public.priority (id, created_by, title, path, user_id, role_id) VALUES
        (v_focus_r, v_user, 'Reclassify focus', v_root_path || 'mrtfocusr', v_user, public.default_role_id(v_user)),
        (v_focus_a, v_user, 'Merge source', v_root_path || 'mrtfocusa', v_user, public.default_role_id(v_user)),
        (v_focus_b, v_user, 'Merge target', v_root_path || 'mrtfocusb', v_user, public.default_role_id(v_user));

    -- Threads for the reclassify-scope tests (filed in focus R):
    --   d0 sticky  — training example so the function doesn't no-op
    --   d1 anchor  — contacts: own + sender X
    --   d2 peer    — shares sender X with the anchor      → marked
    --   d3 other   — shares ONLY the user's own contact   → must NOT be marked
    --   d4 pending — shares sender X but already pending  → must NOT re-mark
    INSERT INTO public.thread (id, created_by, title, contacts) VALUES
        ('00000000-0000-0000-0000-00000000e0d0', v_user, 'sticky training', ARRAY[v_own, v_sender_x]),
        ('00000000-0000-0000-0000-00000000e0d1', v_user, 'anchor', ARRAY[v_own, v_sender_x]),
        ('00000000-0000-0000-0000-00000000e0d2', v_user, 'same sender', ARRAY[v_own, v_sender_x]),
        ('00000000-0000-0000-0000-00000000e0d3', v_user, 'own contact only', ARRAY[v_own, v_sender_y]),
        ('00000000-0000-0000-0000-00000000e0d4', v_user, 'already pending', ARRAY[v_own, v_sender_x]);

    INSERT INTO public.thread_priority (thread_id, user_id, priority_id, user_moved, classify_at)
    VALUES
        ('00000000-0000-0000-0000-00000000e0d0', v_user, v_focus_r, TRUE, NULL),
        ('00000000-0000-0000-0000-00000000e0d1', v_user, v_focus_r, TRUE, NULL),
        ('00000000-0000-0000-0000-00000000e0d2', v_user, v_focus_r, FALSE, NULL),
        ('00000000-0000-0000-0000-00000000e0d3', v_user, v_focus_r, FALSE, NULL),
        ('00000000-0000-0000-0000-00000000e0d4', v_user, v_focus_r, FALSE, '2026-01-01T00:00:00Z')
    ON CONFLICT (thread_id, user_id) DO UPDATE
        SET priority_id = EXCLUDED.priority_id,
            user_moved = EXCLUDED.user_moved,
            classify_at = EXCLUDED.classify_at;

    -- Threads for the merge tests (filed in focus A):
    --   e1 auto-classified, e2 user-moved (sticky), e3 pending re-check.
    INSERT INTO public.thread (id, created_by, title, contacts) VALUES
        ('00000000-0000-0000-0000-00000000e0e1', v_user, 'merge auto', ARRAY[v_own]),
        ('00000000-0000-0000-0000-00000000e0e2', v_user, 'merge sticky', ARRAY[v_own]),
        ('00000000-0000-0000-0000-00000000e0e3', v_user, 'merge pending', ARRAY[v_own]);

    INSERT INTO public.thread_priority (thread_id, user_id, priority_id, user_moved, classify_at)
    VALUES
        ('00000000-0000-0000-0000-00000000e0e1', v_user, v_focus_a, FALSE, NULL),
        ('00000000-0000-0000-0000-00000000e0e2', v_user, v_focus_a, TRUE, NULL),
        ('00000000-0000-0000-0000-00000000e0e3', v_user, v_focus_a, FALSE, '2026-01-01T00:00:00Z')
    ON CONFLICT (thread_id, user_id) DO UPDATE
        SET priority_id = EXCLUDED.priority_id,
            user_moved = EXCLUDED.user_moved,
            classify_at = EXCLUDED.classify_at;
END $$;

-- ---------------------------------------------------------------------------
-- mark_reclassify_candidates scoping
-- ---------------------------------------------------------------------------

-- 1. Only the genuine sender-overlap thread is marked: the own-contact-only
--    thread and the already-pending thread are excluded.
SELECT results_eq(
  $$ SELECT thread_id FROM public.mark_reclassify_candidates(
       '00000000-0000-0000-0000-00000000e0a1'::uuid,
       '00000000-0000-0000-0000-00000000e0d1'::uuid) ORDER BY thread_id $$,
  $$ VALUES ('00000000-0000-0000-0000-00000000e0d2'::uuid) $$,
  'anchor sweep marks only the sender-overlap thread');

-- 2. The marked thread is pending.
SELECT isnt(
  (SELECT classify_at FROM thread_priority
    WHERE thread_id = '00000000-0000-0000-0000-00000000e0d2'
      AND user_id = '00000000-0000-0000-0000-00000000e0a1'),
  NULL,
  'sender-overlap thread now pending re-classification');

-- 3. The own-contact-only thread was NOT marked (this fails on the
--    pre-fix function, which matched every thread via the user's own
--    contact in thread.contacts).
SELECT is(
  (SELECT classify_at FROM thread_priority
    WHERE thread_id = '00000000-0000-0000-0000-00000000e0d3'
      AND user_id = '00000000-0000-0000-0000-00000000e0a1'),
  NULL,
  'own-contact-only thread stays settled');

-- 4. The already-pending thread keeps its original mark (not re-enqueued —
--    it did not appear in the function results above, and its timestamp is
--    untouched).
SELECT is(
  (SELECT classify_at FROM thread_priority
    WHERE thread_id = '00000000-0000-0000-0000-00000000e0d4'
      AND user_id = '00000000-0000-0000-0000-00000000e0a1'),
  '2026-01-01T00:00:00Z'::timestamptz,
  'already-pending thread keeps its original classify_at');

-- ---------------------------------------------------------------------------
-- user.merge_priority
-- ---------------------------------------------------------------------------

-- 5. Moves every filing from source to target and reports the count.
SELECT is(
  "user".merge_priority(
    '00000000-0000-0000-0000-00000000e0a1'::uuid,
    '00000000-0000-0000-0000-00000000e0f2'::uuid,
    '00000000-0000-0000-0000-00000000e0f3'::uuid),
  3,
  'merge_priority moves all three filings');

-- 6. All three rows now point at the target.
SELECT is(
  (SELECT count(*)::int FROM thread_priority
    WHERE user_id = '00000000-0000-0000-0000-00000000e0a1'
      AND priority_id = '00000000-0000-0000-0000-00000000e0f3'),
  3,
  'all source filings re-filed onto the target');

-- 7. user_moved is preserved (no training signal from a bulk merge).
SELECT is(
  (SELECT user_moved FROM thread_priority
    WHERE thread_id = '00000000-0000-0000-0000-00000000e0e2'
      AND user_id = '00000000-0000-0000-0000-00000000e0a1'),
  TRUE,
  'sticky filing stays sticky through the merge');

-- 8. classify_at is preserved (pending re-checks stay pending, settled rows
--    stay settled).
SELECT is(
  (SELECT classify_at FROM thread_priority
    WHERE thread_id = '00000000-0000-0000-0000-00000000e0e3'
      AND user_id = '00000000-0000-0000-0000-00000000e0a1'),
  '2026-01-01T00:00:00Z'::timestamptz,
  'pending filing keeps its classify_at through the merge');

-- 9. The source focus is archived.
SELECT isnt(
  (SELECT archived_at FROM priority
    WHERE id = '00000000-0000-0000-0000-00000000e0f2'),
  NULL,
  'source focus archived after merge');

-- 10. Merging a focus into itself is rejected.
SELECT throws_ok(
  $$ SELECT "user".merge_priority(
       '00000000-0000-0000-0000-00000000e0a1'::uuid,
       '00000000-0000-0000-0000-00000000e0f3'::uuid,
       '00000000-0000-0000-0000-00000000e0f3'::uuid) $$,
  'Cannot merge a focus into itself');

-- 11. An archived target is rejected (focus A was archived in test 9).
SELECT throws_ok(
  $$ SELECT "user".merge_priority(
       '00000000-0000-0000-0000-00000000e0a1'::uuid,
       '00000000-0000-0000-0000-00000000e0f3'::uuid,
       '00000000-0000-0000-0000-00000000e0f2'::uuid) $$,
  'Target focus not found or archived');

-- 12. A source the user does not own is rejected.
SELECT throws_ok(
  $$ SELECT "user".merge_priority(
       '00000000-0000-0000-0000-00000000e0a1'::uuid,
       '00000000-0000-0000-0000-00000000e0ff'::uuid,
       '00000000-0000-0000-0000-00000000e0f3'::uuid) $$,
  'Source focus not found');

SELECT * FROM finish();
ROLLBACK;
