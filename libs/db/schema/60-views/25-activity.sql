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

CREATE OR REPLACE VIEW "public"."activity_children" WITH ( security_invoker = TRUE)
--
AS
SELECT
    a.id,
    c.id AS child_id
FROM
    "public"."activity" a
    JOIN "public"."activity" c ON c.path <@ a.path;

CREATE OR REPLACE VIEW "public"."user_activity_unread" WITH ( security_invoker = TRUE)
--
AS
SELECT
    up.user_id,
    a.id AS activity_id,
    unread.updated_at IS NOT NULL AS unread,
    COALESCE(ar.updated_at, unread.updated_at) AS updated_at
FROM
    user_priority up
    JOIN contact c ON c.user_id = up.user_id
    JOIN activity a ON a.priority_id = up.id
    LEFT JOIN activity_read ar ON ar.user_id = up.user_id
        AND ar.activity_path = subpath (a.path, 0, 1)
    LEFT JOIN LATERAL (
        SELECT
            MAX(a2.updated_at) AS updated_at
        FROM
            activity a2
        WHERE
            a2.archived_at IS NULL
            AND a2.path <@ a.path
            AND a2.author_id <> c.id
            AND (ar.read_at IS NULL
                OR a2.created_at > ar.read_at)) unread ON TRUE
WHERE
    up.archived_at IS NULL
    AND nlevel (a.path) = 1;

-- To filter on a date range, use both the `range_at` and `range_on` columns.
-- They're separate because combining timestamps and dates requires knowing
-- the user's timezone, which is client-specific.
CREATE OR REPLACE VIEW "public"."user_activity" AS
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
    p.path AS priority_path,
    a.type,
    a.path,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.note,
    a.links,
    a.at,
    a."on",
    a.duration,
    a.done_at,
    a.recurrence_rule,
    a.recurrence_exdates,
    a.recurrence_dates,
    a.meta,
    a.mentions,
    CASE WHEN (a.done_at IS NOT NULL) THEN
        tstzrange(a.done_at, a.done_at, '[]'::text)
    WHEN (a.at IS NOT NULL) THEN
        a.at
    WHEN (a."on" IS NOT NULL) THEN
        NULL::tstzrange
    ELSE
        tstzrange(a.created_at, a.created_at, '[]'::text)
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
FROM (((activity a
            JOIN priority p ON (p.id = a.priority_id))
        JOIN user_priority up ON (a.priority_id = up.id))
    LEFT JOIN user_activity_unread uau ON (((uau.user_id = up.user_id)
                AND (uau.activity_id = a.id))))
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

CREATE OR REPLACE FUNCTION public.activity_thread (p_activity_id uuid)
    RETURNS SETOF activity
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN QUERY
    SELECT
        ac.*
    FROM
        activity a
        JOIN activity ac ON a.path <@ ac.path
            OR (nlevel (a.path) > 1
                AND subpath (a.path, 0, nlevel (a.path) - 1) = subpath (ac.path, 0, nlevel (ac.path) - 1))
    WHERE
        a.id = p_activity_id
        AND ac.created_at <= a.created_at
    ORDER BY
        ac.created_at;
END;
$function$;

