-- Upsert schedule contacts for a given schedule.
-- Each contact is upserted by (schedule_id, contact_id).
-- Contacts not in the array are left unchanged (not deleted).
-- Set archived_at to remove a contact.
CREATE OR REPLACE FUNCTION "user".upsert_schedule_contacts (
    user_id uuid,
    p_schedule_id uuid,
    p_contacts jsonb
)
    RETURNS void
    LANGUAGE plpgsql
    AS $function$
DECLARE
    v_contact jsonb;
    v_contact_id uuid;
    v_status text;
    v_role text;
    v_archived boolean;
    v_priority_id uuid;
BEGIN
    -- Validate user has access to the schedule's priority
    -- Supports both thread_id and link_id paths
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
    -- Enforce viewer restriction: viewers cannot manage schedule contacts
    IF "user".get_effective_role(upsert_schedule_contacts.user_id, v_priority_id) = 'viewer' THEN
        RAISE EXCEPTION 'Viewer members cannot manage schedule contacts';
    END IF;

    FOR v_contact IN SELECT * FROM jsonb_array_elements(p_contacts)
    LOOP
        v_contact_id := (v_contact ->> 'contact_id')::uuid;
        v_status := v_contact ->> 'status';
        v_role := v_contact ->> 'role';
        v_archived := COALESCE((v_contact ->> 'archived')::boolean, false);

        INSERT INTO schedule_contact (schedule_id, contact_id, status, role, archived_at)
        VALUES (
            p_schedule_id,
            v_contact_id,
            v_status,
            COALESCE(v_role, 'required'),
            CASE WHEN v_archived THEN now() ELSE NULL END
        )
        ON CONFLICT (schedule_id, contact_id)
        DO UPDATE SET
            status = CASE
                WHEN v_contact ? 'status' THEN EXCLUDED.status
                ELSE schedule_contact.status
            END,
            role = CASE
                WHEN v_contact ? 'role' THEN EXCLUDED.role
                ELSE schedule_contact.role
            END,
            archived_at = CASE
                WHEN v_archived THEN COALESCE(schedule_contact.archived_at, now())
                ELSE NULL
            END;

        -- Ensure priority_contact exists for the contact
        INSERT INTO priority_contact (priority_id, contact_id)
        VALUES (v_priority_id, v_contact_id)
        ON CONFLICT (priority_id, contact_id) DO NOTHING;
    END LOOP;
END;
$function$;

-- Update the current user's RSVP status on a schedule.
-- Works for both thread and link schedules (unlike POST /sync/schedules which blocks link schedules).
--
-- Actor resolution: a user may have multiple linked contacts (primary + non-primary
-- emails). When one of those contacts already has a schedule_contact row on this
-- schedule (typically placed there by sync from a non-primary calendar), update
-- that row instead of creating a new one under the primary contact. This keeps
-- the connector write-back path using the correct account's auth token and avoids
-- orphan rows.
CREATE OR REPLACE FUNCTION "user".update_schedule_contact_status (
    user_id uuid,
    p_schedule_id uuid,
    p_status text
)
    RETURNS void
    LANGUAGE plpgsql
    AS $function$
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
$function$;
