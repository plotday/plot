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
    -- Get all users with access to the link's priority (including hierarchical access)
    -- Use COALESCE to derive priority from thread when link has no direct priority_id
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        LEFT JOIN thread t ON t.id = n.thread_id
        JOIN "user".priority_expanded upe ON upe.priority_id = COALESCE(n.priority_id, t.priority_id)
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
