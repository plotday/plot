-- Modify "twist_sync_note_tag_update" trigger
CREATE OR REPLACE TRIGGER "twist_sync_note_tag_update" AFTER UPDATE ON "public"."note_tag" REFERENCING OLD TABLE AS "old_table" NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_twist_for_note_tag"();
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
                OR n.private IS DISTINCT FROM o.private
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
-- Modify "sync_twist_for_note_tag" function
CREATE OR REPLACE FUNCTION "public"."sync_twist_for_note_tag" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_priority_twist_id uuid;
BEGIN
    -- Only consider tags on non-draft notes on non-draft threads.
    -- For UPDATE, only consider rows where tag state actually changed to avoid
    -- unnecessary priority_twist_sync updates from no-op upserts.
    IF TG_OP = 'UPDATE' THEN
        SELECT
            MAX(n.updated_at) INTO v_max_updated_at
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN note nt ON nt.id = n.note_id
            JOIN thread a ON a.id = nt.thread_id
        WHERE
            nt.draft = FALSE
            AND a.draft = FALSE
            AND (n.archived_at IS DISTINCT FROM o.archived_at
                OR n.tag_id IS DISTINCT FROM o.tag_id
                OR n.actor_id IS DISTINCT FROM o.actor_id);
    ELSE
        SELECT
            MAX(n.updated_at) INTO v_max_updated_at
        FROM
            new_table n
            JOIN note nt ON nt.id = n.note_id
            JOIN thread a ON a.id = nt.thread_id
        WHERE
            nt.draft = FALSE
            AND a.draft = FALSE;
    END IF;
    -- Exit early if all changes were to tags on draft notes or draft threads
    IF v_max_updated_at IS NULL THEN
        RETURN NULL;
    END IF;
    -- Track sync state for twists that created the affected notes
    -- Only consider tags on non-draft notes on non-draft threads
    FOR v_priority_twist_id IN SELECT DISTINCT
        pct.id
    FROM
        new_table n
        JOIN note nt ON nt.id = n.note_id
        JOIN thread a ON a.id = nt.thread_id
        JOIN priority p_child ON p_child.id = a.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN priority_twist pct ON pct.priority_id = p_parent.id
    WHERE
        nt.draft = FALSE
        AND a.draft = FALSE
        AND pct.archived_at IS NULL
        -- Track sync for the twist that created this note
        AND nt.created_by = pct.id

    UNION

    -- Direct match for account-based sources (NULL priority_id)
    SELECT DISTINCT
        pct.id
    FROM
        new_table n
        JOIN note nt ON nt.id = n.note_id
        JOIN priority_twist pct ON nt.created_by = pct.id
    WHERE
        nt.draft = FALSE
        AND pct.priority_id IS NULL
        AND pct.archived_at IS NULL

    ORDER BY
        id LOOP
            INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                VALUES (v_priority_twist_id, 'note', 'update', v_max_updated_at)
            ON CONFLICT (priority_twist_id, entity, operation)
                DO UPDATE SET
                    last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
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
                OR n.private IS DISTINCT FROM o.private
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
