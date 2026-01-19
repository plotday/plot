-- Data migration: Convert existing recurrence_dates to activity_exception rows
-- Each date in recurrence_dates becomes an exception row with the activity's time and duration
INSERT INTO activity_exception (id, activity_id, occurrence, at, duration)
SELECT
    gen_random_uuid_v7(),
    a.id,
    -- Format occurrence as YYYY-MM-DDTHH:MM for timed events, YYYY-MM-DD for all-day
    CASE
        WHEN a.at IS NOT NULL THEN to_char(rd AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI')
        ELSE to_char(rd::date, 'YYYY-MM-DD')
    END,
    -- Set at range using the recurrence date with same duration
    CASE
        WHEN a.at IS NOT NULL AND a.duration IS NOT NULL THEN tstzrange(rd, rd + a.duration, '[)')
        WHEN a.at IS NOT NULL THEN tstzrange(rd, rd, '[]')
        ELSE NULL
    END,
    a.duration
FROM activity a, unnest(a.recurrence_dates) AS rd
WHERE a.recurrence_dates IS NOT NULL
  AND array_length(a.recurrence_dates, 1) > 0;

DROP TRIGGER IF EXISTS "upsert_user_priority" ON "public"."user_priority";

-- Drop actor functions that depend on view types before dropping views
DROP FUNCTION IF EXISTS "public"."actor" (user_activity);
DROP FUNCTION IF EXISTS "public"."actor" (activity_x);

DROP FUNCTION IF EXISTS "public"."upsert_activity" (p_id uuid, p_user_id uuid, p_updated_by integer, p_archived_at timestamp with time zone, p_priority_id uuid, p_draft boolean, p_private boolean, p_at tstzrange, p_on daterange, p_duration interval, p_done_at timestamp with time zone, p_title text, p_preview text, p_assignee_id uuid, p_order double precision, p_recurrence_rule text, p_recurrence_exdates timestamp with time zone[], p_recurrence_dates timestamp with time zone[], p_series uuid, p_occurrence_start timestamp with time zone);

DROP VIEW IF EXISTS "public"."priority_tags";

DROP VIEW IF EXISTS "public"."priority_twist_activity_tag_change";

DROP VIEW IF EXISTS "public"."priority_twist_activity_update";

DROP VIEW IF EXISTS "public"."priority_twist_note_create";

DROP VIEW IF EXISTS "public"."priority_twist_note_update";

DROP VIEW IF EXISTS "public"."user_activity_exception";

DROP VIEW IF EXISTS "public"."user_activity_tags";

DROP VIEW IF EXISTS "public"."user_note";

DROP VIEW IF EXISTS "public"."user_note_tags";

DROP VIEW IF EXISTS "public"."user_priority";

DROP VIEW IF EXISTS "public"."user_priority_unread";

DROP VIEW IF EXISTS "public"."user_activity";

DROP VIEW IF EXISTS "public"."user_activity_unread";

DROP VIEW IF EXISTS "public"."activity_x";

ALTER TABLE "public"."activity"
    DROP COLUMN "recurrence_dates";

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.upsert_activity (p_id uuid, p_user_id uuid, p_updated_by integer, p_archived_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_priority_id uuid DEFAULT NULL::uuid, p_draft boolean DEFAULT NULL::boolean, p_private boolean DEFAULT NULL::boolean, p_at tstzrange DEFAULT NULL::tstzrange, p_on daterange DEFAULT NULL::dateRANGE, p_duration interval DEFAULT NULL::interval, p_done_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_title text DEFAULT NULL::text, p_preview text DEFAULT NULL::text, p_assignee_id uuid DEFAULT NULL::uuid, p_order double precision DEFAULT NULL::double precision, p_recurrence_rule text DEFAULT NULL::text, p_recurrence_exdates timestamp with time zone[] DEFAULT NULL::timestamp with time zone[], p_series uuid DEFAULT NULL::uuid, p_occurrence_start timestamp with time zone DEFAULT NULL::timestamp with time zone)
    RETURNS uuid
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    _activity_id uuid;
    _occurrence_root_id uuid;
    _occurrence_original_start timestamptz;
BEGIN
    -- Convert series field to occurrence_root_id
    _occurrence_root_id := p_series;
    _occurrence_original_start := p_occurrence_start;
    -- Check if this is an update to an existing activity
    IF p_id IS NOT NULL THEN
        SELECT
            id INTO _activity_id
        FROM
            activity
        WHERE
            id = p_id;
    END IF;
    -- If updating a synthetic recurrence instance (generated ID), create a new exception record
    IF _activity_id IS NULL AND _occurrence_root_id IS NOT NULL AND _occurrence_original_start IS NOT NULL THEN
        -- This is a new exception for a recurring activity
        _activity_id := gen_random_uuid_v7 ();
        -- Insert new exception activity
        INSERT INTO activity (id, updated_by, archived_at, priority_id, draft, private, at, "on", duration, done_at, title, preview, assignee_id, "order", recurrence_rule, recurrence_exdates, occurrence_root_id, occurrence_original_start)
            VALUES (_activity_id, p_updated_by, p_archived_at, COALESCE(p_priority_id, (
                        SELECT
                            priority_id
                        FROM activity
                        WHERE
                            id = _occurrence_root_id)),
                COALESCE(p_draft, FALSE),
                COALESCE(p_private, FALSE),
                p_at,
                p_on,
                p_duration,
                p_done_at,
                p_title,
                p_preview,
                p_assignee_id,
                p_order,
                NULL, -- Exceptions don't have their own recurrence rules
                NULL,
                _occurrence_root_id,
                _occurrence_original_start);
        RETURN _activity_id;
    END IF;
    -- Standard upsert for regular activities or existing exception records
    INSERT INTO activity (id, updated_by, archived_at, priority_id, draft, private, at, "on", duration, done_at, title, preview, assignee_id, "order", recurrence_rule, recurrence_exdates, occurrence_root_id, occurrence_original_start)
        VALUES (COALESCE(p_id, gen_random_uuid_v7 ()), p_updated_by, p_archived_at, p_priority_id, COALESCE(p_draft, FALSE), COALESCE(p_private, FALSE), p_at, p_on, p_duration, p_done_at, p_title, p_preview, p_assignee_id, COALESCE(p_order, public.order_first ()), p_recurrence_rule, p_recurrence_exdates, _occurrence_root_id, _occurrence_original_start)
    ON CONFLICT (id)
        DO UPDATE SET
            updated_by = EXCLUDED.updated_by,
            updated_at = now(),
            archived_at = COALESCE(EXCLUDED.archived_at, activity.archived_at),
            priority_id = COALESCE(EXCLUDED.priority_id, activity.priority_id),
            draft = COALESCE(EXCLUDED.draft, activity.draft),
            private = COALESCE(EXCLUDED.private, activity.private),
            at = COALESCE(EXCLUDED.at, activity.at),
            "on" = COALESCE(EXCLUDED.on, activity.on),
            duration = COALESCE(EXCLUDED.duration, activity.duration),
            done_at = COALESCE(EXCLUDED.done_at, activity.done_at),
            title = COALESCE(EXCLUDED.title, activity.title),
            preview = COALESCE(EXCLUDED.preview, activity.preview),
            assignee_id = COALESCE(EXCLUDED.assignee_id, activity.assignee_id),
            "order" = COALESCE(EXCLUDED."order", activity."order"),
            recurrence_rule = COALESCE(EXCLUDED.recurrence_rule, activity.recurrence_rule),
            recurrence_exdates = COALESCE(EXCLUDED.recurrence_exdates, activity.recurrence_exdates)
        RETURNING
            id INTO _activity_id;
    RETURN _activity_id;
END;
$function$;

CREATE OR REPLACE VIEW "public"."activity_x" AS
SELECT
    a.id,
    a.created_at,
    a.updated_at,
    a.source_created_at,
    a.author_id,
    a.created_by,
    a.assignee_id,
    a.updated_by,
    a.sync_depth,
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
    a.meta,
    a.source,
    a.created_by_twist_id,
    a.embedding,
    a.pick_priority,
    a.last_note_created_at,
    a.last_note_source_created_at,
    a.source_priority_root,
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

CREATE OR REPLACE VIEW "public"."priority_twist_activity_tag_change" AS
SELECT
    a.created_by AS priority_twist_id,
    at.activity_id,
    at.occurrence,
    at.tag_id,
    at.actor_id,
    at.updated_at,
    CASE WHEN (at.archived_at IS NULL) THEN
        'added'::text
    ELSE
        'removed'::text
    END AS change_type
FROM ((activity_tag at
        JOIN activity a ON (a.id = at.activity_id))
    JOIN priority_child_twist pct ON (((pct.priority_child_id = a.priority_id)
                AND (pct.id = a.created_by))))
WHERE (a.draft = FALSE);

CREATE OR REPLACE VIEW "public"."priority_twist_activity_update" AS
SELECT
    ax.created_by AS priority_twist_id,
    ax.id,
    ax.created_at,
    GREATEST (ax.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    ax.source_created_at,
    ax.author_id,
    ax.created_by,
    ax.assignee_id,
    ax.updated_by,
    ax.sync_depth,
    ax.archived_at,
    ax.priority_id,
    ax.type,
    ax."order",
    ax.draft,
    ax.private,
    ax.title,
    ax.preview,
    ax.at,
    ax."on",
    ax.duration,
    ax.done_at,
    ax.recurrence_rule,
    ax.recurrence_exdates,
    ax.source,
    ax.meta,
    ax.mentions,
    author.name AS author_name,
    author.type AS author_type,
    p.title AS priority_title,
    at.tags
FROM ((((activity_x ax
                JOIN priority_child_twist pct ON (((pct.priority_child_id = ax.priority_id)
                            AND (pct.id = ax.created_by))))
            LEFT JOIN actor author ON (author.id = ax.author_id))
        LEFT JOIN priority p ON (p.id = ax.priority_id))
    LEFT JOIN activity_tags at ON (((at.activity_id = ax.id)
                AND (at.occurrence IS NULL))))
WHERE (ax.draft = FALSE);

CREATE OR REPLACE VIEW "public"."priority_twist_note_create" AS
SELECT
    pct.id AS priority_twist_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.sync_depth,
    n.archived_at,
    n.activity_id,
    n.draft,
    n.private,
    n.content,
    n.links,
    n.key,
    n.mentions,
    a.priority_id,
    a.title AS activity_title,
    a.created_by AS activity_created_by,
    a.meta AS activity_meta,
    ax.mentions AS activity_mentions,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags,
    fm.first_mentioned_at
FROM ((((((priority_child_twist pct
                        JOIN activity a ON (a.priority_id = pct.priority_child_id))
                    JOIN note n ON (n.activity_id = a.id))
                LEFT JOIN activity_x ax ON (ax.id = a.id))
            LEFT JOIN actor author ON (author.id = n.author_id))
        LEFT JOIN note_tags nt ON (nt.note_id = n.id))
    LEFT JOIN LATERAL (
        SELECT
            min(note.created_at) AS first_mentioned_at
        FROM
            note
        WHERE ((note.activity_id = a.id)
            AND (pct.id = ANY (note.mentions))
            AND (note.archived_at IS NULL))) fm ON (TRUE))
WHERE ((n.draft = FALSE)
    AND (a.draft = FALSE)
    AND ((a.created_by = pct.id)
        OR ((fm.first_mentioned_at IS NOT NULL)
            AND (n.created_at >= fm.first_mentioned_at))));

CREATE OR REPLACE VIEW "public"."priority_twist_note_update" AS
SELECT
    n.created_by AS priority_twist_id,
    n.id,
    n.created_at,
    GREATEST (n.updated_at, COALESCE(nt.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.sync_depth,
    n.archived_at,
    n.activity_id,
    n.draft,
    n.private,
    n.content,
    n.links,
    n.key,
    n.mentions,
    a.priority_id,
    a.title AS activity_title,
    a.created_by AS activity_created_by,
    a.meta AS activity_meta,
    ax.mentions AS activity_mentions,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
FROM (((((note n
                    JOIN activity a ON (a.id = n.activity_id))
                JOIN priority_child_twist pct ON (((pct.priority_child_id = a.priority_id)
                            AND (pct.id = n.created_by))))
            LEFT JOIN activity_x ax ON (ax.id = a.id))
        LEFT JOIN actor author ON (author.id = n.author_id))
    LEFT JOIN note_tags nt ON (nt.note_id = n.id))
WHERE ((n.draft = FALSE)
    AND (a.draft = FALSE));

CREATE OR REPLACE VIEW "public"."user_activity_unread" AS
SELECT
    upe.user_id,
    a.id AS activity_id,
    (ar.read_at IS NULL) AS unread,
    GREATEST (COALESCE(ar.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone), CASE WHEN (a.created_by = upe.user_id) THEN
            COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)
        ELSE
            COALESCE(a.last_note_created_at, a.created_at)
        END) AS updated_at
FROM ((user_priority_expanded upe
        JOIN activity a ON (((a.priority_id = upe.priority_id)
                    AND (a.archived_at IS NULL)
                    AND (((a.created_by = upe.user_id)
                            AND (a.last_note_created_at IS NOT NULL)
                            AND (a.last_note_created_at > upe.joined_at))
                        OR (((a.created_by IS NULL)
                                OR (a.created_by <> upe.user_id))
                            AND (COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at))))))
    LEFT JOIN activity_read ar ON (((ar.user_id = upe.user_id)
                AND (ar.activity_id = a.id)
                AND (ar.read_at >= CASE WHEN (a.created_by = upe.user_id) THEN
                        a.last_note_created_at
                    ELSE
                        COALESCE(a.last_note_created_at, a.created_at)
                    END))));

CREATE OR REPLACE VIEW "public"."user_note" AS
SELECT
    upe.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
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
    JOIN user_priority_expanded upe ON (upe.priority_id = a.priority_id));

CREATE OR REPLACE VIEW "public"."user_priority_unread" AS
SELECT
    upe.user_id,
    upe.priority_id,
    TRUE AS unread,
    max(GREATEST (COALESCE(ar.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone), CASE WHEN (a.created_by = upe.user_id) THEN
                COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)
            ELSE
                COALESCE(a.last_note_created_at, a.created_at)
            END)) AS updated_at
FROM ((user_priority_expanded upe
        JOIN activity a ON (((a.priority_id = upe.priority_id)
                    AND (a.archived_at IS NULL)
                    AND (((a.created_by = upe.user_id)
                            AND (a.last_note_created_at IS NOT NULL)
                            AND (a.last_note_created_at > upe.joined_at))
                        OR (((a.created_by IS NULL)
                                OR (a.created_by <> upe.user_id))
                            AND (COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at))))))
    LEFT JOIN activity_read ar ON (((ar.user_id = upe.user_id)
                AND (ar.activity_id = a.id))))
GROUP BY
    upe.user_id,
    upe.priority_id;

CREATE OR REPLACE VIEW "public"."user_activity" AS
SELECT
    upe.user_id,
    a.id,
    a.created_at,
    GREATEST (a.updated_at, COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone), COALESCE(uau.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    a.source_created_at,
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
    a.meta,
    a.source,
    a.created_by_twist_id,
    a.last_note_created_at,
    a.last_note_source_created_at,
    a.mentions,
    CASE WHEN (a.done_at IS NOT NULL) THEN
        tstzrange(a.done_at, a.done_at, '[]'::text)
    WHEN ((a.assignee_id IS NOT NULL)
        AND (ac.user_id <> upe.user_id)) THEN
        tstzrange(GREATEST (a.source_created_at, COALESCE(a.last_note_source_created_at, a.source_created_at)), GREATEST (a.source_created_at, COALESCE(a.last_note_source_created_at, a.source_created_at)), '[]'::text)
    WHEN (a.at IS NOT NULL) THEN
        a.at
    WHEN (a."on" IS NOT NULL) THEN
        NULL::tstzrange
    ELSE
        tstzrange(GREATEST (a.source_created_at, COALESCE(a.last_note_source_created_at, a.source_created_at)), GREATEST (a.source_created_at, COALESCE(a.last_note_source_created_at, a.source_created_at)), '[]'::text)
    END AS range_at,
    CASE WHEN (a.done_at IS NOT NULL) THEN
        NULL::daterange
    WHEN ((a.assignee_id IS NOT NULL)
        AND (ac.user_id <> upe.user_id)) THEN
        NULL::daterange
    WHEN (a.at IS NOT NULL) THEN
        NULL::daterange
    WHEN (a."on" IS NOT NULL) THEN
        a."on"
    ELSE
        NULL::daterange
    END AS range_on,
    COALESCE(uau.unread, FALSE) AS unread
FROM (((activity_x a
            JOIN user_priority_expanded upe ON (a.priority_id = upe.priority_id))
        LEFT JOIN contact ac ON (ac.id = a.assignee_id))
    LEFT JOIN user_activity_unread uau ON (((uau.user_id = upe.user_id)
                AND (uau.activity_id = a.id))));

CREATE OR REPLACE VIEW "public"."user_activity_exception" AS
SELECT
    ua.user_id,
    ua.id,
    COALESCE(ae.archived_at, ua.archived_at) AS archived_at,
    ae.occurrence,
    ae.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    ae.at,
    ae."on",
    ae.title,
    ae.preview
FROM (activity_exception ae
    JOIN user_activity ua ON (ua.id = ae.activity_id));

CREATE OR REPLACE VIEW "public"."user_activity_tags" AS
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
FROM (activity_tags at
    JOIN user_activity ua ON (ua.id = at.activity_id));

CREATE OR REPLACE VIEW "public"."user_note_tags" AS
SELECT
    ua.user_id,
    n.id,
    nt.updated_at,
    ua.archived_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    nt.tags
FROM ((note_tags nt
        JOIN note n ON (n.id = nt.note_id))
    JOIN user_activity ua ON (ua.id = n.activity_id));

CREATE OR REPLACE VIEW "public"."user_priority" AS
SELECT
    pu.user_id,
    p.id,
    p.created_at,
    GREATEST (settings.updated_at, pu.updated_at, p.updated_at, COALESCE(upu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    GREATEST (pu.archived_at, p.archived_at) AS archived_at,
    p.created_by,
    p.updated_by,
    ((pu.personal = TRUE)
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
    COALESCE(upu.unread, FALSE) AS unread
FROM (((((((priority_user pu
                            JOIN priority root ON (pu.priority_id = root.id))
                        JOIN priority_user pu_root ON (((pu.user_id = pu_root.user_id)
                                    AND (pu_root.personal = TRUE))))
                    JOIN priority user_root ON (pu_root.priority_id = user_root.id))
                JOIN priority p ON (root.path @> p.path))
            LEFT JOIN priority_settings settings ON (((settings.user_id = pu.user_id)
                        AND (p.id = settings.priority_id))))
        LEFT JOIN priority_settings_inherited inherited_settings ON (((inherited_settings.user_id = pu.user_id)
                    AND (p.id = inherited_settings.priority_id))))
    LEFT JOIN user_priority_unread upu ON (((upu.user_id = pu.user_id)
                AND (upu.priority_id = p.id))))
WHERE (pu.archived_at IS NULL);

CREATE TRIGGER upsert_user_priority
    INSTEAD OF INSERT OR UPDATE ON public.user_priority
    FOR EACH ROW
    EXECUTE FUNCTION handle_user_priority_upsert ();

ALTER VIEW "public"."user_note" SET ( security_invoker = TRUE);
ALTER VIEW "public"."note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_twist" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_exception" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_activity_update" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_note_create" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_note_update" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_expanded" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_activity_tag_change" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);

-- Recreate actor functions that were dropped
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

CREATE OR REPLACE FUNCTION public.actor (activity_x)
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
