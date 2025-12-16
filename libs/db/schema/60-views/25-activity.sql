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
AS SELECT DISTINCT ON (up.user_id, a.id)
    up.user_id,
    a.id AS activity_id,
    unread.updated_at IS NOT NULL AS unread,
    GREATEST (ar.updated_at, unread.updated_at) AS updated_at,
    last_note.created_at AS last_note_created_at
FROM
    user_priority up
    JOIN contact c ON c.user_id = up.user_id
    JOIN activity a ON a.priority_id = up.id
    LEFT JOIN activity_read ar ON ar.user_id = up.user_id
        AND ar.activity_id = a.id
        -- Join to get when user was added to the priority root
    LEFT JOIN LATERAL (
        SELECT
            pu.created_at
        FROM
            priority_user pu
            JOIN priority p ON p.id = pu.priority_id
            JOIN priority ap ON ap.id = a.priority_id
        WHERE
            pu.user_id = up.user_id
            AND p.path @> ap.path
        ORDER BY
            nlevel (p.path) ASC
        LIMIT 1) member ON TRUE
    LEFT JOIN LATERAL (
        -- Check for notes by another author newer than read_at
        SELECT
            MAX(GREATEST (a.updated_at, n.created_at)) AS updated_at
        FROM
            note n
        WHERE
            n.activity_id = a.id
            AND n.archived_at IS NULL
            AND n.author_id <> c.id
            -- Only notes created after user joined the priority
            AND (member.created_at IS NULL
                OR n.created_at >= member.created_at)
            AND (ar.read_at IS NULL
                OR n.created_at > ar.read_at)
        UNION ALL
        -- Check if activity itself is by another author and not read
        SELECT
            a.updated_at
        WHERE
            a.author_id <> c.id
            -- Only activities created after user joined the priority
            AND (member.created_at IS NULL
                OR a.created_at >= member.created_at)
            AND ar.read_at IS NULL) unread ON TRUE
    LEFT JOIN LATERAL (
        -- Get the most recent note created_at for this activity
        SELECT
            MAX(n.created_at) AS created_at
        FROM
            note n
        WHERE
            n.activity_id = a.id
            AND n.draft = FALSE
            AND n.archived_at IS NULL) last_note ON TRUE
    WHERE
        up.archived_at IS NULL
    ORDER BY
        up.user_id,
        a.id,
        -- Prefer rows where unread is true (unread.updated_at IS NOT NULL)
        unread.updated_at DESC NULLS LAST;

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
    up.user_id,
    a.id,
    a.created_at,
    COALESCE(uau.updated_at, a.updated_at) AS updated_at,
    a.author_id,
    a.assignee_id,
    a.updated_by,
    a.archived_at,
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
    uau.last_note_created_at,
    (
        SELECT
            ARRAY ( SELECT DISTINCT
                    unnest(n.mentions)
                FROM
                    note n
                WHERE
                    n.activity_id = a.id
                    AND n.archived_at IS NULL
                    AND n.mentions IS NOT NULL)) AS mentions,
        CASE WHEN (a.done_at IS NOT NULL) THEN
            tstzrange(a.done_at, a.done_at, '[]'::text)
        WHEN (a.at IS NOT NULL) THEN
            a.at
        WHEN (a."on" IS NOT NULL) THEN
            NULL::tstzrange
        ELSE
            tstzrange(GREATEST (a.created_at, COALESCE(uau.last_note_created_at, a.created_at)), GREATEST (a.created_at, COALESCE(uau.last_note_created_at, a.created_at)), '[]'::text)
        END AS range_at,
        CASE WHEN (a.done_at IS NOT NULL) THEN
            NULL::daterange
        WHEN (a.at IS NOT NULL) THEN
            NULL::daterange
        WHEN (a."on" IS NOT NULL) THEN
            a."on"
        ELSE
            NULL::daterange
        END AS range_on,
        COALESCE(uau.unread, FALSE) AS unread
    FROM (activity_x a
        JOIN user_priority up ON (a.priority_id = up.id))
    LEFT JOIN user_activity_unread uau ON (((uau.user_id = up.user_id)
                AND (uau.activity_id = a.id)))
WHERE (up.archived_at IS NULL);

CREATE OR REPLACE VIEW "public"."user_activity_exception" WITH ( security_invoker = TRUE)
--
AS
SELECT
    ua.user_id,
    ua.id,
    ae.occurrence,
    ae.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    -- exception overrides
    CASE WHEN ae.archived_at IS NULL THEN
        ae.at
    ELSE
        NULL
    END AS at,
    CASE WHEN ae.archived_at IS NULL THEN
        ae.on
    ELSE
        NULL
    END AS ON,
    CASE WHEN ae.archived_at IS NULL THEN
        ae.title
    ELSE
        NULL
    END AS title,
    CASE WHEN ae.archived_at IS NULL THEN
        ae.note
    ELSE
        NULL
    END AS note
FROM
    activity_exception ae
    JOIN user_activity ua ON ua.id = ae.activity_id;

CREATE OR REPLACE VIEW "public"."user_activity_tags" WITH ( security_invoker = TRUE)
--
AS
SELECT
    ua.user_id,
    ua.id,
    at.occurrence,
    at.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    at.tags
FROM
    activity_tags at
    JOIN user_activity ua ON ua.id = at.activity_id;

