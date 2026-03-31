-- Create "upsert_thread_unread" function
CREATE FUNCTION "user"."upsert_thread_unread" ("user_id" uuid, "p_thread_id" uuid, "p_urgency" text, "p_importance" smallint DEFAULT 50, "p_read_at" timestamptz DEFAULT NULL::timestamp with time zone, "p_bumped_at" timestamptz DEFAULT NULL::timestamp with time zone, "p_note_created_at" timestamptz DEFAULT NULL::timestamp with time zone) RETURNS "public"."thread_unread" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
#variable_conflict use_column
DECLARE
    v_priority_id uuid;
    v_row thread_unread;
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
    PERFORM "user".assert_priority_access(upsert_thread_unread.user_id, v_priority_id);

    INSERT INTO thread_unread (user_id, thread_id, urgency, importance, read_at, bumped_at)
        VALUES (upsert_thread_unread.user_id, p_thread_id, p_urgency, p_importance, p_read_at, p_bumped_at)
    ON CONFLICT (user_id, thread_id)
        DO UPDATE SET
            urgency = EXCLUDED.urgency,
            importance = EXCLUDED.importance,
            read_at = CASE
                -- Race condition: user read after the note was created → preserve their read
                WHEN p_note_created_at IS NOT NULL
                    AND thread_unread.read_at IS NOT NULL
                    AND thread_unread.read_at >= p_note_created_at
                THEN thread_unread.read_at
                -- New activity or no timestamp context: use caller's value (NULL = unread)
                ELSE EXCLUDED.read_at
            END,
            bumped_at = CASE WHEN p_bumped_at IS NOT NULL THEN p_bumped_at ELSE thread_unread.bumped_at END,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Drop "upsert_thread_unread" function
DROP FUNCTION "user"."upsert_thread_unread" (uuid, uuid, text, smallint, timestamptz, timestamptz);
