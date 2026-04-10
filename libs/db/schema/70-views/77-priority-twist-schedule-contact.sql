-- Schedule contact status changes on shared schedules (link schedules) created by each twist.
-- Used to dispatch onScheduleContactUpdated callbacks to sources.
-- Scoped by created_by so it works for sources (priority_twist.priority_id IS NULL).
-- Exposes the link's owning thread as thread_id (schedule.thread_id itself is
-- NULL for link schedules) so the dispatcher can resolve the thread via
-- getThread({ id: item.thread_id }).
CREATE OR REPLACE VIEW "public"."priority_twist_schedule_contact"
AS
SELECT
    a.created_by AS priority_twist_id,
    sc.id AS schedule_contact_id,
    sc.schedule_id,
    sc.contact_id,
    sc.status,
    sc.role,
    sc.archived_at,
    a.id AS thread_id,
    s.link_id,
    sc.updated_at,
    a.priority_id
FROM
    priority_twist pt
    JOIN thread a ON a.created_by = pt.id
    JOIN link l ON l.thread_id = a.id AND l.created_by = pt.id
    JOIN schedule s ON s.link_id = l.id
    JOIN schedule_contact sc ON sc.schedule_id = s.id
WHERE
    a.draft = FALSE
    AND pt.archived_at IS NULL
    AND sc.updated_at > pt.created_at
ORDER BY
    sc.updated_at ASC;
