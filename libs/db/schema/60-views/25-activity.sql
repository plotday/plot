CREATE OR REPLACE VIEW "public"."activity_tags" WITH ( security_invoker = TRUE)
--
AS
SELECT
    sq.activity_id,
    sq.occurrence,
    jsonb_object_agg(sq.tag_id, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL
        AND jsonb_array_length(sq.actor_ids) > 0) AS tags,
    MAX(sq.updated_at) AS updated_at,
    (array_agg(sq.updated_by ORDER BY sq.updated_at DESC))[1] AS updated_by
FROM (
    SELECT
        at.activity_id,
        at.occurrence,
        at.tag_id,
        jsonb_agg(at.actor_id) FILTER (WHERE at.archived_at IS NULL) AS actor_ids,
        MAX(COALESCE(at.archived_at, at.updated_at)) AS updated_at,
        (array_agg(at.updated_by ORDER BY at.updated_at DESC))[1] AS updated_by
    FROM
        "public"."activity_tag" at
    GROUP BY
        at.activity_id,
        at.occurrence,
        at.tag_id) sq
GROUP BY
    sq.activity_id,
    sq.occurrence;

CREATE OR REPLACE VIEW "public"."user_activity_unread" WITH ( security_invoker = TRUE)
--
AS
SELECT
    upe.user_id,
    a.id AS activity_id,
    ar.read_at IS NULL AS unread,
    GREATEST (COALESCE(ar.updated_at, 'epoch'), CASE WHEN a.created_by = upe.user_id THEN
            COALESCE(a.last_note_created_at, 'epoch')
        ELSE
            COALESCE(a.last_note_created_at, a.created_at)
        END) AS updated_at
FROM
    -- All the user's priorities
    user_priority_expanded upe
    -- All non-archived activities in those priorities created after user joined
    JOIN activity a ON a.priority_id = upe.priority_id
        AND a.archived_at IS NULL
        -- For self-created activities: only include if there are notes
        -- For others: use standard logic
        AND ((a.created_by = upe.user_id
                AND a.last_note_created_at IS NOT NULL
                AND a.last_note_created_at > upe.joined_at)
            OR ((a.created_by IS NULL
                    OR a.created_by != upe.user_id)
                AND COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at))
    LEFT JOIN activity_read ar ON ar.user_id = upe.user_id
        AND ar.activity_id = a.id
        AND ar.read_at >= CASE WHEN a.created_by = upe.user_id THEN
            a.last_note_created_at
        ELSE
            COALESCE(a.last_note_created_at, a.created_at)
        END;

-- Add priority_path and mentions to activity view
CREATE OR REPLACE VIEW "public"."activity_x" WITH ( security_invoker = TRUE)
--
AS
SELECT
    a.*,
    p.path AS priority_path,
    m.mentions
FROM
    activity a
    JOIN priority p ON p.id = a.priority_id
    LEFT JOIN (
        SELECT
            n.activity_id,
            ARRAY_AGG(DISTINCT mention) AS mentions
        FROM
            note n,
            LATERAL unnest(n.mentions) AS mention
        WHERE
            n.archived_at IS NULL
            AND n.mentions IS NOT NULL
        GROUP BY
            n.activity_id) m ON m.activity_id = a.id;

-- To filter on a date range, use both the `range_at` and `range_on` columns.
-- They're separate because combining timestamps and dates requires knowing
-- the user's timezone, which is client-specific.
CREATE OR REPLACE VIEW "public"."user_activity" WITH ( security_invoker = TRUE)
--
AS
SELECT
    upe.user_id,
    a.id,
    a.created_at,
    -- updated_at includes last_note_created_at for sync
    COALESCE(GREATEST (a.updated_at, a.last_note_created_at), a.updated_at) AS updated_at,
    a.author_id,
    a.assignee_id,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at) AS archived_at,
    a.priority_id,
    a.priority_path,
    a.type,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.at,
    a."on",
    a.duration,
    a.done_at,
    a.recurrence_rule,
    a.recurrence_exdates,
    a.recurrence_dates,
    a.meta,
    a.source,
    a.created_by_twist_id,
    a.last_note_created_at,
    a.mentions,
    CASE WHEN a.done_at IS NOT NULL THEN
        tstzrange(a.done_at, a.done_at, '[]')
    WHEN a.at IS NOT NULL THEN
        a.at
    WHEN a."on" IS NOT NULL THEN
        NULL::tstzrange
    ELSE
        tstzrange(GREATEST (a.created_at, COALESCE(a.last_note_created_at, a.created_at)), GREATEST (a.created_at, COALESCE(a.last_note_created_at, a.created_at)), '[]')
    END AS range_at,
    CASE WHEN a.done_at IS NOT NULL THEN
        NULL::daterange
    WHEN a.at IS NOT NULL THEN
        NULL::daterange
    WHEN a."on" IS NOT NULL THEN
        a."on"
    ELSE
        NULL::daterange
    END AS range_on,
    COALESCE(uau.unread, FALSE) AS unread
FROM
    activity_x a
    JOIN user_priority_expanded upe ON a.priority_id = upe.priority_id
    LEFT JOIN user_activity_unread uau ON uau.user_id = upe.user_id
        AND uau.activity_id = a.id;

CREATE OR REPLACE VIEW "public"."user_activity_exception" WITH ( security_invoker = TRUE)
--
AS
SELECT
    ua.user_id,
    ua.id,
    COALESCE(ae.archived_at, ua.archived_at) AS archived_at,
    ae.occurrence,
    ae.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    -- exception overrides
    ae.at,
    ae.on,
    ae.title,
    ae.note
FROM
    activity_exception ae
    JOIN user_activity ua ON ua.id = ae.activity_id;

CREATE OR REPLACE VIEW "public"."user_activity_tags" WITH ( security_invoker = TRUE)
--
AS
SELECT
    ua.user_id,
    ua.id,
    ua.archived_at,
    at.occurrence,
    at.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    at.tags
FROM
    activity_tags at
    JOIN user_activity ua ON ua.id = at.activity_id;

