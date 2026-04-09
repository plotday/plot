-- Drop "priority_twist_channel_note_create" view
DROP VIEW "public"."priority_twist_channel_note_create";
-- Drop "priority_twist_note_update" view
DROP VIEW "public"."priority_twist_note_update";
-- Drop "priority_twist_note_create" view
DROP VIEW "public"."priority_twist_note_create";
-- Drop "note" view
DROP VIEW "user"."note";
-- Drop "note_tags" view
DROP VIEW "user"."note_tags";
-- Modify "note" table: add new column first, migrate data, then drop old
ALTER TABLE "public"."note" ADD COLUMN "access_contacts" uuid[] NULL;

-- Data migration: note.private → note.access_contacts
-- Private notes: set access_contacts to empty array (author only) to preserve private behavior
UPDATE "public"."note" SET access_contacts = ARRAY[]::uuid[]
WHERE private = TRUE;

-- Split note.mentions: move user contacts to access_contacts, keep twist IDs in mentions
UPDATE "public"."note" n SET
    access_contacts = COALESCE(access_contacts, ARRAY[]::uuid[]) || (
        SELECT COALESCE(array_agg(m), ARRAY[]::uuid[])
        FROM unnest(n.mentions) m
        WHERE EXISTS (SELECT 1 FROM contact c WHERE c.id = m)
    )
WHERE n.mentions IS NOT NULL
  AND EXISTS (
    SELECT 1 FROM unnest(n.mentions) m
    WHERE EXISTS (SELECT 1 FROM contact c WHERE c.id = m)
  );

-- Remove user contacts from mentions (keep only twist IDs)
UPDATE "public"."note" n SET
    mentions = (
        SELECT array_agg(m)
        FROM unnest(n.mentions) m
        WHERE EXISTS (SELECT 1 FROM priority_twist pt WHERE pt.id = m)
    )
WHERE n.mentions IS NOT NULL
  AND EXISTS (
    SELECT 1 FROM unnest(n.mentions) m
    WHERE EXISTS (SELECT 1 FROM contact c WHERE c.id = m)
  );

-- NOTE: DROP COLUMN "private" moved to end of migration (after function recreation)
-- Create index "idx_note_access_contacts" to table: "note"
CREATE INDEX "idx_note_access_contacts" ON "public"."note" USING GIN ("access_contacts") WHERE (access_contacts IS NOT NULL);
-- Set comment to column: "mentions" on table: "note"
COMMENT ON COLUMN "public"."note"."mentions" IS 'Array of priority_twist_ids (twists and connectors) mentioned in this note. Used for dispatch routing only — user visibility is handled by access_contacts.';
-- Set comment to column: "access_contacts" on table: "note"
COMMENT ON COLUMN "public"."note"."access_contacts" IS 'Restricts note visibility within thread viewers. NULL = all thread viewers can see, empty array = author only, array of contact_ids = author + listed contacts.';
-- Drop "priority_twist_thread_update" view
DROP VIEW "public"."priority_twist_thread_update";
-- Drop "thread_tags" view
DROP VIEW "user"."thread_tags";
-- Drop "thread" view
DROP VIEW "user"."thread";
-- Drop "thread_x" view
DROP VIEW "public"."thread_x";
-- Modify "thread" table: add new columns first, migrate data, then drop old
ALTER TABLE "public"."thread" ADD COLUMN "access" text NOT NULL DEFAULT 'members', ADD COLUMN "access_contacts" uuid[] NULL;

-- Data migration: thread.private → thread.access
-- Identify priorities with viewers for context-dependent migration
CREATE TEMPORARY TABLE _priorities_with_viewers AS
SELECT DISTINCT pu.priority_id
FROM priority_user pu
WHERE pu.role = 'viewer' AND pu.archived_at IS NULL;

-- Priorities with viewers: private=false → access='public'
UPDATE "public"."thread" SET access = 'public'
WHERE private = FALSE
  AND priority_id IN (SELECT priority_id FROM _priorities_with_viewers);

-- Other priorities: private=true → access='restricted'
UPDATE "public"."thread" SET access = 'restricted'
WHERE private = TRUE
  AND priority_id NOT IN (SELECT priority_id FROM _priorities_with_viewers);

-- Priorities with viewers: private=true stays as access='members' (the default)
-- Other priorities: private=false stays as access='members' (the default)

-- Thread access_contacts: for restricted threads, aggregate user contacts from note access_contacts
UPDATE "public"."thread" t SET
    access_contacts = sub.contacts
FROM (
    SELECT n.thread_id, COALESCE(array_agg(DISTINCT ac), ARRAY[]::uuid[]) AS contacts
    FROM "public"."note" n, unnest(n.access_contacts) ac
    WHERE n.access_contacts IS NOT NULL AND array_length(n.access_contacts, 1) > 0
    GROUP BY n.thread_id
) sub
WHERE t.id = sub.thread_id AND t.access = 'restricted';

DROP TABLE _priorities_with_viewers;

ALTER TABLE "public"."thread" ADD CONSTRAINT "thread_access_valid" CHECK (access = ANY (ARRAY['public'::text, 'members'::text, 'restricted'::text]));
-- NOTE: DROP COLUMN "private" moved to end of migration (after function recreation)
-- Create index "idx_thread_access" to table: "thread"
CREATE INDEX "idx_thread_access" ON "public"."thread" ("access") WHERE (access <> 'public'::text);
-- Create index "idx_thread_access_contacts" to table: "thread"
CREATE INDEX "idx_thread_access_contacts" ON "public"."thread" USING GIN ("access_contacts") WHERE (access_contacts IS NOT NULL);
-- Set comment to column: "access" on table: "thread"
COMMENT ON COLUMN "public"."thread"."access" IS 'Access level: public (everyone in priority), members (members only), restricted (author + access_contacts only). Default is members, which equals public in priorities without viewers.';
-- Set comment to column: "access_contacts" on table: "thread"
COMMENT ON COLUMN "public"."thread"."access_contacts" IS 'Array of contact_ids granted additional access beyond the base access level. For members access, these are viewer-role contacts. For restricted access, these are the only contacts who can see the thread (besides the author).';
-- Modify "apply_default_thread_icon" function
CREATE OR REPLACE FUNCTION "public"."apply_default_thread_icon" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_default_icon text;
BEGIN
    -- Apply when icon is unset or is a default sub-type auto-assigned by the app
    IF (NEW.icon IS NULL OR NEW.icon IN ('notes', 'discussion')) AND NEW.access != 'restricted' THEN
        SELECT
            default_thread_icon INTO v_default_icon
        FROM
            priority
        WHERE
            id = NEW.priority_id;
        IF v_default_icon IS NOT NULL THEN
            NEW.icon := v_default_icon;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
-- Modify "search_notes_and_links" function
CREATE OR REPLACE FUNCTION "public"."search_notes_and_links" ("query_embedding" text, "scope_priority_id" uuid, "requesting_user_id" uuid, "exclude_created_by" uuid DEFAULT NULL::uuid, "similarity_threshold" double precision DEFAULT 0.3, "match_limit" integer DEFAULT 20) RETURNS TABLE ("result_type" text, "result_id" uuid, "thread_id" uuid, "thread_title" text, "priority_id" uuid, "priority_title" text, "content" text, "title" text, "source_url" text, "similarity" double precision) LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    SELECT * FROM (
        -- Notes
        SELECT 'note'::text, n.id, n.thread_id, t.title, t.priority_id,
               p.title, n.content, NULL::text, NULL::text,
               (1 - (n.embedding <=> query_embedding::halfvec))::float AS similarity
        FROM note n
        JOIN thread t ON t.id = n.thread_id
        JOIN priority p ON p.id = t.priority_id
        JOIN priority_child pc ON pc.priority_id = scope_priority_id
                              AND pc.child_id = t.priority_id
        WHERE n.embedding IS NOT NULL
          AND n.archived_at IS NULL AND n.draft = FALSE
          AND t.archived_at IS NULL
          AND (t.access = 'public' AND n.access_contacts IS NULL OR n.created_by = requesting_user_id OR t.created_by = requesting_user_id)
          AND (exclude_created_by IS NULL OR n.created_by != exclude_created_by)
          AND (1 - (n.embedding <=> query_embedding::halfvec)) >= similarity_threshold

        UNION ALL

        -- Links
        SELECT 'link'::text, l.id, l.thread_id, t.title, t.priority_id,
               p.title, l.preview, l.title, l.source_url,
               (1 - (l.embedding <=> query_embedding::halfvec))::float AS similarity
        FROM link l
        JOIN thread t ON t.id = l.thread_id
        JOIN priority p ON p.id = t.priority_id
        JOIN priority_child pc ON pc.priority_id = scope_priority_id
                              AND pc.child_id = t.priority_id
        WHERE l.embedding IS NOT NULL AND l.thread_id IS NOT NULL
          AND t.archived_at IS NULL
          AND (t.access = 'public' OR t.created_by = requesting_user_id)
          AND (1 - (l.embedding <=> query_embedding::halfvec)) >= similarity_threshold
    ) combined
    ORDER BY combined.similarity DESC
    LIMIT match_limit;
END;
$$;
-- Modify "sync_twist_for_note" function
CREATE OR REPLACE FUNCTION "public"."sync_twist_for_note" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_create_timestamp timestamptz;
    v_update_timestamp timestamptz;
    v_priority_twist_id uuid;
BEGIN
    -- Determine timestamps for create and update operations
    IF TG_OP = 'INSERT' THEN
        -- For inserts, all non-draft notes on non-draft threads are creates
        SELECT
            MAX(n.created_at) INTO v_create_timestamp
        FROM
            new_table n
            JOIN thread a ON a.id = n.thread_id
        WHERE
            n.draft = FALSE
            AND a.draft = FALSE;
    ELSE
        -- For UPDATE, check for "published" rows (draft true→false) vs regular updates
        -- "Published" rows: draft changed from TRUE to FALSE - treat as create
        SELECT
            MAX(n.updated_at) INTO v_create_timestamp
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN thread a ON a.id = n.thread_id
        WHERE
            o.draft = TRUE
            AND n.draft = FALSE
            AND a.draft = FALSE;
        -- Regular updated rows: was already published (not draft) and still not draft
        -- Only consider rows where meaningful fields actually changed, to avoid
        -- unnecessary priority_twist_sync updates from no-op upserts.
        SELECT
            MAX(n.updated_at) INTO v_update_timestamp
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN thread a ON a.id = n.thread_id
        WHERE
            o.draft = FALSE
            AND n.draft = FALSE
            AND a.draft = FALSE
            AND (n.content IS DISTINCT FROM o.content
                OR n.author_id IS DISTINCT FROM o.author_id
                OR n.source_created_at IS DISTINCT FROM o.source_created_at
                OR n.archived_at IS DISTINCT FROM o.archived_at
                OR n.re_note_id IS DISTINCT FROM o.re_note_id
                OR n.mentions IS DISTINCT FROM o.mentions
                OR n.actions IS DISTINCT FROM o.actions
                OR n.draft IS DISTINCT FROM o.draft
                OR n.access_contacts IS DISTINCT FROM o.access_contacts
                OR n.updated_by IS DISTINCT FROM o.updated_by);
    END IF;
    -- Exit early if all changes were to draft notes or notes on draft threads
    IF v_create_timestamp IS NULL AND v_update_timestamp IS NULL THEN
        RETURN NULL;
    END IF;
    -- Process CREATE operations (new inserts or published drafts)
    -- For creates: track sync state for twists that are mentioned in the note
    -- Split into separate branches to avoid referencing old_table during INSERT
    IF v_create_timestamp IS NOT NULL THEN
        IF TG_OP = 'INSERT' THEN
            -- INSERT: no old_table reference, all non-draft notes on non-draft threads are creates
            FOR v_priority_twist_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN thread a ON a.id = n.thread_id
                JOIN priority p_child ON p_child.id = a.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN priority_twist pct ON pct.priority_id = p_parent.id
            WHERE
                n.draft = FALSE
                AND a.draft = FALSE
                AND pct.archived_at IS NULL
                AND n.created_by != pct.id
                -- Only route to twists mentioned in this note
                AND pct.id = ANY (n.mentions)

            UNION

            -- Direct match for account-based sources (NULL priority_id)
            SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN priority_twist pct ON pct.id = ANY (n.mentions)
            WHERE
                n.draft = FALSE
                AND pct.priority_id IS NULL
                AND pct.archived_at IS NULL
                AND n.created_by != pct.id

                    ORDER BY
                        id LOOP
                        INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                            VALUES (v_priority_twist_id, 'note', 'create', v_create_timestamp)
                        ON CONFLICT (priority_twist_id, entity, operation)
                            DO UPDATE SET
                                last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
                    END LOOP;
        ELSE
            -- UPDATE (publishing draft): can reference old_table for draft true→false check
            FOR v_priority_twist_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN old_table o ON o.id = n.id
                JOIN thread a ON a.id = n.thread_id
                JOIN priority p_child ON p_child.id = a.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN priority_twist pct ON pct.priority_id = p_parent.id
            WHERE
                o.draft = TRUE
                AND n.draft = FALSE
                AND a.draft = FALSE
                AND pct.archived_at IS NULL
                AND n.created_by != pct.id
                -- Only route to twists mentioned in this note
                AND pct.id = ANY (n.mentions)

            UNION

            -- Direct match for account-based sources (NULL priority_id)
            SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN old_table o ON o.id = n.id
                JOIN priority_twist pct ON pct.id = ANY (n.mentions)
            WHERE
                o.draft = TRUE
                AND n.draft = FALSE
                AND pct.priority_id IS NULL
                AND pct.archived_at IS NULL
                AND n.created_by != pct.id

                    ORDER BY
                        id LOOP
                        INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                            VALUES (v_priority_twist_id, 'note', 'create', v_create_timestamp)
                        ON CONFLICT (priority_twist_id, entity, operation)
                            DO UPDATE SET
                                last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
                    END LOOP;
        END IF;
    END IF;
    -- Process UPDATE operations (regular updates to already-published notes)
    -- For updates: track sync state for twist that created the note
    IF v_update_timestamp IS NOT NULL THEN
        FOR v_priority_twist_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN thread a ON a.id = n.thread_id
            JOIN priority p_child ON p_child.id = a.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN priority_twist pct ON pct.priority_id = p_parent.id
        WHERE
            n.draft = FALSE
            AND o.draft = FALSE
            AND a.draft = FALSE
            AND pct.archived_at IS NULL
            -- Track sync for note creator
            AND n.created_by = pct.id

        UNION

        -- Direct match for account-based sources (NULL priority_id)
        SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN priority_twist pct ON n.created_by = pct.id
        WHERE
            n.draft = FALSE
            AND o.draft = FALSE
            AND pct.priority_id IS NULL
            AND pct.archived_at IS NULL

        ORDER BY
            id LOOP
                INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                    VALUES (v_priority_twist_id, 'note', 'update', v_update_timestamp)
                ON CONFLICT (priority_twist_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
            END LOOP;
    END IF;
    RETURN NULL;
END;
$$;
-- Modify "sync_twist_for_thread" function
CREATE OR REPLACE FUNCTION "public"."sync_twist_for_thread" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_create_timestamp timestamptz;
    v_update_timestamp timestamptz;
    v_priority_twist_id uuid;
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
        -- unnecessary priority_twist_sync updates from no-op upserts (which cause
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
                OR n.access IS DISTINCT FROM o.access
                OR n.access_contacts IS DISTINCT FROM o.access_contacts
                OR n.icon IS DISTINCT FROM o.icon
                OR n.priority_id IS DISTINCT FROM o.priority_id
                OR n.updated_by IS DISTINCT FROM o.updated_by);
    END IF;
    -- Exit early if all changes were to draft threads (nothing to sync)
    IF v_create_timestamp IS NULL AND v_update_timestamp IS NULL THEN
        RETURN NULL;
    END IF;
    -- Process CREATE operations (new inserts or published drafts)
    -- Split into separate branches to avoid referencing old_table during INSERT
    IF v_create_timestamp IS NOT NULL THEN
        IF TG_OP = 'INSERT' THEN
            -- INSERT: no old_table reference, all non-draft rows are creates
            FOR v_priority_twist_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN priority p_child ON p_child.id = n.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN priority_twist pct ON pct.priority_id = p_parent.id
            WHERE
                n.draft = FALSE
                AND pct.archived_at IS NULL
                -- Track sync for the twist that created this thread
                AND n.created_by = pct.id

            UNION

            -- Direct match for account-based sources (NULL priority_id)
            SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN priority_twist pct ON n.created_by = pct.id
            WHERE
                n.draft = FALSE
                AND pct.priority_id IS NULL
                AND pct.archived_at IS NULL

            ORDER BY
                id LOOP
                    INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                        VALUES (v_priority_twist_id, 'thread', 'create', v_create_timestamp)
                    ON CONFLICT (priority_twist_id, entity, operation)
                        DO UPDATE SET
                            last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
                END LOOP;
        ELSE
            -- UPDATE (publishing draft): can reference old_table for draft true→false check
            FOR v_priority_twist_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN old_table o ON o.id = n.id
                JOIN priority p_child ON p_child.id = n.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN priority_twist pct ON pct.priority_id = p_parent.id
            WHERE
                o.draft = TRUE
                AND n.draft = FALSE
                AND pct.archived_at IS NULL
                -- Track sync for the twist that created this thread
                AND n.created_by = pct.id

            UNION

            -- Direct match for account-based sources (NULL priority_id)
            SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN old_table o ON o.id = n.id
                JOIN priority_twist pct ON n.created_by = pct.id
            WHERE
                o.draft = TRUE
                AND n.draft = FALSE
                AND pct.priority_id IS NULL
                AND pct.archived_at IS NULL

            ORDER BY
                id LOOP
                    INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                        VALUES (v_priority_twist_id, 'thread', 'create', v_create_timestamp)
                    ON CONFLICT (priority_twist_id, entity, operation)
                        DO UPDATE SET
                            last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
                END LOOP;
        END IF;
    END IF;
    -- Process UPDATE operations (regular updates to already-published threads)
    IF v_update_timestamp IS NOT NULL THEN
        FOR v_priority_twist_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN priority p_child ON p_child.id = n.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN priority_twist pct ON pct.priority_id = p_parent.id
        WHERE
            n.draft = FALSE
            AND o.draft = FALSE
            AND pct.archived_at IS NULL
            -- Track sync for the twist that created this thread
            AND n.created_by = pct.id

        UNION

        -- Direct match for account-based sources (NULL priority_id)
        SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN priority_twist pct ON n.created_by = pct.id
        WHERE
            n.draft = FALSE
            AND o.draft = FALSE
            AND pct.priority_id IS NULL
            AND pct.archived_at IS NULL

        ORDER BY
            id LOOP
                INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                    VALUES (v_priority_twist_id, 'thread', 'update', v_update_timestamp)
                ON CONFLICT (priority_twist_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
            END LOOP;
    END IF;
    RETURN NULL;
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
        VALUES (v_id, v_created_by, v_priority_id, COALESCE(p_thread ->> 'title', p_defaults ->> 'title'), COALESCE(p_thread ->> 'preview', p_defaults ->> 'preview'), COALESCE((p_thread ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, 0), COALESCE((p_thread ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint), COALESCE(p_thread ->> 'access', p_defaults ->> 'access', 'members'), CASE WHEN p_thread ? 'access_contacts' THEN (SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'access_contacts') elem) WHEN p_defaults ? 'access_contacts' THEN (SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'access_contacts') elem) ELSE NULL END, COALESCE((p_thread ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, FALSE), COALESCE(p_thread ->> 'key', p_defaults ->> 'key'), COALESCE(p_thread ->> 'icon', p_defaults ->> 'icon'))
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
                CASE WHEN p_thread ? 'access_contacts' THEN
                    (SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'access_contacts') elem)
                WHEN p_defaults ? 'access_contacts' THEN
                    (SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'access_contacts') elem)
                ELSE thread.access_contacts END
            ELSE
                CASE WHEN p_thread ? 'access_contacts' THEN
                    (SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'access_contacts') elem)
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
    RETURN v_result;
END;
$$;
-- Drop "upsert_note" function
DROP FUNCTION "user"."upsert_note" (uuid, uuid, uuid, uuid, integer, timestamptz, uuid, boolean, boolean, text, jsonb, uuid[], uuid, timestamptz, text, uuid);
-- Create "upsert_note" function
CREATE FUNCTION "user"."upsert_note" ("user_id" uuid, "p_id" uuid, "p_author_id" uuid, "p_created_by" uuid, "p_updated_by" integer, "p_archived_at" timestamptz, "p_thread_id" uuid, "p_draft" boolean, "p_access_contacts" uuid[], "p_content" text, "p_actions" jsonb, "p_mentions" uuid[], "p_re_note_id" uuid, "p_source_created_at" timestamptz, "p_key" text, "p_merged_from_thread_id" uuid DEFAULT NULL::uuid) RETURNS "public"."note" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_priority_id uuid;
    v_created_by uuid;
    v_author_id uuid;
    v_thread_author_id uuid;
    v_thread_access text;
    v_thread_created_by uuid;
    v_thread_access_contacts uuid[];
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
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

    -- Check thread access
    SELECT access, created_by, access_contacts
    INTO v_thread_access, v_thread_created_by, v_thread_access_contacts
    FROM thread WHERE id = p_thread_id;

    IF v_thread_access != 'public' THEN
        IF v_thread_created_by != upsert_note.user_id
           AND NOT (v_thread_access = 'members' AND "user".get_effective_role(user_id, v_priority_id) = 'member')
           AND NOT ("user".user_contact_id(upsert_note.user_id) = ANY(COALESCE(v_thread_access_contacts, ARRAY[]::uuid[])))
        THEN
            RAISE EXCEPTION 'Access denied to private thread';
        END IF;
    END IF;

    -- Viewer enforcement: in public threads, force note to be author-only
    IF "user".get_effective_role(user_id, v_priority_id) = 'viewer' THEN
        IF v_thread_access = 'public' THEN
            p_access_contacts := ARRAY[]::uuid[];
        END IF;
        -- In non-public threads: keep whatever access_contacts was passed (default NULL = all thread viewers)
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
                priority_twist pt
            WHERE
                pt.id = v_created_by
                AND pt.owner_id = upsert_note.user_id) THEN
            RAISE EXCEPTION 'created_by must be user or owned priority_twist';
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
-- Create "priority_twist_channel_note_create" view
CREATE VIEW "public"."priority_twist_channel_note_create" (
  "priority_twist_id",
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
) AS SELECT DISTINCT ON (ptc.priority_twist_id, n.id) ptc.priority_twist_id,
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
    t.priority_id,
    t.title AS thread_title,
    t.created_by AS thread_created_by,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM public.priority_twist_channel ptc
     JOIN public.link l ON l.created_by = ptc.source_priority_twist_id AND l.channel_id = ptc.channel_id
     JOIN public.thread t ON t.id = l.thread_id
     JOIN public.note n ON n.thread_id = t.id
     JOIN public.priority_twist pt ON pt.id = ptc.priority_twist_id
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.id = t.priority_id AND pc.path OPERATOR(public.<@) pp.path
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE ptc.enabled = true AND pt.archived_at IS NULL AND t.draft = false AND n.draft = false AND n.created_by <> ptc.priority_twist_id AND n.created_at > pt.created_at
  ORDER BY ptc.priority_twist_id, n.id, n.created_at;
-- Create "priority_twist_note_update" view
CREATE VIEW "public"."priority_twist_note_update" (
  "priority_twist_id",
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
) AS SELECT n.created_by AS priority_twist_id,
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
    a.priority_id,
    a.title AS thread_title,
    a.created_by AS thread_created_by,
    NULL::jsonb AS thread_meta,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM public.priority_twist pt
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
     JOIN public.thread a ON a.priority_id = pc.id
     JOIN public.note n ON a.id = n.thread_id
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE n.draft = false AND n.updated_at > n.created_at AND public.updated_by_uuid(pt.id) <> n.updated_by::numeric AND a.archived_at IS NULL AND pt.archived_at IS NULL AND n.updated_at > pt.created_at
  ORDER BY n.updated_at;
-- Create "priority_twist_note_create" view
CREATE VIEW "public"."priority_twist_note_create" (
  "priority_twist_id",
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
) AS SELECT pt.id AS priority_twist_id,
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
    a.priority_id,
    a.title AS thread_title,
    a.created_by AS thread_created_by,
    NULL::jsonb AS thread_meta,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM public.priority_twist pt
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
     JOIN public.thread a ON a.priority_id = pc.id AND a.archived_at IS NULL
     JOIN public.note n ON n.thread_id = a.id AND (pt.id = ANY (n.mentions))
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE n.draft = false AND n.created_by <> pt.id AND public.updated_by_uuid(pt.id) <> n.updated_by::numeric AND pt.archived_at IS NULL AND n.created_at > pt.created_at
UNION ALL
 SELECT pt.id AS priority_twist_id,
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
    a.priority_id,
    a.title AS thread_title,
    a.created_by AS thread_created_by,
    NULL::jsonb AS thread_meta,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM public.priority_twist pt
     JOIN public.note n ON pt.id = ANY (n.mentions)
     JOIN public.thread a ON a.id = n.thread_id AND a.archived_at IS NULL
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE pt.priority_id IS NULL AND n.draft = false AND n.created_by <> pt.id AND public.updated_by_uuid(pt.id) <> n.updated_by::numeric AND pt.archived_at IS NULL AND n.created_at > pt.created_at
  ORDER BY 3;
-- Create "priority_twist_thread_update" view
CREATE VIEW "public"."priority_twist_thread_update" (
  "priority_twist_id",
  "id",
  "created_at",
  "updated_at",
  "created_by",
  "updated_by",
  "sync_depth",
  "archived_at",
  "priority_id",
  "draft",
  "access",
  "access_contacts",
  "title",
  "preview",
  "priority_title",
  "tags"
) AS SELECT a.created_by AS priority_twist_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    a.created_by,
    a.updated_by,
    a.sync_depth,
    a.archived_at,
    a.priority_id,
    a.draft,
    a.access,
    a.access_contacts,
    a.title,
    a.preview,
    pc.title AS priority_title,
    at.tags
   FROM public.priority_twist pt
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
     JOIN public.thread a ON a.priority_id = pc.id
     LEFT JOIN public.thread_tags at ON at.thread_id = a.id AND at.occurrence IS NULL
  WHERE a.draft = false AND pt.id = a.created_by AND GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) > a.created_at AND public.updated_by_uuid(pt.id) <> a.updated_by::numeric AND pt.archived_at IS NULL AND GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) > pt.created_at
  ORDER BY (GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)));
-- Create "thread_x" view
CREATE VIEW "public"."thread_x" (
  "id",
  "created_at",
  "updated_at",
  "created_by",
  "updated_by",
  "archived_at",
  "priority_id",
  "draft",
  "access",
  "access_contacts",
  "title",
  "preview",
  "last_note_created_at",
  "sync_depth",
  "last_note_source_created_at",
  "key",
  "icon",
  "priority_path"
) AS SELECT a.id,
    a.created_at,
    a.updated_at,
    a.created_by,
    a.updated_by,
    a.archived_at,
    a.priority_id,
    a.draft,
    a.access,
    a.access_contacts,
    a.title,
    a.preview,
    a.last_note_created_at,
    a.sync_depth,
    a.last_note_source_created_at,
    a.key,
    a.icon,
    p.path AS priority_path
   FROM public.thread a
     JOIN public.priority p ON p.id = a.priority_id;
-- Create "note" view
CREATE VIEW "user"."note" (
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
) AS SELECT upe.user_id,
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
     JOIN "user".priority_expanded upe ON upe.priority_id = a.priority_id
  WHERE (n.draft = false OR n.created_by = upe.user_id) AND (n.access_contacts IS NULL OR n.created_by = upe.user_id OR ("user".user_contact_id(upe.user_id) = ANY (n.access_contacts))) AND (a.draft = false OR a.created_by = upe.user_id) AND
        CASE
            WHEN a.access = 'public'::text THEN true
            WHEN a.created_by = upe.user_id THEN true
            WHEN a.access = 'members'::text AND upe.role = 'member'::text THEN true
            WHEN "user".user_contact_id(upe.user_id) = ANY (a.access_contacts) THEN true
            ELSE false
        END
UNION ALL
 SELECT upe.user_id,
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
     JOIN "user".priority_expanded upe ON upe.priority_id = a.priority_id
  WHERE (n.draft = false OR n.created_by = upe.user_id) AND (a.draft = false OR a.created_by = upe.user_id) AND (n.access_contacts IS NOT NULL AND n.created_by <> upe.user_id AND NOT ("user".user_contact_id(upe.user_id) = ANY (COALESCE(n.access_contacts, ARRAY[]::uuid[]))) OR a.access <> 'public'::text AND a.created_by <> upe.user_id AND NOT (a.access = 'members'::text AND upe.role = 'member'::text) AND NOT ("user".user_contact_id(upe.user_id) = ANY (COALESCE(a.access_contacts, ARRAY[]::uuid[]))));
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
  "access",
  "access_contacts",
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
 SELECT upe.user_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone), COALESCE(tu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at) AS archived_at,
    a.priority_id,
    upe.path AS priority_path,
    a.draft,
    a.access,
    a.access_contacts,
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
                          WHERE s_lo.thread_id = a.id AND s_lo.user_id = upe.user_id AND s_lo.archived_at IS NULL
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
                              WHERE s_hi.thread_id = a.id AND s_hi.user_id = upe.user_id AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1), ( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                                 JOIN public.link l_hi ON l_hi.id = s_hi.link_id
                              WHERE l_hi.thread_id = a.id AND s_hi.user_id IS NULL AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1))
                        END, a.created_at) AS hi) bounds) AS agenda_at
   FROM public.thread_x a
     JOIN "user".priority_expanded upe ON a.priority_id = upe.priority_id
     LEFT JOIN public.thread_unread tu ON tu.user_id = upe.user_id AND tu.thread_id = a.id
     LEFT JOIN link_agg la ON la.thread_id = a.id
  WHERE (a.draft = false OR a.created_by = upe.user_id) AND
        CASE
            WHEN a.access = 'public'::text THEN true
            WHEN a.created_by = upe.user_id THEN true
            WHEN a.access = 'members'::text AND upe.role = 'member'::text THEN true
            WHEN "user".user_contact_id(upe.user_id) = ANY (a.access_contacts) THEN true
            ELSE false
        END
UNION ALL
 SELECT upe.user_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at, a.updated_at) AS archived_at,
    a.priority_id,
    upe.path AS priority_path,
    a.draft,
    a.access,
    NULL::uuid[] AS access_contacts,
    NULL::text AS title,
    NULL::text AS preview,
    a.icon,
    a.last_note_created_at,
    a.last_note_source_created_at,
    NULL::timestamp with time zone AS bumped_at,
    false AS unread,
    0::smallint AS importance,
    NULL::text AS urgency,
    a.created_at AS activity_at,
    tstzrange(a.created_at, a.created_at, '[]'::text) AS agenda_at
   FROM public.thread_x a
     JOIN "user".priority_expanded upe ON a.priority_id = upe.priority_id
  WHERE (a.draft = false OR a.created_by = upe.user_id) AND a.access <> 'public'::text AND a.created_by <> upe.user_id AND NOT (a.access = 'members'::text AND upe.role = 'member'::text) AND NOT ("user".user_contact_id(upe.user_id) = ANY (COALESCE(a.access_contacts, ARRAY[]::uuid[])));
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
  WHERE (n.draft = false OR n.created_by = ua.user_id) AND (n.access_contacts IS NULL OR n.created_by = ua.user_id OR ("user".user_contact_id(ua.user_id) = ANY (n.access_contacts)));
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
-- Modify "priority_unread" view
CREATE OR REPLACE VIEW "user"."priority_unread" (
  "user_id",
  "priority_id",
  "unread",
  "updated_at"
) AS SELECT upe.user_id,
    upe.priority_id,
    true AS unread,
    max(tu.updated_at) AS updated_at
   FROM "user".priority_expanded upe
     JOIN public.thread a ON a.priority_id = upe.priority_id AND a.archived_at IS NULL AND (a.draft = false OR a.created_by = upe.user_id) AND
        CASE
            WHEN a.access = 'public'::text THEN true
            WHEN a.created_by = upe.user_id THEN true
            WHEN a.access = 'members'::text AND upe.role = 'member'::text THEN true
            WHEN "user".user_contact_id(upe.user_id) = ANY (a.access_contacts) THEN true
            ELSE false
        END
     JOIN public.thread_unread tu ON tu.user_id = upe.user_id AND tu.thread_id = a.id AND tu.read_at IS NULL
  GROUP BY upe.user_id, upe.priority_id;
-- Drop "get_thread_mentions" function
DROP FUNCTION "public"."get_thread_mentions";
-- Drop "mentioned_in_thread" function
DROP FUNCTION "user"."mentioned_in_thread";
-- Now safe to drop old columns (all functions/views have been recreated)
ALTER TABLE "public"."note" DROP COLUMN "private";
ALTER TABLE "public"."thread" DROP COLUMN "private";
