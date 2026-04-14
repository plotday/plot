-- Modify "sync_user_for_twist_instance" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_twist_instance" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Notify the owner of each twist_instance
    FOR v_user_id IN SELECT DISTINCT
        n.owner_id
    FROM
        new_table n
    ORDER BY
        1 LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'twist_instance', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
