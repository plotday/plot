-- Data backfill for the denormalized feed sort key.
--
-- Populates thread.activity_base and thread_priority.activity_at for rows that
-- predate the columns. Wrapped in plot.skip_activity_seq = 'on' so neither the
-- direct UPDATEs nor the activity_at fan-out trigger advance any seq — a backfill
-- of the whole table must NOT re-emit every thread to every client (that would be
-- a sync storm on deploy). The app strips activity_at and recomputes feed ordering
-- locally, so no client re-pull is needed.
--
-- Idempotent: re-running only ever raises values via GREATEST.
--
-- Disable statement_timeout for this migration transaction. On large
-- deployments the whole-table thread UPDATE (with its per-row link/schedule
-- subqueries) and the unconditional thread_priority rewrite exceed the default
-- per-statement budget (production hit 57014 on the thread UPDATE). The whole
-- migration runs in one transaction, so SET LOCAL scopes the override here and
-- reverts at the end of Atlas's migration transaction. plot.skip_activity_seq
-- keeps the fan-out trigger quiet, so this long write does not re-emit rows to
-- clients no matter how many it touches.
SET LOCAL statement_timeout = 0;
SELECT set_config('plot.skip_activity_seq', 'on', TRUE);

-- thread.activity_base = GREATEST(last note source time, latest link source time,
-- latest already-past non-recurring event end, created_at).
UPDATE public.thread a
SET activity_base = GREATEST(
        COALESCE(a.last_note_source_created_at, '-infinity'::timestamptz),
        COALESCE((SELECT MAX(l.source_created_at) FROM public.link l WHERE l.thread_id = a.id),
                 '-infinity'::timestamptz),
        COALESCE((SELECT MAX(COALESCE(upper(s.at), upper(s."on")::timestamptz))
                    FROM public.schedule s
                   WHERE s.thread_id = a.id
                     AND s.occurrence IS NULL
                     AND s.recurrence_rule IS NULL
                     AND s.archived_at IS NULL
                     AND COALESCE(upper(s.at), upper(s."on")::timestamptz) <= now()),
                 '-infinity'::timestamptz),
        a.created_at)
WHERE a.activity_base IS NULL;

-- thread_priority.activity_at = GREATEST(thread.activity_base, this user's
-- thread_state.bumped_at). Unconditional GREATEST so it also corrects any interim
-- value the fan-out trigger wrote while thread.activity_base was being backfilled.
UPDATE public.thread_priority tp
SET activity_at = GREATEST(
        (SELECT COALESCE(a.activity_base, a.created_at) FROM public.thread a WHERE a.id = tp.thread_id),
        COALESCE((SELECT ts.bumped_at FROM public.thread_state ts
                   WHERE ts.thread_id = tp.thread_id AND ts.user_id = tp.user_id),
                 '-infinity'::timestamptz));

SELECT set_config('plot.skip_activity_seq', 'off', TRUE);
