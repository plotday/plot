-- Classify a thread into a priority for a specific user by scoring it against
-- the user's explicitly-moved threads (thread_priority.user_moved = TRUE).
--
-- Two entry points live in this file:
--   * classify_thread_for_user_explain — the canonical implementation. Returns
--     (priority_id, stage, scores) so callers that need attribution (eval
--     framework, tooling) can see which stage matched and the scoring detail.
--   * classify_thread_for_user — thin SQL wrapper that selects just the
--     priority_id. All existing call sites (triggers, API, twist tools) use
--     this entry point; their behavior is unchanged.
--
-- Algorithm (executed in order; first match wins):
--   1. Load the thread's current signals (topic, embedding, contacts, groups,
--      created_by) from the thread row when p_thread_id is provided. Non-NULL
--      explicit parameters override what was loaded.
--   2. Topic short-circuit: if the candidate thread has a topic AND any of
--      the user's moved threads share that topic, the user has already
--      answered "threads with this topic belong here." Return the most-used
--      priority among those same-topic moves (mode; ties broken by most
--      recent). Topic match alone is a strong enough signal — we don't need
--      to also require contact/group/embedding overlap. This is the path
--      that carries siblings from a connector channel into the same priority
--      after one explicit user move.
--   2.3. Cross-user keyed priority match. If another user has filed this
--      thread under a priority that has a `key` (Using Plot is `@plot.app`,
--      Twist Development is `@plot.twist-dev`), prefer the recipient's
--      same-keyed priority. This makes "filed in Using Plot" propagate to
--      every recipient's Using Plot without requiring a topic convention,
--      and works for any current or future keyed priority. The recipient's
--      own user_moved short-circuit (step 2) ran first, so explicit moves
--      always win.
--   2.5. Channel default: if topic is of the form 'channel:<pk>' and the
--      channel has a non-archived default_priority_id, return it. Defaults
--      are LLM-assigned (per the channel router) and are always overridden
--      by a user_moved example (step 2 runs first). The caller is
--      responsible for stamping thread_priority.applied_default_channel_id
--      when this branch is taken.
--   3. When no user_moved example shares the topic, score every moved thread:
--        sem = cosine similarity, thresholded at 0.5, scaled to [0,1], squared
--        con = Jaccard on expanded contacts (linked-alias-aware), squared
--        grp = Jaccard on groups, squared
--        combined = 0.5*sem + 0.35*con + 0.15*grp
--      Each per-signal score is squared so weak signals contribute near-zero.
--      Return the highest-scoring priority when its combined score >= 0.15.
--   4. If neither path matched and thread.topic starts with
--      'priority:{KEY}[:...]', resolve that priority by (user_id, key). This
--      gives a caller-specified default (onboarding threads, twist logs)
--      that the user's own moves always override via the topic short-circuit.
--   5. Final fallback: return the user's root priority (oldest non-archived
--      depth-1). Focuses are team-agnostic — any focus can hold a thread of
--      any team — so classification no longer restricts candidates by team.
--      Team scope lives on thread.team_id and is enforced by the user.thread
--      visibility firewall, not by filing.
--
-- All signals are read live — nothing is frozen. Linking a new email alias
-- or updating a thread's contacts immediately shifts future classifications.
--
-- Stage values returned by classify_thread_for_user_explain:
--   topic_shortcircuit, keyed_priority, channel_default, scoring,
--   priority_prefix, root_fallback, none.

CREATE OR REPLACE FUNCTION public.classify_thread_for_user_explain (
    p_user_id uuid,
    p_thread_id uuid DEFAULT NULL,
    p_embedding halfvec DEFAULT NULL,
    p_topic text DEFAULT NULL,
    p_contacts uuid[] DEFAULT NULL,
    p_groups uuid[] DEFAULT NULL
)
    RETURNS TABLE (priority_id uuid, stage text, scores jsonb)
    LANGUAGE plpgsql
    STABLE
    AS $function$
DECLARE
    v_embedding halfvec;
    v_topic text;
    v_contacts uuid[];
    v_groups uuid[];
    v_matched uuid;
    v_scores jsonb;
    v_channel_pk bigint;
    v_priority_key text;
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
$function$;

COMMENT ON FUNCTION public.classify_thread_for_user_explain IS 'Verbose classifier returning (priority_id, stage, scores). Same algorithm as classify_thread_for_user; the stage column attributes the match to one of: topic_shortcircuit, keyed_priority, channel_default, scoring, priority_prefix, root_fallback, none. Focuses are team-agnostic, so classification does not restrict candidates by team — team scope is enforced by the user.thread visibility firewall on thread.team_id.';

-- Thin wrapper used by all existing call sites. Identical signature and
-- return type to the pre-refactor function.
CREATE OR REPLACE FUNCTION public.classify_thread_for_user (
    p_user_id uuid,
    p_thread_id uuid DEFAULT NULL,
    p_embedding halfvec DEFAULT NULL,
    p_topic text DEFAULT NULL,
    p_contacts uuid[] DEFAULT NULL,
    p_groups uuid[] DEFAULT NULL
)
    RETURNS uuid
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT priority_id
    FROM public.classify_thread_for_user_explain(
        p_user_id,
        p_thread_id,
        p_embedding,
        p_topic,
        p_contacts,
        p_groups
    );
$function$;

COMMENT ON FUNCTION public.classify_thread_for_user IS 'Classify a thread into a priority. Thin wrapper around classify_thread_for_user_explain. Order: (1) topic short-circuit on user_moved siblings, (2) cross-user keyed priority match (file under recipient''s same-keyed priority when another user already filed there), (3) channel.default_priority_id when topic is ''channel:<pk>'', (4) semantic/contact/group scoring against user_moved examples, (5) priority:{KEY} prefix, (6) root priority fallback. Focuses are team-agnostic; team scope is enforced by the user.thread visibility firewall on thread.team_id.';
