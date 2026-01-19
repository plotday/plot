-- Helper function to call the twist sync API with a batch of priority_twist IDs
CREATE OR REPLACE FUNCTION public.call_twist_sync_api (priority_twist_ids uuid[])
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $function$
DECLARE
    v_api_root text;
    v_hmac_secret text;
    v_payload jsonb;
    v_signature text;
    v_request_id bigint;
BEGIN
    -- Get API configuration
    SELECT
        current_setting('plot.api_root', TRUE) INTO v_api_root;
    IF v_api_root IS NULL THEN
        v_api_root := 'http://host.docker.internal:8787';
    END IF;
    SELECT
        current_setting('plot.api_hmac_secret', TRUE) INTO v_hmac_secret;
    IF v_hmac_secret IS NULL THEN
        v_hmac_secret := 'dev-not-secret';
    END IF;
    -- Build payload
    v_payload := jsonb_build_object('ids', to_jsonb (priority_twist_ids));
    -- Calculate HMAC signature
    v_signature := 'sha256=' || encode(hmac(v_payload::text, v_hmac_secret, 'sha256'), 'hex');
    -- Make async HTTP POST request
    SELECT
        net.http_post (url := v_api_root || '/sync/twists', body := v_payload, headers := jsonb_build_object('Content-Type', 'application/json', 'X-Plot-Signature', v_signature)) INTO v_request_id;
EXCEPTION
    WHEN OTHERS THEN
        -- Log error but don't block the transaction
        RAISE WARNING 'Failed to call twist sync API: %', SQLERRM;
END;

$function$;

-- Twist sync trigger function for activity changes
-- Handles both INSERT (create) and UPDATE operations
-- For UPDATE, treats draft=true→false transitions as 'create' operations
CREATE OR REPLACE FUNCTION public.sync_twist_for_activity ()
    RETURNS TRIGGER
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
                -- Only notify the twist that created this activity
                AND n.created_by = pct.id
                AND (v_updated_by IS NULL
                    OR v_updated_by = 0
                    OR updated_by_uuid (pct.id) != v_updated_by)
                    LOOP
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
                        IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_create_timestamp > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at AND v_create_timestamp > v_current_sync_at) OR (v_current_sync_at IS NOT NULL AND v_create_timestamp > v_current_sync_at + interval '60 seconds') THEN
                            v_twists_to_notify := array_append(v_twists_to_notify, v_priority_twist_id);
                        END IF;
                    END LOOP;
        ELSE
            -- UPDATE (publishing draft): can reference old_table for draft true→false check
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
                -- Only notify the twist that created this activity
                AND n.created_by = pct.id
                AND (v_updated_by IS NULL
                    OR v_updated_by = 0
                    OR updated_by_uuid (pct.id) != v_updated_by)
                    LOOP
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
                        IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_create_timestamp > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at AND v_create_timestamp > v_current_sync_at) OR (v_current_sync_at IS NOT NULL AND v_create_timestamp > v_current_sync_at + interval '60 seconds') THEN
                            v_twists_to_notify := array_append(v_twists_to_notify, v_priority_twist_id);
                        END IF;
                    END LOOP;
        END IF;
    END IF;
    -- Process UPDATE operations (regular updates to already-published activities)
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
            -- Only notify the twist that created this activity
            AND n.created_by = pct.id
            AND (v_updated_by IS NULL
                OR v_updated_by = 0
                OR updated_by_uuid (pct.id) != v_updated_by)
                LOOP
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
                    IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_update_timestamp > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at AND v_update_timestamp > v_current_sync_at) OR (v_current_sync_at IS NOT NULL AND v_update_timestamp > v_current_sync_at + interval '60 seconds') THEN
                        v_twists_to_notify := array_append(v_twists_to_notify, v_priority_twist_id);
                    END IF;
                END LOOP;
    END IF;
    -- Batch notify all twists that need it
    IF array_length(v_twists_to_notify, 1) > 0 THEN
        PERFORM
            call_twist_sync_api (v_twists_to_notify);
    END IF;
    RETURN NULL;
END;
$function$;

-- Twist sync trigger function for note changes
-- For UPDATE, treats draft=true→false transitions as 'create' operations
CREATE OR REPLACE FUNCTION public.sync_twist_for_note ()
    RETURNS TRIGGER
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
    -- For creates: notify twist if it created the activity OR is mentioned in any note on the activity
    -- Split into separate branches to avoid referencing old_table during INSERT
    IF v_create_timestamp IS NOT NULL THEN
        IF TG_OP = 'INSERT' THEN
            -- INSERT: no old_table reference, all non-draft notes on non-draft activities are creates
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
                -- Notify if created activity OR mentioned anywhere in thread
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
                AND (v_updated_by IS NULL
                    OR v_updated_by = 0
                    OR updated_by_uuid (pct.id) != v_updated_by)
                    LOOP
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
                        IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_create_timestamp > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at AND v_create_timestamp > v_current_sync_at) OR (v_current_sync_at IS NOT NULL AND v_create_timestamp > v_current_sync_at + interval '60 seconds') THEN
                            v_twists_to_notify := array_append(v_twists_to_notify, v_priority_twist_id);
                        END IF;
                    END LOOP;
        ELSE
            -- UPDATE (publishing draft): can reference old_table for draft true→false check
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
                -- Notify if created activity OR mentioned anywhere in thread
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
                AND (v_updated_by IS NULL
                    OR v_updated_by = 0
                    OR updated_by_uuid (pct.id) != v_updated_by)
                    LOOP
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
                        IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_create_timestamp > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at AND v_create_timestamp > v_current_sync_at) OR (v_current_sync_at IS NOT NULL AND v_create_timestamp > v_current_sync_at + interval '60 seconds') THEN
                            v_twists_to_notify := array_append(v_twists_to_notify, v_priority_twist_id);
                        END IF;
                    END LOOP;
        END IF;
    END IF;
    -- Process UPDATE operations (regular updates to already-published notes)
    -- For updates: only notify twist that created the note
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
            -- Only notify note creator
            AND n.created_by = pct.id
            AND (v_updated_by IS NULL
                OR v_updated_by = 0
                OR updated_by_uuid (pct.id) != v_updated_by)
                LOOP
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
                    IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_update_timestamp > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at AND v_update_timestamp > v_current_sync_at) OR (v_current_sync_at IS NOT NULL AND v_update_timestamp > v_current_sync_at + interval '60 seconds') THEN
                        v_twists_to_notify := array_append(v_twists_to_notify, v_priority_twist_id);
                    END IF;
                END LOOP;
    END IF;
    IF array_length(v_twists_to_notify, 1) > 0 THEN
        PERFORM
            call_twist_sync_api (v_twists_to_notify);
    END IF;
    RETURN NULL;
END;
$function$;

-- Twist sync trigger function for activity_tag changes
CREATE OR REPLACE FUNCTION public.sync_twist_for_activity_tag ()
    RETURNS TRIGGER
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
    -- Get twists that created the affected activities
    -- Exclude the twist that made the update by comparing truncated UUID with updated_by
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
        -- Only notify the twist that created this activity
        AND a.created_by = pct.id
        AND (v_updated_by IS NULL
            OR v_updated_by = 0
            OR updated_by_uuid (pct.id) != v_updated_by)
            LOOP
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
                IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_current_sync_at IS NOT NULL AND v_max_updated_at > v_current_sync_at + interval '60 seconds') THEN
                    v_twists_to_notify := array_append(v_twists_to_notify, v_priority_twist_id);
                END IF;
            END LOOP;
    IF array_length(v_twists_to_notify, 1) > 0 THEN
        PERFORM
            call_twist_sync_api (v_twists_to_notify);
    END IF;
    RETURN NULL;
END;
$function$;

-- Twist sync trigger function for note_tag changes
CREATE OR REPLACE FUNCTION public.sync_twist_for_note_tag ()
    RETURNS TRIGGER
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
    -- Get twists that created the affected notes
    -- Exclude the twist that made the update by comparing truncated UUID with updated_by
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
        -- Only notify the twist that created this note
        AND nt.created_by = pct.id
        AND (v_updated_by IS NULL
            OR v_updated_by = 0
            OR updated_by_uuid (pct.id) != v_updated_by)
            LOOP
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
                IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_current_sync_at IS NOT NULL AND v_max_updated_at > v_current_sync_at + interval '60 seconds') THEN
                    v_twists_to_notify := array_append(v_twists_to_notify, v_priority_twist_id);
                END IF;
            END LOOP;
    IF array_length(v_twists_to_notify, 1) > 0 THEN
        PERFORM
            call_twist_sync_api (v_twists_to_notify);
    END IF;
    RETURN NULL;
END;
$function$;

-- Restrict access: only service_role can call these functions
-- call_twist_sync_api calls external API with internal credentials
REVOKE EXECUTE ON FUNCTION public.call_twist_sync_api (uuid[]) FROM PUBLIC;

-- Trigger functions cannot be called via RPC, but REVOKE for defense-in-depth
REVOKE EXECUTE ON FUNCTION public.sync_twist_for_activity () FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.sync_twist_for_note () FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.sync_twist_for_activity_tag () FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.sync_twist_for_note_tag () FROM PUBLIC;
