-- Maintenance for thread_priority.activity_at (the per-user feed sort key) =
--   COALESCE(GREATEST(thread.activity_base, thread_state.bumped_at),
--            thread.created_at).
--
-- created_at is a FALLBACK only — used when the thread has no content signal
-- (activity_base NULL) and no per-user bump. It is NOT folded into the GREATEST,
-- so a thread whose only content was imported "now" but originated long ago
-- (a backfilled link / note / private reply) sorts at its ORIGIN time, matching
-- what the app displays (Thread.contentActivityAt). This mirrors the client's
-- getter: GREATEST over content/bump primitives, then `?? createdAt`.
--
-- Three pieces:
--   1. Seed on thread_priority INSERT from the thread's current activity_base
--      (and any existing per-user bumped_at), falling back to created_at.
--   2. Recompute on a thread.activity_base change for every filed thread_priority
--      row (covers the note / link / schedule paths, which all bump
--      activity_base). The recompute may LOWER activity_at off the created_at
--      seed once the first (older) content time lands.
--   3. Recompute on a per-user thread_state.bumped_at change for that user's row
--      (covers scoped notes — whose origin time arrives via bumped_at — and the
--      app's explicit Active→Done bump).
--
-- All maintenance writes set plot.skip_activity_seq so they do NOT advance the
-- sync cursor: the Flutter app strips activity_at and recomputes feed ordering
-- locally, so re-emitting would be wasted sync + index churn. Updating
-- activity_at never trips thread_priority_bump_parent (that fires only on
-- priority_id changes).

-- 1. Seed on INSERT.
CREATE OR REPLACE FUNCTION public.seed_thread_priority_activity_at ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
BEGIN
    IF NEW.activity_at IS NULL THEN
        SELECT COALESCE(
                   GREATEST(a.activity_base, ts.bumped_at),
                   a.created_at)
          INTO NEW.activity_at
          FROM thread a
          LEFT JOIN thread_state ts
                 ON ts.thread_id = a.id AND ts.user_id = NEW.user_id
         WHERE a.id = NEW.thread_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER seed_thread_priority_activity_at_trigger
    BEFORE INSERT ON "public"."thread_priority"
    FOR EACH ROW
    EXECUTE FUNCTION seed_thread_priority_activity_at ();

-- 2. Recompute on a thread.activity_base change, for every filed user.
-- Full recompute (not a monotonic raise): when the first content time lands and
-- it predates the import, activity_at must drop off the created_at seed.
CREATE OR REPLACE FUNCTION public.fanout_activity_at_to_thread_priority ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
BEGIN
    PERFORM set_config('plot.skip_activity_seq', 'on', TRUE);
    UPDATE thread_priority tp
    SET activity_at = v.new_at
    FROM (
        SELECT tp2.user_id,
               COALESCE(GREATEST(NEW.activity_base, ts.bumped_at), NEW.created_at) AS new_at
        FROM thread_priority tp2
        LEFT JOIN thread_state ts
               ON ts.thread_id = tp2.thread_id AND ts.user_id = tp2.user_id
        WHERE tp2.thread_id = NEW.id
    ) v
    WHERE tp.thread_id = NEW.id
      AND tp.user_id = v.user_id
      AND tp.activity_at IS DISTINCT FROM v.new_at;
    PERFORM set_config('plot.skip_activity_seq', 'off', TRUE);
    RETURN NULL;
END;
$$;

CREATE TRIGGER fanout_activity_at_trigger
    AFTER UPDATE OF activity_base ON "public"."thread"
    FOR EACH ROW
    WHEN (NEW.activity_base IS DISTINCT FROM OLD.activity_base)
    EXECUTE FUNCTION fanout_activity_at_to_thread_priority ();

-- 3. Recompute a single user's row on a thread_state.bumped_at change.
-- Full recompute so a bump that is OLDER than the created_at seed (a backfilled
-- scoped reply) correctly lowers activity_at, while a newer bump (Active→Done,
-- live reply) raises it.
CREATE OR REPLACE FUNCTION public.update_tp_activity_from_thread_state ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
BEGIN
    PERFORM set_config('plot.skip_activity_seq', 'on', TRUE);
    UPDATE thread_priority tp
    SET activity_at = COALESCE(GREATEST(a.activity_base, NEW.bumped_at), a.created_at)
    FROM thread a
    WHERE tp.thread_id = NEW.thread_id
      AND tp.user_id = NEW.user_id
      AND a.id = tp.thread_id
      AND tp.activity_at IS DISTINCT FROM COALESCE(GREATEST(a.activity_base, NEW.bumped_at), a.created_at);
    PERFORM set_config('plot.skip_activity_seq', 'off', TRUE);
    RETURN NULL;
END;
$$;

CREATE TRIGGER update_tp_activity_from_thread_state_ins
    AFTER INSERT ON "public"."thread_state"
    FOR EACH ROW
    EXECUTE FUNCTION update_tp_activity_from_thread_state ();

CREATE TRIGGER update_tp_activity_from_thread_state_upd
    AFTER UPDATE OF bumped_at ON "public"."thread_state"
    FOR EACH ROW
    WHEN (NEW.bumped_at IS DISTINCT FROM OLD.bumped_at)
    EXECUTE FUNCTION update_tp_activity_from_thread_state ();
