-- Corrective backfill for the activity_at origin-time fix.
--
-- The previous triggers folded thread.created_at (the IMPORT time) into the feed
-- sort key, so any thread whose real content predates its import into Plot sorted
-- at the import time instead of the content's origin — scrambling the feed
-- relative to what the app displays (which uses content time). This rewrites the
-- denormalized values to the corrected formula:
--
--   thread.activity_base        = max CONTENT source time (note/link/past sched),
--                                 NULL when there is no content (NOT created_at)
--   thread_state.bumped_at       = note ORIGIN time for scoped-note import bumps
--                                 (was wrongly stamped now() at import)
--   thread_priority.activity_at  = COALESCE(GREATEST(activity_base, bumped_at),
--                                           created_at)
--
-- Wrapped in plot.skip_activity_seq = 'on' so neither the direct UPDATEs nor the
-- fan-out triggers advance any seq — a whole-table rewrite must NOT re-emit every
-- thread to every client (sync storm). The app strips activity_at and recomputes
-- ordering locally, so no client re-pull is needed.
--
-- statement_timeout disabled: the whole-table thread rewrite with per-row
-- link/schedule subqueries exceeds the default budget on large deployments
-- (the 2026-06-19 backfill hit 57014). SET LOCAL scopes it to this migration
-- transaction.
SET LOCAL statement_timeout = 0;
SELECT set_config('plot.skip_activity_seq', 'on', TRUE);

-- 1. Recompute thread.activity_base = max of CONTENT source times only; NULL when
--    the thread has no content. Corrects rows previously poisoned with the import
--    time (and lowers them to their true origin).
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
UPDATE public.thread a
SET activity_base = w.new_base
FROM want w
WHERE a.id = w.id AND a.activity_base IS DISTINCT FROM w.new_base;

-- 2. Repair scoped-note import bumps: bumped_at was set to now() at import while
--    the private reply's true source time is older. Reset to that source time
--    (carried per-user on last_note_source_created_at). Guarded to the import
--    signature (bump within an hour of thread creation) so a genuine, later
--    Active→Done bump on a pre-existing thread is never lowered. Rows whose
--    bumped_at is purely an app Active→Done action have last_note_source_created_at
--    NULL and are skipped.
UPDATE public.thread_state ts
SET bumped_at = ts.last_note_source_created_at
FROM public.thread t
WHERE t.id = ts.thread_id
  AND ts.bumped_at IS NOT NULL
  AND ts.last_note_source_created_at IS NOT NULL
  AND ts.last_note_source_created_at < ts.bumped_at
  AND ts.bumped_at <= t.created_at + interval '1 hour';

-- 3. Recompute thread_priority.activity_at = COALESCE(GREATEST(activity_base,
--    bumped_at), created_at) for every filed row, correcting any interim values
--    the fan-out triggers wrote while steps 1-2 ran.
WITH want AS (
    SELECT tp.thread_id, tp.user_id,
           COALESCE(GREATEST(a.activity_base, ts.bumped_at), a.created_at) AS new_at
    FROM public.thread_priority tp
    JOIN public.thread a ON a.id = tp.thread_id
    LEFT JOIN public.thread_state ts ON ts.thread_id = tp.thread_id AND ts.user_id = tp.user_id
)
UPDATE public.thread_priority tp
SET activity_at = w.new_at
FROM want w
WHERE w.thread_id = tp.thread_id AND w.user_id = tp.user_id
  AND tp.activity_at IS DISTINCT FROM w.new_at;

SELECT set_config('plot.skip_activity_seq', 'off', TRUE);
