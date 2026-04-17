-- Retroactively re-file a user's threads that would now classify to a
-- different priority, given an anchor thread that was just explicitly moved.
--
-- Called asynchronously (via c.executionCtx.waitUntil from the priority-moves
-- sync endpoint). Bounded, index-driven, single function — the worker makes
-- one RPC call and does not iterate.
--
-- Algorithm:
--   1. Load the anchor thread's current signals (topic, embedding,
--      contacts, groups).
--   2. Build a candidate set via an index-backed UNION:
--        - threads with the same topic (idx_thread_topic)
--        - threads within HNSW cosine distance of the anchor's embedding,
--          capped at p_max_candidates (idx_thread_embedding)
--        - threads with contact or group overlap (idx_thread_contacts /
--          idx_thread_groups GIN)
--      Every candidate is currently filed for this user with
--      user_moved = FALSE — explicit moves are sticky and never overwritten.
--   3. For each candidate, call classify_thread_for_user(p_user_id, id).
--      Move candidates whose new priority differs from their current one.
--   4. Return the number of moved rows.
CREATE OR REPLACE FUNCTION public.reclassify_user_threads (
    p_user_id uuid,
    p_anchor_thread_id uuid,
    p_max_candidates int DEFAULT 500
)
    RETURNS int
    LANGUAGE plpgsql
    AS $function$
DECLARE
    v_topic text;
    v_embedding halfvec;
    v_contacts uuid[];
    v_groups uuid[];
    v_moved_count int;
BEGIN
    SELECT t.topic, t.embedding, t.contacts, t.groups
    INTO v_topic, v_embedding, v_contacts, v_groups
    FROM public.thread t
    WHERE t.id = p_anchor_thread_id;

    IF NOT FOUND THEN
        RETURN 0;
    END IF;

    -- No-op when the user has no training examples yet. classify would
    -- otherwise fall back to root for every candidate, yanking currently-
    -- well-placed threads into the root priority with no real signal.
    IF NOT EXISTS (
        SELECT 1 FROM public.thread_priority tp
        WHERE tp.user_id = p_user_id AND tp.user_moved = TRUE
    ) THEN
        RETURN 0;
    END IF;

    WITH candidates AS (
        -- Topic equality (idx_thread_topic partial index).
        SELECT t.id
        FROM public.thread t
        JOIN public.thread_priority tp
          ON tp.thread_id = t.id
         AND tp.user_id = p_user_id
         AND tp.user_moved = FALSE
        WHERE v_topic IS NOT NULL
          AND t.topic = v_topic
          AND t.archived_at IS NULL
          AND t.draft = FALSE

        UNION

        -- Semantic nearest-neighbor (HNSW idx_thread_embedding), bounded.
        SELECT id FROM (
            SELECT t.id, (t.embedding <=> v_embedding) AS dist
            FROM public.thread t
            JOIN public.thread_priority tp
              ON tp.thread_id = t.id
             AND tp.user_id = p_user_id
             AND tp.user_moved = FALSE
            WHERE v_embedding IS NOT NULL
              AND t.embedding IS NOT NULL
              AND (1 - (t.embedding <=> v_embedding)) >= 0.5
              AND t.archived_at IS NULL
              AND t.draft = FALSE
            ORDER BY t.embedding <=> v_embedding ASC
            LIMIT p_max_candidates
        ) semantic

        UNION

        -- Contact / group overlap (GIN idx_thread_contacts, idx_thread_groups).
        SELECT t.id
        FROM public.thread t
        JOIN public.thread_priority tp
          ON tp.thread_id = t.id
         AND tp.user_id = p_user_id
         AND tp.user_moved = FALSE
        WHERE t.archived_at IS NULL
          AND t.draft = FALSE
          AND (
              (cardinality(v_contacts) > 0 AND t.contacts && v_contacts)
              OR (cardinality(v_groups) > 0 AND t.groups && v_groups)
          )
    ),
    reclass AS (
        SELECT c.id AS thread_id,
               public.classify_thread_for_user(p_user_id, c.id) AS new_priority_id
        FROM candidates c
        WHERE c.id IS DISTINCT FROM p_anchor_thread_id
    ),
    updated AS (
        UPDATE public.thread_priority tp
        SET priority_id = r.new_priority_id,
            updated_at = now()
        FROM reclass r
        WHERE tp.thread_id = r.thread_id
          AND tp.user_id = p_user_id
          AND tp.user_moved = FALSE
          AND r.new_priority_id IS NOT NULL
          AND r.new_priority_id IS DISTINCT FROM tp.priority_id
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_moved_count FROM updated;

    RETURN v_moved_count;
END;
$function$;

COMMENT ON FUNCTION public.reclassify_user_threads IS 'After an explicit user move (anchor thread), retroactively re-file other threads that now classify differently. Uses indexed candidate prefilter (topic, HNSW, GIN), runs classify_thread_for_user per candidate, and moves those whose new classification differs — never touching rows where user_moved = TRUE.';
