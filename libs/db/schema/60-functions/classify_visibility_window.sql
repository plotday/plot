-- Length of time a pending case-A (priority_id IS NULL) thread_priority
-- row stays hidden before the user.* views fall back to surfacing it at
-- the user's root priority. Bounds visibility latency during classifier
-- outages: even if the consumer Worker is fully down, every thread
-- becomes visible (at root) after this window elapses.
--
-- Defined as a function so views, the sweep, and the consumer can share a
-- single source of truth — the window can be tuned in one place.
CREATE OR REPLACE FUNCTION public.classify_visibility_window ()
    RETURNS interval
    LANGUAGE sql
    IMMUTABLE
    PARALLEL SAFE
    AS $$
    SELECT interval '5 minutes'
$$;
