-- Modify "apply_channel_default" function
CREATE OR REPLACE FUNCTION "public"."apply_channel_default" ("p_channel_id" bigint) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_owner_id uuid;
    v_root_id uuid;
    v_updated int;
BEGIN
    SELECT ti.owner_id
    INTO v_owner_id
    FROM public.channel c
    JOIN public.twist_instance ti ON ti.id = c.twist_instance_id
    WHERE c.id = p_channel_id;

    IF v_owner_id IS NULL THEN
        RETURN 0;
    END IF;

    SELECT p.id INTO v_root_id
    FROM public.priority p
    WHERE p.user_id = v_owner_id
      AND nlevel(p.path) = 1
      AND p.archived_at IS NULL
    ORDER BY p.created_at ASC
    LIMIT 1;

    -- AS MATERIALIZED on both CTEs is load-bearing: classify_thread_for_user
    -- is STABLE, so without the fence the planner inlines `reclass` and
    -- pushes the outer `r.new_priority_id IS NOT NULL` filter into
    -- `candidates`'s thread_priority bitmap scan. That broadens the inner
    -- scan to every (user_id, priority_id=root) row instead of only
    -- candidates whose thread.topic matches this channel, and classify
    -- ends up called on every root-filed thread (≫ candidates). With the
    -- fence, candidates is computed once and classify is called exactly
    -- once per row. Reproduced 30s timeout vs. 47ms with materialization.
    WITH candidates AS MATERIALIZED (
        SELECT tp.thread_id, tp.user_id
        FROM public.thread_priority tp
        WHERE tp.applied_default_channel_id = p_channel_id
          AND tp.user_id = v_owner_id
          AND tp.user_moved = FALSE

        UNION

        SELECT tp.thread_id, tp.user_id
        FROM public.thread_priority tp
        JOIN public.thread t ON t.id = tp.thread_id
        WHERE tp.user_id = v_owner_id
          AND tp.user_moved = FALSE
          AND tp.priority_id = v_root_id
          AND t.topic = 'channel:' || p_channel_id::text
          AND t.archived_at IS NULL
    ),
    reclass AS MATERIALIZED (
        SELECT c.thread_id,
               c.user_id,
               public.classify_thread_for_user(c.user_id, c.thread_id) AS new_priority_id
        FROM candidates c
    ),
    updated AS (
        UPDATE public.thread_priority tp
        SET priority_id = r.new_priority_id,
            applied_default_channel_id = public.channel_default_marker (
                r.user_id, r.thread_id, r.new_priority_id
            ),
            updated_at = now()
        FROM reclass r
        WHERE tp.thread_id = r.thread_id
          AND tp.user_id = r.user_id
          AND tp.user_moved = FALSE
          AND r.new_priority_id IS NOT NULL
          AND (
              r.new_priority_id IS DISTINCT FROM tp.priority_id
              OR public.channel_default_marker (
                     r.user_id, r.thread_id, r.new_priority_id
                 ) IS DISTINCT FROM tp.applied_default_channel_id
          )
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_updated FROM updated;

    RETURN v_updated;
END;
$$;
-- Modify "reclassify_user_threads" function
CREATE OR REPLACE FUNCTION "public"."reclassify_user_threads" ("p_user_id" uuid, "p_anchor_thread_id" uuid, "p_max_candidates" integer DEFAULT 500) RETURNS integer LANGUAGE plpgsql AS $$
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

    -- AS MATERIALIZED on both CTEs is load-bearing: classify_thread_for_user
    -- is STABLE, so without the fence the planner can inline `reclass` and
    -- push the outer `r.new_priority_id IS NOT NULL` filter through into
    -- `candidates`'s scans, calling classify against the unbounded
    -- pre-filter set instead of the indexed UNION result. Same shape as
    -- apply_channel_default; same fix. With the fence, candidates is
    -- computed once via the index path and classify is called exactly
    -- once per surviving row.
    WITH candidates AS MATERIALIZED (
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
    reclass AS MATERIALIZED (
        SELECT c.id AS thread_id,
               public.classify_thread_for_user(p_user_id, c.id) AS new_priority_id
        FROM candidates c
        WHERE c.id IS DISTINCT FROM p_anchor_thread_id
    ),
    updated AS (
        UPDATE public.thread_priority tp
        SET priority_id = r.new_priority_id,
            applied_default_channel_id = public.channel_default_marker (
                p_user_id, r.thread_id, r.new_priority_id
            ),
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
$$;
