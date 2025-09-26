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
        jsonb_agg(at.actor_id) FILTER (WHERE at.deleted_at IS NULL) AS actor_ids,
        MAX(COALESCE(at.deleted_at, at.updated_at)) AS updated_at,
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

-- To filter on a date range, use both the `range_at` and `range_on` columns.
-- They're separate because combining timestamps and dates requires knowing
-- the user's timezone, which is client-specific.
CREATE OR REPLACE VIEW "public"."user_activity" WITH ( security_invoker = TRUE)
--
AS
SELECT
    up.user_id,
    a.*,
    CASE WHEN a.done_at IS NOT NULL THEN
        tstzrange(a.done_at, a.done_at, '[]')
    WHEN a.at IS NOT NULL THEN
        a.at
    WHEN a.on IS NOT NULL THEN
        NULL
    ELSE
        tstzrange(a.created_at, a.created_at, '[]')
    END AS range_at,
    CASE WHEN a.done_at IS NOT NULL THEN
        NULL
    WHEN a.at IS NOT NULL THEN
        NULL
    WHEN a.on IS NOT NULL THEN
        a.on
    ELSE
        NULL
    END AS range_on
FROM
    activity a
    JOIN user_priority up ON a.priority_id = up.id
WHERE
    up.deleted_at IS NULL;

CREATE OR REPLACE VIEW "public"."user_activity_exception" WITH ( security_invoker = TRUE)
--
AS
SELECT
    ua.user_id,
    ua.id,
    ae.occurrence,
    ae.updated_at,
    ua.range_at,
    ua.range_on,
    -- exception overrides
    CASE WHEN ae.deleted_at IS NULL THEN
        ae.at
    ELSE
        NULL
    END AS at,
    CASE WHEN ae.deleted_at IS NULL THEN
        ae.on
    ELSE
        NULL
    END AS ON,
    CASE WHEN ae.deleted_at IS NULL THEN
        ae.title
    ELSE
        NULL
    END AS title,
    CASE WHEN ae.deleted_at IS NULL THEN
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

