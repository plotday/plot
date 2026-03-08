-- User-scoped schedule view
-- Shows shared schedules (user_id IS NULL) to all priority members
-- Shows per-user schedules (user_id IS NOT NULL) only to the owning user
-- Computes range_at/range_on for client-side time-based filtering
-- Handles both thread_id and link_id paths for priority access
CREATE OR REPLACE VIEW "user"."schedule"
--
AS
SELECT
    upe.user_id,
    s.id,
    s.created_at,
    s.updated_at,
    COALESCE(s.archived_at, upe.archived_at) AS archived_at,
    s.user_id AS schedule_user_id,
    s."order",
    s.at,
    s."on",
    s.recurrence_rule,
    s.duration,
    s.recurrence_exdates,
    s.occurrence,
    s.thread_id,
    s.link_id,
    upe.path AS priority_path,
    -- range_at: for timestamp-based schedules
    CASE WHEN s.at IS NOT NULL THEN
        s.at
    ELSE
        NULL::tstzrange
    END AS range_at,
    -- range_on: for date-based schedules
    CASE WHEN s."on" IS NOT NULL THEN
        s."on"
    ELSE
        NULL::daterange
    END AS range_on,
    -- contacts: aggregated schedule_contact rows with contact details as JSON array
    COALESCE(
        (SELECT jsonb_agg(jsonb_build_object(
            'id', sc.id,
            'contact_id', sc.contact_id,
            'contact_email', c.email,
            'contact_name', c.name,
            'contact_user_id', c.user_id,
            'status', sc.status,
            'role', sc.role,
            'archived_at', sc.archived_at,
            'updated_at', sc.updated_at
        ) ORDER BY sc.created_at)
        FROM schedule_contact sc
        JOIN contact c ON c.id = sc.contact_id
        WHERE sc.schedule_id = s.id),
        '[]'::jsonb
    ) AS contacts
FROM
    schedule s
    -- Join via thread when thread_id is set
    LEFT JOIN thread t_thread ON t_thread.id = s.thread_id
    -- Join via link -> thread when link_id is set
    LEFT JOIN link l ON l.id = s.link_id
    LEFT JOIN thread t_link ON t_link.id = l.thread_id
    -- Get priority from whichever path is active
    JOIN "user".priority_expanded upe ON upe.priority_id = COALESCE(t_thread.priority_id, t_link.priority_id)
WHERE
    -- Shared schedules visible to all priority members
    (s.user_id IS NULL
    -- Per-user schedules visible only to the owning user
    OR s.user_id = upe.user_id);

ALTER VIEW "user"."schedule" OWNER TO postgres;
