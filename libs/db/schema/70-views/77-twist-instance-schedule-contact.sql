-- Schedule contact status changes on shared schedules (link schedules).
-- Used to dispatch onScheduleContactUpdated callbacks.
--
-- Routes to the RSVPing user's own connector instance (resolved via
-- twist_instance_for_actor on sc.contact_id), NOT the link's first-writer
-- twist instance. Each user must have their own connection to write the
-- RSVP back to the external calendar with their own OAuth token; the first
-- writer's instance does not have other users' tokens.
--
-- Rows are emitted only when the RSVPing user has a matching, non-archived
-- twist instance of the same connector type (Google Calendar, Outlook
-- Calendar, etc.). If the user does not have such a connection, the RSVP
-- still lives in Plot but does not propagate to their external calendar.
CREATE OR REPLACE VIEW "public"."twist_instance_schedule_contact"
AS
SELECT
    pt.id AS twist_instance_id,
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
    schedule_contact sc
    JOIN schedule s ON s.id = sc.schedule_id
    JOIN link l ON l.id = s.link_id
    JOIN thread a ON a.id = l.thread_id
    JOIN twist_instance pt
        ON pt.id = public.twist_instance_for_actor (sc.contact_id, l.created_by)
    LEFT JOIN thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
WHERE
    a.draft = FALSE
    AND sc.updated_at > pt.created_at
ORDER BY
    sc.updated_at ASC;
