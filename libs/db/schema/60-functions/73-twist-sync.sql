CREATE OR REPLACE FUNCTION public.sync_twist_for_thread ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
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
        SELECT
            MAX(n.updated_at) INTO v_update_timestamp
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
        WHERE
            o.draft = FALSE
            AND n.draft = FALSE;
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
$function$;

CREATE OR REPLACE FUNCTION public.sync_twist_for_thread_tag ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_priority_twist_id uuid;
BEGIN
    -- Only consider tags on non-draft threads
    SELECT
        MAX(n.updated_at) INTO v_max_updated_at
    FROM
        new_table n
        JOIN thread a ON a.id = n.thread_id
    WHERE
        a.draft = FALSE;
    -- Exit early if all changes were to tags on draft threads
    IF v_max_updated_at IS NULL THEN
        RETURN NULL;
    END IF;
    -- Track sync state for twists that created the affected threads
    -- Only consider tags on non-draft threads
    FOR v_priority_twist_id IN SELECT DISTINCT
        pct.id
    FROM
        new_table n
        JOIN thread a ON a.id = n.thread_id
        JOIN priority p_child ON p_child.id = a.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN priority_twist pct ON pct.priority_id = p_parent.id
    WHERE
        a.draft = FALSE
        AND pct.archived_at IS NULL
        -- Track sync for the twist that created this thread
        AND a.created_by = pct.id

    UNION

    -- Direct match for account-based sources (NULL priority_id)
    SELECT DISTINCT
        pct.id
    FROM
        new_table n
        JOIN thread a ON a.id = n.thread_id
        JOIN priority_twist pct ON a.created_by = pct.id
    WHERE
        a.draft = FALSE
        AND pct.priority_id IS NULL
        AND pct.archived_at IS NULL

    ORDER BY
        id LOOP
            INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                VALUES (v_priority_twist_id, 'thread', 'update', v_max_updated_at)
            ON CONFLICT (priority_twist_id, entity, operation)
                DO UPDATE SET
                    last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_twist_for_note ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
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
        SELECT
            MAX(n.updated_at) INTO v_update_timestamp
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN thread a ON a.id = n.thread_id
        WHERE
            o.draft = FALSE
            AND n.draft = FALSE
            AND a.draft = FALSE;
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
$function$;

CREATE OR REPLACE FUNCTION public.sync_twist_for_note_tag ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_priority_twist_id uuid;
BEGIN
    -- Only consider tags on non-draft notes on non-draft threads
    SELECT
        MAX(n.updated_at) INTO v_max_updated_at
    FROM
        new_table n
        JOIN note nt ON nt.id = n.note_id
        JOIN thread a ON a.id = nt.thread_id
    WHERE
        nt.draft = FALSE
        AND a.draft = FALSE;
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
$function$;

-- Sync twist state when links are created or updated
-- Links don't have a draft concept, so all inserts are creates and all updates are updates
CREATE OR REPLACE FUNCTION public.sync_twist_for_link ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_create_timestamp timestamptz;
    v_update_timestamp timestamptz;
    v_priority_twist_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT
            MAX(created_at) INTO v_create_timestamp
        FROM
            new_table;
    ELSE
        SELECT
            MAX(n.updated_at) INTO v_update_timestamp
        FROM
            new_table n;
    END IF;
    -- Exit early if nothing to sync
    IF v_create_timestamp IS NULL AND v_update_timestamp IS NULL THEN
        RETURN NULL;
    END IF;
    -- Process CREATE operations (new inserts)
    IF v_create_timestamp IS NOT NULL THEN
        FOR v_priority_twist_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN thread t ON t.id = n.thread_id
            JOIN priority p_child ON p_child.id = t.priority_id
            JOIN priority p_parent ON p_child.path <@ p_parent.path
            JOIN priority_twist pct ON pct.priority_id = p_parent.id
        WHERE
            pct.archived_at IS NULL
            -- Track sync for the twist that created this link
            AND n.created_by = pct.id

        UNION

        -- Direct match for account-based sources (NULL priority_id)
        SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN priority_twist pct ON n.created_by = pct.id
        WHERE
            pct.priority_id IS NULL
            AND pct.archived_at IS NULL

        ORDER BY
            id LOOP
                INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                    VALUES (v_priority_twist_id, 'link', 'create', v_create_timestamp)
                ON CONFLICT (priority_twist_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
            END LOOP;
    END IF;
    -- Process UPDATE operations
    IF v_update_timestamp IS NOT NULL THEN
        FOR v_priority_twist_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN thread t ON t.id = n.thread_id
            JOIN priority p_child ON p_child.id = t.priority_id
            JOIN priority p_parent ON p_child.path <@ p_parent.path
            JOIN priority_twist pct ON pct.priority_id = p_parent.id
        WHERE
            pct.archived_at IS NULL
            -- Track sync for the twist that created this link
            AND n.created_by = pct.id

        UNION

        -- Direct match for account-based sources (NULL priority_id)
        SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN priority_twist pct ON n.created_by = pct.id
        WHERE
            pct.priority_id IS NULL
            AND pct.archived_at IS NULL

        ORDER BY
            id LOOP
                INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                    VALUES (v_priority_twist_id, 'link', 'update', v_update_timestamp)
                ON CONFLICT (priority_twist_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
            END LOOP;
    END IF;
    RETURN NULL;
END;
$function$;
