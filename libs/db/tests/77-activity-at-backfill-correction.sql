-- Corrective backfill for the activity_at origin-time fix
-- (migrations/20260625213000_backfill_activity_at_origin.sql).
--
-- Triggers are disabled (session_replication_role = replica) so we can plant the
-- POISONED pre-fix state directly — activity_base/activity_at = import time,
-- scoped bumped_at = now() — then run the same backfill statements and assert
-- the corrected origin-time values. Mirrors 41-activity-at-backfill.sql.
BEGIN;
SET LOCAL search_path = public, extensions;
SET LOCAL session_replication_role = replica;

SELECT plan(5);

-- Plant: a thread imported "now" whose only content (link + scoped note) is old,
-- with the poisoned denormalized values the OLD triggers would have written.
CREATE TEMP TABLE _bf (
    link_src timestamptz, note_src timestamptz, import timestamptz,
    base timestamptz, at timestamptz, bump timestamptz,
    done_at timestamptz, done_result timestamptz);
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    v_thr  uuid := gen_random_uuid();   -- backfilled link + scoped note
    v_done uuid := gen_random_uuid();   -- genuine Active→Done of an old thread
    v_import   timestamptz := now();
    v_link_src timestamptz := now() - interval '300 days';
    v_note_src timestamptz := now() - interval '120 days';
    v_done_bump timestamptz := now();   -- done long after the thread was created
    v_base timestamptz; v_at timestamptz; v_bump timestamptz; v_dres timestamptz;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'bf2@t.l');

    -- POISONED thread: activity_base = import time (created_at), a link + scoped
    -- note both older, scoped bumped_at = now() (the bug).
    INSERT INTO public.thread (id, created_by, title, created_at, activity_base)
    VALUES (v_thr, v_user, 'poisoned', v_import, v_import);
    INSERT INTO public.link (thread_id, source_created_at) VALUES (v_thr, v_link_src);
    INSERT INTO public.thread_state (user_id, thread_id, bumped_at, last_note_source_created_at)
    VALUES (v_user, v_thr, v_import, v_note_src);   -- bumped_at poisoned to import
    INSERT INTO public.thread_priority (thread_id, user_id, classify_at, activity_at)
    VALUES (v_thr, v_user, now(), v_import);        -- activity_at poisoned to import

    -- GENUINE Active→Done: an OLD thread the user marked done "now". created_at
    -- is far in the past, so bumped_at is NOT within an hour of it — must be kept.
    INSERT INTO public.thread (id, created_by, title, created_at, activity_base)
    VALUES (v_done, v_user, 'done old', now() - interval '200 days', now() - interval '150 days');
    INSERT INTO public.thread_state (user_id, thread_id, bumped_at, last_note_source_created_at)
    VALUES (v_user, v_done, v_done_bump, now() - interval '150 days');
    INSERT INTO public.thread_priority (thread_id, user_id, classify_at, activity_at)
    VALUES (v_done, v_user, now(), v_done_bump);

    -- ── Backfill (identical statements to the migration) ────────────────────
    WITH want AS (
        SELECT a.id,
               NULLIF(GREATEST(
                   COALESCE(a.last_note_source_created_at, '-infinity'::timestamptz),
                   COALESCE((SELECT MAX(l.source_created_at) FROM public.link l WHERE l.thread_id = a.id),
                            '-infinity'::timestamptz),
                   COALESCE((SELECT MAX(COALESCE(upper(s.at), upper(s."on")::timestamptz))
                               FROM public.schedule s
                              WHERE s.thread_id = a.id AND s.occurrence IS NULL
                                AND s.recurrence_rule IS NULL AND s.archived_at IS NULL
                                AND COALESCE(upper(s.at), upper(s."on")::timestamptz) <= now()),
                            '-infinity'::timestamptz)
               ), '-infinity'::timestamptz) AS new_base
        FROM public.thread a
    )
    UPDATE public.thread a SET activity_base = w.new_base
    FROM want w WHERE a.id = w.id AND a.activity_base IS DISTINCT FROM w.new_base;

    UPDATE public.thread_state ts
    SET bumped_at = ts.last_note_source_created_at
    FROM public.thread t
    WHERE t.id = ts.thread_id
      AND ts.bumped_at IS NOT NULL
      AND ts.last_note_source_created_at IS NOT NULL
      AND ts.last_note_source_created_at < ts.bumped_at
      AND ts.bumped_at <= t.created_at + interval '1 hour';

    WITH want AS (
        SELECT tp.thread_id, tp.user_id,
               COALESCE(GREATEST(a.activity_base, ts.bumped_at), a.created_at) AS new_at
        FROM public.thread_priority tp
        JOIN public.thread a ON a.id = tp.thread_id
        LEFT JOIN public.thread_state ts ON ts.thread_id = tp.thread_id AND ts.user_id = tp.user_id
    )
    UPDATE public.thread_priority tp SET activity_at = w.new_at
    FROM want w
    WHERE w.thread_id = tp.thread_id AND w.user_id = tp.user_id
      AND tp.activity_at IS DISTINCT FROM w.new_at;

    SELECT activity_base INTO v_base FROM public.thread WHERE id = v_thr;
    SELECT activity_at INTO v_at FROM public.thread_priority WHERE thread_id = v_thr AND user_id = v_user;
    SELECT bumped_at INTO v_bump FROM public.thread_state WHERE thread_id = v_thr AND user_id = v_user;
    SELECT activity_at INTO v_dres FROM public.thread_priority WHERE thread_id = v_done AND user_id = v_user;
    INSERT INTO _bf VALUES (v_link_src, v_note_src, v_import, v_base, v_at, v_bump, v_done_bump, v_dres);
END $$;

SELECT is((SELECT base FROM _bf), (SELECT link_src FROM _bf),
    'backfill: activity_base recomputed to max content source (link), not import time');
SELECT is((SELECT bump FROM _bf), (SELECT note_src FROM _bf),
    'backfill: poisoned scoped bumped_at reset to the note origin time');
-- activity_base = link (older, 300d); bumped_at = scoped note (newer, 120d);
-- activity_at = GREATEST(...) = the newest content (the note), well below import.
SELECT is((SELECT at FROM _bf), (SELECT note_src FROM _bf),
    'backfill: activity_at = GREATEST(activity_base, bumped_at) = newest content (note origin)');
SELECT ok((SELECT at FROM _bf) < (SELECT import FROM _bf),
    'backfill: activity_at dropped BELOW import time');
SELECT is((SELECT done_result FROM _bf), (SELECT done_at FROM _bf),
    'backfill: a genuine Active→Done bump (not near created_at) is preserved');

SELECT * FROM finish();
ROLLBACK;
