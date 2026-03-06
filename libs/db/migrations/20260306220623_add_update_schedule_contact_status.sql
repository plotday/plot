-- Create "update_schedule_contact_status" function
CREATE FUNCTION "user"."update_schedule_contact_status" ("user_id" uuid, "p_schedule_id" uuid, "p_status" text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_contact_id uuid;
    v_priority_id uuid;
BEGIN
    -- Resolve user's contact_id
    v_contact_id := "user".user_contact_id(user_id);
    IF v_contact_id IS NULL THEN
        RAISE EXCEPTION 'User has no contact record';
    END IF;

    -- Validate user has priority access to the schedule (supports both thread_id and link_id paths)
    SELECT
        CASE
            WHEN s.thread_id IS NOT NULL THEN t.priority_id
            WHEN s.link_id IS NOT NULL THEN lt.priority_id
        END INTO v_priority_id
    FROM schedule s
    LEFT JOIN thread t ON t.id = s.thread_id
    LEFT JOIN link l ON l.id = s.link_id
    LEFT JOIN thread lt ON lt.id = l.thread_id
    WHERE s.id = p_schedule_id;

    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Schedule not found';
    END IF;

    IF NOT "user".has_priority_access(user_id, v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this schedule';
    END IF;

    -- Validate status
    IF p_status IS NOT NULL AND p_status NOT IN ('attend', 'skip') THEN
        RAISE EXCEPTION 'Invalid status: must be attend, skip, or null';
    END IF;

    -- Upsert schedule_contact row
    INSERT INTO schedule_contact (schedule_id, contact_id, status)
    VALUES (p_schedule_id, v_contact_id, p_status)
    ON CONFLICT (schedule_id, contact_id)
    DO UPDATE SET status = p_status;
END;
$$;
