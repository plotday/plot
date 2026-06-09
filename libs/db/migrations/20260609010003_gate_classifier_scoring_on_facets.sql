-- Modify "classify_thread_for_user_explain" function
CREATE OR REPLACE FUNCTION "public"."classify_thread_for_user_explain" ("p_user_id" uuid, "p_thread_id" uuid DEFAULT NULL::uuid, "p_embedding" public.halfvec DEFAULT NULL::public.halfvec, "p_topic" text DEFAULT NULL::text, "p_contacts" uuid[] DEFAULT NULL::uuid[], "p_groups" uuid[] DEFAULT NULL::uuid[]) RETURNS TABLE ("priority_id" uuid, "stage" text, "scores" jsonb) LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_embedding halfvec;
    v_topic text;
    v_contacts uuid[];
    v_groups uuid[];
    v_facets jsonb;
    v_author_id uuid;
    v_matched uuid;
    v_scores jsonb;
    v_channel_pk bigint;
    v_priority_key text;
BEGIN
    -- 1. Load thread signals when an id was supplied.
    IF p_thread_id IS NOT NULL THEN
        SELECT t.embedding, t.topic, t.contacts, t.groups, t.facets, t.author_id
        INTO v_embedding, v_topic, v_contacts, v_groups, v_facets, v_author_id
        FROM public.thread t
        WHERE t.id = p_thread_id;
    END IF;

    v_embedding := COALESCE(p_embedding, v_embedding);
    v_topic     := COALESCE(p_topic, v_topic);
    v_contacts  := COALESCE(p_contacts, v_contacts, ARRAY[]::uuid[]);
    v_groups    := COALESCE(p_groups, v_groups, ARRAY[]::uuid[]);

    -- 2. Topic short-circuit on user_moved siblings.
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
            RETURN QUERY SELECT v_matched,
                                'topic_shortcircuit'::text,
                                jsonb_build_object('topic', v_topic);
            RETURN;
        END IF;
    END IF;

    -- 2.3. Cross-user keyed priority match.
    IF p_thread_id IS NOT NULL THEN
        SELECT p.id INTO v_matched
        FROM public.thread_priority tp
        JOIN public.priority src ON src.id = tp.priority_id
        JOIN public.priority p
          ON p.user_id = p_user_id
         AND p.key = src.key
         AND p.archived_at IS NULL
        WHERE tp.thread_id = p_thread_id
          AND tp.user_id <> p_user_id
          AND src.key IS NOT NULL
          AND src.archived_at IS NULL
        ORDER BY tp.created_at ASC
        LIMIT 1;
        IF v_matched IS NOT NULL THEN
            SELECT jsonb_build_object('key', p.key)
            INTO v_scores
            FROM public.priority p
            WHERE p.id = v_matched;
            RETURN QUERY SELECT v_matched,
                                'keyed_priority'::text,
                                COALESCE(v_scores, '{}'::jsonb);
            RETURN;
        END IF;
    END IF;

    -- 2.5. Channel default.
    IF v_topic LIKE 'channel:%' THEN
        BEGIN
            v_channel_pk := NULLIF(substring(v_topic FROM 9), '')::bigint;
            IF v_channel_pk IS NOT NULL THEN
                SELECT c.default_priority_id INTO v_matched
                FROM public.channel c
                JOIN public.priority p ON p.id = c.default_priority_id
                WHERE c.id = v_channel_pk
                  AND c.default_priority_id IS NOT NULL
                  AND p.user_id = p_user_id
                  AND p.archived_at IS NULL;
                IF v_matched IS NOT NULL THEN
                    RETURN QUERY SELECT v_matched,
                                        'channel_default'::text,
                                        jsonb_build_object('channel_id', v_channel_pk);
                    RETURN;
                END IF;
            END IF;
        EXCEPTION WHEN invalid_text_representation THEN
            NULL;
        END;
    END IF;

    -- 3. Score all moved threads when no topic match was available.
    WITH moved AS (
        SELECT tp.priority_id,
               tp.thread_id,
               mt.embedding,
               mt.contacts,
               mt.groups
        FROM public.thread_priority tp
        JOIN public.thread mt ON mt.id = tp.thread_id
        WHERE tp.user_id = p_user_id
          AND tp.user_moved = TRUE
          AND mt.archived_at IS NULL
    ),
    candidate AS (
        SELECT public.expand_contacts(v_contacts) AS exp_contacts,
               v_groups AS groups,
               v_embedding AS embedding
    ),
    -- Negative examples per priority: max cosine similarity between the
    -- candidate and threads the user moved out of / deselected for that focus.
    -- Subtracted from the priority's combined score below (mirror of the
    -- user_moved positive set; see thread_priority_negative).
    neg AS (
        SELECT n.priority_id,
               MAX(GREATEST(0, 1 - (nt.embedding <=> v_embedding))) AS neg_sim
        FROM public.thread_priority_negative n
        JOIN public.thread nt ON nt.id = n.thread_id
        WHERE n.user_id = p_user_id
          AND nt.archived_at IS NULL
          AND nt.embedding IS NOT NULL
          AND v_embedding IS NOT NULL
        GROUP BY n.priority_id
    ),
    scored AS (
        SELECT
            f.priority_id,
            f.thread_id,
            COALESCE(ng.neg_sim, 0) AS neg_sim,
            CASE
                WHEN f.embedding IS NULL OR c.embedding IS NULL THEN 0
                ELSE POWER(
                    GREATEST(0, (1 - (f.embedding <=> c.embedding)) - 0.5) * 2,
                    2
                )
            END AS sem,
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
        LEFT JOIN neg ng ON ng.priority_id = f.priority_id
    )
    SELECT jsonb_build_object(
        'top', COALESCE(jsonb_agg(
            jsonb_build_object(
                'priority_id', top_scored.pid,
                'thread_id', top_scored.tid,
                'sem', round(top_scored.sem::numeric, 4),
                'con', round(top_scored.con::numeric, 4),
                'grp', round(top_scored.grp::numeric, 4),
                'combined', round((0.5 * top_scored.sem + 0.35 * top_scored.con + 0.15 * top_scored.grp - 0.3 * top_scored.neg_sim)::numeric, 4)
            )
            ORDER BY (0.5 * top_scored.sem + 0.35 * top_scored.con + 0.15 * top_scored.grp - 0.3 * top_scored.neg_sim) DESC
        ), '[]'::jsonb)
    )
    INTO v_scores
    FROM (
        SELECT scored.priority_id AS pid,
               scored.thread_id AS tid,
               scored.sem,
               scored.con,
               scored.grp,
               scored.neg_sim
        FROM scored
        ORDER BY (0.5 * scored.sem + 0.35 * scored.con + 0.15 * scored.grp - 0.3 * scored.neg_sim) DESC
        LIMIT 3
    ) top_scored;

    SELECT (x.priority_id)::uuid INTO v_matched
    FROM jsonb_to_recordset(v_scores->'top')
        AS x(priority_id uuid, combined numeric)
    WHERE x.combined >= 0.15
      -- Facet gate: drop a scored focus whose filters this thread violates,
      -- unless a per-focus trusted-sender exception applies. Only the scoring
      -- stage is gated; explicit/structural stages above always win. A
      -- fully-gated thread falls through to priority_prefix / root_fallback.
      AND NOT public.thread_facets_gated(p_user_id, v_facets, v_author_id, x.priority_id)
    ORDER BY x.combined DESC
    LIMIT 1;

    IF v_matched IS NOT NULL THEN
        RETURN QUERY SELECT v_matched,
                            'scoring'::text,
                            COALESCE(v_scores, '{}'::jsonb);
        RETURN;
    END IF;

    -- 5. priority:{KEY}[:{SUB_TOPIC}] prefix.
    IF v_topic LIKE 'priority:%' THEN
        v_priority_key := split_part(v_topic, ':', 2);
        IF v_priority_key <> '' THEN
            SELECT p.id INTO v_matched
            FROM public.priority p
            WHERE p.user_id = p_user_id
              AND p.key = v_priority_key
              AND p.archived_at IS NULL
            LIMIT 1;
            IF v_matched IS NOT NULL THEN
                RETURN QUERY SELECT v_matched,
                                    'priority_prefix'::text,
                                    jsonb_build_object('key', v_priority_key);
                RETURN;
            END IF;
        END IF;
    END IF;

    -- 6. Root fallback. Focuses are team-agnostic, so every unmatched thread
    -- (personal or team-connector) routes to the user's root priority (oldest
    -- non-archived depth-1). Team scope is enforced by the user.thread
    -- visibility firewall on thread.team_id, not by where the thread is filed.
    SELECT p.id INTO v_matched
    FROM public.priority p
    WHERE p.user_id = p_user_id
      AND nlevel(p.path) = 1
      AND p.archived_at IS NULL
    ORDER BY p.created_at ASC
    LIMIT 1;

    IF v_matched IS NOT NULL THEN
        RETURN QUERY SELECT v_matched,
                            'root_fallback'::text,
                            '{}'::jsonb;
        RETURN;
    END IF;

    RETURN QUERY SELECT NULL::uuid,
                        'none'::text,
                        '{}'::jsonb;
    RETURN;
END;
$$;
