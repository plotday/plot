DROP INDEX IF EXISTS "public"."idx_activity_source_twist_unique";

DROP VIEW IF EXISTS "public"."user_activity_exception";

DROP VIEW IF EXISTS "public"."user_activity_tags";

DROP VIEW IF EXISTS "public"."user_note_tags";

DROP FUNCTION public.actor (user_activity);

DROP VIEW IF EXISTS "public"."user_activity";

DROP VIEW IF EXISTS "public"."activity_x";

ALTER TABLE "public"."activity"
    ADD COLUMN "active_source" text GENERATED ALWAYS AS ( CASE WHEN (archived_at IS NULL) THEN
        source
    ELSE
        NULL::text
    END) STORED;

CREATE UNIQUE INDEX activity_source_twist_unique ON public.activity USING btree (active_source, created_by_twist_id);

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
    a.source,
    a.created_by_twist_id,
    a.embedding,
    a.pick_priority,
    a.last_note_created_at,
    a.active_source,
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

CREATE OR REPLACE VIEW "public"."user_activity" AS
SELECT
    upe.user_id,
    a.id,
    a.created_at,
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
    CASE WHEN (a.done_at IS NOT NULL) THEN
        tstzrange(a.done_at, a.done_at, '[]'::text)
    WHEN (a.at IS NOT NULL) THEN
        a.at
    WHEN (a."on" IS NOT NULL) THEN
        NULL::tstzrange
    ELSE
        tstzrange(GREATEST (a.created_at, COALESCE(a.last_note_created_at, a.created_at)), GREATEST (a.created_at, COALESCE(a.last_note_created_at, a.created_at)), '[]'::text)
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
        JOIN user_priority_expanded upe ON (a.priority_id = upe.priority_id))
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
    ae.note
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

ALTER VIEW "public"."user_priority_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_expanded" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_settings_inherited" SET (security_invoker = TRUE);

ALTER VIEW "public"."actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child_twist" SET (security_invoker = TRUE);

