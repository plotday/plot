-- Retroactively apply a newly created priority_rule to existing threads.
-- Finds threads matching the rule's type/criteria/channel that are
-- currently filed in a different priority, and moves them.
--
-- Only moves threads where no higher-precedence rule already applies,
-- to avoid overriding content rules with a new channel rule.
CREATE OR REPLACE FUNCTION public.apply_priority_rule (
    p_rule_id uuid,
    p_max_moves int DEFAULT 100
)
    RETURNS TABLE (
        thread_id uuid,
        old_priority_id uuid)
    LANGUAGE plpgsql
    AS $function$
DECLARE
    v_rule RECORD;
BEGIN
    -- Load the rule.
    SELECT * INTO v_rule
    FROM public.priority_rule
    WHERE id = p_rule_id;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH candidates AS (
        -- Threads for this user in a different priority, matching channel scope.
        SELECT tp.thread_id, tp.priority_id AS current_priority_id
        FROM public.thread_priority tp
        JOIN public.thread t ON t.id = tp.thread_id
        LEFT JOIN LATERAL (
            SELECT c.id AS resolved_channel_id
            FROM public.link l
            JOIN public.channel c
                ON c.twist_instance_id = l.created_by
               AND c.channel_id = l.channel_id
            WHERE l.thread_id = tp.thread_id
              AND l.channel_id IS NOT NULL
            ORDER BY l.created_at DESC
            LIMIT 1
        ) ch ON TRUE
        WHERE tp.user_id = v_rule.user_id
          AND tp.priority_id IS DISTINCT FROM v_rule.priority_id
          AND t.archived_at IS NULL
          AND t.draft = FALSE
          AND ch.resolved_channel_id IS NOT DISTINCT FROM v_rule.channel_id
    ),
    matched AS (
        SELECT c.thread_id, c.current_priority_id
        FROM candidates c
        JOIN public.thread t ON t.id = c.thread_id
        WHERE
            CASE v_rule.type
                WHEN 'content' THEN
                    t.embedding IS NOT NULL
                    AND v_rule.embedding IS NOT NULL
                    AND (1 - (t.embedding <=> v_rule.embedding)) >= 0.7
                WHEN 'contact_topics' THEN
                    (v_rule.criteria ? 'topics'
                        AND t.topics && ARRAY(
                            SELECT jsonb_array_elements_text(v_rule.criteria -> 'topics')
                        )::uuid[])
                    OR
                    (v_rule.criteria ? 'contacts'
                        AND t.contacts && ARRAY(
                            SELECT jsonb_array_elements_text(v_rule.criteria -> 'contacts')
                        )::uuid[])
                WHEN 'channel' THEN
                    TRUE  -- All threads in this channel match.
            END
        LIMIT p_max_moves
    ),
    -- Only move if no higher-precedence rule already classifies this thread
    -- into a different priority.
    filtered AS (
        SELECT m.thread_id, m.current_priority_id
        FROM matched m
        WHERE public.classify_thread_for_user(
            v_rule.user_id,
            m.thread_id
        ) IS NOT DISTINCT FROM v_rule.priority_id
    ),
    moved AS (
        UPDATE public.thread_priority tp
        SET priority_id = v_rule.priority_id
        FROM filtered f
        WHERE tp.thread_id = f.thread_id
          AND tp.user_id = v_rule.user_id
        RETURNING tp.thread_id, f.current_priority_id AS old_priority_id
    )
    SELECT moved.thread_id, moved.old_priority_id FROM moved;
END;
$function$;

COMMENT ON FUNCTION public.apply_priority_rule IS 'Retroactively apply a priority_rule to existing threads. Only moves threads where the rule is the highest-precedence match, capped at p_max_moves.';
