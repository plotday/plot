-- Modify "classify_thread_for_user" function
CREATE OR REPLACE FUNCTION "public"."classify_thread_for_user" ("p_user_id" uuid, "p_thread_id" uuid DEFAULT NULL::uuid, "p_embedding" public.halfvec DEFAULT NULL::public.halfvec, "p_topic" text DEFAULT NULL::text, "p_contacts" uuid[] DEFAULT NULL::uuid[], "p_groups" uuid[] DEFAULT NULL::uuid[]) RETURNS uuid LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_embedding halfvec;
    v_topic text;
    v_contacts uuid[];
    v_groups uuid[];
    v_matched uuid;
BEGIN
    -- 1. Load thread signals when an id was supplied.
    IF p_thread_id IS NOT NULL THEN
        SELECT t.embedding, t.topic, t.contacts, t.groups
        INTO v_embedding, v_topic, v_contacts, v_groups
        FROM public.thread t
        WHERE t.id = p_thread_id;
    END IF;

    v_embedding := COALESCE(p_embedding, v_embedding);
    v_topic     := COALESCE(p_topic, v_topic);
    v_contacts  := COALESCE(p_contacts, v_contacts, ARRAY[]::uuid[]);
    v_groups    := COALESCE(p_groups, v_groups, ARRAY[]::uuid[]);

    -- 2. Topic short-circuit. When the user has moved threads carrying the
    --    same topic, that's a direct statement about where same-topic threads
    --    belong — return the mode of those priorities. Ties broken by the
    --    most recently updated thread_priority row.
    IF v_topic IS NOT NULL THEN
        SELECT tp.priority_id INTO v_matched
        FROM public.thread_priority tp
        JOIN public.thread mt ON mt.id = tp.thread_id
        WHERE tp.user_id = p_user_id
          AND tp.user_moved = TRUE
          AND mt.archived_at IS NULL
          AND mt.topic = v_topic
        GROUP BY tp.priority_id
        ORDER BY COUNT(*) DESC, MAX(tp.updated_at) DESC
        LIMIT 1;
        IF v_matched IS NOT NULL THEN
            RETURN v_matched;
        END IF;
    END IF;

    -- 3. Score all moved threads when no topic match was available.
    WITH moved AS (
        -- Every thread this user has explicitly moved. Read CURRENT signals
        -- from the thread row so relinking aliases / group edits take effect
        -- without a rule rewrite.
        SELECT tp.priority_id,
               mt.embedding,
               mt.contacts,
               mt.groups
        FROM public.thread_priority tp
        JOIN public.thread mt ON mt.id = tp.thread_id
        WHERE tp.user_id = p_user_id
          AND tp.user_moved = TRUE
          AND mt.archived_at IS NULL
    ),
    -- Pre-expand contacts once per side to avoid recomputation per candidate.
    candidate AS (
        SELECT public.expand_contacts(v_contacts) AS exp_contacts,
               v_groups AS groups,
               v_embedding AS embedding
    ),
    scored AS (
        SELECT
            f.priority_id,
            -- Semantic: cosine sim thresholded at 0.5, scaled to [0,1], squared.
            CASE
                WHEN f.embedding IS NULL OR c.embedding IS NULL THEN 0
                ELSE POWER(
                    GREATEST(0, (1 - (f.embedding <=> c.embedding)) - 0.5) * 2,
                    2
                )
            END AS sem,
            -- Contacts: Jaccard on expanded sets, squared.
            CASE
                WHEN cardinality(f.contacts) = 0 OR cardinality(c.exp_contacts) = 0 THEN 0
                ELSE POWER(
                    cardinality(ARRAY(
                        SELECT unnest(public.expand_contacts(f.contacts))
                        INTERSECT
                        SELECT unnest(c.exp_contacts)
                    ))::numeric
                    / NULLIF(cardinality(ARRAY(
                        SELECT unnest(public.expand_contacts(f.contacts))
                        UNION
                        SELECT unnest(c.exp_contacts)
                    )), 0),
                    2
                )
            END AS con,
            -- Groups: Jaccard (raw, not expanded), squared.
            CASE
                WHEN cardinality(f.groups) = 0 OR cardinality(c.groups) = 0 THEN 0
                ELSE POWER(
                    cardinality(ARRAY(
                        SELECT unnest(f.groups) INTERSECT SELECT unnest(c.groups)
                    ))::numeric
                    / NULLIF(cardinality(ARRAY(
                        SELECT unnest(f.groups) UNION SELECT unnest(c.groups)
                    )), 0),
                    2
                )
            END AS grp
        FROM moved f
        CROSS JOIN candidate c
    )
    SELECT priority_id INTO v_matched
    FROM scored
    WHERE (0.5 * sem + 0.35 * con + 0.15 * grp) >= 0.15
    ORDER BY (0.5 * sem + 0.35 * con + 0.15 * grp) DESC
    LIMIT 1;

    IF v_matched IS NOT NULL THEN
        RETURN v_matched;
    END IF;

    -- priority:{KEY}[:{SUB_TOPIC}] topic prefix — caller-specified default
    -- routing. Only reached when no user_moved example beat the score floor,
    -- so the user's own moves (same full topic string) always win.
    IF v_topic LIKE 'priority:%' THEN
        DECLARE
            v_priority_key text := split_part(v_topic, ':', 2);
        BEGIN
            IF v_priority_key <> '' THEN
                SELECT p.id INTO v_matched
                FROM public.priority p
                WHERE p.user_id = p_user_id
                  AND p.key = v_priority_key
                  AND p.archived_at IS NULL
                LIMIT 1;
                IF v_matched IS NOT NULL THEN
                    RETURN v_matched;
                END IF;
            END IF;
        END;
    END IF;

    -- Fallback: user's oldest non-archived root priority.
    SELECT p.id INTO v_matched
    FROM public.priority p
    WHERE p.user_id = p_user_id
      AND nlevel(p.path) = 1
      AND p.archived_at IS NULL
    ORDER BY p.created_at ASC
    LIMIT 1;

    RETURN v_matched;
END;
$$;
-- Set comment to function: "classify_thread_for_user"
COMMENT ON FUNCTION "public"."classify_thread_for_user" IS 'Classify a thread into a priority by looking up the user''s explicitly-moved threads (thread_priority.user_moved = TRUE). Topic match is a direct short-circuit (mode of same-topic moves). Otherwise scores by contact/group/embedding overlap (weights 0.35/0.15/0.5 after squaring) and keeps the best match above 0.15. Falls back to the priority:{KEY} prefix lookup, then to the user''s root priority.';
