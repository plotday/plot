-- Modify "clear_thread_unread" function
CREATE OR REPLACE FUNCTION "user"."clear_thread_unread" ("user_id" uuid, "p_thread_id" uuid, "p_read_at" timestamptz DEFAULT now(), "p_bumped_at" timestamptz DEFAULT NULL::timestamp with time zone) RETURNS void LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
#variable_conflict use_column
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

    -- Upsert to handle the race where the user reads a thread before analysis
    -- creates the thread_unread row. If no row exists, INSERT a preemptive read
    -- marker so that when analysis later calls upsert_thread_unread, the
    -- race guard (read_at >= note_created_at) preserves it.
    -- If a row exists, only clear it if the client has seen all current content
    -- (p_read_at >= thread's content timestamp).
    INSERT INTO thread_unread (user_id, thread_id, urgency, importance, read_at, bumped_at)
        VALUES (clear_thread_unread.user_id, p_thread_id, 'inform-updates', 50, p_read_at, p_bumped_at)
    ON CONFLICT (user_id, thread_id)
        DO UPDATE SET
            read_at = p_read_at,
            updated_at = now(),
            bumped_at = CASE WHEN p_bumped_at IS NOT NULL THEN p_bumped_at ELSE thread_unread.bumped_at END
        WHERE
            thread_unread.read_at IS NULL
            AND p_read_at >= (
                SELECT COALESCE(t.last_note_source_created_at, t.created_at)
                FROM thread t
                WHERE t.id = p_thread_id
            );
END;
$$;
