-- Create "sync_user_for_thread_unread" function
CREATE FUNCTION "public"."sync_user_for_thread_unread" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Only notify the affected user (the one marked as unread)
    FOR v_user_id IN SELECT DISTINCT
        user_id
    FROM
        new_table
    ORDER BY
        user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'thread_read', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create trigger "user_sync_thread_unread_insert"
CREATE TRIGGER "user_sync_thread_unread_insert" AFTER INSERT ON "public"."thread_unread" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_thread_unread"();
-- Create trigger "user_sync_thread_unread_update"
CREATE TRIGGER "user_sync_thread_unread_update" AFTER UPDATE ON "public"."thread_unread" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_thread_unread"();
