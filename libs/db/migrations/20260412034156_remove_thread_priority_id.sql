-- Drop "populate_thread_priority_for_author" trigger
DROP TRIGGER "populate_thread_priority_for_author" ON "public"."thread";
-- Drop "sync_thread_contacts" trigger
DROP TRIGGER "sync_thread_contacts" ON "public"."thread";
-- Drop "thread_x" view
DROP VIEW "public"."thread_x";
-- Drop "twist_instance_thread_update" view
DROP VIEW "public"."twist_instance_thread_update";
-- Drop "note_tags" view
DROP VIEW "user"."note_tags";
-- Drop "thread_tags" view
DROP VIEW "user"."thread_tags";
-- Drop "thread" view
DROP VIEW "user"."thread";
-- Modify "thread" table
-- thread.access_contacts data was migrated to thread.contacts in 20260411031028
-- (including the author's primary contact); the column is now safe to drop.
ALTER TABLE "public"."thread" DROP CONSTRAINT "thread_access_valid", DROP COLUMN "priority_id" CASCADE, DROP COLUMN "access" CASCADE, DROP COLUMN "access_contacts" CASCADE;
-- Create index "idx_thread_created_at" to table: "thread"
CREATE INDEX "idx_thread_created_at" ON "public"."thread" ("created_at" DESC) WHERE (archived_at IS NULL);
-- Set comment to column: "key" on table: "thread"
COMMENT ON COLUMN "public"."thread"."key" IS 'Internal identifier for deduplication within a creator. Used with created_by for upsert behavior. Not synced to clients.';
-- Modify "archive_links" function
CREATE OR REPLACE FUNCTION "public"."archive_links" ("p_created_by" uuid, "p_filter" jsonb DEFAULT '{}') RETURNS uuid[] LANGUAGE plpgsql AS $$
DECLARE
    v_affected_priority_ids uuid[];
    v_now timestamptz := now();
BEGIN
    -- 1. Find matching link IDs and their thread IDs
    WITH matched_links AS (
        SELECT
            l.id AS link_id,
            l.thread_id
        FROM
            public.link l
        WHERE
            l.created_by = p_created_by
            AND l.thread_id IS NOT NULL
            -- Only match links on non-archived threads
            AND EXISTS (
                SELECT 1 FROM public.thread t
                WHERE t.id = l.thread_id AND t.archived_at IS NULL
            )
            -- channel_id filter
            AND (NOT (p_filter ? 'channelId')
                OR l.channel_id = (p_filter ->> 'channelId'))
            -- type filter
            AND (NOT (p_filter ? 'type')
                OR l.type = (p_filter ->> 'type'))
            -- status filter
            AND (NOT (p_filter ? 'status')
                OR l.status = (p_filter ->> 'status'))
            -- meta containment filter
            AND (NOT (p_filter ? 'meta')
                OR l.meta @> (p_filter -> 'meta'))
    ),
    -- 2. Find threads that should be archived:
    --    threads where ALL their links are in the matched set (no other active links)
    threads_to_archive AS (
        SELECT DISTINCT ml.thread_id
        FROM matched_links ml
        WHERE NOT EXISTS (
            -- Check for any link on this thread that is NOT in the matched set
            SELECT 1
            FROM public.link other_l
            WHERE other_l.thread_id = ml.thread_id
                AND other_l.id NOT IN (SELECT link_id FROM matched_links)
        )
    ),
    -- 3. Archive the threads and collect their IDs
    archived_threads AS (
        UPDATE public.thread t
        SET archived_at = v_now
        FROM threads_to_archive ta
        WHERE t.id = ta.thread_id
        RETURNING t.id
    )
    -- 4. Collect affected priority IDs from thread_priority
    SELECT ARRAY(
        SELECT DISTINCT tp.priority_id
        FROM archived_threads at
        JOIN thread_priority tp ON tp.thread_id = at.id
    )
    INTO v_affected_priority_ids;

    RETURN COALESCE(v_affected_priority_ids, ARRAY[]::uuid[]);
END;
$$;
-- Modify "ensure_link_assignee_priority_contact" function
CREATE OR REPLACE FUNCTION "public"."ensure_link_assignee_priority_contact" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_priority_id uuid;
BEGIN
    IF NEW.assignee_id IS NULL THEN
        RETURN NULL;
    END IF;
    -- Get the priority_id via thread_priority (for the link creator's owner)
    -- or via the link's own priority_id
    IF NEW.thread_id IS NOT NULL THEN
        SELECT tp.priority_id INTO v_priority_id
        FROM thread_priority tp
        WHERE tp.thread_id = NEW.thread_id
          AND tp.user_id = COALESCE(
              (SELECT pt.owner_id FROM twist_instance pt WHERE pt.id = NEW.created_by),
              NEW.created_by
          );
    ELSE
        v_priority_id := NEW.priority_id;
    END IF;
    IF v_priority_id IS NULL THEN
        RETURN NULL;
    END IF;
    -- Only create priority_contact if assignee is a contact (not a twist_instance)
    IF EXISTS (
        SELECT
            1
        FROM
            contact
        WHERE
            id = NEW.assignee_id) THEN
    INSERT INTO priority_contact (priority_id, contact_id)
        VALUES (v_priority_id, NEW.assignee_id)
    ON CONFLICT (priority_id, contact_id)
        DO NOTHING;
    END IF;
    RETURN NULL;
END;
$$;
-- Modify "find_matching_threads_scored" function
CREATE OR REPLACE FUNCTION "public"."find_matching_threads_scored" ("query_embedding" text, "created_by_id" uuid DEFAULT NULL::uuid, "required_filters" jsonb DEFAULT '{}', "scored_fields" jsonb DEFAULT '{}', "thread_data" jsonb DEFAULT '{}', "similarity_threshold" double precision DEFAULT 0.7, "p_user_id" uuid DEFAULT NULL::uuid) RETURNS TABLE ("id" uuid, "priority_id" uuid, "title" text, "total_score" double precision) LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY WITH filtered_links AS (
        -- First filter by required exact matches on link fields
        SELECT
            l.id AS link_id,
            l.thread_id,
            tp.priority_id,
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
-- Modify "find_similar_threads" function
CREATE OR REPLACE FUNCTION "public"."find_similar_threads" ("query_embedding" text, "created_by_id" uuid, "similarity_threshold" double precision DEFAULT 0.5, "match_limit" integer DEFAULT 1) RETURNS TABLE ("id" uuid, "priority_id" uuid, "title" text, "similarity" double precision) LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    SELECT
        l.thread_id AS id,
        tp.priority_id,
        COALESCE(l.title, t.title) AS title,
        1 - (l.embedding <=> query_embedding::vector) AS similarity
    FROM
        public.link l
        JOIN public.thread t ON t.id = l.thread_id
        LEFT JOIN public.thread_priority tp ON tp.thread_id = t.id
            AND tp.user_id = COALESCE(
                (SELECT pt.owner_id FROM public.twist_instance pt WHERE pt.id = created_by_id),
                created_by_id
            )
    WHERE
        l.created_by = created_by_id
        AND l.embedding IS NOT NULL
        AND t.archived_at IS NULL
        AND (1 - (l.embedding <=> query_embedding::vector)) >= similarity_threshold
    ORDER BY
        l.embedding <=> query_embedding::vector
    LIMIT match_limit;
END;
$$;
-- Modify "search_notes_and_links" function
CREATE OR REPLACE FUNCTION "public"."search_notes_and_links" ("query_embedding" text, "scope_priority_id" uuid, "requesting_user_id" uuid, "exclude_created_by" uuid DEFAULT NULL::uuid, "similarity_threshold" double precision DEFAULT 0.3, "match_limit" integer DEFAULT 20) RETURNS TABLE ("result_type" text, "result_id" uuid, "thread_id" uuid, "thread_title" text, "priority_id" uuid, "priority_title" text, "content" text, "title" text, "source_url" text, "similarity" double precision) LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    SELECT * FROM (
        -- Notes
        SELECT 'note'::text, n.id, n.thread_id, t.title, tp.priority_id,
               p.title, n.content, NULL::text, NULL::text,
               (1 - (n.embedding <=> query_embedding::halfvec))::float AS similarity
        FROM note n
        JOIN thread t ON t.id = n.thread_id
        JOIN thread_priority tp ON tp.thread_id = t.id AND tp.user_id = requesting_user_id
        JOIN priority p ON p.id = tp.priority_id
        JOIN priority_child pc ON pc.priority_id = scope_priority_id
                              AND pc.child_id = tp.priority_id
        WHERE n.embedding IS NOT NULL
          AND n.archived_at IS NULL AND n.draft = FALSE
          AND t.archived_at IS NULL
          AND t.contacts && "user".user_contact_ids(requesting_user_id)
          AND (n.access_contacts IS NULL OR n.created_by = requesting_user_id
               OR n.access_contacts && "user".user_contact_ids(requesting_user_id))
          AND (exclude_created_by IS NULL OR n.created_by != exclude_created_by)
          AND (1 - (n.embedding <=> query_embedding::halfvec)) >= similarity_threshold

        UNION ALL

        -- Links
        SELECT 'link'::text, l.id, l.thread_id, t.title, tp.priority_id,
               p.title, l.preview, l.title, l.source_url,
               (1 - (l.embedding <=> query_embedding::halfvec))::float AS similarity
        FROM link l
        JOIN thread t ON t.id = l.thread_id
        JOIN thread_priority tp ON tp.thread_id = t.id AND tp.user_id = requesting_user_id
        JOIN priority p ON p.id = tp.priority_id
        JOIN priority_child pc ON pc.priority_id = scope_priority_id
                              AND pc.child_id = tp.priority_id
        WHERE l.embedding IS NOT NULL AND l.thread_id IS NOT NULL
          AND t.archived_at IS NULL
          AND t.contacts && "user".user_contact_ids(requesting_user_id)
          AND (1 - (l.embedding <=> query_embedding::halfvec)) >= similarity_threshold
    ) combined
    ORDER BY combined.similarity DESC
    LIMIT match_limit;
END;
$$;
-- Modify "set_link_source_priority_root" function
CREATE OR REPLACE FUNCTION "public"."set_link_source_priority_root" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    priority_path ltree;
BEGIN
    -- Only set source_priority_root when source is non-null
    IF NEW.source IS NOT NULL THEN
        -- Get the priority path via thread_priority (for the link creator's owner)
        -- or via the link's own priority_id
        SELECT
            p.path INTO priority_path
        FROM
            public.priority p
        WHERE
            p.id = COALESCE(
                (SELECT tp.priority_id
                 FROM public.thread_priority tp
                 WHERE tp.thread_id = NEW.thread_id
                   AND tp.user_id = COALESCE(
                       (SELECT pt.owner_id FROM public.twist_instance pt WHERE pt.id = NEW.created_by),
                       NEW.created_by
                   )
                ),
                NEW.priority_id
            );
        -- Extract the root element (first segment) of the priority path
        IF priority_path IS NOT NULL THEN
            NEW.source_priority_root := subpath (priority_path, 0, 1);
        END IF;
    ELSE
        -- Clear source_priority_root when source is null
        NEW.source_priority_root := NULL;
    END IF;
    RETURN NEW;
END;
$$;
-- Modify "sync_twist_for_thread" function
CREATE OR REPLACE FUNCTION "public"."sync_twist_for_thread" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_create_timestamp timestamptz;
    v_update_timestamp timestamptz;
    v_twist_instance_id uuid;
BEGIN
    -- Determine timestamps for create and update operations
    IF TG_OP = 'INSERT' THEN
        -- For inserts, all non-draft rows are creates
        SELECT
            MAX(created_at) INTO v_create_timestamp
        FROM
            new_table
        WHERE
            draft = FALSE;
    ELSE
        -- For UPDATE, check for "published" rows (draft true→false) vs regular updates
        -- "Published" rows: draft changed from TRUE to FALSE - treat as create
        SELECT
            MAX(n.updated_at) INTO v_create_timestamp
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
        WHERE
            o.draft = TRUE
            AND n.draft = FALSE;
        -- Regular updated rows: was already published (not draft) and still not draft
        -- Only consider rows where meaningful fields actually changed, to avoid
        -- unnecessary twist_instance_sync updates from no-op upserts (which cause
        -- SyncRecovery to re-trigger connectors in a feedback loop).
        SELECT
            MAX(n.updated_at) INTO v_update_timestamp
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
        WHERE
            o.draft = FALSE
            AND n.draft = FALSE
            AND (n.title IS DISTINCT FROM o.title
                OR n.preview IS DISTINCT FROM o.preview
                OR n.archived_at IS DISTINCT FROM o.archived_at
                OR n.draft IS DISTINCT FROM o.draft
                OR n.contacts IS DISTINCT FROM o.contacts
                OR n.icon IS DISTINCT FROM o.icon
                OR n.priority_id IS DISTINCT FROM o.priority_id
                OR n.updated_by IS DISTINCT FROM o.updated_by);
    END IF;
    -- Exit early if all changes were to draft threads (nothing to sync)
    IF v_create_timestamp IS NULL AND v_update_timestamp IS NULL THEN
        RETURN NULL;
    END IF;
    -- Process CREATE operations (new inserts or published drafts)
    -- Twists are workspace-level; match strictly by created_by.
    IF v_create_timestamp IS NOT NULL THEN
        IF TG_OP = 'INSERT' THEN
            FOR v_twist_instance_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN twist_instance pct ON pct.id = n.created_by
            WHERE
                n.draft = FALSE
                AND pct.archived_at IS NULL
            ORDER BY
                id LOOP
                    INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at)
                        VALUES (v_twist_instance_id, 'thread', 'create', v_create_timestamp)
                    ON CONFLICT (twist_instance_id, entity, operation)
                        DO UPDATE SET
                            last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at);
                END LOOP;
        ELSE
            -- UPDATE (publishing draft): reference old_table for draft true→false check
            FOR v_twist_instance_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN old_table o ON o.id = n.id
                JOIN twist_instance pct ON pct.id = n.created_by
            WHERE
                o.draft = TRUE
                AND n.draft = FALSE
                AND pct.archived_at IS NULL
            ORDER BY
                id LOOP
                    INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at)
                        VALUES (v_twist_instance_id, 'thread', 'create', v_create_timestamp)
                    ON CONFLICT (twist_instance_id, entity, operation)
                        DO UPDATE SET
                            last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at);
                END LOOP;
        END IF;
    END IF;
    -- Process UPDATE operations (regular updates to already-published threads)
    IF v_update_timestamp IS NOT NULL THEN
        FOR v_twist_instance_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN twist_instance pct ON pct.id = n.created_by
        WHERE
            n.draft = FALSE
            AND o.draft = FALSE
            AND pct.archived_at IS NULL
        ORDER BY
            id LOOP
                INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at)
                    VALUES (v_twist_instance_id, 'thread', 'update', v_update_timestamp)
                ON CONFLICT (twist_instance_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at);
            END LOOP;
    END IF;
    RETURN NULL;
END;
$$;
-- Modify "sync_user_for_link" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_link" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users who have the link's thread filed via thread_priority,
    -- or who own the link's direct priority (for threadless links)
    FOR v_user_id IN SELECT DISTINCT
        COALESCE(tp.user_id, p.user_id) AS user_id
    FROM
        new_table n
        LEFT JOIN thread_priority tp ON tp.thread_id = n.thread_id
        LEFT JOIN priority p ON p.id = n.priority_id AND n.thread_id IS NULL
    WHERE
        tp.user_id IS NOT NULL OR p.user_id IS NOT NULL
    ORDER BY
        1 LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'thread', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_user_for_note" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_note" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users who have the note's thread filed via thread_priority
    FOR v_user_id IN SELECT DISTINCT
        tp.user_id
    FROM
        new_table n
        JOIN thread_priority tp ON tp.thread_id = n.thread_id
    ORDER BY
        tp.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'note', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_user_for_note_tag" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_note_tag" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users who have the note's thread filed via thread_priority
    FOR v_user_id IN SELECT DISTINCT
        tp.user_id
    FROM
        new_table n
        JOIN note nt ON nt.id = n.note_id
        JOIN thread_priority tp ON tp.thread_id = nt.thread_id
    ORDER BY
        tp.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'note', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_user_for_schedule" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_schedule" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users who have the schedule's thread filed via thread_priority
    -- Handles both direct thread_id and link schedules (via link → thread)
    FOR v_user_id IN SELECT DISTINCT
        tp.user_id
    FROM
        new_table n
        LEFT JOIN link l ON l.id = n.link_id
        JOIN thread_priority tp ON tp.thread_id = COALESCE(n.thread_id, l.thread_id)
    ORDER BY
        tp.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'schedule', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    -- Also notify per-user schedule owners directly
    FOR v_user_id IN SELECT DISTINCT
        n.user_id
    FROM
        new_table n
    WHERE
        n.user_id IS NOT NULL
    ORDER BY
        n.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'schedule', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_user_for_thread" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_thread" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    -- Get max updated_at from the batch
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users who have this thread filed via thread_priority
    FOR v_user_id IN SELECT DISTINCT
        tp.user_id
    FROM
        new_table n
        JOIN thread_priority tp ON tp.thread_id = n.id
    ORDER BY
        tp.user_id LOOP
            -- Upsert the sync record
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'thread', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_user_for_thread_tag" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_thread_tag" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users who have the thread filed via thread_priority
    FOR v_user_id IN SELECT DISTINCT
        tp.user_id
    FROM
        new_table n
        JOIN thread a ON a.id = n.thread_id
        JOIN thread_priority tp ON tp.thread_id = a.id
    ORDER BY
        tp.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'thread', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "update_note_tags" function
CREATE OR REPLACE FUNCTION "user"."update_note_tags" ("user_id" uuid, "p_note_id" uuid, "p_actor_id" uuid, "p_client_id" integer, "p_tag_updates" jsonb) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    tag_record record;
    tag_id_int integer;
    is_adding boolean;
    current_tag_type tag_type;
    target_actor_id uuid;
    v_priority_id uuid;
    v_effective_role text;
BEGIN
    -- Validate that note_id is provided
    IF p_note_id IS NULL THEN
        RAISE EXCEPTION 'p_note_id must be provided';
    END IF;
    -- Validate access to the note's thread via thread_priority
    SELECT
        tp.priority_id INTO v_priority_id
    FROM
        note n
        JOIN thread_priority tp ON tp.thread_id = n.thread_id
            AND tp.user_id = update_note_tags.user_id
    WHERE
        n.id = p_note_id;
    IF v_priority_id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM note WHERE id = p_note_id) THEN
            RAISE EXCEPTION 'Note not found';
        END IF;
        RAISE EXCEPTION 'User does not have access to this note';
    END IF;
    IF NOT user_has_priority_access(update_note_tags.user_id, v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;
    -- All users are members in the per-user model
    v_effective_role := 'member';
    -- Iterate through the tag updates JSON object
    FOR tag_record IN
    SELECT
        key,
        value
    FROM
        jsonb_each(p_tag_updates)
        LOOP
            -- Parse key: "tagId" or "tagId:actorId"
            IF position(':' in tag_record.key) > 0 THEN
                tag_id_int := split_part(tag_record.key, ':', 1)::integer;
                target_actor_id := split_part(tag_record.key, ':', 2)::uuid;
            ELSE
                tag_id_int := tag_record.key::integer;
                target_actor_id := p_actor_id;
            END IF;
            is_adding := tag_record.value::boolean;
            -- Get tag type using the get_tag_type function
            current_tag_type := get_tag_type (tag_id_int);
            -- Viewer enforcement: viewers can only modify count tags
            IF v_effective_role = 'viewer' AND current_tag_type != 'count' THEN
                RAISE EXCEPTION 'Viewer members can only modify count tags (tag_id: %)', tag_id_int;
            END IF;
            -- Validate computed tags for notes
            -- Notes can have 'todo' (1) and 'done' (3) tags for per-user assignment/completion
            -- But not 'archived' (4), 'attachment' (5), 'link' (6) - those are computed
            IF current_tag_type = 'compute' AND tag_id_int NOT IN (1, 3) THEN
                RAISE EXCEPTION 'Cannot add computed tag (tag_id: %) - this tag is calculated from note state', tag_id_int;
            END IF;
            -- Validate cross-user targeting: only allow for compute tags 1, 3 (todo, done)
            IF target_actor_id != p_actor_id AND (current_tag_type != 'compute' OR tag_id_int NOT IN (1, 3)) THEN
                RAISE EXCEPTION 'Cannot modify this tag for other users (tag_id: %)', tag_id_int;
            END IF;
            IF is_adding THEN
                -- When adding 'done' tag (3), automatically remove 'todo' tag (1) for this actor
                -- This is how individual completion works for multi-assignee notes
                IF tag_id_int = 3 THEN
                    UPDATE
                        note_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        note_id = p_note_id
                        AND tag_id = 1
                        AND actor_id = target_actor_id
                        AND archived_at IS NULL;
                END IF;
                -- Adding a tag - use upsert to create or reactivate
                INSERT INTO note_tag (actor_id, note_id, tag_id, updated_at, archived_at, updated_by)
                    VALUES (target_actor_id, p_note_id, tag_id_int, now(), NULL, p_client_id)
                ON CONFLICT (actor_id, note_id, tag_id)
                    DO UPDATE SET
                        archived_at = NULL,
                        updated_at = now(),
                        updated_by = p_client_id;
                -- Reply tag propagation: note → thread
                IF tag_id_int = 1019 THEN
                    INSERT INTO thread_tag (actor_id, thread_id, occurrence, tag_id, updated_at, archived_at, updated_by)
                    SELECT target_actor_id, n.thread_id, NULL, 1019, now(), NULL, p_client_id
                    FROM note n WHERE n.id = p_note_id
                    ON CONFLICT (actor_id, thread_id, occurrence, tag_id)
                    DO UPDATE SET archived_at = NULL, updated_at = now(), updated_by = p_client_id;
                END IF;
            ELSE
                -- Removing a tag - use update to soft delete existing records
                IF current_tag_type = 'toggle' THEN
                    -- For toggle tags, remove all users' tags
                    UPDATE
                        note_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        note_id = p_note_id
                        AND tag_id = tag_id_int
                        AND archived_at IS NULL;
                ELSE
                    -- For count/compute tags, only remove target actor's tag
                    UPDATE
                        note_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        note_id = p_note_id
                        AND tag_id = tag_id_int
                        AND actor_id = target_actor_id
                        AND archived_at IS NULL;
                END IF;
                -- Reply tag propagation: remove from thread if no other notes have it
                IF tag_id_int = 1019 THEN
                    IF NOT EXISTS (
                        SELECT 1 FROM note_tag nt
                        JOIN note n2 ON n2.id = nt.note_id
                        WHERE n2.thread_id = (SELECT thread_id FROM note WHERE id = p_note_id)
                        AND nt.tag_id = 1019 AND nt.actor_id = target_actor_id
                        AND nt.archived_at IS NULL AND nt.note_id != p_note_id
                    ) THEN
                        UPDATE thread_tag SET archived_at = now(), updated_by = p_client_id
                        WHERE thread_id = (SELECT thread_id FROM note WHERE id = p_note_id)
                        AND tag_id = 1019 AND actor_id = target_actor_id AND archived_at IS NULL;
                    END IF;
                END IF;
            END IF;
        END LOOP;
END;
$$;
-- Modify "update_schedule_contact_status" function
CREATE OR REPLACE FUNCTION "user"."update_schedule_contact_status" ("user_id" uuid, "p_schedule_id" uuid, "p_status" text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_priority_id uuid;
    v_primary_contact_id uuid;
    v_updated_count integer;
BEGIN
    -- Validate user has access to the schedule's thread via thread_priority
    SELECT tp.priority_id INTO v_priority_id
    FROM schedule s
    LEFT JOIN thread_priority tp ON tp.thread_id = COALESCE(s.thread_id, (SELECT l.thread_id FROM link l WHERE l.id = s.link_id))
      AND tp.user_id = update_schedule_contact_status.user_id
    WHERE s.id = p_schedule_id;

    IF v_priority_id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM schedule WHERE id = p_schedule_id) THEN
            RAISE EXCEPTION 'Schedule not found';
        END IF;
        RAISE EXCEPTION 'User does not have access to this schedule';
    END IF;

    IF NOT user_has_priority_access(update_schedule_contact_status.user_id, v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;

    -- Validate status
    IF p_status IS NOT NULL AND p_status NOT IN ('attend', 'skip') THEN
        RAISE EXCEPTION 'Invalid status: must be attend, skip, or null';
    END IF;

    -- Prefer updating any existing row whose contact_id belongs to the user.
    -- If the user has multiple linked contacts that are independently listed
    -- as attendees on this schedule, all rows get the same status.
    UPDATE schedule_contact
    SET status = p_status
    WHERE schedule_id = p_schedule_id
      AND contact_id = ANY("user".user_contact_ids(user_id))
      AND archived_at IS NULL;

    GET DIAGNOSTICS v_updated_count = ROW_COUNT;

    -- Fall back to inserting a row under the user's primary contact for native
    -- schedules where the user has no pre-existing attendee row.
    IF v_updated_count = 0 THEN
        v_primary_contact_id := "user".user_contact_id(user_id);
        IF v_primary_contact_id IS NULL THEN
            RAISE EXCEPTION 'User has no contact record';
        END IF;

        INSERT INTO schedule_contact (schedule_id, contact_id, status, role)
        VALUES (p_schedule_id, v_primary_contact_id, p_status, 'required')
        ON CONFLICT (schedule_id, contact_id)
        DO UPDATE SET status = EXCLUDED.status;
    END IF;
END;
$$;
-- Modify "update_thread_tags" function
CREATE OR REPLACE FUNCTION "user"."update_thread_tags" ("user_id" uuid, "p_thread_id" uuid, "p_actor_id" uuid, "p_client_id" integer, "p_tag_updates" jsonb, "p_occurrence" text DEFAULT NULL::text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    tag_record record;
    tag_id_int integer;
    is_adding boolean;
    current_tag_type tag_type;
    v_priority_id uuid;
    v_effective_role text;
BEGIN
    -- Validate that thread_id is provided
    IF p_thread_id IS NULL THEN
        RAISE EXCEPTION 'p_thread_id must be provided';
    END IF;
    -- Validate access to the thread via thread_priority
    SELECT
        tp.priority_id INTO v_priority_id
    FROM
        thread_priority tp
    WHERE
        tp.thread_id = p_thread_id
        AND tp.user_id = update_thread_tags.user_id;
    IF v_priority_id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM thread WHERE id = p_thread_id) THEN
            RAISE EXCEPTION 'Thread not found';
        END IF;
        RAISE EXCEPTION 'User does not have access to this thread';
    END IF;
    IF NOT user_has_priority_access(update_thread_tags.user_id, v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;
    -- All users are members in the per-user model
    v_effective_role := 'member';
    -- Iterate through the tag updates JSON object
    FOR tag_record IN
    SELECT
        key,
        value
    FROM
        jsonb_each(p_tag_updates)
        LOOP
            -- Convert key to integer and value to boolean
            tag_id_int := tag_record.key::integer;
            is_adding := tag_record.value::boolean;
            -- Get tag type using the get_tag_type function
            current_tag_type := get_tag_type (tag_id_int);
            -- Viewer enforcement: viewers can only modify count tags
            IF v_effective_role = 'viewer' AND current_tag_type != 'count' THEN
                RAISE EXCEPTION 'Viewer members can only modify count tags (tag_id: %)', tag_id_int;
            END IF;
            -- Prevent insertion of computed tags (tag_id 1-99)
            -- Exception: 'done' (3) acts as a toggle tag on threads
            IF current_tag_type = 'compute' AND tag_id_int != 3 THEN
                RAISE EXCEPTION 'Cannot add computed tag (tag_id: %) - these tags are calculated from thread state', tag_id_int;
            END IF;
            -- For count tags, enforce that users can only modify their own tags
            -- p_actor_id should match the authenticated user's contact_id
            -- Note: RLS policies already enforce this, but we validate explicitly for clarity
            IF current_tag_type = 'count' THEN
                -- Validate p_actor_id matches one of the user's linked contacts
                IF NOT (p_actor_id = ANY("user".user_contact_ids (user_id))) THEN
                    RAISE EXCEPTION 'Cannot modify count tags for other users (tag_id: %)', tag_id_int;
                END IF;
            END IF;
            IF is_adding THEN
                -- Adding a tag - use upsert to create or reactivate
                INSERT INTO thread_tag (actor_id, thread_id, occurrence, tag_id, updated_at, archived_at, updated_by)
                    VALUES (p_actor_id, p_thread_id, p_occurrence, tag_id_int, now(), NULL, p_client_id)
                ON CONFLICT (actor_id, thread_id, occurrence, tag_id)
                    DO UPDATE SET
                        archived_at = NULL,
                        updated_at = now(),
                        updated_by = p_client_id;
                -- Ensure priority_contact exists if actor is a contact
                -- This allows contacts to be visible via RLS when tagged on threads
                IF EXISTS (
                    SELECT
                        1
                    FROM
                        contact
                    WHERE
                        id = p_actor_id) THEN
                INSERT INTO priority_contact (priority_id, contact_id)
                VALUES (v_priority_id, p_actor_id)
                ON CONFLICT (priority_id,
                    contact_id)
                    DO NOTHING;
            END IF;
        ELSE
            -- Removing a tag - use update to soft delete existing records
            IF current_tag_type = 'toggle' OR tag_id_int = 3 THEN
                -- For toggle tags, remove all users' tags
                UPDATE
                    thread_tag
                SET
                    archived_at = now(),
                    updated_by = p_client_id
                WHERE
                    thread_id = p_thread_id
                    AND tag_id = tag_id_int
                    AND (occurrence IS NOT DISTINCT FROM p_occurrence)
                    AND archived_at IS NULL;
            ELSE
                -- For count/compute tags, only remove current actor's tag
                UPDATE
                    thread_tag
                SET
                    archived_at = now(),
                    updated_by = p_client_id
                WHERE
                    thread_id = p_thread_id
                    AND tag_id = tag_id_int
                    AND actor_id = p_actor_id
                    AND (occurrence IS NOT DISTINCT FROM p_occurrence)
                    AND archived_at IS NULL;
            END IF;
            -- Reply tag propagation: thread → notes
            IF tag_id_int = 1019 THEN
                UPDATE note_tag SET archived_at = now(), updated_by = p_client_id
                WHERE note_id IN (SELECT id FROM note WHERE thread_id = p_thread_id)
                AND tag_id = 1019 AND actor_id = p_actor_id AND archived_at IS NULL;
            END IF;
        END IF;
END LOOP;
END;
$$;
-- Modify "upsert_link" function
CREATE OR REPLACE FUNCTION "user"."upsert_link" ("user_id" uuid, "p_link" jsonb, "p_defaults" jsonb DEFAULT '{}') RETURNS "public"."link" LANGUAGE plpgsql AS $$
DECLARE
    v_result link;
    v_id uuid;
    v_thread_id uuid;
    v_source text;
    v_source_priority_root ltree;
    v_created_by uuid;
    v_twist_id bigint;
    v_author_id uuid;
    v_assignee_id uuid;
    v_priority_id uuid;
    v_role text;
BEGIN
    -- Extract required fields from JSONB, with fallback to p_defaults for INSERT
    v_id := COALESCE((p_link ->> 'id')::uuid, (p_defaults ->> 'id')::uuid);
    v_thread_id := COALESCE((p_link ->> 'thread_id')::uuid, (p_defaults ->> 'thread_id')::uuid);
    v_source := p_link ->> 'source';
    v_created_by := COALESCE((p_link ->> 'created_by')::uuid, (p_defaults ->> 'created_by')::uuid, user_id);
    v_author_id := COALESCE((p_link ->> 'author_id')::uuid, (p_defaults ->> 'author_id')::uuid, v_created_by);

    -- DERIVE source_priority_root if explicitly provided
    IF p_link ? 'source_priority_root' AND (p_link ->> 'source_priority_root') IS NOT NULL THEN
        v_source_priority_root := (p_link ->> 'source_priority_root')::ltree;
    END IF;

    -- Generate id if not provided
    IF v_id IS NULL THEN
        v_id := uuidv7 ();
    END IF;

    -- Resolve thread_id from existing link if missing
    IF v_thread_id IS NULL THEN
        SELECT
            l.thread_id INTO v_thread_id
        FROM
            link l
        WHERE
            l.id = v_id;
    END IF;

    IF v_thread_id IS NULL THEN
        RAISE EXCEPTION 'thread_id must be provided';
    END IF;

    -- Look up the calling user's priority for this thread and derive source_priority_root
    SELECT
        tp.priority_id,
        CASE WHEN v_source_priority_root IS NULL AND v_source IS NOT NULL
            THEN subpath(p.path, 0, 1)
            ELSE v_source_priority_root
        END
    INTO v_priority_id, v_source_priority_root
    FROM
        thread_priority tp
        JOIN priority p ON p.id = tp.priority_id
    WHERE
        tp.thread_id = v_thread_id
        AND tp.user_id = upsert_link.user_id;

    IF v_priority_id IS NULL THEN
        -- Check if the thread exists at all
        IF NOT EXISTS (SELECT 1 FROM thread WHERE id = v_thread_id) THEN
            RAISE EXCEPTION 'Thread not found';
        END IF;
        RAISE EXCEPTION 'User does not have access to this thread';
    END IF;
    IF NOT user_has_priority_access(upsert_link.user_id, v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;

    -- For existing links, preserve the original created_by (any priority member
    -- can update link fields like assignee_id without owning the creator entity).
    -- For new links, validate that created_by is the user or their owned twist.
    -- Single query instead of EXISTS + separate SELECT
    DECLARE
        v_existing_created_by uuid;
    BEGIN
        SELECT l.created_by INTO v_existing_created_by FROM link l WHERE l.id = v_id;
        IF v_existing_created_by IS NOT NULL THEN
            v_created_by := v_existing_created_by;
        ELSE
            IF v_created_by IS DISTINCT FROM user_id THEN
                IF NOT EXISTS (
                    SELECT
                        1
                    FROM
                        twist_instance pt
                    WHERE
                        pt.id = v_created_by
                        AND pt.owner_id = upsert_link.user_id) THEN
                    RAISE EXCEPTION 'created_by must be user or owned twist_instance';
                END IF;
            END IF;
        END IF;
    END;

    -- DERIVE twist_id from created_by (twist_instance_id)
    IF p_link ? 'twist_id' AND (p_link ->> 'twist_id') IS NOT NULL THEN
        v_twist_id := (p_link ->> 'twist_id')::bigint;
    ELSIF v_created_by IS NOT NULL THEN
        SELECT
            pt.twist_id INTO v_twist_id
        FROM
            twist_instance pt
        WHERE
            pt.id = v_created_by;
    END IF;

    -- Resolve assignee
    IF p_link ? 'assignee_id' THEN
        v_assignee_id := (p_link ->> 'assignee_id')::uuid;
    ELSIF p_defaults ? 'assignee_id' THEN
        v_assignee_id := (p_defaults ->> 'assignee_id')::uuid;
    ELSE
        v_assignee_id := NULL;
    END IF;

    -- Perform the upsert and return the full row
    INSERT INTO link (id, thread_id, source, source_created_at, author_id, twist_id,
        created_by, updated_by, sync_depth, title, preview, assignee_id, type, status,
        actions, meta, source_url, embedding, match, merged_from_thread_id, related_source,
        channel_id)
        VALUES (v_id, v_thread_id, v_source,
            COALESCE((p_link ->> 'source_created_at')::timestamptz, (p_defaults ->> 'source_created_at')::timestamptz, now()),
            v_author_id, v_twist_id, v_created_by,
            COALESCE((p_link ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, 0),
            COALESCE((p_link ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint),
            COALESCE(p_link ->> 'title', p_defaults ->> 'title'),
            COALESCE(p_link ->> 'preview', p_defaults ->> 'preview'),
            v_assignee_id,
            COALESCE(p_link ->> 'type', p_defaults ->> 'type'),
            COALESCE(p_link ->> 'status', p_defaults ->> 'status'),
            COALESCE(p_link -> 'actions', p_defaults -> 'actions'),
            COALESCE(p_link -> 'meta', p_defaults -> 'meta'),
            COALESCE(p_link ->> 'source_url', p_defaults ->> 'source_url'),
            COALESCE((p_link ->> 'embedding')::halfvec, (p_defaults ->> 'embedding')::halfvec),
            COALESCE(p_link -> 'match', p_defaults -> 'match'),
            COALESCE((p_link ->> 'merged_from_thread_id')::uuid, (p_defaults ->> 'merged_from_thread_id')::uuid),
            COALESCE(p_link ->> 'related_source', p_defaults ->> 'related_source'),
            COALESCE(p_link ->> 'channel_id', p_defaults ->> 'channel_id'))
    ON CONFLICT (source, source_priority_root)
        DO UPDATE SET
            title = CASE WHEN p_link ? 'title' THEN
                p_link ->> 'title'
            ELSE
                link.title
            END,
            preview = CASE WHEN p_link ? 'preview' THEN
                p_link ->> 'preview'
            ELSE
                link.preview
            END,
            assignee_id = CASE WHEN p_link ? 'assignee_id' THEN
                (p_link ->> 'assignee_id')::uuid
            ELSE
                COALESCE(v_assignee_id, link.assignee_id)
            END,
            type = CASE WHEN p_link ? 'type' THEN
                p_link ->> 'type'
            ELSE
                link.type
            END,
            status = CASE WHEN p_link ? 'status' THEN
                p_link ->> 'status'
            ELSE
                link.status
            END,
            actions = CASE WHEN p_link ? 'actions' THEN
                p_link -> 'actions'
            ELSE
                link.actions
            END,
            meta = CASE WHEN p_link ? 'meta' THEN
                p_link -> 'meta'
            ELSE
                link.meta
            END,
            source_url = CASE WHEN p_link ? 'source_url' THEN
                p_link ->> 'source_url'
            ELSE
                link.source_url
            END,
            updated_by = CASE WHEN p_link ? 'updated_by' THEN
                (p_link ->> 'updated_by')::integer
            ELSE
                link.updated_by
            END,
            sync_depth = CASE WHEN p_link ? 'sync_depth' THEN
                (p_link ->> 'sync_depth')::smallint
            ELSE
                link.sync_depth
            END,
            source = COALESCE(v_source, link.source),
            source_priority_root = COALESCE(v_source_priority_root, link.source_priority_root),
            created_by = v_created_by,
            twist_id = v_twist_id,
            -- Keep existing thread_id on update to prevent race conditions
            -- where concurrent saveLink calls create orphaned threads
            thread_id = link.thread_id,
            merged_from_thread_id = CASE WHEN p_link ? 'merged_from_thread_id' THEN
                (p_link ->> 'merged_from_thread_id')::uuid
            ELSE
                link.merged_from_thread_id
            END,
            related_source = CASE WHEN p_link ? 'related_source' THEN
                p_link ->> 'related_source'
            ELSE
                link.related_source
            END,
            channel_id = CASE WHEN p_link ? 'channel_id' THEN
                p_link ->> 'channel_id'
            ELSE
                link.channel_id
            END
        RETURNING
            * INTO v_result;
    RETURN v_result;
END;
$$;
-- Modify "upsert_note" function
CREATE OR REPLACE FUNCTION "user"."upsert_note" ("user_id" uuid, "p_id" uuid, "p_author_id" uuid, "p_created_by" uuid, "p_updated_by" integer, "p_archived_at" timestamptz, "p_thread_id" uuid, "p_draft" boolean, "p_access_contacts" uuid[], "p_content" text, "p_actions" jsonb, "p_mentions" uuid[], "p_re_note_id" uuid, "p_source_created_at" timestamptz, "p_key" text, "p_merged_from_thread_id" uuid DEFAULT NULL::uuid) RETURNS "public"."note" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_priority_id uuid;
    v_created_by uuid;
    v_author_id uuid;
    v_thread_created_by uuid;
    v_row note;
BEGIN
    SELECT
        priority_id INTO v_priority_id
    FROM
        thread
    WHERE
        id = p_thread_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;

    -- Check thread access via contacts intersection
    SELECT created_by INTO v_thread_created_by FROM thread WHERE id = p_thread_id;
    IF v_thread_created_by != upsert_note.user_id
       AND NOT EXISTS (
           SELECT 1 FROM thread
           WHERE id = p_thread_id
             AND contacts && "user".user_contact_ids(upsert_note.user_id)
       )
    THEN
        RAISE EXCEPTION 'Access denied to thread';
    END IF;

    v_created_by := COALESCE(p_created_by, user_id);
    -- When the user creates directly (not via twist), force author to their contact ID.
    -- This prevents impersonation: clients cannot spoof author_id.
    -- When a twist creates (created_by != user_id), trust the provided author_id.
    IF v_created_by = user_id THEN
        v_author_id := COALESCE("user".user_contact_id(user_id), user_id);
    ELSE
        v_author_id := COALESCE(p_author_id, v_created_by);
    END IF;

    IF v_created_by IS DISTINCT FROM user_id THEN
        IF NOT EXISTS (
            SELECT
                1
            FROM
                twist_instance pt
            WHERE
                pt.id = v_created_by
                AND pt.owner_id = upsert_note.user_id) THEN
            RAISE EXCEPTION 'created_by must be user or owned twist_instance';
        END IF;
    END IF;

    IF p_id IS NULL THEN
        INSERT INTO note (id, author_id, created_by, updated_by, archived_at, thread_id, draft, access_contacts, content, actions, mentions, re_note_id, source_created_at, key, merged_from_thread_id)
            VALUES (uuidv7(), v_author_id, v_created_by, COALESCE(p_updated_by, 0), p_archived_at, p_thread_id, COALESCE(p_draft, FALSE), p_access_contacts, p_content, p_actions, p_mentions, p_re_note_id, COALESCE(p_source_created_at, now()), p_key, p_merged_from_thread_id)
        ON CONFLICT (thread_id, key)
            DO UPDATE SET
                author_id = note.author_id,
                created_by = note.created_by,
                updated_by = EXCLUDED.updated_by,
                archived_at = EXCLUDED.archived_at,
                draft = EXCLUDED.draft,
                access_contacts = EXCLUDED.access_contacts,
                content = EXCLUDED.content,
                actions = EXCLUDED.actions,
                mentions = EXCLUDED.mentions,
                re_note_id = EXCLUDED.re_note_id,
                source_created_at = EXCLUDED.source_created_at,
                key = EXCLUDED.key,
                merged_from_thread_id = EXCLUDED.merged_from_thread_id,
                updated_at = now()
        RETURNING * INTO v_row;
    ELSE
        INSERT INTO note (id, author_id, created_by, updated_by, archived_at, thread_id, draft, access_contacts, content, actions, mentions, re_note_id, source_created_at, key, merged_from_thread_id)
            VALUES (p_id, v_author_id, v_created_by, COALESCE(p_updated_by, 0), p_archived_at, p_thread_id, COALESCE(p_draft, FALSE), p_access_contacts, p_content, p_actions, p_mentions, p_re_note_id, COALESCE(p_source_created_at, now()), p_key, p_merged_from_thread_id)
        ON CONFLICT (id)
            DO UPDATE SET
                author_id = note.author_id,
                created_by = note.created_by,
                updated_by = EXCLUDED.updated_by,
                archived_at = EXCLUDED.archived_at,
                thread_id = EXCLUDED.thread_id,
                draft = EXCLUDED.draft,
                access_contacts = EXCLUDED.access_contacts,
                content = EXCLUDED.content,
                actions = EXCLUDED.actions,
                mentions = EXCLUDED.mentions,
                re_note_id = EXCLUDED.re_note_id,
                source_created_at = EXCLUDED.source_created_at,
                key = COALESCE(EXCLUDED.key, note.key),
                merged_from_thread_id = EXCLUDED.merged_from_thread_id,
                updated_at = now()
        RETURNING * INTO v_row;
    END IF;

    RETURN v_row;
END;
$$;
-- Modify "upsert_note_tag" function
CREATE OR REPLACE FUNCTION "user"."upsert_note_tag" ("user_id" uuid, "p_actor_id" uuid, "p_note_id" uuid, "p_tag_id" integer, "p_updated_by" integer DEFAULT 0, "p_archived_at" timestamptz DEFAULT NULL::timestamp with time zone) RETURNS "public"."note_tag" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_priority_id uuid;
    v_tag_type tag_type;
    v_row note_tag;
BEGIN
    SELECT
        tp.priority_id INTO v_priority_id
    FROM
        note n
        JOIN thread_priority tp ON tp.thread_id = n.thread_id
            AND tp.user_id = upsert_note_tag.user_id
    WHERE
        n.id = p_note_id;
    IF v_priority_id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM note WHERE id = p_note_id) THEN
            RAISE EXCEPTION 'Note not found';
        END IF;
        RAISE EXCEPTION 'User does not have access to this note';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

    v_tag_type := get_tag_type(p_tag_id);
    IF v_tag_type = 'compute' THEN
        RAISE EXCEPTION 'Cannot add computed tag (tag_id: %)', p_tag_id;
    END IF;
    IF v_tag_type = 'count' AND NOT (p_actor_id = ANY("user".user_contact_ids(user_id))) THEN
        RAISE EXCEPTION 'Cannot modify count tags for other users (tag_id: %)', p_tag_id;
    END IF;

    INSERT INTO note_tag (actor_id, note_id, tag_id, updated_by, archived_at)
        VALUES (p_actor_id, p_note_id, p_tag_id, COALESCE(p_updated_by, 0), p_archived_at)
    ON CONFLICT (actor_id, note_id, tag_id)
        DO UPDATE SET
            archived_at = EXCLUDED.archived_at,
            updated_by = EXCLUDED.updated_by,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Modify "upsert_schedule" function
CREATE OR REPLACE FUNCTION "user"."upsert_schedule" ("user_id" uuid, "p_schedule" jsonb, "p_defaults" jsonb DEFAULT '{}') RETURNS "public"."schedule" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_id uuid;
    v_thread_id uuid;
    v_link_id uuid;
    v_priority_id uuid;
    v_role text;
    v_schedule_user_id uuid;
    v_recurrence_exdates timestamptz[];
    v_recurrence_exdates_add timestamptz[];
    v_recurrence_exdates_remove timestamptz[];
    v_result schedule;
BEGIN
    -- Extract fields
    v_id := COALESCE((p_schedule ->> 'id')::uuid, (p_defaults ->> 'id')::uuid);
    v_thread_id := COALESCE((p_schedule ->> 'thread_id')::uuid, (p_defaults ->> 'thread_id')::uuid);
    v_link_id := COALESCE((p_schedule ->> 'link_id')::uuid, (p_defaults ->> 'link_id')::uuid);
    v_schedule_user_id := COALESCE((p_schedule ->> 'user_id')::uuid, (p_defaults ->> 'user_id')::uuid);

    -- Resolve thread_id/link_id from existing schedule if updating
    IF v_thread_id IS NULL AND v_link_id IS NULL AND v_id IS NOT NULL THEN
        SELECT
            s.thread_id, s.link_id INTO v_thread_id, v_link_id
        FROM
            schedule s
        WHERE
            s.id = v_id;
    END IF;

    -- Must have either thread_id or link_id
    IF v_thread_id IS NULL AND v_link_id IS NULL THEN
        RAISE EXCEPTION 'thread_id or link_id must be provided';
    END IF;

    -- Look up priority via thread_priority for the calling user
    IF v_thread_id IS NOT NULL THEN
        SELECT tp.priority_id INTO v_priority_id
        FROM thread_priority tp
        WHERE tp.thread_id = v_thread_id
          AND tp.user_id = upsert_schedule.user_id;
        IF v_priority_id IS NULL THEN
            IF NOT EXISTS (SELECT 1 FROM thread WHERE id = v_thread_id) THEN
                RAISE EXCEPTION 'Thread not found';
            END IF;
            RAISE EXCEPTION 'User does not have access to this thread';
        END IF;
    ELSIF v_link_id IS NOT NULL THEN
        SELECT tp.priority_id INTO v_priority_id
        FROM link l
        JOIN thread_priority tp ON tp.thread_id = l.thread_id
          AND tp.user_id = upsert_schedule.user_id
        WHERE l.id = v_link_id;
        IF v_priority_id IS NULL THEN
            IF NOT EXISTS (SELECT 1 FROM link WHERE id = v_link_id) THEN
                RAISE EXCEPTION 'Link not found';
            END IF;
            RAISE EXCEPTION 'User does not have access to this link';
        END IF;
    END IF;

    IF NOT user_has_priority_access(upsert_schedule.user_id, v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;

    -- Per-user schedules can only be created/modified by the owning user
    IF v_schedule_user_id IS NOT NULL AND v_schedule_user_id != upsert_schedule.user_id THEN
        RAISE EXCEPTION 'Cannot create/modify per-user schedule for another user';
    END IF;

    -- Resolve to existing schedule ID based on unique constraints.
    -- This prevents unique constraint violations when client and server
    -- have different UUIDs for the same logical schedule.
    DECLARE
        v_occurrence text;
        v_existing_id uuid;
    BEGIN
        v_occurrence := COALESCE(p_schedule ->> 'occurrence', p_defaults ->> 'occurrence');

        IF v_occurrence IS NOT NULL THEN
            -- Occurrence override: resolve by (link_id/thread_id, occurrence)
            IF v_link_id IS NOT NULL THEN
                SELECT s.id INTO v_existing_id
                FROM schedule s
                WHERE s.link_id = v_link_id
                  AND s.occurrence = v_occurrence;
            ELSIF v_thread_id IS NOT NULL THEN
                SELECT s.id INTO v_existing_id
                FROM schedule s
                WHERE s.thread_id = v_thread_id
                  AND s.occurrence = v_occurrence;
            END IF;
        ELSIF v_schedule_user_id IS NOT NULL THEN
            -- Per-user base schedule: resolve by (link_id/thread_id, user_id)
            IF v_link_id IS NOT NULL THEN
                SELECT s.id INTO v_existing_id
                FROM schedule s
                WHERE s.link_id = v_link_id
                  AND s.user_id = v_schedule_user_id
                  AND s.occurrence IS NULL;
            ELSIF v_thread_id IS NOT NULL THEN
                SELECT s.id INTO v_existing_id
                FROM schedule s
                WHERE s.thread_id = v_thread_id
                  AND s.user_id = v_schedule_user_id
                  AND s.occurrence IS NULL;
            END IF;
        ELSE
            -- Shared base schedule: resolve by (link_id/thread_id, user_id IS NULL)
            IF v_link_id IS NOT NULL THEN
                SELECT s.id INTO v_existing_id
                FROM schedule s
                WHERE s.link_id = v_link_id
                  AND s.user_id IS NULL
                  AND s.occurrence IS NULL;
            ELSIF v_thread_id IS NOT NULL THEN
                SELECT s.id INTO v_existing_id
                FROM schedule s
                WHERE s.thread_id = v_thread_id
                  AND s.user_id IS NULL
                  AND s.occurrence IS NULL;
            END IF;
        END IF;

        IF v_existing_id IS NOT NULL THEN
            v_id := v_existing_id;
        END IF;
    END;

    -- Generate id if not provided
    IF v_id IS NULL THEN
        v_id := uuidv7 ();
    END IF;

    -- Handle recurrence_exdates array conversion from JSONB
    IF p_schedule ? 'recurrence_exdates' AND jsonb_typeof(p_schedule -> 'recurrence_exdates') = 'array' THEN
        SELECT
            ARRAY (
                SELECT
                    (jsonb_array_elements_text(p_schedule -> 'recurrence_exdates'))::timestamptz) INTO v_recurrence_exdates;
    ELSIF p_defaults ? 'recurrence_exdates'
            AND jsonb_typeof(p_defaults -> 'recurrence_exdates') = 'array' THEN
            SELECT
                ARRAY (
                    SELECT
                        (jsonb_array_elements_text(p_defaults -> 'recurrence_exdates'))::timestamptz) INTO v_recurrence_exdates;
    END IF;

    -- Handle add/remove exdates
    IF p_schedule ? 'recurrence_exdates_add' AND jsonb_typeof(p_schedule -> 'recurrence_exdates_add') = 'array' THEN
        SELECT
            ARRAY (
                SELECT
                    (jsonb_array_elements_text(p_schedule -> 'recurrence_exdates_add'))::timestamptz) INTO v_recurrence_exdates_add;
    END IF;
    IF p_schedule ? 'recurrence_exdates_remove' AND jsonb_typeof(p_schedule -> 'recurrence_exdates_remove') = 'array' THEN
        SELECT
            ARRAY (
                SELECT
                    (jsonb_array_elements_text(p_schedule -> 'recurrence_exdates_remove'))::timestamptz) INTO v_recurrence_exdates_remove;
    END IF;

    -- Perform the upsert
    INSERT INTO schedule (id, thread_id, link_id, user_id, "order", at, "on", recurrence_rule, duration, recurrence_exdates, occurrence, reason, archived_at, outstanding_tasks)
        VALUES (
            v_id,
            v_thread_id,
            v_link_id,
            v_schedule_user_id,
            CASE WHEN v_schedule_user_id IS NOT NULL THEN
                COALESCE((p_schedule ->> 'order')::double precision, (p_defaults ->> 'order')::double precision, public.order_first())
            ELSE
                NULL
            END,
            COALESCE((p_schedule ->> 'at')::tstzrange, (p_defaults ->> 'at')::tstzrange),
            COALESCE((p_schedule ->> 'on')::daterange, (p_defaults ->> 'on')::daterange),
            COALESCE(p_schedule ->> 'recurrence_rule', p_defaults ->> 'recurrence_rule'),
            COALESCE((p_schedule ->> 'duration')::interval, (p_defaults ->> 'duration')::interval),
            v_recurrence_exdates,
            COALESCE(p_schedule ->> 'occurrence', p_defaults ->> 'occurrence'),
            COALESCE(p_schedule ->> 'reason', p_defaults ->> 'reason'),
            COALESCE((p_schedule ->> 'archived_at')::timestamptz, (p_defaults ->> 'archived_at')::timestamptz),
            COALESCE((p_schedule ->> 'outstanding_tasks')::boolean, (p_defaults ->> 'outstanding_tasks')::boolean, FALSE)
        )
    ON CONFLICT (id)
        DO UPDATE SET
            at = CASE WHEN p_schedule ? 'at' THEN
                (p_schedule ->> 'at')::tstzrange
            WHEN p_schedule ? 'on' THEN
                NULL -- Clear at when on is being set (XOR constraint)
            ELSE
                schedule.at
            END,
            "on" = CASE WHEN p_schedule ? 'on' THEN
                (p_schedule ->> 'on')::daterange
            WHEN p_schedule ? 'at' THEN
                NULL -- Clear on when at is being set (XOR constraint)
            ELSE
                schedule."on"
            END,
            recurrence_rule = CASE WHEN p_schedule ? 'recurrence_rule' THEN
                p_schedule ->> 'recurrence_rule'
            ELSE
                schedule.recurrence_rule
            END,
            duration = CASE WHEN p_schedule ? 'duration' THEN
                (p_schedule ->> 'duration')::interval
            ELSE
                schedule.duration
            END,
            recurrence_exdates = CASE WHEN p_schedule ? 'recurrence_exdates' THEN
                v_recurrence_exdates
            WHEN v_recurrence_exdates_add IS NOT NULL OR v_recurrence_exdates_remove IS NOT NULL THEN
                (SELECT ARRAY(
                    SELECT DISTINCT unnest
                    FROM unnest(
                        COALESCE(schedule.recurrence_exdates, ARRAY[]::timestamptz[]) ||
                        COALESCE(v_recurrence_exdates_add, ARRAY[]::timestamptz[])
                    )
                    WHERE unnest IS NOT NULL
                      AND (v_recurrence_exdates_remove IS NULL
                           OR unnest != ALL(v_recurrence_exdates_remove))
                    ORDER BY 1
                ))
            ELSE
                schedule.recurrence_exdates
            END,
            "order" = CASE
                WHEN schedule.user_id IS NULL THEN NULL
                WHEN p_schedule ? 'order' THEN COALESCE((p_schedule ->> 'order')::double precision, schedule."order", public.order_first())
                ELSE COALESCE(schedule."order", public.order_first())
            END,
            reason = CASE WHEN p_schedule ? 'reason' THEN
                CASE
                    WHEN schedule.reason IS NULL THEN (p_schedule ->> 'reason')
                    WHEN schedule.reason = 'unread' AND (p_schedule ->> 'reason') IN ('task', 'add', 'schedule') THEN (p_schedule ->> 'reason')
                    WHEN schedule.reason = 'task' AND (p_schedule ->> 'reason') IN ('add', 'schedule') THEN (p_schedule ->> 'reason')
                    WHEN schedule.reason = 'add' AND (p_schedule ->> 'reason') = 'schedule' THEN 'schedule'
                    ELSE schedule.reason
                END
            ELSE schedule.reason
            END,
            archived_at = CASE WHEN p_schedule ? 'archived_at' THEN
                (p_schedule ->> 'archived_at')::timestamptz
            ELSE
                schedule.archived_at
            END,
            outstanding_tasks = CASE WHEN p_schedule ? 'outstanding_tasks' THEN
                (p_schedule ->> 'outstanding_tasks')::boolean
            ELSE
                schedule.outstanding_tasks
            END
        RETURNING
            * INTO v_result;
    RETURN v_result;
END;
$$;
-- Modify "upsert_schedule_contacts" function
CREATE OR REPLACE FUNCTION "user"."upsert_schedule_contacts" ("user_id" uuid, "p_schedule_id" uuid, "p_contacts" jsonb) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_contact jsonb;
    v_contact_id uuid;
    v_status text;
    v_role text;
    v_archived boolean;
    v_priority_id uuid;
BEGIN
    -- Validate user has access to the schedule's thread via thread_priority
    SELECT tp.priority_id INTO v_priority_id
    FROM schedule s
    LEFT JOIN thread_priority tp ON tp.thread_id = COALESCE(s.thread_id, (SELECT l.thread_id FROM link l WHERE l.id = s.link_id))
      AND tp.user_id = upsert_schedule_contacts.user_id
    WHERE s.id = p_schedule_id;

    IF v_priority_id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM schedule WHERE id = p_schedule_id) THEN
            RAISE EXCEPTION 'Schedule not found';
        END IF;
        RAISE EXCEPTION 'User does not have access to this schedule';
    END IF;

    IF NOT user_has_priority_access(upsert_schedule_contacts.user_id, v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;

    FOR v_contact IN SELECT * FROM jsonb_array_elements(p_contacts)
    LOOP
        v_contact_id := (v_contact ->> 'contact_id')::uuid;
        v_status := v_contact ->> 'status';
        v_role := v_contact ->> 'role';
        v_archived := COALESCE((v_contact ->> 'archived')::boolean, false);

        INSERT INTO schedule_contact (schedule_id, contact_id, status, role, archived_at)
        VALUES (
            p_schedule_id,
            v_contact_id,
            v_status,
            COALESCE(v_role, 'required'),
            CASE WHEN v_archived THEN now() ELSE NULL END
        )
        ON CONFLICT (schedule_id, contact_id)
        DO UPDATE SET
            status = CASE
                WHEN v_contact ? 'status' THEN EXCLUDED.status
                ELSE schedule_contact.status
            END,
            role = CASE
                WHEN v_contact ? 'role' THEN EXCLUDED.role
                ELSE schedule_contact.role
            END,
            archived_at = CASE
                WHEN v_archived THEN COALESCE(schedule_contact.archived_at, now())
                ELSE NULL
            END;

        -- Ensure priority_contact exists for the contact
        INSERT INTO priority_contact (priority_id, contact_id)
        VALUES (v_priority_id, v_contact_id)
        ON CONFLICT (priority_id, contact_id) DO NOTHING;
    END LOOP;
END;
$$;
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
    INSERT INTO thread (id, created_by, title, preview, updated_by, sync_depth, contacts, draft, key, icon)
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
    ON CONFLICT (thread_id, user_id)
    DO UPDATE SET
        priority_id = CASE
            WHEN p_thread ? 'priority_id' THEN EXCLUDED.priority_id
            WHEN v_is_archived THEN EXCLUDED.priority_id
            ELSE thread_priority.priority_id
        END,
        updated_at = now();

    -- Peer thread_priority rows are populated by the file_thread_priority_peers
    -- trigger on thread, so both upsert_thread callers and raw inserts from
    -- the twist runtime share the same filing behaviour.

    RETURN v_result;
END;
$$;
-- Modify "upsert_thread_association" function
CREATE OR REPLACE FUNCTION "user"."upsert_thread_association" ("user_id" uuid, "p_association" jsonb) RETURNS "public"."thread_association" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_id uuid;
    v_parent_thread_id uuid;
    v_child_thread_id uuid;
    v_parent_priority_id uuid;
    v_child_priority_id uuid;
    v_existing_id uuid;
    v_result thread_association;
BEGIN
    -- Extract fields
    v_id := (p_association ->> 'id')::uuid;
    v_parent_thread_id := (p_association ->> 'parent_thread_id')::uuid;
    v_child_thread_id := (p_association ->> 'child_thread_id')::uuid;

    -- Resolve parent/child from existing association if updating
    IF v_parent_thread_id IS NULL AND v_child_thread_id IS NULL AND v_id IS NOT NULL THEN
        SELECT
            ta.parent_thread_id, ta.child_thread_id
            INTO v_parent_thread_id, v_child_thread_id
        FROM
            thread_association ta
        WHERE
            ta.id = v_id;
    END IF;

    -- Must have both parent and child
    IF v_parent_thread_id IS NULL THEN
        RAISE EXCEPTION 'parent_thread_id must be provided';
    END IF;
    IF v_child_thread_id IS NULL THEN
        RAISE EXCEPTION 'child_thread_id must be provided';
    END IF;

    -- Cannot associate a thread with itself
    IF v_parent_thread_id = v_child_thread_id THEN
        RAISE EXCEPTION 'Cannot associate a thread with itself';
    END IF;

    -- Check access to parent thread via thread_priority
    SELECT tp.priority_id INTO v_parent_priority_id
    FROM thread_priority tp
    WHERE tp.thread_id = v_parent_thread_id
      AND tp.user_id = upsert_thread_association.user_id;

    IF v_parent_priority_id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM thread WHERE id = v_parent_thread_id) THEN
            RAISE EXCEPTION 'Parent thread not found';
        END IF;
        RAISE EXCEPTION 'User does not have access to parent thread';
    END IF;
    IF NOT user_has_priority_access(upsert_thread_association.user_id, v_parent_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to parent thread priority';
    END IF;

    -- Check access to child thread via thread_priority
    SELECT tp.priority_id INTO v_child_priority_id
    FROM thread_priority tp
    WHERE tp.thread_id = v_child_thread_id
      AND tp.user_id = upsert_thread_association.user_id;

    IF v_child_priority_id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM thread WHERE id = v_child_thread_id) THEN
            RAISE EXCEPTION 'Child thread not found';
        END IF;
        RAISE EXCEPTION 'User does not have access to child thread';
    END IF;

    -- Resolve existing association ID based on unique constraints
    -- Try to find an existing active association for this child (a child
    -- can only be actively associated with one parent at a time)
    IF v_id IS NULL THEN
        SELECT ta.id INTO v_existing_id
        FROM thread_association ta
        WHERE ta.parent_thread_id = v_parent_thread_id
          AND ta.child_thread_id = v_child_thread_id
          AND ta.archived_at IS NULL;

        IF v_existing_id IS NOT NULL THEN
            v_id := v_existing_id;
        END IF;
    END IF;

    -- Archive any existing active association for this child with a different parent
    -- (handles the "move to different event" case)
    UPDATE thread_association
    SET archived_at = now()
    WHERE child_thread_id = v_child_thread_id
      AND archived_at IS NULL
      AND (v_id IS NULL OR id != v_id)
      AND parent_thread_id != v_parent_thread_id;

    -- Generate id if not provided
    IF v_id IS NULL THEN
        v_id := uuidv7();
    END IF;

    -- Perform the upsert
    INSERT INTO thread_association (id, parent_thread_id, child_thread_id, "order", archived_at)
        VALUES (
            v_id,
            v_parent_thread_id,
            v_child_thread_id,
            COALESCE((p_association ->> 'order')::double precision, public.order_first()),
            (p_association ->> 'archived_at')::timestamptz
        )
    ON CONFLICT (id)
        DO UPDATE SET
            "order" = CASE WHEN p_association ? 'order' THEN
                (p_association ->> 'order')::double precision
            ELSE
                thread_association."order"
            END,
            archived_at = CASE WHEN p_association ? 'archived_at' THEN
                (p_association ->> 'archived_at')::timestamptz
            ELSE
                thread_association.archived_at
            END
    RETURNING * INTO v_result;

    RETURN v_result;
END;
$$;
-- Create "thread_x" view
CREATE VIEW "public"."thread_x" (
  "id",
  "created_at",
  "updated_at",
  "created_by",
  "updated_by",
  "archived_at",
  "draft",
  "contacts",
  "title",
  "preview",
  "last_note_created_at",
  "sync_depth",
  "last_note_source_created_at",
  "key",
  "icon"
) AS SELECT id,
    created_at,
    updated_at,
    created_by,
    updated_by,
    archived_at,
    draft,
    contacts,
    title,
    preview,
    last_note_created_at,
    sync_depth,
    last_note_source_created_at,
    key,
    icon
   FROM public.thread a;
-- Create "twist_instance_thread_update" view
CREATE VIEW "public"."twist_instance_thread_update" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
  "created_by",
  "updated_by",
  "sync_depth",
  "archived_at",
  "priority_id",
  "draft",
  "contacts",
  "title",
  "preview",
  "priority_title",
  "tags"
) AS SELECT a.created_by AS twist_instance_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    a.created_by,
    a.updated_by,
    a.sync_depth,
    a.archived_at,
    tp.priority_id,
    a.draft,
    a.contacts,
    a.title,
    a.preview,
    pc.title AS priority_title,
    at.tags
   FROM public.twist_instance pt
     JOIN public.thread a ON a.created_by = pt.id
     LEFT JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
     LEFT JOIN public.priority pc ON pc.id = tp.priority_id
     LEFT JOIN public.thread_tags at ON at.thread_id = a.id AND at.occurrence IS NULL
  WHERE a.draft = false AND GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) > a.created_at AND public.updated_by_uuid(pt.id) <> a.updated_by::numeric AND pt.archived_at IS NULL AND GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) > pt.created_at
  ORDER BY (GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)));
-- Create "thread" view
CREATE VIEW "user"."thread" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "updated_by",
  "archived_at",
  "priority_id",
  "priority_path",
  "draft",
  "contacts",
  "title",
  "preview",
  "icon",
  "last_note_created_at",
  "last_note_source_created_at",
  "bumped_at",
  "unread",
  "importance",
  "urgency",
  "activity_at",
  "agenda_at"
) AS WITH link_agg AS (
         SELECT link.thread_id,
            max(link.source_created_at) AS source_created_at
           FROM public.link
          GROUP BY link.thread_id
        )
 SELECT tp.user_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone), COALESCE(tu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at) AS archived_at,
    tp.priority_id,
    upe.path AS priority_path,
    a.draft,
    a.contacts,
    a.title,
    a.preview,
    a.icon,
    a.last_note_created_at,
    a.last_note_source_created_at,
    tu.bumped_at,
    COALESCE(tu.read_at IS NULL AND tu.user_id IS NOT NULL, false) AS unread,
    COALESCE(
        CASE
            WHEN tu.read_at IS NULL AND tu.user_id IS NOT NULL THEN tu.importance
            ELSE NULL::smallint
        END, 0::smallint) AS importance,
    COALESCE(
        CASE
            WHEN tu.read_at IS NULL AND tu.user_id IS NOT NULL THEN tu.urgency
            ELSE NULL::text
        END, NULL::text) AS urgency,
    COALESCE(GREATEST(a.last_note_source_created_at, la.source_created_at, tu.bumped_at, ( SELECT
                CASE
                    WHEN COALESCE(upper(s_feed.at), upper(s_feed."on")::timestamp with time zone) <= now() THEN COALESCE(upper(s_feed.at), upper(s_feed."on")::timestamp with time zone)
                    ELSE NULL::timestamp with time zone
                END AS "case"
           FROM public.schedule s_feed
          WHERE s_feed.thread_id = a.id AND s_feed.user_id IS NULL AND s_feed.occurrence IS NULL AND s_feed.archived_at IS NULL
         LIMIT 1)), a.created_at) AS activity_at,
    ( SELECT tstzrange(bounds.lo, GREATEST(bounds.lo, bounds.hi), '[]'::text) AS tstzrange
           FROM ( SELECT COALESCE(LEAST(( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                          WHERE s_lo.thread_id = a.id AND s_lo.user_id IS NULL AND s_lo.archived_at IS NULL
                          ORDER BY (COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone))
                         LIMIT 1), ( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                          WHERE s_lo.thread_id = a.id AND s_lo.user_id = tp.user_id AND s_lo.archived_at IS NULL
                          ORDER BY (COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone))
                         LIMIT 1), ( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                             JOIN public.link l_lo ON l_lo.id = s_lo.link_id
                          WHERE l_lo.thread_id = a.id AND s_lo.user_id IS NULL AND s_lo.archived_at IS NULL
                          ORDER BY (COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone))
                         LIMIT 1)), a.created_at) AS lo,
                    COALESCE(
                        CASE
                            WHEN (EXISTS ( SELECT 1
                               FROM public.schedule s_rec
                              WHERE s_rec.thread_id = a.id AND s_rec.archived_at IS NULL AND s_rec.recurrence_rule IS NOT NULL)) OR (EXISTS ( SELECT 1
                               FROM public.schedule s_rec
                                 JOIN public.link l_rec ON l_rec.id = s_rec.link_id
                              WHERE l_rec.thread_id = a.id AND s_rec.archived_at IS NULL AND s_rec.recurrence_rule IS NOT NULL)) THEN 'infinity'::timestamp with time zone
                            WHEN (EXISTS ( SELECT 1
                               FROM public.schedule s_ub
                              WHERE s_ub.thread_id = a.id AND s_ub.archived_at IS NULL AND (s_ub.at IS NOT NULL OR s_ub."on" IS NOT NULL) AND COALESCE(upper(s_ub.at), upper(s_ub."on")::timestamp with time zone) IS NULL)) OR (EXISTS ( SELECT 1
                               FROM public.schedule s_ub
                                 JOIN public.link l_ub ON l_ub.id = s_ub.link_id
                              WHERE l_ub.thread_id = a.id AND s_ub.archived_at IS NULL AND (s_ub.at IS NOT NULL OR s_ub."on" IS NOT NULL) AND COALESCE(upper(s_ub.at), upper(s_ub."on")::timestamp with time zone) IS NULL)) THEN 'infinity'::timestamp with time zone
                            ELSE GREATEST(( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                              WHERE s_hi.thread_id = a.id AND s_hi.user_id IS NULL AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1), ( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                              WHERE s_hi.thread_id = a.id AND s_hi.user_id = tp.user_id AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1), ( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                                 JOIN public.link l_hi ON l_hi.id = s_hi.link_id
                              WHERE l_hi.thread_id = a.id AND s_hi.user_id IS NULL AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1))
                        END, a.created_at) AS hi) bounds) AS agenda_at
   FROM public.thread a
     JOIN public.thread_priority tp ON tp.thread_id = a.id
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = tp.priority_id
     LEFT JOIN public.thread_unread tu ON tu.user_id = tp.user_id AND tu.thread_id = a.id
     LEFT JOIN link_agg la ON la.thread_id = a.id
  WHERE (a.draft = false OR a.created_by = tp.user_id) AND a.contacts && "user".user_contact_ids(tp.user_id);
-- Create "note_tags" view
CREATE VIEW "user"."note_tags" (
  "user_id",
  "id",
  "updated_at",
  "archived_at",
  "priority_id",
  "priority_path",
  "tags"
) AS SELECT ua.user_id,
    n.id,
    nt.updated_at,
    ua.archived_at,
    ua.priority_id,
    ua.priority_path,
    nt.tags
   FROM public.note_tags nt
     JOIN public.note n ON n.id = nt.note_id
     JOIN "user".thread ua ON ua.id = n.thread_id
  WHERE (n.draft = false OR n.created_by = ua.user_id) AND (n.access_contacts IS NULL OR n.created_by = ua.user_id OR n.access_contacts && "user".user_contact_ids(ua.user_id));
-- Create "thread_tags" view
CREATE VIEW "user"."thread_tags" (
  "user_id",
  "id",
  "archived_at",
  "occurrence",
  "updated_at",
  "priority_id",
  "priority_path",
  "tags"
) AS SELECT ua.user_id,
    ua.id,
    ua.archived_at,
    tt.occurrence,
    tt.updated_at,
    ua.priority_id,
    ua.priority_path,
    tt.tags
   FROM "user".thread ua
     JOIN LATERAL ( SELECT sq.occurrence,
            jsonb_object_agg(sq.tag_id, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL AND jsonb_array_length(sq.actor_ids) > 0) AS tags,
            max(sq.updated_at) AS updated_at
           FROM ( SELECT at.occurrence,
                    at.tag_id,
                    jsonb_agg(at.actor_id) FILTER (WHERE at.archived_at IS NULL) AS actor_ids,
                    max(COALESCE(at.archived_at, at.updated_at)) AS updated_at
                   FROM public.thread_tag at
                  WHERE at.thread_id = ua.id
                  GROUP BY at.occurrence, at.tag_id) sq
          GROUP BY sq.occurrence) tt ON true;
-- Modify "link_x" view
CREATE OR REPLACE VIEW "public"."link_x" (
  "id",
  "created_at",
  "updated_at",
  "thread_id",
  "source",
  "source_created_at",
  "source_priority_root",
  "author_id",
  "twist_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "title",
  "preview",
  "assignee_id",
  "type",
  "status",
  "actions",
  "meta",
  "source_url",
  "logo",
  "channel_id",
  "embedding",
  "match",
  "merged_from_thread_id",
  "priority_id",
  "priority_path"
) AS SELECT l.id,
    l.created_at,
    l.updated_at,
    l.thread_id,
    l.source,
    l.source_created_at,
    l.source_priority_root,
    l.author_id,
    l.twist_id,
    l.created_by,
    l.updated_by,
    l.sync_depth,
    l.title,
    l.preview,
    l.assignee_id,
    l.type,
    l.status,
    l.actions,
    l.meta,
    l.source_url,
    l.logo,
    l.channel_id,
    l.embedding,
    l.match,
    l.merged_from_thread_id,
    l.priority_id,
    pp.path AS priority_path
   FROM public.link l
     LEFT JOIN public.priority pp ON pp.id = l.priority_id;
-- Modify "twist_instance_channel_link_create" view
CREATE OR REPLACE VIEW "public"."twist_instance_channel_link_create" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
  "thread_id",
  "source",
  "source_created_at",
  "author_id",
  "twist_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "title",
  "preview",
  "assignee_id",
  "type",
  "status",
  "actions",
  "meta",
  "channel_id",
  "source_url",
  "priority_id",
  "author_name",
  "author_type",
  "priority_title"
) AS SELECT ptc.twist_instance_id,
    l.id,
    l.created_at,
    l.updated_at,
    l.thread_id,
    l.source,
    l.source_created_at,
    l.author_id,
    l.twist_id,
    l.created_by,
    l.updated_by,
    l.sync_depth,
    l.title,
    l.preview,
    l.assignee_id,
    l.type,
    l.status,
    l.actions,
    l.meta,
    l.channel_id,
    l.source_url,
    tp.priority_id,
    author.name AS author_name,
    author.type AS author_type,
    pc.title AS priority_title
   FROM public.twist_instance_channel ptc
     JOIN public.link l ON l.created_by = ptc.source_twist_instance_id AND l.channel_id = ptc.channel_id
     JOIN public.thread t ON t.id = l.thread_id
     JOIN public.twist_instance pt ON pt.id = ptc.twist_instance_id
     LEFT JOIN public.thread_priority tp ON tp.thread_id = t.id AND tp.user_id = pt.owner_id
     LEFT JOIN public.priority pc ON pc.id = tp.priority_id
     LEFT JOIN public.actor author ON author.id = l.author_id
  WHERE ptc.enabled = true AND pt.archived_at IS NULL AND t.draft = false AND l.created_at > pt.created_at
  ORDER BY l.created_at;
-- Modify "twist_instance_schedule_contact" view
CREATE OR REPLACE VIEW "public"."twist_instance_schedule_contact" (
  "twist_instance_id",
  "schedule_contact_id",
  "schedule_id",
  "contact_id",
  "status",
  "role",
  "archived_at",
  "thread_id",
  "link_id",
  "updated_at",
  "priority_id"
) AS SELECT a.created_by AS twist_instance_id,
    sc.id AS schedule_contact_id,
    sc.schedule_id,
    sc.contact_id,
    sc.status,
    sc.role,
    sc.archived_at,
    s.thread_id,
    s.link_id,
    sc.updated_at,
    tp.priority_id
   FROM public.twist_instance pt
     JOIN public.link l ON l.created_by = pt.id
     JOIN public.thread a ON a.id = l.thread_id
     LEFT JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
     JOIN public.schedule s ON s.link_id = l.id
     JOIN public.schedule_contact sc ON sc.schedule_id = s.id
  WHERE a.draft = false AND pt.archived_at IS NULL AND sc.updated_at > pt.created_at
  ORDER BY sc.updated_at;
-- Modify "twist_instance_thread_read" view
CREATE OR REPLACE VIEW "public"."twist_instance_thread_read" (
  "twist_instance_id",
  "thread_id",
  "user_id",
  "read_at",
  "updated_at",
  "priority_id"
) AS SELECT a.created_by AS twist_instance_id,
    tu.thread_id,
    tu.user_id,
    tu.read_at,
    tu.updated_at,
    tp.priority_id
   FROM public.twist_instance pt
     JOIN public.thread a ON a.created_by = pt.id
     LEFT JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
     JOIN public.thread_unread tu ON tu.thread_id = a.id
  WHERE a.draft = false AND pt.archived_at IS NULL AND tu.read_at IS NOT NULL AND tu.updated_at > pt.created_at
  ORDER BY tu.updated_at;
-- Modify "schedule" view
CREATE OR REPLACE VIEW "user"."schedule" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "archived_at",
  "schedule_user_id",
  "order",
  "at",
  "on",
  "recurrence_rule",
  "duration",
  "recurrence_exdates",
  "occurrence",
  "thread_id",
  "link_id",
  "reason",
  "outstanding_tasks",
  "priority_path",
  "range_at",
  "range_on",
  "contacts"
) AS SELECT tp.user_id,
    s.id,
    s.created_at,
    s.updated_at,
    COALESCE(s.archived_at, upe.archived_at) AS archived_at,
    s.user_id AS schedule_user_id,
    s."order",
    s.at,
    s."on",
    s.recurrence_rule,
    s.duration,
    s.recurrence_exdates,
    s.occurrence,
    s.thread_id,
    s.link_id,
    s.reason,
    s.outstanding_tasks,
    upe.path AS priority_path,
        CASE
            WHEN s.at IS NOT NULL THEN s.at
            ELSE NULL::tstzrange
        END AS range_at,
        CASE
            WHEN s."on" IS NOT NULL THEN s."on"
            ELSE NULL::daterange
        END AS range_on,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', sc.id, 'contact_id', sc.contact_id, 'contact_email', c.email, 'contact_name', c.name, 'contact_user_id', c.user_id, 'status', sc.status, 'role', sc.role, 'archived_at', sc.archived_at, 'updated_at', sc.updated_at) ORDER BY sc.created_at) AS jsonb_agg
           FROM public.schedule_contact sc
             JOIN public.contact c ON c.id = sc.contact_id
          WHERE sc.schedule_id = s.id), '[]'::jsonb) AS contacts
   FROM public.schedule s
     LEFT JOIN public.link l ON l.id = s.link_id
     JOIN public.thread_priority tp ON tp.thread_id = COALESCE(s.thread_id, l.thread_id)
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = tp.priority_id
  WHERE s.user_id IS NULL OR s.user_id = tp.user_id;
-- Modify "twist_instance_channel_note_create" view
CREATE OR REPLACE VIEW "public"."twist_instance_channel_note_create" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "archived_at",
  "thread_id",
  "draft",
  "access_contacts",
  "content",
  "actions",
  "key",
  "mentions",
  "re_note_id",
  "link_id",
  "link_source",
  "link_title",
  "link_type",
  "link_meta",
  "link_channel_id",
  "link_source_url",
  "priority_id",
  "thread_title",
  "thread_created_by",
  "author_name",
  "author_type",
  "tags"
) AS SELECT DISTINCT ON (ptc.twist_instance_id, n.id) ptc.twist_instance_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.sync_depth,
    n.archived_at,
    n.thread_id,
    n.draft,
    n.access_contacts,
    n.content,
    n.actions,
    n.key,
    n.mentions,
    n.re_note_id,
    l.id AS link_id,
    l.source AS link_source,
    l.title AS link_title,
    l.type AS link_type,
    l.meta AS link_meta,
    l.channel_id AS link_channel_id,
    l.source_url AS link_source_url,
    tp.priority_id,
    t.title AS thread_title,
    t.created_by AS thread_created_by,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM public.twist_instance_channel ptc
     JOIN public.link l ON l.created_by = ptc.source_twist_instance_id AND l.channel_id = ptc.channel_id
     JOIN public.thread t ON t.id = l.thread_id
     JOIN public.note n ON n.thread_id = t.id
     JOIN public.twist_instance pt ON pt.id = ptc.twist_instance_id
     LEFT JOIN public.thread_priority tp ON tp.thread_id = t.id AND tp.user_id = pt.owner_id
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE ptc.enabled = true AND pt.archived_at IS NULL AND t.draft = false AND n.draft = false AND n.created_by <> ptc.twist_instance_id AND n.created_at > pt.created_at
  ORDER BY ptc.twist_instance_id, n.id, n.created_at;
-- Modify "priority_tags" view
CREATE OR REPLACE VIEW "public"."priority_tags" (
  "priority_id",
  "tag_id",
  "count",
  "updated_at"
) AS SELECT tp.priority_id,
    at.tag_id,
    count(*) AS count,
    max(COALESCE(at.archived_at, at.updated_at)) AS updated_at
   FROM public.thread_tag at
     JOIN public.thread a ON at.thread_id = a.id
     JOIN public.thread_priority tp ON tp.thread_id = a.id
  WHERE at.archived_at IS NULL AND a.archived_at IS NULL
  GROUP BY tp.priority_id, at.tag_id;
-- Modify "twist_instance_note_update" view
CREATE OR REPLACE VIEW "public"."twist_instance_note_update" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "archived_at",
  "thread_id",
  "draft",
  "access_contacts",
  "content",
  "actions",
  "key",
  "mentions",
  "re_note_id",
  "priority_id",
  "thread_title",
  "thread_created_by",
  "thread_meta",
  "author_name",
  "author_type",
  "tags"
) AS SELECT n.created_by AS twist_instance_id,
    n.id,
    n.created_at,
    GREATEST(n.updated_at, COALESCE(nt.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.sync_depth,
    n.archived_at,
    n.thread_id,
    n.draft,
    n.access_contacts,
    n.content,
    n.actions,
    n.key,
    n.mentions,
    n.re_note_id,
    tp.priority_id,
    a.title AS thread_title,
    a.created_by AS thread_created_by,
    NULL::jsonb AS thread_meta,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM public.twist_instance pt
     JOIN public.note n ON n.created_by = pt.id
     JOIN public.thread a ON a.id = n.thread_id
     LEFT JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE n.draft = false AND n.updated_at > n.created_at AND public.updated_by_uuid(pt.id) <> n.updated_by::numeric AND a.archived_at IS NULL AND pt.archived_at IS NULL AND n.updated_at > pt.created_at
  ORDER BY n.updated_at;
-- Modify "note" view
CREATE OR REPLACE VIEW "user"."note" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "archived_at",
  "thread_id",
  "draft",
  "access_contacts",
  "content",
  "actions",
  "mentions",
  "re_note_id",
  "merged_from_thread_id"
) AS SELECT tp.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.archived_at,
    n.thread_id,
    n.draft,
    n.access_contacts,
    n.content,
    n.actions,
    n.mentions,
    n.re_note_id,
    n.merged_from_thread_id
   FROM public.note n
     JOIN public.thread a ON a.id = n.thread_id
     JOIN public.thread_priority tp ON tp.thread_id = a.id
  WHERE (n.draft = false OR n.created_by = tp.user_id) AND (n.access_contacts IS NULL OR n.created_by = tp.user_id OR n.access_contacts && "user".user_contact_ids(tp.user_id)) AND (a.draft = false OR a.created_by = tp.user_id) AND a.contacts && "user".user_contact_ids(tp.user_id)
UNION ALL
 SELECT tp.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    COALESCE(n.archived_at, n.updated_at) AS archived_at,
    n.thread_id,
    n.draft,
    NULL::uuid[] AS access_contacts,
    NULL::text AS content,
    NULL::jsonb AS actions,
    NULL::uuid[] AS mentions,
    n.re_note_id,
    n.merged_from_thread_id
   FROM public.note n
     JOIN public.thread a ON a.id = n.thread_id
     JOIN public.thread_priority tp ON tp.thread_id = a.id
  WHERE (n.draft = false OR n.created_by = tp.user_id) AND (a.draft = false OR a.created_by = tp.user_id) AND a.contacts && "user".user_contact_ids(tp.user_id) AND n.access_contacts IS NOT NULL AND n.created_by <> tp.user_id AND NOT COALESCE(n.access_contacts, ARRAY[]::uuid[]) && "user".user_contact_ids(tp.user_id);
-- Modify "twist_instance_channel_link_update" view
CREATE OR REPLACE VIEW "public"."twist_instance_channel_link_update" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
  "thread_id",
  "source",
  "source_created_at",
  "author_id",
  "twist_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "title",
  "preview",
  "assignee_id",
  "type",
  "status",
  "actions",
  "meta",
  "channel_id",
  "source_url",
  "priority_id",
  "author_name",
  "author_type",
  "priority_title"
) AS SELECT ptc.twist_instance_id,
    l.id,
    l.created_at,
    l.updated_at,
    l.thread_id,
    l.source,
    l.source_created_at,
    l.author_id,
    l.twist_id,
    l.created_by,
    l.updated_by,
    l.sync_depth,
    l.title,
    l.preview,
    l.assignee_id,
    l.type,
    l.status,
    l.actions,
    l.meta,
    l.channel_id,
    l.source_url,
    tp.priority_id,
    author.name AS author_name,
    author.type AS author_type,
    pc.title AS priority_title
   FROM public.twist_instance_channel ptc
     JOIN public.link l ON l.created_by = ptc.source_twist_instance_id AND l.channel_id = ptc.channel_id
     JOIN public.thread t ON t.id = l.thread_id
     JOIN public.twist_instance pt ON pt.id = ptc.twist_instance_id
     LEFT JOIN public.thread_priority tp ON tp.thread_id = t.id AND tp.user_id = pt.owner_id
     LEFT JOIN public.priority pc ON pc.id = tp.priority_id
     LEFT JOIN public.actor author ON author.id = l.author_id
  WHERE ptc.enabled = true AND pt.archived_at IS NULL AND t.draft = false AND l.updated_at > l.created_at AND public.updated_by_uuid(ptc.twist_instance_id) <> l.updated_by::numeric AND l.updated_at > pt.created_at
  ORDER BY l.updated_at;
-- Modify "twist_instance_link_update" view
CREATE OR REPLACE VIEW "public"."twist_instance_link_update" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
  "thread_id",
  "source",
  "source_created_at",
  "author_id",
  "twist_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "title",
  "preview",
  "assignee_id",
  "type",
  "status",
  "actions",
  "meta",
  "priority_id",
  "author_name",
  "author_type",
  "priority_title"
) AS SELECT l.created_by AS twist_instance_id,
    l.id,
    l.created_at,
    l.updated_at,
    l.thread_id,
    l.source,
    l.source_created_at,
    l.author_id,
    l.twist_id,
    l.created_by,
    l.updated_by,
    l.sync_depth,
    l.title,
    l.preview,
    l.assignee_id,
    l.type,
    l.status,
    l.actions,
    l.meta,
    tp.priority_id,
    author.name AS author_name,
    author.type AS author_type,
    pc.title AS priority_title
   FROM public.twist_instance pt
     JOIN public.link l ON l.created_by = pt.id
     JOIN public.thread t ON t.id = l.thread_id
     LEFT JOIN public.thread_priority tp ON tp.thread_id = t.id AND tp.user_id = pt.owner_id
     LEFT JOIN public.priority pc ON pc.id = tp.priority_id
     LEFT JOIN public.actor author ON author.id = l.author_id
  WHERE t.draft = false AND l.updated_at > l.created_at AND public.updated_by_uuid(pt.id) <> l.updated_by::numeric AND pt.archived_at IS NULL AND l.updated_at > pt.created_at
  ORDER BY l.updated_at;
-- Modify "twist_instance_note_create" view
CREATE OR REPLACE VIEW "public"."twist_instance_note_create" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "archived_at",
  "thread_id",
  "draft",
  "access_contacts",
  "content",
  "actions",
  "key",
  "mentions",
  "re_note_id",
  "priority_id",
  "thread_title",
  "thread_created_by",
  "thread_meta",
  "author_name",
  "author_type",
  "tags"
) AS SELECT pt.id AS twist_instance_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.sync_depth,
    n.archived_at,
    n.thread_id,
    n.draft,
    n.access_contacts,
    n.content,
    n.actions,
    n.key,
    n.mentions,
    n.re_note_id,
    tp.priority_id,
    a.title AS thread_title,
    a.created_by AS thread_created_by,
    NULL::jsonb AS thread_meta,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM public.twist_instance pt
     JOIN public.note n ON pt.id = ANY (n.mentions)
     JOIN public.thread a ON a.id = n.thread_id AND a.archived_at IS NULL
     LEFT JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE n.draft = false AND n.created_by <> pt.id AND public.updated_by_uuid(pt.id) <> n.updated_by::numeric AND pt.archived_at IS NULL AND n.created_at > pt.created_at
  ORDER BY n.created_at;
-- Modify "twist_instance_thread_schedule" view
CREATE OR REPLACE VIEW "public"."twist_instance_thread_schedule" (
  "twist_instance_id",
  "thread_id",
  "schedule_id",
  "user_id",
  "on",
  "at",
  "updated_at",
  "priority_id"
) AS SELECT a.created_by AS twist_instance_id,
    s.thread_id,
    s.id AS schedule_id,
    s.user_id,
    s."on",
    s.at,
    s.updated_at,
    tp.priority_id
   FROM public.twist_instance pt
     JOIN public.thread a ON a.created_by = pt.id
     LEFT JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
     JOIN public.schedule s ON s.thread_id = a.id
  WHERE a.draft = false AND pt.archived_at IS NULL AND s.user_id IS NOT NULL AND s.archived_at IS NULL AND s.updated_at > pt.created_at
  ORDER BY s.updated_at;
-- Modify "link" view
CREATE OR REPLACE VIEW "user"."link" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "thread_id",
  "source",
  "source_created_at",
  "author_id",
  "twist_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "title",
  "preview",
  "assignee_id",
  "type",
  "status",
  "actions",
  "meta",
  "source_url",
  "logo",
  "priority_id",
  "merged_from_thread_id",
  "priority_path"
) AS SELECT COALESCE(tp.user_id, p.user_id) AS user_id,
    l.id,
    l.created_at,
    l.updated_at,
    l.thread_id,
    l.source,
    l.source_created_at,
    l.author_id,
    l.twist_id,
    l.created_by,
    l.updated_by,
    l.sync_depth,
    l.title,
    l.preview,
    l.assignee_id,
    l.type,
    l.status,
    l.actions,
    l.meta,
    l.source_url,
    l.logo,
    COALESCE(tp.priority_id, l.priority_id) AS priority_id,
    l.merged_from_thread_id,
    COALESCE(upe.path, pp.path) AS priority_path
   FROM public.link l
     LEFT JOIN public.thread_priority tp ON tp.thread_id = l.thread_id
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = tp.priority_id
     LEFT JOIN public.priority pp ON pp.id = l.priority_id AND l.thread_id IS NULL
     LEFT JOIN public.priority p ON p.id = l.priority_id AND l.thread_id IS NULL
  WHERE tp.user_id IS NOT NULL OR p.user_id IS NOT NULL;
-- Modify "thread_association" view
CREATE OR REPLACE VIEW "user"."thread_association" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "archived_at",
  "parent_thread_id",
  "child_thread_id",
  "order"
) AS SELECT tp.user_id,
    ta.id,
    ta.created_at,
    ta.updated_at,
    ta.archived_at,
    ta.parent_thread_id,
    ta.child_thread_id,
    ta."order"
   FROM public.thread_association ta
     JOIN public.thread_priority tp ON tp.thread_id = ta.parent_thread_id;
-- Drop "populate_thread_priority_for_author" function
DROP FUNCTION "public"."populate_thread_priority_for_author";
-- Drop "sync_thread_contacts" function
DROP FUNCTION "public"."sync_thread_contacts";
