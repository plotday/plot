-- Regression: schedule writes must succeed and notify the filing user.
--
-- Background: the "replace_urgency_collapse_schedule_into_thread_state"
-- refactor dropped the per-user schedule.user_id column (per-user "todo"
-- intent moved to thread_state), but left a second loop in
-- sync_user_for_schedule() that still selected n.user_id from the schedule
-- transition table. That trigger fires AFTER INSERT/UPDATE on every
-- schedule, so EVERY schedule write threw "column n.user_id does not exist"
-- (SQLSTATE 42703). The insert rolled back; the calendar connector (no
-- PostHog access) swallowed it to console, so user agendas silently went
-- blank for ~a week.
--
-- These tests guard the trigger: a link schedule and a thread schedule must
-- both insert without raising, and each must bump user_sync('schedule') for
-- every user who has the schedule's thread filed via thread_priority.
BEGIN;
SET LOCAL search_path = public, "user", extensions;

SELECT plan(4);

CREATE TEMP TABLE _ids (
    user_id uuid,
    priority_id uuid,
    thread_id uuid,
    link_id uuid
);

DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    v_priority uuid;
    v_thread uuid := gen_random_uuid();
    v_link uuid := gen_random_uuid();
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'sched@test.local');
    PERFORM public.upsert_user_contact(v_user, 'sched@test.local', 'Scheduler', NULL);
    SELECT id INTO v_priority FROM public.priority WHERE user_id = v_user LIMIT 1;

    INSERT INTO public.thread (id, created_by, title)
    VALUES (v_thread, v_user, 'event thread');

    -- Settled filing so the schedule's thread resolves to this user.
    INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
    VALUES (v_thread, v_user, v_priority);

    -- A connector-style link hanging off the thread.
    INSERT INTO public.link (id, thread_id, created_by, source, type)
    VALUES (v_link, v_thread, v_user, 'google-calendar:test-event@google.com', 'event');

    INSERT INTO _ids VALUES (v_user, v_priority, v_thread, v_link);
END $$;

-- ---------------------------------------------------------------------------
-- Case 1: a link schedule insert must not raise (the trigger fired here).
-- ---------------------------------------------------------------------------
SELECT lives_ok(
    $$ INSERT INTO public.schedule (link_id, "at")
       VALUES (
         (SELECT link_id FROM _ids),
         '[2026-06-04 10:00+00,2026-06-04 11:00+00)'
       ) $$,
    'case 1: link schedule insert does not raise (sync_user_for_schedule)'
);

-- Case 2: the filing user got a user_sync('schedule') row from the trigger.
SELECT ok(
    EXISTS (
        SELECT 1 FROM user_sync us, _ids
         WHERE us.user_id = _ids.user_id AND us.entity = 'schedule'
    ),
    'case 2: link schedule write bumped user_sync for the filing user'
) FROM _ids LIMIT 1;

-- ---------------------------------------------------------------------------
-- Case 3: a thread schedule insert must not raise either (same trigger).
-- ---------------------------------------------------------------------------
SELECT lives_ok(
    $$ INSERT INTO public.schedule (thread_id, "on")
       VALUES (
         (SELECT thread_id FROM _ids),
         '[2026-06-05,2026-06-06)'
       ) $$,
    'case 3: thread schedule insert does not raise'
);

-- Case 4: an UPDATE to a schedule must not raise (update trigger path).
SELECT lives_ok(
    $$ UPDATE public.schedule
          SET "at" = '[2026-06-04 12:00+00,2026-06-04 13:00+00)'
        WHERE link_id = (SELECT link_id FROM _ids) $$,
    'case 4: schedule update does not raise (sync_user_for_schedule update path)'
);

SELECT * FROM finish();
ROLLBACK;
