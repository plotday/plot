-- User-scoped schedule view. Shows shared schedules to users who can see the
-- schedule's parent.
--   - Link-attached schedules (link_id IS NOT NULL) follow the link's per-user
--     visibility: connector-authored links are visible only to the twist_instance
--     owner, so their schedules are too. This keeps two users' connections of the
--     same calendar event from each showing as duplicate agenda entries.
--   - Thread-scoped schedules (link_id IS NULL) stay shared across thread members.
-- Per-user todo/order/action state now lives on thread_state, not schedule.
-- Computes range_at/range_on for client-side time-based filtering.
CREATE OR REPLACE VIEW "user"."schedule"
--
AS
SELECT
    tp.user_id,
    s.id,
    s.created_at,
    s.updated_at,
    s.seq,
    COALESCE(s.archived_at, upe.archived_at) AS archived_at,
    s.at,
    s."on",
    s.recurrence_rule,
    s.duration,
    s.recurrence_exdates,
    s.occurrence,
    s.thread_id,
    s.link_id,
    s.reason,
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
    -- Join via link -> thread when link_id is set
    LEFT JOIN link l ON l.id = s.link_id AND l.archived_at IS NULL
    -- Resolve the link's owning twist_instance for per-user visibility.
    -- When l.twist_id IS NOT NULL, link.created_by is a twist_instance_id.
    LEFT JOIN twist_instance ti
        ON ti.id = l.created_by
        AND l.twist_id IS NOT NULL
        AND ti.archived_at IS NULL
    -- Resolve thread_id from either direct or via link
    JOIN thread_priority tp ON tp.thread_id = COALESCE(s.thread_id, l.thread_id)
        AND tp.revoked_at IS NULL
        AND (
            tp.priority_id IS NOT NULL
            OR tp.classify_at < now() - public.classify_visibility_window()
        )
        -- Per-user gate for connector link schedules: only the twist_instance owner sees them.
        -- Thread-scoped schedules (link_id IS NULL) and schedules on user-authored links
        -- (l.twist_id IS NULL) stay shared across thread members.
        AND (
            s.link_id IS NULL
            OR l.twist_id IS NULL
            OR ti.owner_id = tp.user_id
        )
    -- Get priority path from the user's filing (case-A → root via COALESCE)
    LEFT JOIN "user".priority_expanded upe
        ON upe.user_id = tp.user_id
        AND upe.priority_id = "user".effective_priority_id(tp.priority_id, tp.user_id);
