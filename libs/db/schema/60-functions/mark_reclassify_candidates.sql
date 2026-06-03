-- Mark thread_priority rows pending after an explicit user move, so the
-- consumer Worker can re-classify them. Replaces reclassify_user_threads
-- in the hybrid-classifier production wiring; the worker pushes the
-- (user_id, thread_id) result rows onto the classify-thread queue.
--
-- Algorithm:
--   1. Same indexed candidate prefilter as the old function (topic, HNSW,
--      contact/group overlap). Onboarding threads (topic = 'onboarding') are
--      excluded from the HNSW/contact/group branches so they never leave the
--      Inbox on an unrelated move — they only move via the topic branch, i.e.
--      when the user explicitly moves one onboarding thread (then all follow).
--   2. UPDATE thread_priority SET classify_at = now() for each candidate
--      that's currently settled and non-sticky.
--   3. Return the (user_id, thread_id) pairs so the API can enqueue
--      ClassifyJob messages.
--
-- Sticky rows (user_moved = TRUE) are never touched; pending rows
-- (priority_id IS NULL) are already pending and don't need marking again.
CREATE OR REPLACE FUNCTION public.mark_reclassify_candidates (
    p_user_id uuid,
    p_anchor_thread_id uuid,
    p_max_candidates int DEFAULT 500
)
    RETURNS TABLE (user_id uuid, thread_id uuid)
    LANGUAGE plpgsql
    AS $function$
DECLARE
    v_topic text;
    v_embedding halfvec;
    v_contacts uuid[];
    v_groups uuid[];
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended('mark_reclassify_candidates:' || p_user_id::text, 0)
    );

    SELECT t.topic, t.embedding, t.contacts, t.groups
    INTO v_topic, v_embedding, v_contacts, v_groups
    FROM public.thread t
    WHERE t.id = p_anchor_thread_id;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    -- No-op when the user has no training examples yet — same rationale
    -- as the old function (classifier would yank rows into root).
    IF NOT EXISTS (
        SELECT 1 FROM public.thread_priority tp
        WHERE tp.user_id = p_user_id AND tp.user_moved = TRUE
    ) THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH candidates AS MATERIALIZED (
        SELECT t.id
        FROM public.thread t
        JOIN public.thread_priority tp
          ON tp.thread_id = t.id
         AND tp.user_id = p_user_id
         AND tp.user_moved = FALSE
         AND tp.priority_id IS NOT NULL
        WHERE v_topic IS NOT NULL
          AND t.topic = v_topic
          AND t.archived_at IS NULL
          AND t.draft = FALSE

        UNION

        SELECT id FROM (
            SELECT t.id, (t.embedding <=> v_embedding) AS dist
            FROM public.thread t
            JOIN public.thread_priority tp
              ON tp.thread_id = t.id
             AND tp.user_id = p_user_id
             AND tp.user_moved = FALSE
             AND tp.priority_id IS NOT NULL
            WHERE v_embedding IS NOT NULL
              AND t.embedding IS NOT NULL
              AND (1 - (t.embedding <=> v_embedding)) >= 0.5
              AND t.archived_at IS NULL
              AND t.draft = FALSE
              -- Onboarding threads stay pinned to the Inbox: they're only
              -- ever dragged along the topic branch above (when the moved
              -- anchor is itself an 'onboarding' thread), never pulled out
              -- by similarity to some unrelated thread the user moved.
              AND t.topic IS DISTINCT FROM 'onboarding'
            ORDER BY t.embedding <=> v_embedding ASC
            LIMIT p_max_candidates
        ) semantic

        UNION

        SELECT t.id
        FROM public.thread t
        JOIN public.thread_priority tp
          ON tp.thread_id = t.id
         AND tp.user_id = p_user_id
         AND tp.user_moved = FALSE
         AND tp.priority_id IS NOT NULL
        WHERE t.archived_at IS NULL
          AND t.draft = FALSE
          -- Onboarding threads only move via the topic branch (see above).
          AND t.topic IS DISTINCT FROM 'onboarding'
          AND (
              (cardinality(v_contacts) > 0 AND t.contacts && v_contacts)
              OR (cardinality(v_groups) > 0 AND t.groups && v_groups)
          )
    )
    UPDATE public.thread_priority tp
    SET classify_at = now(),
        updated_at = now()
    FROM candidates c
    WHERE tp.thread_id = c.id
      AND tp.user_id = p_user_id
      AND tp.user_moved = FALSE
      AND tp.priority_id IS NOT NULL
      AND c.id IS DISTINCT FROM p_anchor_thread_id
    RETURNING tp.user_id, tp.thread_id;
END;
$function$;

COMMENT ON FUNCTION public.mark_reclassify_candidates IS 'After an explicit user move, mark candidate thread_priority rows pending re-classification. Returns (user_id, thread_id) of the marked rows so the API can enqueue ClassifyJobs. Replaces reclassify_user_threads in the hybrid-classifier wiring.';
