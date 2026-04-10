-- Modify "update_schedule_contact_status" function
CREATE OR REPLACE FUNCTION "user"."update_schedule_contact_status" ("user_id" uuid, "p_schedule_id" uuid, "p_status" text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_priority_id uuid;
    v_primary_contact_id uuid;
    v_updated_count integer;
BEGIN
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

    -- Prefer updating any existing row whose contact_id belongs to the user.
    -- If the user has multiple linked contacts that are independently listed
    -- as attendees on this schedule, all rows get the same status.
    UPDATE schedule_contact
    SET status = p_status
    WHERE schedule_id = p_schedule_id
      AND contact_id = ANY("user".user_contact_ids(user_id))
      AND archived_at IS NULL;

    GET DIAGNOSTICS v_updated_count = ROW_COUNT;

    -- Fall back to inserting a row under the user's primary contact for native
    -- schedules where the user has no pre-existing attendee row.
    IF v_updated_count = 0 THEN
        v_primary_contact_id := "user".user_contact_id(user_id);
        IF v_primary_contact_id IS NULL THEN
            RAISE EXCEPTION 'User has no contact record';
        END IF;

        INSERT INTO schedule_contact (schedule_id, contact_id, status, role)
        VALUES (p_schedule_id, v_primary_contact_id, p_status, 'required')
        ON CONFLICT (schedule_id, contact_id)
        DO UPDATE SET status = EXCLUDED.status;
    END IF;
END;
$$;
