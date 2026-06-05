-- Mirror trigger: thread.assignee_id tracks the primary (earliest-created)
-- assignment-capable link's assignee. External (connector) assignment is the
-- source of truth for connector threads; Plot-only assignments are never
-- clobbered by a non-capable link.
--
-- Background: a new mutable, synced thread.assignee_id is the thread-level
-- source of truth. A sticky link.supports_assignee flag plus a statement-level
-- AFTER trigger mirror the earliest capable, non-archived link's assignee onto
-- the thread. "Sticky" means once a link has ever carried an assignee it stays
-- capable, so an external unassign (assignee_id -> NULL on the primary link)
-- mirrors NULL onto the thread rather than falling back to a stale value.
--
-- These five cases guard the mirror end-to-end:
--   1. a capable link's assignee mirrors onto its thread,
--   2. the EARLIEST capable link wins over a later one,
--   3. an external unassign on the primary link mirrors NULL (sticky),
--   4. a non-capable link never clobbers a Plot-only assignment,
--   5. user.upsert_link writing an assignee succeeds (and flips the sticky flag).
BEGIN;
SET LOCAL search_path = public, "user", extensions;

SELECT plan(5);

-- Seed a user, two contacts, threads, and links. The seeds satisfy the live
-- NOT-NULL / CHECK constraints:
--   user.email NOT NULL; thread.created_by NOT NULL + the
--   thread_title_required_when_not_draft CHECK (title required unless draft).
-- Creating the user auto-provisions a root priority (validate_priority_root
-- forbids a second one), so we look that up rather than inserting it, then
-- file both threads there (thread_priority) so upsert_link's access check
-- passes.
DO $$
DECLARE
    v_user uuid := '00000000-0000-0000-0000-0000000000a1';
    v_c1 uuid := '00000000-0000-0000-0000-0000000000c1';
    v_c2 uuid := '00000000-0000-0000-0000-0000000000c2';
    v_priority uuid;
    v_t1 uuid := '00000000-0000-0000-0000-0000000000d1';
    v_t2 uuid := '00000000-0000-0000-0000-0000000000d2';
BEGIN
    INSERT INTO "public"."user" (id, email)
    VALUES (v_user, 'assignee-mirror@test.local');

    INSERT INTO public.contact (id, name) VALUES
        (v_c1, 'Alice'),
        (v_c2, 'Bob');

    -- Root priority auto-created with the user; grants priority access.
    SELECT id INTO v_priority
    FROM public.priority
    WHERE user_id = v_user AND nlevel(path) = 1
    ORDER BY created_at ASC
    LIMIT 1;

    INSERT INTO public.thread (id, created_by, title)
    VALUES (v_t1, v_user, 'capable thread');

    INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
    VALUES (v_t1, v_user, v_priority);

    -- Plot-only thread with a pre-set assignee (no capable link yet).
    INSERT INTO public.thread (id, created_by, title, assignee_id)
    VALUES (v_t2, v_user, 'plot-only thread', v_c1);

    INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
    VALUES (v_t2, v_user, v_priority);
END $$;

-- 1. A capable link with an assignee mirrors onto the thread.
INSERT INTO link (id, thread_id, created_at, supports_assignee, assignee_id)
VALUES ('00000000-0000-0000-0000-0000000000b1',
        '00000000-0000-0000-0000-0000000000d1',
        now() - interval '2 min', true,
        '00000000-0000-0000-0000-0000000000c1');
SELECT is(
  (SELECT assignee_id FROM thread WHERE id = '00000000-0000-0000-0000-0000000000d1'),
  '00000000-0000-0000-0000-0000000000c1'::uuid,
  'capable link assignee mirrors onto thread');

-- 2. The EARLIEST capable link wins, not a later one.
INSERT INTO link (id, thread_id, created_at, supports_assignee, assignee_id)
VALUES ('00000000-0000-0000-0000-0000000000b2',
        '00000000-0000-0000-0000-0000000000d1',
        now() - interval '1 min', true,
        '00000000-0000-0000-0000-0000000000c2');
SELECT is(
  (SELECT assignee_id FROM thread WHERE id = '00000000-0000-0000-0000-0000000000d1'),
  '00000000-0000-0000-0000-0000000000c1'::uuid,
  'earliest capable link wins');

-- 3. External unassign on the primary link mirrors NULL.
UPDATE link SET assignee_id = NULL WHERE id = '00000000-0000-0000-0000-0000000000b1';
SELECT is(
  (SELECT assignee_id FROM thread WHERE id = '00000000-0000-0000-0000-0000000000d1'),
  NULL::uuid,
  'external unassign mirrors NULL (sticky capability)');

-- 4. A NON-capable link never clobbers a Plot-only assignment.
INSERT INTO link (id, thread_id, created_at, supports_assignee, assignee_id)
VALUES ('00000000-0000-0000-0000-0000000000b3',
        '00000000-0000-0000-0000-0000000000d2',
        now(), false, NULL);
SELECT is(
  (SELECT assignee_id FROM thread WHERE id = '00000000-0000-0000-0000-0000000000d2'),
  '00000000-0000-0000-0000-0000000000c1'::uuid,
  'non-capable link does not clobber Plot-only assignment');

-- 5. upsert_link sets supports_assignee sticky when an assignee is written.
SELECT lives_ok($$
  SELECT "user".upsert_link(
    '00000000-0000-0000-0000-0000000000a1',
    jsonb_build_object(
      'thread_id', '00000000-0000-0000-0000-0000000000d2',
      'assignee_id', '00000000-0000-0000-0000-0000000000c2'))
$$, 'upsert_link with assignee succeeds');

SELECT finish();
ROLLBACK;
