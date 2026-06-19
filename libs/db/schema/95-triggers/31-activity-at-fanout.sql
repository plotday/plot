-- Maintenance for thread_priority.activity_at (the per-user feed sort key) =
--   GREATEST(thread.activity_base, thread_state.bumped_at).
--
-- Three pieces:
--   1. Seed on thread_priority INSERT from the thread's current activity_base
--      (and any existing per-user bumped_at).
--   2. Fan out a thread.activity_base change to every filed thread_priority row
--      (covers the note / link / schedule paths, which all bump activity_base).
--   3. Apply a per-user thread_state.bumped_at change to that user's row
--      (covers scoped notes and explicit user "bump to top").
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
        SELECT GREATEST(
                   COALESCE(a.activity_base, a.created_at),
                   COALESCE(ts.bumped_at, '-infinity'::timestamptz))
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

-- 2. Fan a thread.activity_base bump out to all filed thread_priority rows.
CREATE OR REPLACE FUNCTION public.fanout_activity_at_to_thread_priority ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
BEGIN
    IF NEW.activity_base IS NOT NULL THEN
        PERFORM set_config('plot.skip_activity_seq', 'on', TRUE);
        UPDATE thread_priority
        SET activity_at = GREATEST(COALESCE(activity_at, '-infinity'::timestamptz), NEW.activity_base)
        WHERE thread_id = NEW.id
          AND (activity_at IS NULL OR activity_at < NEW.activity_base);
        PERFORM set_config('plot.skip_activity_seq', 'off', TRUE);
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER fanout_activity_at_trigger
    AFTER UPDATE OF activity_base ON "public"."thread"
    FOR EACH ROW
    WHEN (NEW.activity_base IS DISTINCT FROM OLD.activity_base)
    EXECUTE FUNCTION fanout_activity_at_to_thread_priority ();

-- 3. Apply a per-user thread_state.bumped_at to that user's thread_priority row.
CREATE OR REPLACE FUNCTION public.update_tp_activity_from_thread_state ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
BEGIN
    IF NEW.bumped_at IS NOT NULL THEN
        PERFORM set_config('plot.skip_activity_seq', 'on', TRUE);
        UPDATE thread_priority
        SET activity_at = GREATEST(COALESCE(activity_at, '-infinity'::timestamptz), NEW.bumped_at)
        WHERE thread_id = NEW.thread_id
          AND user_id = NEW.user_id
          AND (activity_at IS NULL OR activity_at < NEW.bumped_at);
        PERFORM set_config('plot.skip_activity_seq', 'off', TRUE);
    END IF;
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
