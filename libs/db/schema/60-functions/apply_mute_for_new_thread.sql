-- Check a newly synced/classified thread against the user's active mute
-- rules. If it matches one of them, stamp the seed reference and mark the
-- thread read + inactive so it lands in Done rather than Doing.
--
-- Called from the API right after classify_thread_for_user (see
-- workers/api/src/app/sync/threads.ts).
--
-- Returns the seed id that matched (so callers can log it), or NULL when
-- no rule matched.
CREATE OR REPLACE FUNCTION "user".apply_mute_for_new_thread (
    p_user_id uuid,
    p_thread_id uuid
)
    RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_seed_id uuid;
    v_match boolean;
BEGIN
    -- Skip if the thread is already archived (don't reapply on top of an
    -- explicit user action) or if it's itself a seed / already muted.
    IF EXISTS (
        SELECT 1
        FROM public.thread_priority tp
        WHERE tp.thread_id = p_thread_id
          AND tp.user_id = p_user_id
          AND (tp.archived_at IS NOT NULL
               OR tp.mute_by_thread_id IS NOT NULL)
    ) THEN
        RETURN NULL;
    END IF;

    -- Iterate over the user's seed rows (self-referencing ones). Typically
    -- a small set per user. Pick the most recently activated rule first so
    -- newer seeds win when several would match.
    FOR v_seed_id IN
        SELECT tp.thread_id
        FROM public.thread_priority tp
        WHERE tp.user_id = p_user_id
          AND tp.mute_by_thread_id = tp.thread_id
        ORDER BY tp.updated_at DESC
    LOOP
        -- Does the new thread match this seed's criteria?
        SELECT EXISTS (
            SELECT 1
            FROM "user".find_mute_candidates(p_user_id, v_seed_id) cid
            WHERE cid = p_thread_id
        )
        INTO v_match;

        IF v_match THEN
            UPDATE public.thread_priority tp
            SET mute_by_thread_id = v_seed_id,
                updated_at = now()
            WHERE tp.thread_id = p_thread_id
              AND tp.user_id = p_user_id;

            -- Mark read + inactive so the thread surfaces in Done.
            INSERT INTO public.thread_state (
                user_id, thread_id, active, read_at
            )
            VALUES (p_user_id, p_thread_id, FALSE, now())
            ON CONFLICT (user_id, thread_id)
            DO UPDATE SET
                active = FALSE,
                read_at = COALESCE(thread_state.read_at, now()),
                updated_at = now();

            RETURN v_seed_id;
        END IF;
    END LOOP;

    RETURN NULL;
END;
$$;

COMMENT ON FUNCTION "user".apply_mute_for_new_thread (uuid, uuid) IS
    'Check a newly synced thread against the user''s active mute seeds. If it matches one, stamp the seed reference and mark the thread read + inactive. Returns the matching seed id or NULL. No-ops on threads already archived/muted.';
