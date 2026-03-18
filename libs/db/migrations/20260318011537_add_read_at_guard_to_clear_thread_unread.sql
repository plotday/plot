-- Create "clear_thread_unread" function
CREATE FUNCTION "user"."clear_thread_unread" ("user_id" uuid, "p_thread_id" uuid, "p_read_at" timestamptz DEFAULT now()) RETURNS void LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_priority_id uuid;
BEGIN
    SELECT
        priority_id INTO v_priority_id
    FROM
        thread
    WHERE
        id = p_thread_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;
    PERFORM "user".assert_priority_access(clear_thread_unread.user_id, v_priority_id);

    -- Only clear unread rows that were created/updated before the client's read_at.
    -- If updated_at > p_read_at, a new activity arrived after the client last synced,
    -- so we should not clear it (the client hasn't seen that activity yet).
    UPDATE thread_unread
    SET
        read_at = p_read_at,
        updated_at = now()
    WHERE
        thread_unread.user_id = clear_thread_unread.user_id
        AND thread_unread.thread_id = p_thread_id
        AND thread_unread.read_at IS NULL
        AND thread_unread.updated_at <= p_read_at;
END;
$$;
-- Drop "clear_thread_unread" function
DROP FUNCTION "user"."clear_thread_unread" (uuid, uuid);
