-- Create "find_matching_threads_scored" function
CREATE FUNCTION "public"."find_matching_threads_scored" ("query_embedding" text, "created_by_id" uuid DEFAULT NULL::uuid, "required_filters" jsonb DEFAULT '{}', "scored_fields" jsonb DEFAULT '{}', "thread_data" jsonb DEFAULT '{}', "similarity_threshold" double precision DEFAULT 0.7, "p_user_id" uuid DEFAULT NULL::uuid) RETURNS TABLE ("id" uuid, "priority_id" uuid, "title" text, "total_score" double precision) LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY WITH filtered_links AS (
        -- First filter by required exact matches on link fields
        SELECT
            l.id AS link_id,
            l.thread_id,
            COALESCE(tp.priority_id, t.priority_id) AS priority_id,
            COALESCE(l.title, t.title) AS title,
            l.type,
            l.meta,
            l.embedding
        FROM
            public.link l
            JOIN public.thread t ON t.id = l.thread_id
            -- When scoping to a specific user, require a thread_priority row.
            -- The LEFT JOIN + filter (rather than INNER) keeps the optimiser
            -- happy when p_user_id is NULL.
            LEFT JOIN public.thread_priority tp
                ON tp.thread_id = t.id
                AND (p_user_id IS NULL OR tp.user_id = p_user_id)
        WHERE
            t.archived_at IS NULL
            AND (created_by_id IS NULL OR l.created_by = created_by_id)
            AND (p_user_id IS NULL OR tp.user_id IS NOT NULL)
            -- Content similarity filter (when content is required)
            -- Skip if query_embedding is null/empty (embedding generation failed)
            AND ((required_filters ? 'content'
                    AND query_embedding IS NOT NULL
                    AND query_embedding <> ''
                    AND query_embedding <> '[]'
                    AND l.embedding IS NOT NULL
                    AND (1 - (l.embedding <=> query_embedding::vector)) >= similarity_threshold)
                OR NOT (required_filters ? 'content'))
            -- Type exact match (when type is required)
            AND ((required_filters ? 'type'
                    AND l.type = (thread_data ->> 'type'))
                OR NOT (required_filters ? 'type'))
            -- Meta field exact matches (when meta.field is required)
            AND (
                -- Check all required meta fields match
                NOT EXISTS (
                    SELECT
                        1
                    FROM
                        jsonb_object_keys(required_filters) AS key
                    WHERE
                        key LIKE 'meta.%'
                        AND (l.meta IS NULL
                            OR l.meta ->> substring(key FROM 6) IS DISTINCT FROM thread_data -> 'meta' ->> substring(key FROM 6))))
),
scored_links AS (
    -- Calculate scores for each matching link
    SELECT
        fl.thread_id AS id,
        fl.priority_id,
        fl.title,
        -- Sum up all scores
        (
            -- Content similarity score (skip if query_embedding is null/empty)
            COALESCE(
                CASE WHEN scored_fields ? 'content'
                    AND fl.embedding IS NOT NULL
                    AND query_embedding IS NOT NULL
                    AND query_embedding <> ''
                    AND query_embedding <> '[]' THEN
                    (scored_fields ->> 'content')::float * (1 - (fl.embedding <=> query_embedding::vector))
                ELSE
                    0
                END, 0) +
            -- Type exact match score
            COALESCE(
                CASE WHEN scored_fields ? 'type' THEN
                    CASE WHEN fl.type = (thread_data ->> 'type') THEN
                        (scored_fields ->> 'type')::float
                    ELSE
                        0
                    END
                ELSE
                    0
                END, 0) +
            -- Meta field exact match scores
            COALESCE((
                SELECT
                    COALESCE(SUM(
                            CASE WHEN fl.meta IS NOT NULL
                                AND fl.meta ->> substring(key FROM 6) IS NOT DISTINCT FROM thread_data -> 'meta' ->> substring(key FROM 6) THEN
                                (scored_fields ->> key)::float
                            ELSE
                                0
                            END), 0)
                FROM jsonb_object_keys(scored_fields) AS key
                WHERE
                    key LIKE 'meta.%'), 0)) AS total_score
FROM
    filtered_links fl
)
SELECT
    sl.id,
    sl.priority_id,
    sl.title,
    sl.total_score
FROM
    scored_links sl
WHERE
    sl.total_score > 0
ORDER BY
    sl.total_score DESC
LIMIT 1;
END;
$$;
-- Create "match_priority_for_user" function
CREATE FUNCTION "public"."match_priority_for_user" ("p_user_id" uuid, "query_embedding" text DEFAULT NULL::text, "p_thread_data" jsonb DEFAULT '{}', "p_required_filters" jsonb DEFAULT '{}', "p_scored_fields" jsonb DEFAULT '{}', "p_similarity_threshold" double precision DEFAULT 0.7) RETURNS uuid LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_matched_priority_id uuid;
    v_root_priority_id uuid;
BEGIN
    -- 1. Try matching against the user's own filed threads.
    SELECT m.priority_id INTO v_matched_priority_id
    FROM public.find_matching_threads_scored(
        query_embedding,
        NULL,
        p_required_filters,
        p_scored_fields,
        p_thread_data,
        p_similarity_threshold,
        p_user_id
    ) m;

    IF v_matched_priority_id IS NOT NULL THEN
        RETURN v_matched_priority_id;
    END IF;

    -- 2. Fall back to the user's personal root priority.
    SELECT pu.priority_id INTO v_root_priority_id
    FROM public.priority_user pu
    WHERE pu.user_id = p_user_id
      AND pu.personal = TRUE
      AND pu.archived_at IS NULL
    LIMIT 1;

    RETURN v_root_priority_id;
END;
$$;
-- Modify "upsert_thread" function
CREATE OR REPLACE FUNCTION "user"."upsert_thread" ("user_id" uuid, "p_thread" jsonb, "p_defaults" jsonb DEFAULT '{}') RETURNS "public"."thread" LANGUAGE plpgsql AS $$
DECLARE
    v_result thread;
    v_id uuid;
    -- Variables for derived values
    v_priority_id uuid;
    v_created_by uuid;
    v_role text;
    -- Archived status check
    v_is_archived boolean;
BEGIN
    -- Extract required fields from JSONB, with fallback to p_defaults for INSERT
    v_id := COALESCE((p_thread ->> 'id')::uuid, (p_defaults ->> 'id')::uuid);
    v_priority_id := COALESCE((p_thread ->> 'priority_id')::uuid, (p_defaults ->> 'priority_id')::uuid);
    v_created_by := COALESCE((p_thread ->> 'created_by')::uuid, (p_defaults ->> 'created_by')::uuid, user_id);
    -- Generate id if not provided
    -- If key is provided and no id was given, look up existing thread by key + priority
    IF v_id IS NULL THEN
        IF (p_thread ? 'key') AND v_priority_id IS NOT NULL THEN
            SELECT id INTO v_id
            FROM thread
            WHERE key = (p_thread ->> 'key')
              AND priority_id = v_priority_id;
        END IF;
        IF v_id IS NULL THEN
            v_id := uuidv7 ();
        END IF;
    END IF;
    -- Resolve priority_id from existing thread if missing
    IF v_priority_id IS NULL THEN
        SELECT
            priority_id INTO v_priority_id
        FROM
            thread
        WHERE
            id = v_id;
    END IF;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'priority_id must be provided';
    END IF;
    -- Validate access and role in a single query
    SELECT
        CASE WHEN bool_or(pu.role = 'member') THEN 'member' ELSE COALESCE(MAX(pu.role), NULL) END
    INTO v_role
    FROM
        priority_user pu
        JOIN priority pp ON pu.priority_id = pp.id
        JOIN priority p ON p.path <@ pp.path
    WHERE
        pu.user_id = upsert_thread.user_id
        AND pu.archived_at IS NULL
        AND p.id = v_priority_id;
    IF v_role IS NULL THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;
    IF v_role = 'viewer' THEN
        IF NOT EXISTS (SELECT 1 FROM thread WHERE id = v_id) THEN
            -- New thread: viewers cannot create public threads
            IF COALESCE(p_thread ->> 'access', p_defaults ->> 'access', 'members') = 'public' THEN
                RAISE EXCEPTION 'Viewer members can only create private threads';
            END IF;
        ELSE
            -- Existing thread: viewers can only modify their own non-public threads
            IF NOT EXISTS (
                SELECT 1 FROM thread
                WHERE id = v_id AND access != 'public' AND created_by = user_id
            ) THEN
                RAISE EXCEPTION 'Viewer members cannot modify threads they did not create';
            END IF;
        END IF;
    END IF;
    -- Validate created_by when it differs from user_id
    IF v_created_by IS DISTINCT FROM user_id THEN
        IF NOT EXISTS (
            SELECT
                1
            FROM
                priority_twist pt
            WHERE
                pt.id = v_created_by
                AND pt.owner_id = upsert_thread.user_id) THEN
            RAISE EXCEPTION 'created_by must be user or owned priority_twist';
        END IF;
    END IF;
    -- Check if existing thread is archived (either directly or via priority)
    -- Only relevant for UPDATE path; INSERT path will have NULL and be coalesced to false
    SELECT
        (thread.archived_at IS NOT NULL
            OR NOT EXISTS (
                SELECT
                    1
                FROM
                    "user".priority_expanded upe
                WHERE
                    upe.priority_id = thread.priority_id
                    AND upe.user_id = upsert_thread.user_id
                    AND upe.archived_at IS NULL)) INTO v_is_archived
    FROM
        thread
    WHERE
        id = v_id;
    -- If no existing thread, v_is_archived will be NULL (INSERT path)
    v_is_archived := COALESCE(v_is_archived, FALSE);
    -- Perform the upsert and return the full row
    -- On INSERT: Use COALESCE to fall back to p_defaults for fields not in p_thread
    INSERT INTO thread (id, created_by, priority_id, title, preview, updated_by, sync_depth, access, access_contacts, draft, key, icon)
        VALUES (v_id, v_created_by, v_priority_id, COALESCE(p_thread ->> 'title', p_defaults ->> 'title'), COALESCE(p_thread ->> 'preview', p_defaults ->> 'preview'), COALESCE((p_thread ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, 0), COALESCE((p_thread ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint), COALESCE(p_thread ->> 'access', p_defaults ->> 'access', 'members'), CASE WHEN p_thread ? 'access_contacts' AND jsonb_typeof(p_thread -> 'access_contacts') = 'array' THEN COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'access_contacts') elem), ARRAY[]::uuid[]) WHEN p_defaults ? 'access_contacts' AND jsonb_typeof(p_defaults -> 'access_contacts') = 'array' THEN COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'access_contacts') elem), ARRAY[]::uuid[]) ELSE NULL END, COALESCE((p_thread ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, FALSE), COALESCE(p_thread ->> 'key', p_defaults ->> 'key'), COALESCE(p_thread ->> 'icon', p_defaults ->> 'icon'))
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
            priority_id = CASE WHEN v_is_archived THEN
                v_priority_id
            ELSE
                CASE WHEN p_thread ? 'priority_id' THEN
                    (p_thread ->> 'priority_id')::uuid
                ELSE
                    thread.priority_id
                END
            END,
            access = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'access', p_defaults ->> 'access', thread.access)
            ELSE
                CASE WHEN p_thread ? 'access' THEN
                    p_thread ->> 'access'
                ELSE
                    thread.access
                END
            END,
            access_contacts = CASE WHEN v_is_archived THEN
                CASE WHEN p_thread ? 'access_contacts' AND jsonb_typeof(p_thread -> 'access_contacts') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'access_contacts') elem), ARRAY[]::uuid[])
                WHEN p_thread ? 'access_contacts' THEN
                    NULL
                WHEN p_defaults ? 'access_contacts' AND jsonb_typeof(p_defaults -> 'access_contacts') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'access_contacts') elem), ARRAY[]::uuid[])
                WHEN p_defaults ? 'access_contacts' THEN
                    NULL
                ELSE thread.access_contacts END
            ELSE
                CASE WHEN p_thread ? 'access_contacts' AND jsonb_typeof(p_thread -> 'access_contacts') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'access_contacts') elem), ARRAY[]::uuid[])
                WHEN p_thread ? 'access_contacts' THEN
                    NULL
                ELSE
                    thread.access_contacts
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

    -- File thread_priority rows for every linked user appearing in the
    -- thread's final contacts array (other than the author, who is handled
    -- by the populate_thread_priority_for_author trigger). Uses
    -- match_priority_for_user to pick each peer's filing priority, which
    -- for now falls back to their personal root.
    INSERT INTO thread_priority (thread_id, user_id, priority_id, matched)
    SELECT
        v_result.id,
        uc.user_id,
        public.match_priority_for_user(uc.user_id),
        TRUE
    FROM unnest(v_result.contacts) AS arr(contact_id)
    JOIN public.user_contact uc
      ON uc.contact_id = arr.contact_id
     AND uc.linked = TRUE
     AND uc.archived_at IS NULL
    WHERE uc.user_id IS DISTINCT FROM v_result.created_by
      AND public.match_priority_for_user(uc.user_id) IS NOT NULL
    ON CONFLICT (thread_id, user_id) DO NOTHING;

    RETURN v_result;
END;
$$;
-- Drop "find_matching_threads_scored" function
DROP FUNCTION "public"."find_matching_threads_scored" (text, uuid, jsonb, jsonb, jsonb, double precision);
