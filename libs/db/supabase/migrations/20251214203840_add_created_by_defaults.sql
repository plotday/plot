DROP TRIGGER IF EXISTS "upsert_user_priority" ON "public"."user_priority";

DROP VIEW IF EXISTS "public"."priority_tags";

DROP VIEW IF EXISTS "public"."user_activity_exception";

DROP VIEW IF EXISTS "public"."user_activity_tags";

DROP VIEW IF EXISTS "public"."user_note";

DROP VIEW IF EXISTS "public"."user_note_tags";

DROP VIEW IF EXISTS "public"."user_twist";

DROP FUNCTION public.actor (user_activity);

DROP VIEW IF EXISTS "public"."user_activity";

DROP VIEW IF EXISTS "public"."user_activity_unread";

DROP VIEW IF EXISTS "public"."user_priority";

DROP VIEW IF EXISTS "public"."activity_x";

DROP VIEW IF EXISTS "public"."priority_unread";

DROP VIEW IF EXISTS "public"."user_priority_base";

ALTER TABLE "public"."activity"
    ALTER COLUMN "created_by" SET DEFAULT auth.uid ();

ALTER TABLE "public"."note"
    ALTER COLUMN "created_by" SET DEFAULT auth.uid ();

CREATE OR REPLACE VIEW "public"."activity_x" AS
SELECT
    a.id,
    a.created_at,
    a.updated_at,
    a.author_id,
    a.created_by,
    a.assignee_id,
    a.updated_by,
    a.archived_at,
    a.priority_id,
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
    a.embedding,
    a.pick_priority,
    p.path AS priority_path,
    m.mentions
FROM ((activity a
        JOIN priority p ON (p.id = a.priority_id))
    LEFT JOIN (
        SELECT
            n.activity_id,
            array_agg(DISTINCT mention.mention) AS mentions
        FROM
            note n,
            LATERAL unnest(n.mentions) mention (mention)
        WHERE ((n.archived_at IS NULL)
            AND (n.mentions IS NOT NULL))
    GROUP BY
        n.activity_id) m ON (m.activity_id = a.id));

CREATE OR REPLACE VIEW "public"."priority_tags" AS
SELECT
    a.priority_id,
    at.tag_id,
    count(*) AS count,
    max(COALESCE(at.archived_at, at.updated_at)) AS updated_at
FROM (activity_tag at
    JOIN activity a ON (at.activity_id = a.id))
WHERE ((at.archived_at IS NULL)
    AND (a.archived_at IS NULL))
GROUP BY
    a.priority_id,
    at.tag_id;

CREATE OR REPLACE VIEW "public"."user_priority_base" AS
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
    inherited_settings.color
FROM (((((((priority_user pu
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
        FROM (activity_read ar
            JOIN priority ap ON (ap.id = ar.activity_id))
    WHERE ((ar.user_id = pu.user_id)
        AND (ap.path <@ p.path))) ar_max ON (TRUE))
WHERE (pu.archived_at IS NULL);

CREATE OR REPLACE VIEW "public"."priority_unread" AS
SELECT
    upb.user_id,
    upb.id AS priority_id,
    COALESCE(unread_check.unread, FALSE) AS unread
FROM (((user_priority_base upb
        LEFT JOIN contact c ON (c.user_id = upb.user_id))
    LEFT JOIN LATERAL (
        SELECT
            pu.created_at
        FROM (priority_user pu
            JOIN priority p ON (p.id = pu.priority_id))
    WHERE ((pu.user_id = upb.user_id)
        AND (p.path @> upb.path))
ORDER BY
    (nlevel (p.path))
LIMIT 1) member ON (TRUE))
    LEFT JOIN LATERAL (
        SELECT
            TRUE AS unread
        FROM (activity a
            LEFT JOIN activity_read ar ON (((ar.user_id = upb.user_id)
                        AND (ar.activity_id = a.id))))
    WHERE ((a.priority_id = upb.id)
        AND (a.archived_at IS NULL)
        AND (a.draft = FALSE)
        AND (((a.author_id <> c.id)
                AND ((member.created_at IS NULL)
                    OR (a.created_at >= member.created_at))
                AND (ar.read_at IS NULL))
            OR (EXISTS (
                    SELECT
                        1
                    FROM
                        note n
                    WHERE ((n.activity_id = a.id)
                        AND (n.archived_at IS NULL)
                        AND (n.author_id <> c.id)
                        AND ((member.created_at IS NULL)
                            OR (n.created_at >= member.created_at))
                        AND ((ar.read_at IS NULL)
                            OR (n.created_at > ar.read_at)))))))
LIMIT 1) unread_check ON (TRUE));

CREATE OR REPLACE VIEW "public"."user_priority" AS
SELECT
    upb.user_id,
    upb.id,
    upb.created_at,
    upb.updated_at,
    upb.archived_at,
    upb.created_by,
    upb.updated_by,
    upb.root,
    upb.title,
    upb.path,
    upb.top_order,
    upb.pomodoro,
    upb.color,
    COALESCE(pu.unread, FALSE) AS unread
FROM (user_priority_base upb
    LEFT JOIN priority_unread pu ON (((pu.user_id = upb.user_id)
                AND (pu.priority_id = upb.id))));

CREATE OR REPLACE VIEW "public"."user_twist" AS
SELECT
    up.user_id,
    pt.id,
    pt.created_at,
    pt.updated_at,
    pt.archived_at,
    pt.priority_id,
    pt.twist_id,
    pt.twist_environment,
    pt.owner_id,
    pt.name,
    pt.config
FROM (priority_twist pt
    JOIN user_priority up ON (up.id = pt.priority_id));

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

CREATE OR REPLACE VIEW "public"."user_note" AS
SELECT
    up.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.archived_at,
    n.activity_id,
    n.draft,
    n.private,
    n.content,
    n.links,
    n.mentions
FROM ((note n
        JOIN activity a ON (a.id = n.activity_id))
    JOIN user_priority up ON (up.id = a.priority_id));

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
                    unnest(n.mentions) AS unnest
                FROM
                    note n
                WHERE ((n.activity_id = a.id)
                    AND (n.archived_at IS NULL)
                    AND (n.mentions IS NOT NULL))) AS "array") AS mentions,
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
FROM ((activity_x a
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

CREATE OR REPLACE VIEW "public"."user_note_tags" AS
SELECT
    ua.user_id,
    n.id,
    nt.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    nt.tags
FROM ((note_tags nt
        JOIN note n ON (n.id = nt.note_id))
    JOIN user_activity ua ON (ua.id = n.activity_id));

CREATE TRIGGER upsert_user_priority
    INSTEAD OF INSERT OR UPDATE ON public.user_priority
    FOR EACH ROW
    EXECUTE FUNCTION handle_user_priority_upsert ();

CREATE OR REPLACE FUNCTION public.actor (user_activity)
    RETURNS SETOF actor
    LANGUAGE sql
    STABLE ROWS 1
    AS $function$
    SELECT
        actor.*
    FROM
        actor
    WHERE
        actor.id = $1.author_id
$function$;

ALTER VIEW "public"."user_note" SET (security_invoker = TRUE);

ALTER VIEW "public"."note_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_note_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_twist" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_exception" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_settings_inherited" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_base" SET (security_invoker = TRUE);

ALTER VIEW "public"."actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child_twist" SET (security_invoker = TRUE);

