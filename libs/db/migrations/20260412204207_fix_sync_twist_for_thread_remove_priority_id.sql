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
