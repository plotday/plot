DROP TRIGGER IF EXISTS "upsert_user_priority" ON "public"."user_priority";

DROP VIEW IF EXISTS "public"."activity_children";

DROP VIEW IF EXISTS "public"."priority_tags";

DROP VIEW IF EXISTS "public"."user_activity_exception";

DROP VIEW IF EXISTS "public"."user_activity_tags";

DROP VIEW IF EXISTS "public"."user_activity";

DROP VIEW IF EXISTS "public"."user_activity_unread";

DROP VIEW IF EXISTS "public"."user_priority";

ALTER TABLE "public"."activity"
    ADD COLUMN "pick_priority" jsonb;

SET check_function_bodies = OFF;

CREATE OR REPLACE VIEW "public"."activity_children" AS
SELECT
    a.id,
    c.id AS child_id
FROM (activity a
    JOIN activity c ON (c.path <@ a.path));

CREATE OR REPLACE FUNCTION public.find_matching_activities_scored (query_embedding text, created_by_id uuid, required_filters jsonb DEFAULT '{}' ::jsonb, scored_fields jsonb DEFAULT '{}' ::jsonb, activity_data jsonb DEFAULT '{}' ::jsonb, similarity_threshold double precision DEFAULT 0.7)
    RETURNS TABLE (
        id uuid,
        priority_id uuid,
        title text,
        total_score double precision)
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN QUERY WITH filtered_activities AS (
        -- First filter by required exact matches
        SELECT
            a.id,
            a.priority_id,
            a.title,
            a.type,
            a.mentions,
            a.meta,
            a.embedding
        FROM
            public.activity a
        WHERE
            a.created_by = created_by_id
            AND a.archived_at IS NULL
            -- Content similarity filter (when content is required)
            AND ((required_filters ? 'content'
                    AND a.embedding IS NOT NULL
                    AND (1 - (a.embedding <=> query_embedding::vector)) >= similarity_threshold)
                OR NOT (required_filters ? 'content'))
            -- Type exact match (when type is required)
            AND ((required_filters ? 'type'
                    AND a.type = (activity_data ->> 'type')::int)
                OR NOT (required_filters ? 'type'))
            -- Meta field exact matches (when meta.field is required)
            AND (
                -- Check all required meta fields match
                NOT EXISTS (
                    SELECT
                        1
                    FROM
                        jsonb_object_keys(required_filters) AS key
                    WHERE
                        key LIKE 'meta.%'
                        AND (a.meta IS NULL
                            OR a.meta ->> substring(key FROM 6) IS DISTINCT FROM activity_data -> 'meta' ->> substring(key FROM 6))))
),
scored_activities AS (
    -- Calculate scores for each matching activity
    SELECT
        fa.id,
        fa.priority_id,
        fa.title,
        -- Sum up all scores
        (
            -- Content similarity score
            COALESCE(
                CASE WHEN scored_fields ? 'content'
                    AND fa.embedding IS NOT NULL THEN
                    (scored_fields ->> 'content')::float * (1 - (fa.embedding <=> query_embedding::vector))
                ELSE
                    0
                END, 0) +
            -- Type exact match score
            COALESCE(
                CASE WHEN scored_fields ? 'type' THEN
                    CASE WHEN fa.type = (activity_data ->> 'type')::int THEN
                        (scored_fields ->> 'type')::float
                    ELSE
                        0
                END
                ELSE
                    0
                END, 0) +
            -- Mentions array overlap score
            COALESCE(
                CASE WHEN scored_fields ? 'mentions'
                    AND fa.mentions IS NOT NULL
                    AND jsonb_array_length(activity_data -> 'mentions') > 0 THEN
                    (scored_fields ->> 'mentions')::float * (
                        -- Count matching elements / length of existing array
                        (
                            SELECT
                                COUNT(*)::float
                            FROM jsonb_array_elements_text(fa.mentions::jsonb) existing_mention
                            WHERE
                                existing_mention IN (
                                    SELECT
                                        jsonb_array_elements_text(activity_data -> 'mentions'))) / jsonb_array_length(fa.mentions::jsonb))
                ELSE
                    0
                END, 0) +
            -- Meta field exact match scores
            COALESCE((
                SELECT
                    COALESCE(SUM(
                            CASE WHEN fa.meta IS NOT NULL
                                AND fa.meta ->> substring(key FROM 6) IS NOT DISTINCT FROM activity_data -> 'meta' ->> substring(key FROM 6) THEN
                                (scored_fields ->> key)::float
                            ELSE
                                0
                            END), 0)
                FROM jsonb_object_keys(scored_fields) AS key
                WHERE
                    key LIKE 'meta.%'), 0)) AS total_score
FROM
    filtered_activities fa
)
SELECT
    sa.id,
    sa.priority_id,
    sa.title,
    sa.total_score
FROM
    scored_activities sa
WHERE
    sa.total_score > 0
ORDER BY
    sa.total_score DESC
LIMIT 1;
END;
$function$;

CREATE OR REPLACE VIEW "public"."priority_tags" AS
SELECT
    a.priority_id,
    at.tag_id,
    count(*) AS count,
    max(COALESCE(at.archived_at, at.updated_at)) AS updated_at
FROM (activity_tag at
    JOIN activity a ON (at.activity_id = a.id))
WHERE ((at.archived_at IS NULL)
    AND (a.archived_at IS NULL)
    AND (nlevel (a.path) = 1))
GROUP BY
    a.priority_id,
    at.tag_id;

CREATE OR REPLACE VIEW "public"."user_priority" AS
SELECT
    pu.user_id,
    p.id,
    p.created_at,
    GREATEST (settings.updated_at, pu.updated_at, p.updated_at, COALESCE(activity_max.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone), COALESCE(ar_max.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    GREATEST (pu.archived_at, p.archived_at) AS archived_at,
    p.created_by,
    p.updated_by,
    (root.root
        AND (p.id = root.id)) AS root,
    p.title,
    CASE WHEN (inherited_settings.path IS NOT NULL) THEN
        inherited_settings.path
    WHEN (user_root.path @> p.path) THEN
        p.path
    ELSE
        (user_root.path || p.path)
    END AS path,
    settings.top_order,
    inherited_settings.pomodoro,
    inherited_settings.color,
    COALESCE(unread.unread, FALSE) AS unread
FROM (((((((((priority_user pu
                                LEFT JOIN contact c ON (c.user_id = pu.user_id))
                            JOIN priority root ON (pu.priority_id = root.id))
                        JOIN priority user_root ON (((pu.user_id = user_root.created_by)
                                    AND user_root.root)))
                    JOIN priority p ON (root.path @> p.path))
                LEFT JOIN priority_settings settings ON (((settings.user_id = pu.user_id)
                            AND (p.id = settings.priority_id))))
            LEFT JOIN priority_settings_inherited inherited_settings ON (((inherited_settings.user_id = pu.user_id)
                        AND (p.id = inherited_settings.priority_id))))
        LEFT JOIN LATERAL (
            SELECT
                max(a.updated_at) AS updated_at
            FROM (activity a
                JOIN priority ap ON (ap.id = a.priority_id))
        WHERE ((ap.path <@ p.path)
            AND (a.archived_at IS NULL))) activity_max ON (TRUE))
    LEFT JOIN LATERAL (
        SELECT
            max(ar.updated_at) AS updated_at
        FROM
            activity_read ar
        WHERE ((ar.user_id = pu.user_id)
            AND (ar.activity_path <@ p.path))) ar_max ON (TRUE))
    LEFT JOIN LATERAL (
        SELECT
            TRUE AS unread
        FROM ((activity a
                JOIN priority ap ON (ap.id = a.priority_id))
            LEFT JOIN activity_read ar ON (((ar.user_id = pu.user_id)
                        AND (ar.activity_path = subpath (a.path, 0, 1)))))
    WHERE ((ap.path <@ p.path)
        AND (a.archived_at IS NULL)
        AND (a.author_id <> c.id)
        AND ((ar.read_at IS NULL)
            OR (a.created_at > ar.read_at)))
LIMIT 1) unread ON (TRUE))
WHERE (pu.archived_at IS NULL);

CREATE OR REPLACE VIEW "public"."user_activity_unread" AS
SELECT
    up.user_id,
    a.id AS activity_id,
    (unread.updated_at IS NOT NULL) AS unread,
    COALESCE(ar.updated_at, unread.updated_at) AS updated_at
FROM ((((user_priority up
                JOIN contact c ON (c.user_id = up.user_id))
            JOIN activity a ON (a.priority_id = up.id))
        LEFT JOIN activity_read ar ON (((ar.user_id = up.user_id)
                    AND (ar.activity_path = subpath (a.path, 0, 1)))))
    LEFT JOIN LATERAL (
        SELECT
            max(a2.updated_at) AS updated_at
        FROM
            activity a2
        WHERE ((a2.archived_at IS NULL)
            AND (a2.path <@ a.path)
            AND (a2.author_id <> c.id)
            AND ((ar.read_at IS NULL)
                OR (a2.created_at > ar.read_at)))) unread ON (TRUE))
WHERE ((up.archived_at IS NULL)
    AND (nlevel (a.path) = 1));

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

CREATE OR REPLACE VIEW "public"."user_activity_exception" AS
SELECT
    ua.user_id,
    ua.id,
    ae.occurrence,
    ae.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    CASE WHEN (ae.archived_at IS NULL) THEN
        ae.at
    ELSE
        NULL::tstzrange
    END AS at,
    CASE WHEN (ae.archived_at IS NULL) THEN
        ae."on"
    ELSE
        NULL::daterange
    END AS "on",
    CASE WHEN (ae.archived_at IS NULL) THEN
        ae.title
    ELSE
        NULL::text
    END AS title,
    CASE WHEN (ae.archived_at IS NULL) THEN
        ae.note
    ELSE
        NULL::text
    END AS note
FROM (activity_exception ae
    JOIN user_activity ua ON (ua.id = ae.activity_id));

CREATE OR REPLACE VIEW "public"."user_activity_tags" AS
SELECT
    ua.user_id,
    ua.id,
    at.occurrence,
    at.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    at.tags
FROM (activity_tags at
    JOIN user_activity ua ON (ua.id = at.activity_id));

CREATE TRIGGER upsert_user_priority
    INSTEAD OF INSERT OR UPDATE ON public.user_priority
    FOR EACH ROW
    EXECUTE FUNCTION handle_user_priority_upsert ();

ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_children" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_exception" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "admin"."invitation" SET ( security_invoker = FALSE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_agent" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
