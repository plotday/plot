-- Modify "file_thread_priority_peers" function
CREATE OR REPLACE FUNCTION "public"."file_thread_priority_peers" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
    v_peer_priority_id uuid;
    v_author_user_id uuid;
    v_old_contacts uuid[];
BEGIN
    IF NEW.contacts IS NULL OR cardinality(NEW.contacts) = 0 THEN
        RETURN NEW;
    END IF;

    -- Compute old contacts for delta (empty on INSERT)
    IF TG_OP = 'UPDATE' THEN
        v_old_contacts := COALESCE(OLD.contacts, ARRAY[]::uuid[]);
    ELSE
        v_old_contacts := ARRAY[]::uuid[];
    END IF;

    -- Exclude the author (user_id or twist_instance owner) from peer filing
    -- so we don't double-insert against the author trigger.
    IF EXISTS (SELECT 1 FROM "public"."user" WHERE id = NEW.created_by) THEN
        v_author_user_id := NEW.created_by;
    ELSE
        SELECT pt.owner_id INTO v_author_user_id
        FROM public.twist_instance pt
        WHERE pt.id = NEW.created_by;
    END IF;

    -- thread_priority for ALL contacts (idempotent via ON CONFLICT DO NOTHING)
    FOR r IN
        SELECT DISTINCT uc.user_id AS peer_user_id
        FROM unnest(NEW.contacts) AS arr(contact_id)
        JOIN public.user_contact uc
          ON uc.contact_id = arr.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM v_author_user_id
    LOOP
        v_peer_priority_id := public.match_priority_for_user(r.peer_user_id);
        IF v_peer_priority_id IS NOT NULL THEN
            INSERT INTO thread_priority (thread_id, user_id, priority_id, matched)
            VALUES (NEW.id, r.peer_user_id, v_peer_priority_id, TRUE)
            ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;
        END IF;
    END LOOP;

    -- thread_unread for NEWLY ADDED contacts only, so shared threads
    -- appear as unread for peers. Uses ON CONFLICT DO NOTHING to avoid
    -- overwriting existing read state.
    FOR r IN
        SELECT DISTINCT uc.user_id AS peer_user_id
        FROM unnest(NEW.contacts) AS arr(contact_id)
        JOIN public.user_contact uc
          ON uc.contact_id = arr.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM v_author_user_id
          AND arr.contact_id != ALL(v_old_contacts)
    LOOP
        INSERT INTO thread_unread (user_id, thread_id, urgency, importance)
        VALUES (r.peer_user_id, NEW.id, 'inform-updates', 50)
        ON CONFLICT (user_id, thread_id) DO NOTHING;
    END LOOP;

    RETURN NEW;
END;
$$;
-- Modify "refile_threads_like" function
CREATE OR REPLACE FUNCTION "public"."refile_threads_like" ("p_user_id" uuid, "p_anchor_thread_id" uuid, "p_target_priority_id" uuid, "p_similarity_threshold" double precision DEFAULT 1.0, "p_max_moves" integer DEFAULT 20) RETURNS TABLE ("thread_id" uuid, "old_priority_id" uuid) LANGUAGE plpgsql AS $$
DECLARE
    v_batch_id uuid := gen_random_uuid();
    -- Anchor thread fields
    v_anchor_topics uuid[];
    v_anchor_contacts uuid[];
    v_anchor_created_by uuid;
    -- Anchor link fields (from the best link)
    v_anchor_channel_id text;
    v_anchor_link_type text;
    v_anchor_embedding halfvec;
    v_anchor_match jsonb;
BEGIN
    -- 1. Load anchor thread data
    SELECT t.topics, t.contacts, t.created_by
    INTO v_anchor_topics, v_anchor_contacts, v_anchor_created_by
    FROM public.thread t
    WHERE t.id = p_anchor_thread_id
      AND t.archived_at IS NULL;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    -- 2. Load anchor link data (prefer link with match config, else newest)
    SELECT l.channel_id, l.type, l.embedding, l.match
    INTO v_anchor_channel_id, v_anchor_link_type, v_anchor_embedding, v_anchor_match
    FROM public.link l
    WHERE l.thread_id = p_anchor_thread_id
    ORDER BY
        (l.match IS NOT NULL) DESC,
        l.created_at DESC
    LIMIT 1;

    -- 3. Score candidates and move the best ones
    RETURN QUERY
    WITH candidates AS (
        SELECT
            tp.thread_id,
            tp.priority_id AS current_priority_id,
            t.topics AS c_topics,
            t.contacts AS c_contacts,
            t.created_by AS c_created_by
        FROM public.thread_priority tp
        JOIN public.thread t ON t.id = tp.thread_id
        WHERE tp.user_id = p_user_id
          AND tp.matched = TRUE
          AND tp.priority_id IS DISTINCT FROM p_target_priority_id
          AND tp.thread_id IS DISTINCT FROM p_anchor_thread_id
          AND t.archived_at IS NULL
          AND t.draft = FALSE
    ),
    -- Score link-based signals per candidate
    link_scores AS (
        SELECT
            c.thread_id,
            -- Shared channel: 0.5 per matching channel
            COALESCE(MAX(CASE WHEN v_anchor_channel_id IS NOT NULL
                AND l.channel_id = v_anchor_channel_id THEN 0.5 ELSE 0 END), 0)
                AS channel_score,
            -- Shared link type: 0.3 per matching type
            COALESCE(MAX(CASE WHEN v_anchor_link_type IS NOT NULL
                AND l.type = v_anchor_link_type THEN 0.3 ELSE 0 END), 0)
                AS type_score,
            -- Content embedding similarity (when anchor has embedding + match config)
            COALESCE(MAX(CASE
                WHEN v_anchor_embedding IS NOT NULL
                    AND l.embedding IS NOT NULL
                    AND v_anchor_match IS NOT NULL
                    AND (v_anchor_match ? 'content')
                THEN (1 - (l.embedding <=> v_anchor_embedding)) *
                    CASE
                        WHEN jsonb_typeof(v_anchor_match -> 'content') = 'number'
                        THEN (v_anchor_match ->> 'content')::double precision / 100.0
                        ELSE 1.0
                    END
                ELSE 0
            END), 0) AS content_score,
            -- Meta field matches from anchor's match config
            COALESCE(MAX((
                SELECT COALESCE(SUM(
                    CASE WHEN l.meta IS NOT NULL
                        AND l.meta ->> substring(key FROM 6)
                            IS NOT DISTINCT FROM
                            (SELECT al.meta ->> substring(key FROM 6)
                             FROM public.link al
                             WHERE al.thread_id = p_anchor_thread_id
                               AND al.meta IS NOT NULL
                             LIMIT 1)
                    THEN CASE
                        WHEN jsonb_typeof(v_anchor_match -> key) = 'number'
                        THEN (v_anchor_match ->> key)::double precision / 100.0
                        ELSE 0.5
                    END
                    ELSE 0
                    END
                ), 0)
                FROM jsonb_object_keys(COALESCE(v_anchor_match, '{}'::jsonb)) AS key
                WHERE key LIKE 'meta.%'
            )), 0) AS meta_score
        FROM candidates c
        LEFT JOIN public.link l ON l.thread_id = c.thread_id
        GROUP BY c.thread_id
    ),
    -- Score thread-level signals per candidate
    thread_scores AS (
        SELECT
            c.thread_id,
            -- Shared topics: 0.4 each
            COALESCE((SELECT count(*) FROM unnest(c.c_topics) x WHERE x = ANY(v_anchor_topics)), 0) * 0.4
                AS topic_score,
            -- Shared contacts: 0.2 each
            COALESCE((SELECT count(*) FROM unnest(c.c_contacts) x WHERE x = ANY(v_anchor_contacts)), 0) * 0.2
                AS contact_score,
            -- Same creator: 0.2
            CASE WHEN c.c_created_by = v_anchor_created_by THEN 0.2 ELSE 0 END
                AS creator_score
        FROM candidates c
    ),
    scored AS (
        SELECT
            c.thread_id,
            c.current_priority_id,
            COALESCE(ls.channel_score, 0)
                + COALESCE(ls.type_score, 0)
                + COALESCE(ls.content_score, 0)
                + COALESCE(ls.meta_score, 0)
                + ts.topic_score
                + ts.contact_score
                + ts.creator_score
                AS total_score
        FROM candidates c
        JOIN thread_scores ts ON ts.thread_id = c.thread_id
        LEFT JOIN link_scores ls ON ls.thread_id = c.thread_id
        WHERE COALESCE(ls.channel_score, 0)
            + COALESCE(ls.type_score, 0)
            + COALESCE(ls.content_score, 0)
            + COALESCE(ls.meta_score, 0)
            + ts.topic_score
            + ts.contact_score
            + ts.creator_score >= p_similarity_threshold
        ORDER BY total_score DESC
        LIMIT p_max_moves
    ),
    moved AS (
        UPDATE public.thread_priority tp
        SET priority_id = p_target_priority_id,
            refile_batch_id = v_batch_id,
            previous_priority_id = tp.priority_id
        FROM scored s
        WHERE tp.thread_id = s.thread_id
          AND tp.user_id = p_user_id
        RETURNING tp.thread_id, s.current_priority_id AS old_priority_id
    )
    SELECT moved.thread_id, moved.old_priority_id
    FROM moved;
END;
$$;
-- Modify "undo_refile_batch" function
CREATE OR REPLACE FUNCTION "public"."undo_refile_batch" ("p_user_id" uuid, "p_thread_id" uuid, "p_old_priority_id" uuid, "p_similarity_threshold" double precision DEFAULT 1.0) RETURNS TABLE ("thread_id" uuid, "restored_priority_id" uuid) LANGUAGE plpgsql AS $$
DECLARE
    v_batch_id uuid;
BEGIN
    -- 1. Look up the batch this thread belonged to
    SELECT tp.refile_batch_id INTO v_batch_id
    FROM public.thread_priority tp
    WHERE tp.thread_id = p_thread_id
      AND tp.user_id = p_user_id;

    IF v_batch_id IS NULL THEN
        RETURN;
    END IF;

    -- Clear the batch from the moved-away thread itself
    UPDATE public.thread_priority
    SET refile_batch_id = NULL,
        previous_priority_id = NULL
    WHERE thread_priority.thread_id = p_thread_id
      AND thread_priority.user_id = p_user_id;

    -- 2. Find siblings still in the old priority from the same batch
    -- 3. For each sibling, check if any explicitly-filed thread in the
    --    priority still justifies its placement via shared signals
    RETURN QUERY
    WITH siblings AS (
        SELECT tp.thread_id, tp.previous_priority_id
        FROM public.thread_priority tp
        JOIN public.thread t ON t.id = tp.thread_id
        WHERE tp.refile_batch_id = v_batch_id
          AND tp.user_id = p_user_id
          AND tp.priority_id = p_old_priority_id
          AND tp.matched = TRUE
          AND tp.previous_priority_id IS NOT NULL
          AND t.archived_at IS NULL
    ),
    -- Explicitly-filed threads remaining in the priority (the anchors)
    anchors AS (
        SELECT t.id AS thread_id, t.topics, t.contacts, t.created_by
        FROM public.thread_priority tp
        JOIN public.thread t ON t.id = tp.thread_id
        WHERE tp.user_id = p_user_id
          AND tp.priority_id = p_old_priority_id
          AND tp.matched = FALSE
          AND t.archived_at IS NULL
    ),
    -- Score each sibling against the best anchor
    sibling_scores AS (
        SELECT
            s.thread_id,
            s.previous_priority_id,
            COALESCE(MAX(
                -- Thread-level signals
                COALESCE((SELECT count(*) FROM unnest(st.topics) x WHERE x = ANY(a.topics)), 0) * 0.4
                + COALESCE((SELECT count(*) FROM unnest(st.contacts) x WHERE x = ANY(a.contacts)), 0) * 0.2
                + CASE WHEN st.created_by = a.created_by THEN 0.2 ELSE 0 END
                -- Link-level: shared channel
                + COALESCE((
                    SELECT MAX(CASE WHEN sl.channel_id IS NOT NULL
                        AND al.channel_id = sl.channel_id THEN 0.5 ELSE 0 END)
                    FROM public.link sl
                    CROSS JOIN public.link al
                    WHERE sl.thread_id = s.thread_id
                      AND al.thread_id = a.thread_id
                ), 0)
                -- Link-level: shared type
                + COALESCE((
                    SELECT MAX(CASE WHEN sl.type IS NOT NULL
                        AND al.type = sl.type THEN 0.3 ELSE 0 END)
                    FROM public.link sl
                    CROSS JOIN public.link al
                    WHERE sl.thread_id = s.thread_id
                      AND al.thread_id = a.thread_id
                ), 0)
            ), 0) AS best_anchor_score
        FROM siblings s
        JOIN public.thread st ON st.id = s.thread_id
        LEFT JOIN anchors a ON TRUE
        GROUP BY s.thread_id, s.previous_priority_id
    ),
    -- Siblings below threshold get moved back
    to_restore AS (
        SELECT ss.thread_id, ss.previous_priority_id
        FROM sibling_scores ss
        WHERE ss.best_anchor_score < p_similarity_threshold
    ),
    restored AS (
        UPDATE public.thread_priority tp
        SET priority_id = tr.previous_priority_id,
            refile_batch_id = NULL,
            previous_priority_id = NULL
        FROM to_restore tr
        WHERE tp.thread_id = tr.thread_id
          AND tp.user_id = p_user_id
        RETURNING tp.thread_id, tr.previous_priority_id AS restored_priority_id
    )
    SELECT restored.thread_id, restored.restored_priority_id
    FROM restored;
END;
$$;
