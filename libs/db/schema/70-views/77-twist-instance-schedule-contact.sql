-- Schedule contact status changes on shared schedules (link schedules) created by each twist.
-- Used to dispatch onScheduleContactUpdated callbacks to sources.
CREATE OR REPLACE VIEW "public"."twist_instance_schedule_contact"
AS
SELECT
    a.created_by AS twist_instance_id,
    sc.id AS schedule_contact_id,
    sc.schedule_id,
    sc.contact_id,
    sc.status,
    sc.role,
    sc.archived_at,
    s.thread_id,
    s.link_id,
    sc.updated_at,
    sc.seq,
    tp.priority_id
FROM
    twist_instance pt
    JOIN link l ON l.created_by = pt.id
    JOIN thread a ON a.id = l.thread_id
    LEFT JOIN thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
    JOIN schedule s ON s.link_id = l.id
    JOIN schedule_contact sc ON sc.schedule_id = s.id
WHERE
    a.draft = FALSE
    AND pt.archived_at IS NULL
    AND sc.updated_at > pt.created_at
ORDER BY
    sc.updated_at ASC;
