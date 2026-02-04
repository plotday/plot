SET ROLE "postgres";
SET check_function_bodies = false;
CREATE OR REPLACE FUNCTION public.sync_twist_for_activity_tag()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_updated_by integer;
    v_twists_to_notify uuid[] := '{}';
    v_priority_twist_id uuid;
    v_prev_update_at timestamptz;
    v_prev_sync_at timestamptz;
    v_current_sync_at timestamptz;
BEGIN
    -- Only consider tags on non-draft activities
    SELECT
        MAX(n.updated_at) INTO v_max_updated_at
    FROM
        new_table n
        JOIN activity a ON a.id = n.activity_id
    WHERE
        a.draft = FALSE;
    -- Exit early if all changes were to tags on draft activities
    IF v_max_updated_at IS NULL THEN
        RETURN NULL;
    END IF;
    -- Get the updated_by value (if any) to exclude that twist from notifications
    SELECT DISTINCT
        n.updated_by INTO v_updated_by
    FROM
        new_table n
        JOIN activity a ON a.id = n.activity_id
    WHERE
        n.updated_by IS NOT NULL
        AND a.draft = FALSE
    LIMIT 1;
    -- Track sync state for twists that created the affected activities
    -- IMPORTANT: Update sync state for ALL activity creators, not just those we notify
    -- Only consider tags on non-draft activities
    FOR v_priority_twist_id IN SELECT DISTINCT
        pct.id
    FROM
        new_table n
        JOIN activity a ON a.id = n.activity_id
        JOIN priority_child_twist pct ON pct.priority_child_id = a.priority_id
    WHERE
        a.draft = FALSE
        AND pct.archived_at IS NULL
        -- Track sync for the twist that created this activity
        AND a.created_by = pct.id
    ORDER BY
        pct.id LOOP
            SELECT
                last_update_at,
                last_sync_at INTO v_prev_update_at,
                v_prev_sync_at
            FROM
                priority_twist_sync
            WHERE
                priority_twist_id = v_priority_twist_id
                AND entity = 'activity'
                AND operation = 'update';
            INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                VALUES (v_priority_twist_id, 'activity', 'update', v_max_updated_at)
            ON CONFLICT (priority_twist_id, entity, operation)
                DO UPDATE SET
                    last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
            SELECT
                last_sync_at INTO v_current_sync_at
            FROM
                priority_twist_sync
            WHERE
                priority_twist_id = v_priority_twist_id
                AND entity = 'activity'
                AND operation = 'update';
            -- Only notify if not updated by this twist (avoid echo)
            IF ((v_updated_by IS NULL OR v_updated_by = 0 OR updated_by_uuid (v_priority_twist_id) != v_updated_by) AND ((v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_current_sync_at IS NOT NULL AND v_max_updated_at > v_current_sync_at + interval '60 seconds'))) THEN
                v_twists_to_notify := array_append(v_twists_to_notify, v_priority_twist_id);
            END IF;
        END LOOP;
    -- Skip API call for twist-originated writes (negative updated_by)
    IF array_length(v_twists_to_notify, 1) > 0 THEN
        IF EXISTS (SELECT 1 FROM new_table WHERE updated_by >= 0) THEN
            PERFORM
                call_twist_sync_api (v_twists_to_notify);
        END IF;
    END IF;
    RETURN NULL;
END;
$function$;
CREATE OR REPLACE FUNCTION public.sync_twist_for_activity()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_create_timestamp timestamptz;
    v_update_timestamp timestamptz;
    v_updated_by integer;
    v_twists_to_notify uuid[] := '{}';
    v_priority_twist_id uuid;
    v_prev_update_at timestamptz;
    v_prev_sync_at timestamptz;
    v_current_sync_at timestamptz;
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
    -- Exit early if all changes were to draft activities (nothing to sync)
    IF v_create_timestamp IS NULL AND v_update_timestamp IS NULL THEN
        RETURN NULL;
    END IF;
    -- Get the updated_by value (if any) to exclude that twist from notifications
    SELECT DISTINCT
        updated_by INTO v_updated_by
    FROM
        new_table
    WHERE
        updated_by IS NOT NULL
        AND draft = FALSE
    LIMIT 1;
    -- Process CREATE operations (new inserts or published drafts)
    -- Split into separate branches to avoid referencing old_table during INSERT
    -- IMPORTANT: Update sync state for ALL activity creators, not just those we notify
    IF v_create_timestamp IS NOT NULL THEN
        IF TG_OP = 'INSERT' THEN
            -- INSERT: no old_table reference, all non-draft rows are creates
            FOR v_priority_twist_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN priority_child_twist pct ON pct.priority_child_id = n.priority_id
            WHERE
                n.draft = FALSE
                AND pct.archived_at IS NULL
                -- Track sync for the twist that created this activity
                AND n.created_by = pct.id
            ORDER BY
                pct.id LOOP
                    SELECT
                        last_update_at,
                        last_sync_at INTO v_prev_update_at,
                        v_prev_sync_at
                    FROM
                        priority_twist_sync
                    WHERE
                        priority_twist_id = v_priority_twist_id
                        AND entity = 'activity'
                        AND operation = 'create';
                    INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                        VALUES (v_priority_twist_id, 'activity', 'create', v_create_timestamp)
                    ON CONFLICT (priority_twist_id, entity, operation)
                        DO UPDATE SET
                            last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
                    SELECT
                        last_sync_at INTO v_current_sync_at
                    FROM
                        priority_twist_sync
                    WHERE
                        priority_twist_id = v_priority_twist_id
                        AND entity = 'activity'
                        AND operation = 'create';
                    -- Only notify if not updated by this twist (avoid echo)
                    IF ((v_updated_by IS NULL OR v_updated_by = 0 OR updated_by_uuid (v_priority_twist_id) != v_updated_by) AND ((v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_create_timestamp > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at AND v_create_timestamp > v_current_sync_at) OR (v_current_sync_at IS NOT NULL AND v_create_timestamp > v_current_sync_at + interval '60 seconds'))) THEN
                        v_twists_to_notify := array_append(v_twists_to_notify, v_priority_twist_id);
                    END IF;
                END LOOP;
        ELSE
            -- UPDATE (publishing draft): can reference old_table for draft true→false check
            -- IMPORTANT: Update sync state for ALL activity creators, not just those we notify
            FOR v_priority_twist_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN old_table o ON o.id = n.id
                JOIN priority_child_twist pct ON pct.priority_child_id = n.priority_id
            WHERE
                o.draft = TRUE
                AND n.draft = FALSE
                AND pct.archived_at IS NULL
                -- Track sync for the twist that created this activity
                AND n.created_by = pct.id
            ORDER BY
                pct.id LOOP
                    SELECT
                        last_update_at,
                        last_sync_at INTO v_prev_update_at,
                        v_prev_sync_at
                    FROM
                        priority_twist_sync
                    WHERE
                        priority_twist_id = v_priority_twist_id
                        AND entity = 'activity'
                        AND operation = 'create';
                    INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                        VALUES (v_priority_twist_id, 'activity', 'create', v_create_timestamp)
                    ON CONFLICT (priority_twist_id, entity, operation)
                        DO UPDATE SET
                            last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
                    SELECT
                        last_sync_at INTO v_current_sync_at
                    FROM
                        priority_twist_sync
                    WHERE
                        priority_twist_id = v_priority_twist_id
                        AND entity = 'activity'
                        AND operation = 'create';
                    -- Only notify if not updated by this twist (avoid echo)
                    IF ((v_updated_by IS NULL OR v_updated_by = 0 OR updated_by_uuid (v_priority_twist_id) != v_updated_by) AND ((v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_create_timestamp > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at AND v_create_timestamp > v_current_sync_at) OR (v_current_sync_at IS NOT NULL AND v_create_timestamp > v_current_sync_at + interval '60 seconds'))) THEN
                        v_twists_to_notify := array_append(v_twists_to_notify, v_priority_twist_id);
                    END IF;
                END LOOP;
        END IF;
    END IF;
    -- Process UPDATE operations (regular updates to already-published activities)
    -- IMPORTANT: Update sync state for ALL activity creators, not just those we notify
    IF v_update_timestamp IS NOT NULL THEN
        FOR v_priority_twist_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN priority_child_twist pct ON pct.priority_child_id = n.priority_id
        WHERE
            n.draft = FALSE
            AND o.draft = FALSE
            AND pct.archived_at IS NULL
            -- Track sync for the twist that created this activity
            AND n.created_by = pct.id
        ORDER BY
            pct.id LOOP
                SELECT
                    last_update_at,
                    last_sync_at INTO v_prev_update_at,
                    v_prev_sync_at
                FROM
                    priority_twist_sync
                WHERE
                    priority_twist_id = v_priority_twist_id
                    AND entity = 'activity'
                    AND operation = 'update';
                INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                    VALUES (v_priority_twist_id, 'activity', 'update', v_update_timestamp)
                ON CONFLICT (priority_twist_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
                SELECT
                    last_sync_at INTO v_current_sync_at
                FROM
                    priority_twist_sync
                WHERE
                    priority_twist_id = v_priority_twist_id
                    AND entity = 'activity'
                    AND operation = 'update';
                -- Only notify if not updated by this twist (avoid echo)
                IF ((v_updated_by IS NULL OR v_updated_by = 0 OR updated_by_uuid (v_priority_twist_id) != v_updated_by) AND ((v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_update_timestamp > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at AND v_update_timestamp > v_current_sync_at) OR (v_current_sync_at IS NOT NULL AND v_update_timestamp > v_current_sync_at + interval '60 seconds'))) THEN
                    v_twists_to_notify := array_append(v_twists_to_notify, v_priority_twist_id);
                END IF;
            END LOOP;
    END IF;
    -- Batch notify all twists that need it
    -- Skip API call for twist-originated writes (negative updated_by);
    -- the Plot tool notifies sync DOs directly after batch operations.
    IF array_length(v_twists_to_notify, 1) > 0 THEN
        IF EXISTS (SELECT 1 FROM new_table WHERE updated_by >= 0) THEN
            PERFORM
                call_twist_sync_api (v_twists_to_notify);
        END IF;
    END IF;
    RETURN NULL;
END;
$function$;
CREATE OR REPLACE FUNCTION public.sync_twist_for_note_tag()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_updated_by integer;
    v_twists_to_notify uuid[] := '{}';
    v_priority_twist_id uuid;
    v_prev_update_at timestamptz;
    v_prev_sync_at timestamptz;
    v_current_sync_at timestamptz;
BEGIN
    -- Only consider tags on non-draft notes on non-draft activities
    SELECT
        MAX(n.updated_at) INTO v_max_updated_at
    FROM
        new_table n
        JOIN note nt ON nt.id = n.note_id
        JOIN activity a ON a.id = nt.activity_id
    WHERE
        nt.draft = FALSE
        AND a.draft = FALSE;
    -- Exit early if all changes were to tags on draft notes or draft activities
    IF v_max_updated_at IS NULL THEN
        RETURN NULL;
    END IF;
    -- Get the updated_by value (if any) to exclude that twist from notifications
    SELECT DISTINCT
        n.updated_by INTO v_updated_by
    FROM
        new_table n
        JOIN note nt ON nt.id = n.note_id
        JOIN activity a ON a.id = nt.activity_id
    WHERE
        n.updated_by IS NOT NULL
        AND nt.draft = FALSE
        AND a.draft = FALSE
    LIMIT 1;
    -- Track sync state for twists that created the affected notes
    -- IMPORTANT: Update sync state for ALL note creators, not just those we notify
    -- Only consider tags on non-draft notes on non-draft activities
    FOR v_priority_twist_id IN SELECT DISTINCT
        pct.id
    FROM
        new_table n
        JOIN note nt ON nt.id = n.note_id
        JOIN activity a ON a.id = nt.activity_id
        JOIN priority_child_twist pct ON pct.priority_child_id = a.priority_id
    WHERE
        nt.draft = FALSE
        AND a.draft = FALSE
        AND pct.archived_at IS NULL
        -- Track sync for the twist that created this note
        AND nt.created_by = pct.id
    ORDER BY
        pct.id LOOP
            SELECT
                last_update_at,
                last_sync_at INTO v_prev_update_at,
                v_prev_sync_at
            FROM
                priority_twist_sync
            WHERE
                priority_twist_id = v_priority_twist_id
                AND entity = 'note'
                AND operation = 'update';
            INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                VALUES (v_priority_twist_id, 'note', 'update', v_max_updated_at)
            ON CONFLICT (priority_twist_id, entity, operation)
                DO UPDATE SET
                    last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
            SELECT
                last_sync_at INTO v_current_sync_at
            FROM
                priority_twist_sync
            WHERE
                priority_twist_id = v_priority_twist_id
                AND entity = 'note'
                AND operation = 'update';
            -- Only notify if not updated by this twist (avoid echo)
            IF ((v_updated_by IS NULL OR v_updated_by = 0 OR updated_by_uuid (v_priority_twist_id) != v_updated_by) AND ((v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_current_sync_at IS NOT NULL AND v_max_updated_at > v_current_sync_at + interval '60 seconds'))) THEN
                v_twists_to_notify := array_append(v_twists_to_notify, v_priority_twist_id);
            END IF;
        END LOOP;
    -- Skip API call for twist-originated writes (negative updated_by)
    IF array_length(v_twists_to_notify, 1) > 0 THEN
        IF EXISTS (SELECT 1 FROM new_table WHERE updated_by >= 0) THEN
            PERFORM
                call_twist_sync_api (v_twists_to_notify);
        END IF;
    END IF;
    RETURN NULL;
END;
$function$;
CREATE OR REPLACE FUNCTION public.sync_twist_for_note()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_create_timestamp timestamptz;
    v_update_timestamp timestamptz;
    v_updated_by integer;
    v_twists_to_notify uuid[] := '{}';
    v_priority_twist_id uuid;
    v_prev_update_at timestamptz;
    v_prev_sync_at timestamptz;
    v_current_sync_at timestamptz;
BEGIN
    -- Determine timestamps for create and update operations
    IF TG_OP = 'INSERT' THEN
        -- For inserts, all non-draft notes on non-draft activities are creates
        SELECT
            MAX(n.created_at) INTO v_create_timestamp
        FROM
            new_table n
            JOIN activity a ON a.id = n.activity_id
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
            JOIN activity a ON a.id = n.activity_id
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
            JOIN activity a ON a.id = n.activity_id
        WHERE
            o.draft = FALSE
            AND n.draft = FALSE
            AND a.draft = FALSE;
    END IF;
    -- Exit early if all changes were to draft notes or notes on draft activities
    IF v_create_timestamp IS NULL AND v_update_timestamp IS NULL THEN
        RETURN NULL;
    END IF;
    -- Get the updated_by value (if any) to exclude that twist from notifications
    SELECT DISTINCT
        n.updated_by INTO v_updated_by
    FROM
        new_table n
        JOIN activity a ON a.id = n.activity_id
    WHERE
        n.updated_by IS NOT NULL
        AND n.draft = FALSE
        AND a.draft = FALSE
    LIMIT 1;
    -- Process CREATE operations (new inserts or published drafts)
    -- For creates: track sync state for twists that created activity OR are mentioned
    -- Split into separate branches to avoid referencing old_table during INSERT
    IF v_create_timestamp IS NOT NULL THEN
        IF TG_OP = 'INSERT' THEN
            -- INSERT: no old_table reference, all non-draft notes on non-draft activities are creates
            -- IMPORTANT: Update sync state for ALL relevant twists, not just those we notify
            FOR v_priority_twist_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN activity a ON a.id = n.activity_id
                JOIN priority_child_twist pct ON pct.priority_child_id = a.priority_id
            WHERE
                n.draft = FALSE
                AND a.draft = FALSE
                AND pct.archived_at IS NULL
                -- Track sync for twists that created activity OR are mentioned anywhere in thread
                AND (a.created_by = pct.id
                    OR pct.id = ANY (n.mentions)
                    OR EXISTS (
                        SELECT
                            1
                        FROM
                            note
                        WHERE
                            note.activity_id = a.id
                            AND note.id != n.id
                            AND pct.id = ANY (note.mentions)
                            AND note.archived_at IS NULL))
                    ORDER BY
                        pct.id LOOP
                        SELECT
                            last_update_at,
                            last_sync_at INTO v_prev_update_at,
                            v_prev_sync_at
                        FROM
                            priority_twist_sync
                        WHERE
                            priority_twist_id = v_priority_twist_id
                            AND entity = 'note'
                            AND operation = 'create';
                        INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                            VALUES (v_priority_twist_id, 'note', 'create', v_create_timestamp)
                        ON CONFLICT (priority_twist_id, entity, operation)
                            DO UPDATE SET
                                last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
                        SELECT
                            last_sync_at INTO v_current_sync_at
                        FROM
                            priority_twist_sync
                        WHERE
                            priority_twist_id = v_priority_twist_id
                            AND entity = 'note'
                            AND operation = 'create';
                        -- Only notify if not updated by this twist (avoid echo)
                        IF ((v_updated_by IS NULL OR v_updated_by = 0 OR updated_by_uuid (v_priority_twist_id) != v_updated_by) AND ((v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_create_timestamp > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at AND v_create_timestamp > v_current_sync_at) OR (v_current_sync_at IS NOT NULL AND v_create_timestamp > v_current_sync_at + interval '60 seconds'))) THEN
                            v_twists_to_notify := array_append(v_twists_to_notify, v_priority_twist_id);
                        END IF;
                    END LOOP;
        ELSE
            -- UPDATE (publishing draft): can reference old_table for draft true→false check
            -- IMPORTANT: Update sync state for ALL relevant twists, not just those we notify
            FOR v_priority_twist_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN old_table o ON o.id = n.id
                JOIN activity a ON a.id = n.activity_id
                JOIN priority_child_twist pct ON pct.priority_child_id = a.priority_id
            WHERE
                o.draft = TRUE
                AND n.draft = FALSE
                AND a.draft = FALSE
                AND pct.archived_at IS NULL
                -- Track sync for twists that created activity OR are mentioned anywhere in thread
                AND (a.created_by = pct.id
                    OR pct.id = ANY (n.mentions)
                    OR EXISTS (
                        SELECT
                            1
                        FROM
                            note
                        WHERE
                            note.activity_id = a.id
                            AND note.id != n.id
                            AND pct.id = ANY (note.mentions)
                            AND note.archived_at IS NULL))
                    ORDER BY
                        pct.id LOOP
                        SELECT
                            last_update_at,
                            last_sync_at INTO v_prev_update_at,
                            v_prev_sync_at
                        FROM
                            priority_twist_sync
                        WHERE
                            priority_twist_id = v_priority_twist_id
                            AND entity = 'note'
                            AND operation = 'create';
                        INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                            VALUES (v_priority_twist_id, 'note', 'create', v_create_timestamp)
                        ON CONFLICT (priority_twist_id, entity, operation)
                            DO UPDATE SET
                                last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
                        SELECT
                            last_sync_at INTO v_current_sync_at
                        FROM
                            priority_twist_sync
                        WHERE
                            priority_twist_id = v_priority_twist_id
                            AND entity = 'note'
                            AND operation = 'create';
                        -- Only notify if not updated by this twist (avoid echo)
                        IF ((v_updated_by IS NULL OR v_updated_by = 0 OR updated_by_uuid (v_priority_twist_id) != v_updated_by) AND ((v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_create_timestamp > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at AND v_create_timestamp > v_current_sync_at) OR (v_current_sync_at IS NOT NULL AND v_create_timestamp > v_current_sync_at + interval '60 seconds'))) THEN
                            v_twists_to_notify := array_append(v_twists_to_notify, v_priority_twist_id);
                        END IF;
                    END LOOP;
        END IF;
    END IF;
    -- Process UPDATE operations (regular updates to already-published notes)
    -- For updates: track sync state for twist that created the note
    -- IMPORTANT: Update sync state for ALL note creators, not just those we notify
    IF v_update_timestamp IS NOT NULL THEN
        FOR v_priority_twist_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN activity a ON a.id = n.activity_id
            JOIN priority_child_twist pct ON pct.priority_child_id = a.priority_id
        WHERE
            n.draft = FALSE
            AND o.draft = FALSE
            AND a.draft = FALSE
            AND pct.archived_at IS NULL
            -- Track sync for note creator
            AND n.created_by = pct.id
        ORDER BY
            pct.id LOOP
                SELECT
                    last_update_at,
                    last_sync_at INTO v_prev_update_at,
                    v_prev_sync_at
                FROM
                    priority_twist_sync
                WHERE
                    priority_twist_id = v_priority_twist_id
                    AND entity = 'note'
                    AND operation = 'update';
                INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                    VALUES (v_priority_twist_id, 'note', 'update', v_update_timestamp)
                ON CONFLICT (priority_twist_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
                SELECT
                    last_sync_at INTO v_current_sync_at
                FROM
                    priority_twist_sync
                WHERE
                    priority_twist_id = v_priority_twist_id
                    AND entity = 'note'
                    AND operation = 'update';
                -- Only notify if not updated by this twist (avoid echo)
                IF ((v_updated_by IS NULL OR v_updated_by = 0 OR updated_by_uuid (v_priority_twist_id) != v_updated_by) AND ((v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_update_timestamp > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at AND v_update_timestamp > v_current_sync_at) OR (v_current_sync_at IS NOT NULL AND v_update_timestamp > v_current_sync_at + interval '60 seconds'))) THEN
                    v_twists_to_notify := array_append(v_twists_to_notify, v_priority_twist_id);
                END IF;
            END LOOP;
    END IF;
    -- Skip API call for twist-originated writes (negative updated_by)
    IF array_length(v_twists_to_notify, 1) > 0 THEN
        IF EXISTS (SELECT 1 FROM new_table WHERE updated_by >= 0) THEN
            PERFORM
                call_twist_sync_api (v_twists_to_notify);
        END IF;
    END IF;
    RETURN NULL;
END;
$function$;
CREATE OR REPLACE FUNCTION public.sync_user_for_activity_tag()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_users_to_notify uuid[] := '{}';
    v_user_id uuid;
    v_prev_update_at timestamptz;
    v_prev_sync_at timestamptz;
    v_current_sync_at timestamptz;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users with access to the parent activity's priority (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN activity a ON a.id = n.activity_id
        JOIN user_priority_expanded upe ON upe.priority_id = a.priority_id
    WHERE
        upe.archived_at IS NULL
    ORDER BY
        upe.user_id LOOP
            SELECT
                last_update_at,
                last_sync_at INTO v_prev_update_at,
                v_prev_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'activity';
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'activity', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
            SELECT
                last_sync_at INTO v_current_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'activity';
            IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at) THEN
                v_users_to_notify := array_append(v_users_to_notify, v_user_id);
            END IF;
        END LOOP;
    -- Skip API call for twist-originated writes (negative updated_by)
    IF array_length(v_users_to_notify, 1) > 0 THEN
        IF EXISTS (SELECT 1 FROM new_table WHERE updated_by >= 0) THEN
            PERFORM
                call_user_sync_api (v_users_to_notify);
        END IF;
    END IF;
    RETURN NULL;
END;
$function$;
CREATE OR REPLACE FUNCTION public.sync_user_for_activity()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_users_to_notify uuid[] := '{}';
    v_user_id uuid;
    v_prev_update_at timestamptz;
    v_prev_sync_at timestamptz;
    v_current_sync_at timestamptz;
BEGIN
    -- Get max updated_at from the batch
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users with access to affected priorities (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN user_priority_expanded upe ON upe.priority_id = n.priority_id
    WHERE
        upe.archived_at IS NULL
    ORDER BY
        upe.user_id LOOP
            -- Get previous state
            SELECT
                last_update_at,
                last_sync_at INTO v_prev_update_at,
                v_prev_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'activity';
            -- Upsert the sync record
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'activity', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
            -- Get the current sync_at after update
            SELECT
                last_sync_at INTO v_current_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'activity';
            -- Check if we need to notify:
            -- 1. Condition became newly true (wasn't pending before, now is)
            -- 2. OR condition was already true and last_sync_at changed (new update during processing)
            IF (v_prev_update_at IS NULL) OR -- New row, definitely notify
            (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR -- Became pending
        (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at) -- Was pending, sync_at changed
    THEN
                v_users_to_notify := array_append(v_users_to_notify, v_user_id);
            END IF;
        END LOOP;
    -- Batch notify all users that need it
    -- Skip API call for twist-originated writes (negative updated_by);
    -- the Plot tool notifies sync DOs directly after batch operations.
    IF array_length(v_users_to_notify, 1) > 0 THEN
        IF EXISTS (SELECT 1 FROM new_table WHERE updated_by >= 0) THEN
            PERFORM
                call_user_sync_api (v_users_to_notify);
        END IF;
    END IF;
    RETURN NULL;
END;
$function$;
CREATE OR REPLACE FUNCTION public.sync_user_for_note_tag()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_users_to_notify uuid[] := '{}';
    v_user_id uuid;
    v_prev_update_at timestamptz;
    v_prev_sync_at timestamptz;
    v_current_sync_at timestamptz;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users with access to the parent note's activity's priority (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN note nt ON nt.id = n.note_id
        JOIN activity a ON a.id = nt.activity_id
        JOIN user_priority_expanded upe ON upe.priority_id = a.priority_id
    WHERE
        upe.archived_at IS NULL
    ORDER BY
        upe.user_id LOOP
            SELECT
                last_update_at,
                last_sync_at INTO v_prev_update_at,
                v_prev_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'note';
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'note', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
            SELECT
                last_sync_at INTO v_current_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'note';
            IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at) THEN
                v_users_to_notify := array_append(v_users_to_notify, v_user_id);
            END IF;
        END LOOP;
    -- Skip API call for twist-originated writes (negative updated_by)
    IF array_length(v_users_to_notify, 1) > 0 THEN
        IF EXISTS (SELECT 1 FROM new_table WHERE updated_by >= 0) THEN
            PERFORM
                call_user_sync_api (v_users_to_notify);
        END IF;
    END IF;
    RETURN NULL;
END;
$function$;
CREATE OR REPLACE FUNCTION public.sync_user_for_note()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_users_to_notify uuid[] := '{}';
    v_user_id uuid;
    v_prev_update_at timestamptz;
    v_prev_sync_at timestamptz;
    v_current_sync_at timestamptz;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users with access to the parent activity's priority (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN activity a ON a.id = n.activity_id
        JOIN user_priority_expanded upe ON upe.priority_id = a.priority_id
    WHERE
        upe.archived_at IS NULL
    ORDER BY
        upe.user_id LOOP
            SELECT
                last_update_at,
                last_sync_at INTO v_prev_update_at,
                v_prev_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'note';
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'note', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
            SELECT
                last_sync_at INTO v_current_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'note';
            IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at) THEN
                v_users_to_notify := array_append(v_users_to_notify, v_user_id);
            END IF;
        END LOOP;
    -- Skip API call for twist-originated writes (negative updated_by)
    IF array_length(v_users_to_notify, 1) > 0 THEN
        IF EXISTS (SELECT 1 FROM new_table WHERE updated_by >= 0) THEN
            PERFORM
                call_user_sync_api (v_users_to_notify);
        END IF;
    END IF;
    RETURN NULL;
END;
$function$;
CREATE OR REPLACE FUNCTION public.updated_by_uuid(id uuid)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT
        -1 * (CASE WHEN ('x' ||
        RIGHT (REPLACE(id::text, '-', ''),
            16))::bit(64)::bigint < 0 THEN
            (('x' ||
                RIGHT (REPLACE(id::text, '-', ''),
                    16))::bit(64)::bigint::numeric + 18446744073709551616::numeric) % 2147483647
        ELSE
            ('x' ||
            RIGHT (REPLACE(id::text, '-', ''),
                16))::bit(64)::bigint::numeric % 2147483647
        END)
$function$;
