-- Create "sync_user_for_thread_priority" function
CREATE FUNCTION "public"."sync_user_for_thread_priority" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Fall back to now() for DELETE (which has no updated_at column).
    IF v_max_updated_at IS NULL THEN
        v_max_updated_at := now();
    END IF;
    FOR v_user_id IN SELECT DISTINCT
        user_id
    FROM
        new_table
    ORDER BY
        user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'thread', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create trigger "user_sync_thread_priority_delete"
CREATE TRIGGER "user_sync_thread_priority_delete" AFTER DELETE ON "public"."thread_priority" REFERENCING OLD TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_thread_priority"();
-- Create trigger "user_sync_thread_priority_insert"
CREATE TRIGGER "user_sync_thread_priority_insert" AFTER INSERT ON "public"."thread_priority" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_thread_priority"();
-- Create trigger "user_sync_thread_priority_update"
CREATE TRIGGER "user_sync_thread_priority_update" AFTER UPDATE ON "public"."thread_priority" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_thread_priority"();
