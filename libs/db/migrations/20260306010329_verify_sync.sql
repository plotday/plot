-- Create "sync_user_for_link" function
CREATE FUNCTION "public"."sync_user_for_link" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users with access to the link's priority (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN "user".priority_expanded upe ON upe.priority_id = n.priority_id
    WHERE
        upe.archived_at IS NULL
    ORDER BY
        upe.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'thread', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create trigger "user_sync_link_insert"
CREATE TRIGGER "user_sync_link_insert" AFTER INSERT ON "public"."link" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_link"();
-- Create trigger "user_sync_link_update"
CREATE TRIGGER "user_sync_link_update" AFTER UPDATE ON "public"."link" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_link"();
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
    -- Get all users with access to affected thread's priorities (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN thread a ON a.id = n.thread_id
        JOIN "user".priority_expanded upe ON upe.priority_id = a.priority_id
    WHERE
        upe.archived_at IS NULL
    ORDER BY
        upe.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'schedule', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    -- Handle link schedules (thread_id is NULL, link_id is set)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN link l ON l.id = n.link_id
        JOIN "user".priority_expanded upe ON upe.priority_id = l.priority_id
    WHERE
        n.thread_id IS NULL
        AND n.link_id IS NOT NULL
        AND upe.archived_at IS NULL
    ORDER BY
        upe.user_id LOOP
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
