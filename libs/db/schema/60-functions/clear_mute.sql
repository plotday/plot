-- Reverse a "Skip active for threads like this" mute rule for one user.
--
-- Clears mute_by_thread_id on every thread_priority row for the user that
-- was flagged with the given seed. Does NOT touch thread_state — the user
-- has already absorbed the read+inactive transitions; un-muting simply
-- means "let new arrivals like this surface in Doing again." If the user
-- wants to reactivate the already-muted threads, they can do so manually.
--
-- Returns the number of rows the rule had touched.
CREATE OR REPLACE FUNCTION "user".clear_mute (
    p_user_id uuid,
    p_seed_thread_id uuid
)
    RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_affected integer;
    v_target_ids uuid[];
BEGIN
    -- Materialize the target thread ids first so we can lock the parent
    -- thread rows in deterministic order (matching upsert_thread's
    -- thread → thread_priority order). Concurrent upsert_thread on one
    -- of the target threads would otherwise see clear_mute lock
    -- thread_priority first; an AFTER UPDATE trigger could then need the
    -- thread row already held by the other transaction and deadlock.
    SELECT COALESCE(array_agg(tp.thread_id ORDER BY tp.thread_id), ARRAY[]::uuid[])
    INTO v_target_ids
    FROM public.thread_priority tp
    WHERE tp.user_id = p_user_id
      AND tp.mute_by_thread_id = p_seed_thread_id;

    IF cardinality(v_target_ids) = 0 THEN
        RETURN 0;
    END IF;

    PERFORM 1
    FROM public.thread t
    WHERE t.id = ANY(v_target_ids)
    ORDER BY t.id
    FOR NO KEY UPDATE;

    WITH updated AS (
        UPDATE public.thread_priority tp
        SET mute_by_thread_id = NULL,
            updated_at = now()
        WHERE tp.user_id = p_user_id
          AND tp.thread_id = ANY(v_target_ids)
        RETURNING tp.thread_id
    )
    SELECT count(*)::int INTO v_affected FROM updated;

    RETURN COALESCE(v_affected, 0);
END;
$$;

COMMENT ON FUNCTION "user".clear_mute (uuid, uuid) IS
    'Reverse the "Skip active for threads like this" mute rule anchored at p_seed_thread_id for p_user_id. Clears mute_by_thread_id on every thread_priority row that was filed under the seed. Returns affected row count.';
