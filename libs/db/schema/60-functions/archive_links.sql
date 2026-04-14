-- Archives links matching the given filter that were created by the specified source
-- (twist_instance_id). For each archived link's thread, if no other active links
-- remain, the thread is also archived.
-- Returns affected priority IDs for sync notification.
CREATE OR REPLACE FUNCTION public.archive_links (
    p_created_by uuid,
    p_filter jsonb DEFAULT '{}' ::jsonb
) RETURNS uuid[]
    LANGUAGE plpgsql
    AS $function$
DECLARE
    v_affected_priority_ids uuid[];
    v_now timestamptz := now();
BEGIN
    -- 1. Find matching link IDs and their thread IDs
    WITH matched_links AS (
        SELECT
            l.id AS link_id,
            l.thread_id
        FROM
            public.link l
        WHERE
            l.created_by = p_created_by
            AND l.thread_id IS NOT NULL
            -- Only match links on non-archived threads
            AND EXISTS (
                SELECT 1 FROM public.thread t
                WHERE t.id = l.thread_id AND t.archived_at IS NULL
            )
            -- channel_id filter
            AND (NOT (p_filter ? 'channelId')
                OR l.channel_id = (p_filter ->> 'channelId'))
            -- type filter
            AND (NOT (p_filter ? 'type')
                OR l.type = (p_filter ->> 'type'))
            -- status filter
            AND (NOT (p_filter ? 'status')
                OR l.status = (p_filter ->> 'status'))
            -- meta containment filter
            AND (NOT (p_filter ? 'meta')
                OR l.meta @> (p_filter -> 'meta'))
    ),
    -- 2. Find threads that should be archived:
    --    threads where ALL their links are in the matched set (no other active links)
    threads_to_archive AS (
        SELECT DISTINCT ml.thread_id
        FROM matched_links ml
        WHERE NOT EXISTS (
            -- Check for any link on this thread that is NOT in the matched set
            SELECT 1
            FROM public.link other_l
            WHERE other_l.thread_id = ml.thread_id
                AND other_l.id NOT IN (SELECT link_id FROM matched_links)
        )
    ),
    -- 3. Archive the threads and collect their IDs
    archived_threads AS (
        UPDATE public.thread t
        SET archived_at = v_now
        FROM threads_to_archive ta
        WHERE t.id = ta.thread_id
        RETURNING t.id
    )
    -- 4. Collect affected priority IDs from thread_priority
    SELECT ARRAY(
        SELECT DISTINCT tp.priority_id
        FROM archived_threads at
        JOIN thread_priority tp ON tp.thread_id = at.id
    )
    INTO v_affected_priority_ids;

    RETURN COALESCE(v_affected_priority_ids, ARRAY[]::uuid[]);
END;
$function$;
