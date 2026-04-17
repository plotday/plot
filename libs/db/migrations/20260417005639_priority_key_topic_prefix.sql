-- Set comment to column: "topic" on table: "thread"
COMMENT ON COLUMN "public"."thread"."topic" IS 'Routing key used by classify_thread_for_user. Two conventions: (1) priority:{KEY}[:{SUB_TOPIC}] defaults the thread into the user''s priority with that key when no user_moved example wins; (2) any other string acts as the topic filter over user_moved training examples. On INSERT defaults to, in order: explicit input, or groups[1]::text when unset.';
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

    -- 2 + 3 + 4. Score all moved threads in a single SQL pass.
    WITH moved AS (
        -- Every thread this user has explicitly moved. Read CURRENT signals
        -- from the thread row so relinking aliases / group edits take effect
        -- without a rule rewrite.
        SELECT tp.priority_id,
               mt.topic,
               mt.embedding,
               mt.contacts,
               mt.groups
        FROM public.thread_priority tp
        JOIN public.thread mt ON mt.id = tp.thread_id
        WHERE tp.user_id = p_user_id
          AND tp.user_moved = TRUE
          AND mt.archived_at IS NULL
    ),
    -- Topic filter: restrict to same-topic moves when applicable.
    has_topic_moves AS (
        SELECT EXISTS (
            SELECT 1 FROM moved
            WHERE v_topic IS NOT NULL AND topic = v_topic
        ) AS yes
    ),
    filtered AS (
        SELECT m.*
        FROM moved m, has_topic_moves h
        WHERE NOT h.yes OR m.topic = v_topic
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
        FROM filtered f
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
COMMENT ON FUNCTION "public"."classify_thread_for_user" IS 'Classify a thread into a priority by scoring it against the user''s explicitly-moved threads (thread_priority.user_moved = TRUE). Topic acts as a candidate filter; contact overlap, group overlap, and semantic similarity are combined with weights 0.35/0.15/0.5 after non-linear shaping. When no move scores above the floor and thread.topic matches priority:{KEY}[:...], resolves the user''s priority with that key; otherwise falls back to the user''s root priority.';

-- Backfill onboarding threads to the new priority:{KEY}:{SUB_TOPIC} convention
-- so they route to the user's "Using Plot" priority (@plot.app). Safe to
-- re-run: the guard skips threads that already carry the prefix.
UPDATE public.thread
SET topic = 'priority:@plot.app:' || key
WHERE key IN ('welcome', 'priorities', 'connections', 'getting-around',
              'twists', 'notifications', 'clean-up')
  AND (topic IS NULL OR topic NOT LIKE 'priority:@plot.app:%');
