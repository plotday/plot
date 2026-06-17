-- Modify "classify_thread_for_user_explain" function
CREATE OR REPLACE FUNCTION "public"."classify_thread_for_user_explain" ("p_user_id" uuid, "p_thread_id" uuid DEFAULT NULL::uuid, "p_embedding" public.halfvec DEFAULT NULL::public.halfvec, "p_topic" text DEFAULT NULL::text, "p_contacts" uuid[] DEFAULT NULL::uuid[], "p_groups" uuid[] DEFAULT NULL::uuid[]) RETURNS TABLE ("priority_id" uuid, "stage" text, "scores" jsonb) LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_embedding halfvec;
    v_topic text;
    v_contacts uuid[];
    v_groups uuid[];
    v_facets jsonb;
    v_author_id uuid;
    v_created_by uuid;
    v_twist_id bigint;
    v_conn_id uuid;       -- candidate's originating connection (twist_instance) or NULL
    v_org_key text;       -- candidate connection's coarse org-group key or NULL
    v_matched uuid;
    v_scores jsonb;
    v_channel_pk bigint;
    v_priority_key text;
BEGIN
    -- 1. Load the thread's signals when an id was supplied.
    IF p_thread_id IS NOT NULL THEN
        SELECT t.embedding, t.topic, t.contacts, t.groups, t.facets, t.author_id,
               t.created_by, t.twist_id
        INTO v_embedding, v_topic, v_contacts, v_groups, v_facets, v_author_id,
             v_created_by, v_twist_id
        FROM public.thread t
        WHERE t.id = p_thread_id;
    END IF;

    v_embedding := COALESCE(p_embedding, v_embedding);
    v_topic     := COALESCE(p_topic, v_topic);
    v_contacts  := COALESCE(p_contacts, v_contacts, ARRAY[]::uuid[]);
    v_groups    := COALESCE(p_groups, v_groups, ARRAY[]::uuid[]);

    -- Origin signal: a connector thread (twist_id IS NOT NULL) was created by a
    -- connection; created_by is that twist_instance. User-authored threads have
    -- no origin signal. Resolve the candidate's coarse org-group key once.
    v_conn_id := CASE WHEN v_twist_id IS NOT NULL THEN v_created_by ELSE NULL END;
    v_org_key := public.connection_org_key(v_conn_id);

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
    --    Adds an origin term: a user_moved example from the SAME connection
    --    (exact, L1) or the same org group (L2) boosts the focus that has
    --    already seen this mailbox/account. origin rides inside the combined
    --    score — it does not bypass the facet gate or the structural stages.
    WITH moved AS (
        SELECT tp.priority_id,
               tp.thread_id,
               mt.embedding,
               mt.contacts,
               mt.groups,
               CASE WHEN mt.twist_id IS NOT NULL THEN mt.created_by END AS conn_id
        FROM public.thread_priority tp
        JOIN public.thread mt ON mt.id = tp.thread_id
        WHERE tp.user_id = p_user_id
          AND tp.user_moved = TRUE
          AND mt.archived_at IS NULL
    ),
    -- Batched contact expansion. public.expand_contacts is a STABLE function
    -- with a UNION (so Postgres can't inline it); calling it per moved row —
    -- twice, for the con INTERSECT and UNION below — meant 2N non-inlinable
    -- invocations per classify call (~3s for a 1.6k training set), and the
    -- per-candidate callers (reclassify_user_threads, apply_channel_default)
    -- multiply that across thousands of candidates, blowing statement_timeout.
    -- Instead resolve the linked-alias edges for the whole moved-thread contact
    -- set ONCE (alias_edge), then expand each thread's contacts with cheap set
    -- arithmetic (moved_exp). Identical result to expand_contacts(contacts):
    -- raw contacts ∪ every linked alias of any user owning one of them, deduped.
    -- MATERIALIZED on these three is load-bearing (same reasoning as the
    -- candidate/conn_key fences and reclassify_user_threads): without it the
    -- planner inlines alias_edge into the per-row moved_exp subquery and
    -- re-runs the user_contact joins once per moved row, erasing the batching.
    moved_contacts AS MATERIALIZED (
        SELECT DISTINCT c AS contact_id
        FROM moved m, unnest(m.contacts) AS c
    ),
    alias_edge AS MATERIALIZED (
        SELECT uc1.contact_id AS input, uc2.contact_id AS alias
        FROM public.user_contact uc1
        JOIN public.user_contact uc2
            ON uc2.user_id = uc1.user_id
           AND uc2.linked = TRUE
           AND uc2.archived_at IS NULL
        WHERE uc1.contact_id IN (SELECT contact_id FROM moved_contacts)
          AND uc1.linked = TRUE
          AND uc1.archived_at IS NULL
    ),
    moved_exp AS MATERIALIZED (
        SELECT m.priority_id,
               m.thread_id,
               m.embedding,
               m.contacts,
               m.groups,
               m.conn_id,
               (
                   SELECT COALESCE(array_agg(DISTINCT x), ARRAY[]::uuid[])
                   FROM (
                       SELECT unnest(m.contacts) AS x
                       UNION
                       SELECT ae.alias FROM alias_edge ae WHERE ae.input = ANY (m.contacts)
                   ) e
               ) AS exp_contacts
        FROM moved m
    ),
    -- Resolve each distinct example connection to its org key once (avoids a
    -- per-pair function call in the cross join below).
    conn_key AS (
        SELECT m.conn_id, public.connection_org_key(m.conn_id) AS org_key
        FROM (SELECT DISTINCT conn_id FROM moved WHERE conn_id IS NOT NULL) m
    ),
    -- MATERIALIZED so the candidate's single expand_contacts(v_contacts) is
    -- computed once, not re-evaluated per moved row inside the con INTERSECT/
    -- UNION below (that per-row re-eval dominated once the moved side was
    -- batched).
    candidate AS MATERIALIZED (
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
                WHEN v_conn_id IS NOT NULL AND f.conn_id = v_conn_id THEN 0.18
                WHEN v_org_key IS NOT NULL AND ck.org_key = v_org_key THEN 0.09
                ELSE 0
            END AS origin,
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
                        SELECT unnest(f.exp_contacts)
                        INTERSECT
                        SELECT unnest(c.exp_contacts)
                    ))::numeric
                    / NULLIF(cardinality(ARRAY(
                        SELECT unnest(f.exp_contacts)
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
        FROM moved_exp f
        CROSS JOIN candidate c
        LEFT JOIN neg ng ON ng.priority_id = f.priority_id
        LEFT JOIN conn_key ck ON ck.conn_id = f.conn_id
    )
    SELECT jsonb_build_object(
        'top', COALESCE(jsonb_agg(
            jsonb_build_object(
                'priority_id', top_scored.pid,
                'thread_id', top_scored.tid,
                'sem', round(top_scored.sem::numeric, 4),
                'con', round(top_scored.con::numeric, 4),
                'grp', round(top_scored.grp::numeric, 4),
                'origin', round(top_scored.origin::numeric, 4),
                'combined', round((0.5 * top_scored.sem + 0.30 * top_scored.con + 0.12 * top_scored.grp + top_scored.origin - 0.3 * top_scored.neg_sim)::numeric, 4)
            )
            ORDER BY (0.5 * top_scored.sem + 0.30 * top_scored.con + 0.12 * top_scored.grp + top_scored.origin - 0.3 * top_scored.neg_sim) DESC
        ), '[]'::jsonb)
    )
    INTO v_scores
    FROM (
        SELECT scored.priority_id AS pid,
               scored.thread_id AS tid,
               scored.sem,
               scored.con,
               scored.grp,
               scored.origin,
               scored.neg_sim
        FROM scored
        ORDER BY (0.5 * scored.sem + 0.30 * scored.con + 0.12 * scored.grp + scored.origin - 0.3 * scored.neg_sim) DESC
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
