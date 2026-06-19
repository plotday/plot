-- Backfill correctness for thread.activity_base / thread_priority.activity_at
-- (migrations/20260619024500_backfill_activity_at.sql).
--
-- Triggers are disabled (session_replication_role = replica) so we can plant the
-- pre-backfill NULL state directly, then run the same backfill statements and
-- assert the computed GREATEST values. Separate file so the replica setting does
-- not bleed into 40-activity-at-denormalization.sql.
BEGIN;
SET LOCAL search_path = public, extensions;
SET LOCAL session_replication_role = replica;

SELECT plan(2);

CREATE TEMP TABLE _bf (note_t timestamptz, link_t timestamptz, bump_t timestamptz,
                       base timestamptz, at timestamptz);

DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    v_thread uuid := gen_random_uuid();
    v_note timestamptz := now() + interval '1 hour';
    v_link timestamptz := now() + interval '2 hours';
    v_bump timestamptz := now() + interval '3 hours';
    v_base timestamptz; v_at timestamptz;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'bf@t.l');
    -- Plant pre-backfill state with triggers off: thread carries the note source
    -- time, a link carries a later source time, activity_base/activity_at NULL.
    INSERT INTO public.thread (id, created_by, title, last_note_source_created_at, activity_base)
    VALUES (v_thread, v_user, 'T', v_note, NULL);
    INSERT INTO public.link (thread_id, source_created_at) VALUES (v_thread, v_link);
    INSERT INTO public.thread_state (user_id, thread_id, bumped_at) VALUES (v_user, v_thread, v_bump);
    INSERT INTO public.thread_priority (thread_id, user_id, classify_at, activity_at)
    VALUES (v_thread, v_user, now(), NULL);

    -- Backfill (same statements as the migration).
    UPDATE public.thread a
    SET activity_base = GREATEST(
            COALESCE(a.last_note_source_created_at, '-infinity'::timestamptz),
            COALESCE((SELECT MAX(l.source_created_at) FROM public.link l WHERE l.thread_id = a.id),
                     '-infinity'::timestamptz),
            COALESCE((SELECT MAX(COALESCE(upper(s.at), upper(s."on")::timestamptz))
                        FROM public.schedule s
                       WHERE s.thread_id = a.id AND s.occurrence IS NULL AND s.recurrence_rule IS NULL
                         AND s.archived_at IS NULL
                         AND COALESCE(upper(s.at), upper(s."on")::timestamptz) <= now()),
                     '-infinity'::timestamptz),
            a.created_at)
    WHERE a.activity_base IS NULL;

    UPDATE public.thread_priority tp
    SET activity_at = GREATEST(
            (SELECT COALESCE(a.activity_base, a.created_at) FROM public.thread a WHERE a.id = tp.thread_id),
            COALESCE((SELECT ts.bumped_at FROM public.thread_state ts
                       WHERE ts.thread_id = tp.thread_id AND ts.user_id = tp.user_id),
                     '-infinity'::timestamptz));

    SELECT activity_base INTO v_base FROM public.thread WHERE id = v_thread;
    SELECT activity_at INTO v_at FROM public.thread_priority WHERE thread_id = v_thread AND user_id = v_user;
    INSERT INTO _bf VALUES (v_note, v_link, v_bump, v_base, v_at);
END $$;

SELECT is((SELECT base FROM _bf), (SELECT link_t FROM _bf),
    'backfill sets thread.activity_base = GREATEST(note, link, created_at) = link time');
SELECT is((SELECT at FROM _bf), (SELECT bump_t FROM _bf),
    'backfill sets thread_priority.activity_at = GREATEST(activity_base, bumped_at) = bump time');

SELECT * FROM finish();
ROLLBACK;
