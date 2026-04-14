-- Create "refile_threads_like" function
CREATE FUNCTION "public"."refile_threads_like" ("p_user_id" uuid, "p_anchor_thread_id" uuid, "p_target_priority_id" uuid, "p_similarity_threshold" double precision DEFAULT 1.0, "p_max_moves" integer DEFAULT 20) RETURNS TABLE ("thread_id" uuid, "old_priority_id" uuid) LANGUAGE plpgsql AS $$
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
            COALESCE(cardinality(c.c_topics & v_anchor_topics), 0) * 0.4
                AS topic_score,
            -- Shared contacts: 0.2 each
            COALESCE(cardinality(c.c_contacts & v_anchor_contacts), 0) * 0.2
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
-- Set comment to function: "refile_threads_like"
COMMENT ON FUNCTION "public"."refile_threads_like" IS 'Re-file auto-matched threads to follow an explicitly moved anchor thread. Uses link-based signals (channel, content, meta) and thread-level signals (topics, contacts, creator). Only moves matched=true rows, capped at p_max_moves.';
-- Create "undo_refile_batch" function
CREATE FUNCTION "public"."undo_refile_batch" ("p_user_id" uuid, "p_thread_id" uuid, "p_old_priority_id" uuid, "p_similarity_threshold" double precision DEFAULT 1.0) RETURNS TABLE ("thread_id" uuid, "restored_priority_id" uuid) LANGUAGE plpgsql AS $$
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
    WHERE thread_id = p_thread_id
      AND user_id = p_user_id;

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
                COALESCE(cardinality(st.topics & a.topics), 0) * 0.4
                + COALESCE(cardinality(st.contacts & a.contacts), 0) * 0.2
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
-- Set comment to function: "undo_refile_batch"
COMMENT ON FUNCTION "public"."undo_refile_batch" IS 'Undo a re-filing batch when the user corrects a thread placement. Siblings that no longer match any explicit anchor in the priority are moved back to their previous priority.';
-- Modify "upsert_thread" function
CREATE OR REPLACE FUNCTION "user"."upsert_thread" ("user_id" uuid, "p_thread" jsonb, "p_defaults" jsonb DEFAULT '{}') RETURNS "public"."thread" LANGUAGE plpgsql AS $$
DECLARE
    v_result thread;
    v_existing thread;
    v_id uuid;
    -- Variables for derived values
    v_priority_id uuid;
    v_created_by uuid;
    -- Archived status check
    v_is_archived boolean;
BEGIN
    -- Extract required fields from JSONB, with fallback to p_defaults for INSERT
    v_id := COALESCE((p_thread ->> 'id')::uuid, (p_defaults ->> 'id')::uuid);
    v_priority_id := COALESCE((p_thread ->> 'priority_id')::uuid, (p_defaults ->> 'priority_id')::uuid);
    v_created_by := COALESCE((p_thread ->> 'created_by')::uuid, (p_defaults ->> 'created_by')::uuid, user_id);
    -- Generate id if not provided
    -- If key is provided and no id was given, look up existing thread by key + creator
    IF v_id IS NULL THEN
        IF (p_thread ? 'key') AND v_created_by IS NOT NULL THEN
            SELECT id INTO v_id
            FROM thread
            WHERE key = (p_thread ->> 'key')
              AND created_by = v_created_by;
        END IF;
        IF v_id IS NULL THEN
            v_id := uuidv7 ();
        END IF;
    END IF;
    -- Resolve priority_id from existing thread_priority row for this user
    IF v_priority_id IS NULL THEN
        SELECT
            tp.priority_id INTO v_priority_id
        FROM
            thread_priority tp
        WHERE
            tp.thread_id = v_id
            AND tp.user_id = upsert_thread.user_id;
    END IF;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'priority_id must be provided';
    END IF;
    -- Validate access: user must own the target priority
    IF NOT user_has_priority_access(upsert_thread.user_id, v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;
    -- Validate created_by when it differs from user_id
    IF v_created_by IS DISTINCT FROM user_id THEN
        IF NOT EXISTS (
            SELECT
                1
            FROM
                twist_instance pt
            WHERE
                pt.id = v_created_by
                AND pt.owner_id = upsert_thread.user_id) THEN
            RAISE EXCEPTION 'created_by must be user or owned twist_instance';
        END IF;
    END IF;
    -- Fetch the existing thread row (if any) so partial updates can fall
    -- back to current values. Postgres evaluates CHECK constraints on the
    -- INSERT values before ON CONFLICT DO UPDATE kicks in, so the VALUES
    -- clause below must already satisfy the constraints — which means the
    -- INSERT must carry the existing row's values for any field the caller
    -- omitted.
    SELECT * INTO v_existing FROM thread WHERE id = v_id;

    v_is_archived := COALESCE(
        v_existing.archived_at IS NOT NULL
        OR (v_existing.id IS NOT NULL AND NOT EXISTS (
            SELECT 1
            FROM thread_priority tp
            WHERE tp.thread_id = v_existing.id
              AND tp.user_id = upsert_thread.user_id
              AND EXISTS (
                  SELECT 1 FROM priority p
                  WHERE p.id = tp.priority_id
                    AND p.archived_at IS NULL
              )
        )),
        FALSE
    );
    -- Perform the upsert and return the full row.
    -- INSERT values fall through p_thread → p_defaults → v_existing so
    -- that on the UPDATE path the INSERT satisfies CHECK constraints even
    -- when the caller omits fields like title.
    INSERT INTO thread (id, created_by, title, preview, updated_by, sync_depth, contacts, topics, draft, key, icon)
        VALUES (
            v_id,
            v_created_by,
            COALESCE(p_thread ->> 'title', p_defaults ->> 'title', v_existing.title),
            COALESCE(p_thread ->> 'preview', p_defaults ->> 'preview', v_existing.preview),
            COALESCE((p_thread ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, v_existing.updated_by, 0),
            COALESCE((p_thread ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint, v_existing.sync_depth),
            CASE
                WHEN p_thread ? 'contacts' AND jsonb_typeof(p_thread -> 'contacts') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'contacts') elem), ARRAY[]::uuid[])
                WHEN p_defaults ? 'contacts' AND jsonb_typeof(p_defaults -> 'contacts') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'contacts') elem), ARRAY[]::uuid[])
                ELSE COALESCE(v_existing.contacts, ARRAY[]::uuid[])
            END,
            CASE
                WHEN p_thread ? 'topics' AND jsonb_typeof(p_thread -> 'topics') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'topics') elem), ARRAY[]::uuid[])
                WHEN p_defaults ? 'topics' AND jsonb_typeof(p_defaults -> 'topics') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'topics') elem), ARRAY[]::uuid[])
                ELSE COALESCE(v_existing.topics, ARRAY[]::uuid[])
            END,
            COALESCE((p_thread ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, v_existing.draft, FALSE),
            COALESCE(p_thread ->> 'key', p_defaults ->> 'key', v_existing.key),
            COALESCE(p_thread ->> 'icon', p_defaults ->> 'icon', v_existing.icon)
        )
    ON CONFLICT (id)
        DO UPDATE SET
            -- Update fields only if key is present in p_thread
            -- Key absent: keep existing value (unless archived, then use p_defaults)
            -- Key present (even with null): use provided value (allows clearing)
            -- If archived: treat as INSERT and apply p_defaults
            title = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'title', p_defaults ->> 'title', thread.title)
            ELSE
                CASE WHEN p_thread ? 'title' THEN
                    p_thread ->> 'title'
                ELSE
                    thread.title
                END
            END,
            preview = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'preview', p_defaults ->> 'preview', thread.preview)
            ELSE
                CASE WHEN p_thread ? 'preview' THEN
                    p_thread ->> 'preview'
                ELSE
                    thread.preview
                END
            END,
            updated_by = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, thread.updated_by)
            ELSE
                CASE WHEN p_thread ? 'updated_by' THEN
                    (p_thread ->> 'updated_by')::integer
                ELSE
                    thread.updated_by
                END
            END,
            sync_depth = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint, thread.sync_depth)
            ELSE
                CASE WHEN p_thread ? 'sync_depth' THEN
                    (p_thread ->> 'sync_depth')::smallint
                ELSE
                    thread.sync_depth
                END
            END,
            contacts = CASE WHEN v_is_archived THEN
                CASE WHEN p_thread ? 'contacts' AND jsonb_typeof(p_thread -> 'contacts') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'contacts') elem), ARRAY[]::uuid[])
                WHEN p_defaults ? 'contacts' AND jsonb_typeof(p_defaults -> 'contacts') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'contacts') elem), ARRAY[]::uuid[])
                ELSE thread.contacts END
            ELSE
                CASE WHEN p_thread ? 'contacts' AND jsonb_typeof(p_thread -> 'contacts') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'contacts') elem), ARRAY[]::uuid[])
                ELSE
                    thread.contacts
                END
            END,
            topics = CASE WHEN v_is_archived THEN
                CASE WHEN p_thread ? 'topics' AND jsonb_typeof(p_thread -> 'topics') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'topics') elem), ARRAY[]::uuid[])
                WHEN p_defaults ? 'topics' AND jsonb_typeof(p_defaults -> 'topics') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'topics') elem), ARRAY[]::uuid[])
                ELSE thread.topics END
            ELSE
                CASE WHEN p_thread ? 'topics' AND jsonb_typeof(p_thread -> 'topics') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'topics') elem), ARRAY[]::uuid[])
                ELSE
                    thread.topics
                END
            END,
            draft = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, thread.draft)
            ELSE
                CASE WHEN p_thread ? 'draft' THEN
                    (p_thread ->> 'draft')::boolean
                ELSE
                    thread.draft
                END
            END,
            icon = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'icon', p_defaults ->> 'icon', thread.icon)
            ELSE
                CASE WHEN p_thread ? 'icon' THEN
                    p_thread ->> 'icon'
                ELSE
                    thread.icon
                END
            END,
            archived_at = CASE WHEN v_is_archived THEN
                CASE WHEN p_thread ? 'archived_at' THEN
                    (p_thread ->> 'archived_at')::timestamptz
                WHEN p_defaults ? 'archived_at' THEN
                    (p_defaults ->> 'archived_at')::timestamptz
                ELSE
                    thread.archived_at
                END
            ELSE
                CASE WHEN p_thread ? 'archived_at' THEN
                    (p_thread ->> 'archived_at')::timestamptz
                ELSE
                    thread.archived_at
                END
            END,
            created_by = v_created_by
        RETURNING
            * INTO v_result;

    -- Upsert the calling user's thread_priority row. On update, only
    -- change priority_id if the caller explicitly provided one.
    INSERT INTO thread_priority (thread_id, user_id, priority_id, matched)
    VALUES (v_result.id, upsert_thread.user_id, v_priority_id, FALSE)
    ON CONFLICT ON CONSTRAINT thread_priority_pkey
    DO UPDATE SET
        priority_id = CASE
            WHEN p_thread ? 'priority_id' THEN EXCLUDED.priority_id
            WHEN v_is_archived THEN EXCLUDED.priority_id
            ELSE thread_priority.priority_id
        END,
        -- Mark as explicitly filed when user provides priority_id
        matched = CASE
            WHEN p_thread ? 'priority_id' THEN FALSE
            ELSE thread_priority.matched
        END,
        updated_at = now();

    -- Peer thread_priority rows are populated by the file_thread_priority_peers
    -- trigger on thread, so both upsert_thread callers and raw inserts from
    -- the twist runtime share the same filing behaviour.

    RETURN v_result;
END;
$$;
-- Modify "thread_priority" table
ALTER TABLE "public"."thread_priority" ADD COLUMN "refile_batch_id" uuid NULL, ADD COLUMN "previous_priority_id" uuid NULL, ADD CONSTRAINT "thread_priority_previous_priority_id_fkey" FOREIGN KEY ("previous_priority_id") REFERENCES "public"."priority" ("id") ON UPDATE NO ACTION ON DELETE SET NULL;
-- Create index "idx_thread_priority_refile_batch" to table: "thread_priority"
CREATE INDEX "idx_thread_priority_refile_batch" ON "public"."thread_priority" ("refile_batch_id") WHERE (refile_batch_id IS NOT NULL);
-- Set comment to column: "refile_batch_id" on table: "thread_priority"
COMMENT ON COLUMN "public"."thread_priority"."refile_batch_id" IS 'Groups threads moved by a single re-filing operation. Used to undo batch moves when the user corrects one.';
-- Set comment to column: "previous_priority_id" on table: "thread_priority"
COMMENT ON COLUMN "public"."thread_priority"."previous_priority_id" IS 'Priority the thread was filed under before the last re-filing operation. Used to restore threads when a batch is undone.';
