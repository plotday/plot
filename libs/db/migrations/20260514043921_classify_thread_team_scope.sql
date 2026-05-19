-- Modify "classify_thread_for_user" function
CREATE OR REPLACE FUNCTION "public"."classify_thread_for_user" ("p_user_id" uuid, "p_thread_id" uuid DEFAULT NULL::uuid, "p_embedding" public.halfvec DEFAULT NULL::public.halfvec, "p_topic" text DEFAULT NULL::text, "p_contacts" uuid[] DEFAULT NULL::uuid[], "p_groups" uuid[] DEFAULT NULL::uuid[]) RETURNS uuid LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_embedding halfvec;
    v_topic text;
    v_contacts uuid[];
    v_groups uuid[];
    v_matched uuid;
    v_thread_created_by uuid;
    v_creator_team_id bigint;
BEGIN
    -- 1. Load thread signals when an id was supplied.
    IF p_thread_id IS NOT NULL THEN
        SELECT t.embedding, t.topic, t.contacts, t.groups, t.created_by
        INTO v_embedding, v_topic, v_contacts, v_groups, v_thread_created_by
        FROM public.thread t
        WHERE t.id = p_thread_id;
    END IF;

    -- Derive the originating twist_instance team scope. Non-NULL means the
    -- thread was authored by a team-owned connector and must file under a
    -- priority with the matching team_id. NULL means user-authored or
    -- personal-connector — no restriction.
    SELECT ti.team_id INTO v_creator_team_id
    FROM public.twist_instance ti
    WHERE ti.id = v_thread_created_by;

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
        JOIN public.priority p ON p.id = tp.priority_id
        WHERE tp.user_id = p_user_id
          AND tp.user_moved = TRUE
          AND mt.archived_at IS NULL
          AND mt.topic = v_topic
          AND (
              v_creator_team_id IS NULL
              OR p.team_id = v_creator_team_id
          )
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
          AND (
              v_creator_team_id IS NULL
              OR p.team_id = v_creator_team_id
          )
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
                  AND p.archived_at IS NULL
                  AND (
                      v_creator_team_id IS NULL
                      OR p.team_id = v_creator_team_id
                  );
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
        JOIN public.priority p ON p.id = tp.priority_id
        WHERE tp.user_id = p_user_id
          AND tp.user_moved = TRUE
          AND mt.archived_at IS NULL
          AND (
              v_creator_team_id IS NULL
              OR p.team_id = v_creator_team_id
          )
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
                  AND (
                      v_creator_team_id IS NULL
                      OR p.team_id = v_creator_team_id
                  )
                LIMIT 1;
                IF v_matched IS NOT NULL THEN
                    RETURN v_matched;
                END IF;
            END IF;
        END;
    END IF;

    -- Fallback: team-connector threads return the user's first non-archived
    -- nlevel=2 priority with matching team_id, or NULL if none exists.
    -- Personal threads fall back to the user's oldest non-archived root priority.
    IF v_creator_team_id IS NOT NULL THEN
        SELECT p.id INTO v_matched
        FROM public.priority p
        WHERE p.user_id = p_user_id
          AND p.team_id = v_creator_team_id
          AND nlevel(p.path) = 2
          AND p.archived_at IS NULL
        ORDER BY p.created_at ASC
        LIMIT 1;
        RETURN v_matched; -- may be NULL
    END IF;

    -- Personal fallback: oldest non-archived depth-1 priority (root).
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
COMMENT ON FUNCTION "public"."classify_thread_for_user" IS 'Classify a thread into a priority. Order: (1) topic short-circuit on user_moved siblings, (2) cross-user keyed priority match (file under recipient''s same-keyed priority when another user already filed there), (3) channel.default_priority_id when topic is ''channel:<pk>'', (4) semantic/contact/group scoring against user_moved examples, (5) priority:{KEY} prefix, (6) root priority fallback. When the originating twist_instance has team_id set, candidates are restricted to priorities with matching team_id; if no match exists for the user, returns NULL (no filing).';
