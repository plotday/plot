CREATE OR REPLACE FUNCTION public.sync_twist_for_thread ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_create_timestamp timestamptz;
    v_update_timestamp timestamptz;
    v_create_seq xid8;
    v_update_seq xid8;
    v_twist_instance_id uuid;
BEGIN
    -- Determine timestamps for create and update operations
    IF TG_OP = 'INSERT' THEN
        SELECT
            MAX(created_at), MAX(seq) INTO v_create_timestamp, v_create_seq
        FROM
            new_table
        WHERE
            draft = FALSE;
    ELSE
        -- Published rows: draft TRUE -> FALSE
        SELECT
            MAX(n.updated_at), MAX(n.seq) INTO v_create_timestamp, v_create_seq
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
        WHERE
            o.draft = TRUE
            AND n.draft = FALSE;
        -- Regular updates to already-published rows
        SELECT
            MAX(n.updated_at), MAX(n.seq) INTO v_update_timestamp, v_update_seq
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
                OR n.updated_by IS DISTINCT FROM o.updated_by);
    END IF;
    IF v_create_timestamp IS NULL AND v_update_timestamp IS NULL THEN
        RETURN NULL;
    END IF;
    -- Mirror the sync_user_for_* fallback: empty batches / DELETEs leave seq
    -- NULL; clamp to the current xid so the cursor still advances monotonically.
    IF v_create_timestamp IS NOT NULL AND v_create_seq IS NULL THEN
        v_create_seq := pg_current_xact_id();
    END IF;
    IF v_update_timestamp IS NOT NULL AND v_update_seq IS NULL THEN
        v_update_seq := pg_current_xact_id();
    END IF;
    -- CREATE
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
                    INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at, last_update_seq)
                        VALUES (v_twist_instance_id, 'thread', 'create', v_create_timestamp, v_create_seq)
                    ON CONFLICT (twist_instance_id, entity, operation)
                        DO UPDATE SET
                            last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at),
                            last_update_seq = GREATEST (twist_instance_sync.last_update_seq, EXCLUDED.last_update_seq);
                END LOOP;
        ELSE
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
                    INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at, last_update_seq)
                        VALUES (v_twist_instance_id, 'thread', 'create', v_create_timestamp, v_create_seq)
                    ON CONFLICT (twist_instance_id, entity, operation)
                        DO UPDATE SET
                            last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at),
                            last_update_seq = GREATEST (twist_instance_sync.last_update_seq, EXCLUDED.last_update_seq);
                END LOOP;
        END IF;
    END IF;
    -- UPDATE
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
                INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at, last_update_seq)
                    VALUES (v_twist_instance_id, 'thread', 'update', v_update_timestamp, v_update_seq)
                ON CONFLICT (twist_instance_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at),
                        last_update_seq = GREATEST (twist_instance_sync.last_update_seq, EXCLUDED.last_update_seq);
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
    v_max_seq xid8;
    v_twist_instance_id uuid;
BEGIN
    SELECT
        MAX(n.updated_at), MAX(n.seq) INTO v_max_updated_at, v_max_seq
    FROM
        new_table n
        JOIN thread a ON a.id = n.thread_id
    WHERE
        a.draft = FALSE;
    IF v_max_updated_at IS NULL THEN
        RETURN NULL;
    END IF;
    IF v_max_seq IS NULL THEN
        v_max_seq := pg_current_xact_id();
    END IF;
    FOR v_twist_instance_id IN SELECT DISTINCT
        pct.id
    FROM
        new_table n
        JOIN thread a ON a.id = n.thread_id
        JOIN twist_instance pct ON pct.id = a.created_by
    WHERE
        a.draft = FALSE
        AND pct.archived_at IS NULL
    ORDER BY
        id LOOP
            INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at, last_update_seq)
                VALUES (v_twist_instance_id, 'thread', 'update', v_max_updated_at, v_max_seq)
            ON CONFLICT (twist_instance_id, entity, operation)
                DO UPDATE SET
                    last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (twist_instance_sync.last_update_seq, EXCLUDED.last_update_seq);
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
    v_create_seq xid8;
    v_update_seq xid8;
    v_twist_instance_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT
            MAX(n.created_at), MAX(n.seq) INTO v_create_timestamp, v_create_seq
        FROM
            new_table n
            JOIN thread a ON a.id = n.thread_id
        WHERE
            n.draft = FALSE
            AND a.draft = FALSE;
    ELSE
        SELECT
            MAX(n.updated_at), MAX(n.seq) INTO v_create_timestamp, v_create_seq
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN thread a ON a.id = n.thread_id
        WHERE
            o.draft = TRUE
            AND n.draft = FALSE
            AND a.draft = FALSE;
        SELECT
            MAX(n.updated_at), MAX(n.seq) INTO v_update_timestamp, v_update_seq
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
    IF v_create_timestamp IS NULL AND v_update_timestamp IS NULL THEN
        RETURN NULL;
    END IF;
    IF v_create_timestamp IS NOT NULL AND v_create_seq IS NULL THEN
        v_create_seq := pg_current_xact_id();
    END IF;
    IF v_update_timestamp IS NOT NULL AND v_update_seq IS NULL THEN
        v_update_seq := pg_current_xact_id();
    END IF;
    IF v_create_timestamp IS NOT NULL THEN
        IF TG_OP = 'INSERT' THEN
            FOR v_twist_instance_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN twist_instance pct ON pct.id = ANY (n.mentions)
            WHERE
                n.draft = FALSE
                AND pct.archived_at IS NULL
                AND n.created_by != pct.id
            ORDER BY
                id LOOP
                    INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at, last_update_seq)
                        VALUES (v_twist_instance_id, 'note', 'create', v_create_timestamp, v_create_seq)
                    ON CONFLICT (twist_instance_id, entity, operation)
                        DO UPDATE SET
                            last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at),
                            last_update_seq = GREATEST (twist_instance_sync.last_update_seq, EXCLUDED.last_update_seq);
                END LOOP;
        ELSE
            FOR v_twist_instance_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN old_table o ON o.id = n.id
                JOIN twist_instance pct ON pct.id = ANY (n.mentions)
            WHERE
                o.draft = TRUE
                AND n.draft = FALSE
                AND pct.archived_at IS NULL
                AND n.created_by != pct.id
            ORDER BY
                id LOOP
                    INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at, last_update_seq)
                        VALUES (v_twist_instance_id, 'note', 'create', v_create_timestamp, v_create_seq)
                    ON CONFLICT (twist_instance_id, entity, operation)
                        DO UPDATE SET
                            last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at),
                            last_update_seq = GREATEST (twist_instance_sync.last_update_seq, EXCLUDED.last_update_seq);
                END LOOP;
        END IF;
    END IF;
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
                INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at, last_update_seq)
                    VALUES (v_twist_instance_id, 'note', 'update', v_update_timestamp, v_update_seq)
                ON CONFLICT (twist_instance_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at),
                        last_update_seq = GREATEST (twist_instance_sync.last_update_seq, EXCLUDED.last_update_seq);
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
    v_max_seq xid8;
    v_twist_instance_id uuid;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        SELECT
            MAX(n.updated_at), MAX(n.seq) INTO v_max_updated_at, v_max_seq
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
            MAX(n.updated_at), MAX(n.seq) INTO v_max_updated_at, v_max_seq
        FROM
            new_table n
            JOIN note nt ON nt.id = n.note_id
            JOIN thread a ON a.id = nt.thread_id
        WHERE
            nt.draft = FALSE
            AND a.draft = FALSE;
    END IF;
    IF v_max_updated_at IS NULL THEN
        RETURN NULL;
    END IF;
    IF v_max_seq IS NULL THEN
        v_max_seq := pg_current_xact_id();
    END IF;
    FOR v_twist_instance_id IN SELECT DISTINCT
        pct.id
    FROM
        new_table n
        JOIN note nt ON nt.id = n.note_id
        JOIN thread a ON a.id = nt.thread_id
        JOIN twist_instance pct ON pct.id = nt.created_by
    WHERE
        nt.draft = FALSE
        AND a.draft = FALSE
        AND pct.archived_at IS NULL
    ORDER BY
        id LOOP
            INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at, last_update_seq)
                VALUES (v_twist_instance_id, 'note', 'update', v_max_updated_at, v_max_seq)
            ON CONFLICT (twist_instance_id, entity, operation)
                DO UPDATE SET
                    last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (twist_instance_sync.last_update_seq, EXCLUDED.last_update_seq);
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
    v_create_seq xid8;
    v_update_seq xid8;
    v_twist_instance_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT
            MAX(created_at), MAX(seq) INTO v_create_timestamp, v_create_seq
        FROM
            new_table;
    ELSE
        SELECT
            MAX(n.updated_at), MAX(n.seq) INTO v_update_timestamp, v_update_seq
        FROM
            new_table n;
    END IF;
    IF v_create_timestamp IS NULL AND v_update_timestamp IS NULL THEN
        RETURN NULL;
    END IF;
    IF v_create_timestamp IS NOT NULL AND v_create_seq IS NULL THEN
        v_create_seq := pg_current_xact_id();
    END IF;
    IF v_update_timestamp IS NOT NULL AND v_update_seq IS NULL THEN
        v_update_seq := pg_current_xact_id();
    END IF;
    IF v_create_timestamp IS NOT NULL THEN
        FOR v_twist_instance_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN twist_instance pct ON pct.id = n.created_by
        WHERE
            pct.archived_at IS NULL
        ORDER BY
            id LOOP
                INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at, last_update_seq)
                    VALUES (v_twist_instance_id, 'link', 'create', v_create_timestamp, v_create_seq)
                ON CONFLICT (twist_instance_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at),
                        last_update_seq = GREATEST (twist_instance_sync.last_update_seq, EXCLUDED.last_update_seq);
            END LOOP;
    END IF;
    IF v_update_timestamp IS NOT NULL THEN
        FOR v_twist_instance_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN twist_instance pct ON pct.id = n.created_by
        WHERE
            pct.archived_at IS NULL
        ORDER BY
            id LOOP
                INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at, last_update_seq)
                    VALUES (v_twist_instance_id, 'link', 'update', v_update_timestamp, v_update_seq)
                ON CONFLICT (twist_instance_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at),
                        last_update_seq = GREATEST (twist_instance_sync.last_update_seq, EXCLUDED.last_update_seq);
            END LOOP;
    END IF;
    RETURN NULL;
END;
$function$;
