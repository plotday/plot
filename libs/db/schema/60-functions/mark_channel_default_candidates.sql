-- Mark thread_priority rows pending after a channel's default_priority_id
-- has changed, so the consumer Worker re-classifies them with the
-- now-current channel default. Replaces apply_channel_default in the
-- hybrid-classifier production wiring; the API enqueues the returned
-- (user_id, thread_id) pairs.
CREATE OR REPLACE FUNCTION public.mark_channel_default_candidates (
    p_channel_id bigint
)
    RETURNS TABLE (user_id uuid, thread_id uuid)
    LANGUAGE plpgsql
    AS $function$
DECLARE
    v_owner_id uuid;
    v_root_id uuid;
BEGIN
    SELECT ti.owner_id
    INTO v_owner_id
    FROM public.channel c
    JOIN public.twist_instance ti ON ti.id = c.twist_instance_id
    WHERE c.id = p_channel_id;

    IF v_owner_id IS NULL THEN
        RETURN;
    END IF;

    SELECT p.id INTO v_root_id
    FROM public.priority p
    WHERE p.user_id = v_owner_id
      AND nlevel(p.path) = 1
      AND p.archived_at IS NULL
    ORDER BY p.created_at ASC
    LIMIT 1;

    RETURN QUERY
    WITH candidates AS MATERIALIZED (
        -- Previously placed by this channel's default.
        SELECT tp.thread_id, tp.user_id
        FROM public.thread_priority tp
        WHERE tp.applied_default_channel_id = p_channel_id
          AND tp.user_id = v_owner_id
          AND tp.user_moved = FALSE
          AND tp.priority_id IS NOT NULL

        UNION

        -- Sitting at root with no marker, but this channel now claims them.
        SELECT tp.thread_id, tp.user_id
        FROM public.thread_priority tp
        JOIN public.thread t ON t.id = tp.thread_id
        WHERE tp.user_id = v_owner_id
          AND tp.user_moved = FALSE
          AND tp.priority_id = v_root_id
          AND t.topic = 'channel:' || p_channel_id::text
          AND t.archived_at IS NULL
    )
    UPDATE public.thread_priority tp
    SET classify_at = now(),
        updated_at = now()
    FROM candidates c
    WHERE tp.thread_id = c.thread_id
      AND tp.user_id = c.user_id
      AND tp.user_moved = FALSE
      AND tp.priority_id IS NOT NULL
    RETURNING tp.user_id, tp.thread_id;
END;
$function$;

COMMENT ON FUNCTION public.mark_channel_default_candidates IS 'After a channel''s default_priority_id changes, mark candidate thread_priority rows pending re-classification. Returns (user_id, thread_id) of the marked rows so the API can enqueue ClassifyJobs. Replaces apply_channel_default in the hybrid-classifier wiring.';
