-- Modify "thread_priority" table
ALTER TABLE "public"."thread_priority" ADD COLUMN "user_moved" boolean NOT NULL DEFAULT false;
-- Create index "idx_thread_priority_user_moved" to table: "thread_priority"
CREATE INDEX "idx_thread_priority_user_moved" ON "public"."thread_priority" ("user_id") WHERE (user_moved = true);
-- Modify "activate_invited_user" function
CREATE OR REPLACE FUNCTION "public"."activate_invited_user" ("p_user_id" uuid) RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_root_priority_id uuid;
    v_new_path ltree;
BEGIN
    -- Already has a root priority?
    SELECT id INTO v_root_priority_id
    FROM public.priority
    WHERE user_id = p_user_id
      AND nlevel(path) = 1
    ORDER BY created_at ASC
    LIMIT 1;

    IF v_root_priority_id IS NOT NULL THEN
        RETURN jsonb_build_object('activated', FALSE, 'already_active', TRUE, 'root_priority_id', v_root_priority_id);
    END IF;

    -- Create the root priority. default_priority_user_id fills user_id
    -- from created_by, so the new row is fully owned by the user.
    v_new_path := generate_path(NULL);
    INSERT INTO public.priority (created_by, user_id, title, path, color)
        VALUES (p_user_id, p_user_id, 'Everything', v_new_path, 0)
    RETURNING id INTO v_root_priority_id;

    -- Create Using Plot (@plot.app)
    INSERT INTO public.priority (created_by, user_id, title, path, color, key, default_thread_icon)
    VALUES (p_user_id, p_user_id, 'Using Plot', v_new_path || generate_path(NULL), 7, '@plot.app', 'https://plot.day/assets/plot-icon.svg');

    -- Create Twist Development (@plot.twist-dev)
    INSERT INTO public.priority (created_by, user_id, title, path, color, key)
    VALUES (p_user_id, p_user_id, 'Twist Development', v_new_path || generate_path(NULL), 3, '@plot.twist-dev');

    -- Onboarding routing is now learned from user moves (thread_priority.user_moved).
    -- New users start with no training examples; incoming threads land in the
    -- root priority until the user moves one into "Using Plot" or "Twist
    -- Development". classify_thread_for_user then picks those priorities up
    -- automatically for similar future threads.

    RETURN jsonb_build_object('activated', TRUE, 'already_active', FALSE, 'root_priority_id', v_root_priority_id);
END;
$$;
-- Create "expand_contacts" function
CREATE FUNCTION "public"."expand_contacts" ("p_contacts" uuid[]) RETURNS uuid[] LANGUAGE sql STABLE PARALLEL SAFE AS $$
SELECT COALESCE(array_agg(DISTINCT c), ARRAY[]::uuid[])
    FROM (
        SELECT unnest(p_contacts) AS c
        UNION
        SELECT uc2.contact_id
        FROM unnest(p_contacts) raw
        JOIN public.user_contact uc1
            ON uc1.contact_id = raw
           AND uc1.linked = TRUE
           AND uc1.archived_at IS NULL
        JOIN public.user_contact uc2
            ON uc2.user_id = uc1.user_id
           AND uc2.linked = TRUE
           AND uc2.archived_at IS NULL
    ) u;
$$;
-- Set comment to function: "expand_contacts"
COMMENT ON FUNCTION "public"."expand_contacts" IS 'Expand a contact array to include every linked alias of any user that owns one of the input contacts.';
-- Create "classify_thread_for_user" function
CREATE FUNCTION "public"."classify_thread_for_user" ("p_user_id" uuid, "p_thread_id" uuid DEFAULT NULL::uuid, "p_embedding" public.halfvec DEFAULT NULL::public.halfvec, "p_topic" text DEFAULT NULL::text, "p_contacts" uuid[] DEFAULT NULL::uuid[], "p_groups" uuid[] DEFAULT NULL::uuid[]) RETURNS uuid LANGUAGE plpgsql STABLE AS $$
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
COMMENT ON FUNCTION "public"."classify_thread_for_user" (uuid, uuid, public.halfvec, text, uuid[], uuid[]) IS 'Classify a thread into a priority by scoring it against the user''s explicitly-moved threads (thread_priority.user_moved = TRUE). Topic acts as a candidate filter; contact overlap, group overlap, and semantic similarity are combined with weights 0.35/0.15/0.5 after non-linear shaping. Falls back to the user''s root priority.';
-- Modify "match_priority_for_user" function
CREATE OR REPLACE FUNCTION "public"."match_priority_for_user" ("p_user_id" uuid, "query_embedding" text DEFAULT NULL::text, "p_thread_data" jsonb DEFAULT '{}', "p_required_filters" jsonb DEFAULT '{}', "p_scored_fields" jsonb DEFAULT '{}', "p_similarity_threshold" double precision DEFAULT 0.7) RETURNS uuid LANGUAGE plpgsql AS $$
BEGIN
    -- Legacy parameters are ignored; classification scores against
    -- thread_priority.user_moved = TRUE training examples.
    RETURN public.classify_thread_for_user(p_user_id);
END;
$$;
-- Create "reclassify_user_threads" function
CREATE FUNCTION "public"."reclassify_user_threads" ("p_user_id" uuid, "p_anchor_thread_id" uuid, "p_max_candidates" integer DEFAULT 500) RETURNS integer LANGUAGE plpgsql AS $$
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
$$;
-- Set comment to function: "reclassify_user_threads"
COMMENT ON FUNCTION "public"."reclassify_user_threads" IS 'After an explicit user move (anchor thread), retroactively re-file other threads that now classify differently. Uses indexed candidate prefilter (topic, HNSW, GIN), runs classify_thread_for_user per candidate, and moves those whose new classification differs — never touching rows where user_moved = TRUE.';
-- Drop "priority_rule" table
DROP TABLE "public"."priority_rule";
-- Drop "apply_priority_rule" function
DROP FUNCTION "public"."apply_priority_rule";
-- Drop "classify_thread_for_user" function
DROP FUNCTION "public"."classify_thread_for_user" (uuid, uuid, public.halfvec, text);
