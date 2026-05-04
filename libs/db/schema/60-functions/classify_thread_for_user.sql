-- Classify a thread into a priority for a specific user by scoring it against
-- the user's explicitly-moved threads (thread_priority.user_moved = TRUE).
--
-- Algorithm:
--   1. Load the thread's current signals (topic, embedding, contacts, groups)
--      from the thread row when p_thread_id is provided. Non-NULL explicit
--      parameters override what was loaded.
--   2. Topic short-circuit: if the candidate thread has a topic AND any of
--      the user's moved threads share that topic, the user has already
--      answered "threads with this topic belong here." Return the most-used
--      priority among those same-topic moves (mode; ties broken by most
--      recent). Topic match alone is a strong enough signal — we don't need
--      to also require contact/group/embedding overlap. This is the path
--      that carries siblings from a connector channel into the same priority
--      after one explicit user move.
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
--   5. Final fallback: the user's root priority (oldest non-archived depth-1).
--
-- All signals are read live — nothing is frozen. Linking a new email alias
-- or updating a thread's contacts immediately shifts future classifications.
CREATE OR REPLACE FUNCTION public.classify_thread_for_user (
    p_user_id uuid,
    p_thread_id uuid DEFAULT NULL,
    p_embedding halfvec DEFAULT NULL,
    p_topic text DEFAULT NULL,
    p_contacts uuid[] DEFAULT NULL,
    p_groups uuid[] DEFAULT NULL
)
    RETURNS uuid
    LANGUAGE plpgsql
    STABLE
    AS $function$
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

    -- 2.3. Cross-user keyed priority match. If another user has filed this
    --      thread under a priority that has a `key` (Using Plot is `@plot.app`,
    --      Twist Development is `@plot.twist-dev`), prefer the recipient's
    --      same-keyed priority. This makes "filed in Using Plot" propagate to
    --      every recipient's Using Plot without requiring a topic convention,
    --      and works for any current or future keyed priority. The recipient's
    --      own user_moved short-circuit (step 2) ran first, so explicit moves
    --      always win.
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
            RETURN v_matched;
        END IF;
    END IF;

    -- 2.5. Channel default. When the thread topic is of the form
    --      'channel:<pk>' and the channel has a non-archived
    --      default_priority_id, return it. This is the LLM-assigned default
    --      that kicks in before scoring. Step 2 (user_moved topic match)
    --      ran first, so a user move will always trump the default.
    IF v_topic LIKE 'channel:%' THEN
        DECLARE
            v_channel_pk bigint;
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
                    RETURN v_matched;
                END IF;
            END IF;
        EXCEPTION WHEN invalid_text_representation THEN
            -- Topic looked like 'channel:...' but the suffix wasn't numeric.
            -- Fall through to scoring.
            NULL;
        END;
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
$function$;

COMMENT ON FUNCTION public.classify_thread_for_user IS 'Classify a thread into a priority. Order: (1) topic short-circuit on user_moved siblings, (2) cross-user keyed priority match (file under recipient''s same-keyed priority when another user already filed there), (3) channel.default_priority_id when topic is ''channel:<pk>'', (4) semantic/contact/group scoring against user_moved examples, (5) priority:{KEY} prefix, (6) root priority fallback.';
