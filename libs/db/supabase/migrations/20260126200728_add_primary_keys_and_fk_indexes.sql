ALTER TABLE "public"."activity_read"
    DROP CONSTRAINT "activity_read_unique";

ALTER TABLE "public"."priority_settings"
    DROP CONSTRAINT "priority_settings_unique";

ALTER TABLE "public"."priority_user"
    DROP CONSTRAINT "priority_user_unique";

DROP VIEW IF EXISTS "public"."priority_tags";

DROP VIEW IF EXISTS "public"."priority_twist_activity_create";

DROP VIEW IF EXISTS "public"."priority_twist_activity_tag_change";

DROP VIEW IF EXISTS "public"."priority_twist_activity_update";

DROP VIEW IF EXISTS "public"."priority_twist_note_create";

DROP VIEW IF EXISTS "public"."priority_twist_note_update";

DROP VIEW IF EXISTS "public"."user_activity_tags";

DROP VIEW IF EXISTS "public"."user_note_tags";

DROP VIEW IF EXISTS "public"."activity_tags";

DROP VIEW IF EXISTS "public"."note_tags";

DROP INDEX IF EXISTS "public"."activity_read_unique";

DROP INDEX IF EXISTS "public"."priority_settings_unique";

DROP INDEX IF EXISTS "public"."priority_user_unique";

ALTER TABLE "public"."activity_tag"
    ADD COLUMN "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL;

ALTER TABLE "public"."note_tag"
    ADD COLUMN "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL;

CREATE UNIQUE INDEX activity_read_pkey ON public.activity_read USING btree (user_id, activity_id);

CREATE UNIQUE INDEX activity_tag_pkey ON public.activity_tag USING btree (id);

CREATE INDEX idx_session_user_id ON public.session USING btree (user_id)
WHERE (archived_at IS NULL);

CREATE INDEX idx_token_publisher_id ON public.token USING btree (publisher_id)
WHERE (archived_at IS NULL);

CREATE INDEX idx_token_user_id ON public.token USING btree (user_id)
WHERE (archived_at IS NULL);

CREATE INDEX idx_twist_admin_priority_id ON public.twist_admin USING btree (priority_id);

CREATE INDEX idx_twist_admin_publisher_id ON public.twist_admin USING btree (publisher_id);

CREATE INDEX idx_twist_admin_user_id ON public.twist_admin USING btree (user_id);

CREATE UNIQUE INDEX note_tag_pkey ON public.note_tag USING btree (id);

CREATE UNIQUE INDEX priority_settings_pkey ON public.priority_settings USING btree (user_id, priority_id);

CREATE UNIQUE INDEX priority_user_pkey ON public.priority_user USING btree (user_id, priority_id);

ALTER TABLE "public"."activity_read"
    ADD CONSTRAINT "activity_read_pkey" PRIMARY KEY USING INDEX "activity_read_pkey";

ALTER TABLE "public"."activity_tag"
    ADD CONSTRAINT "activity_tag_pkey" PRIMARY KEY USING INDEX "activity_tag_pkey";

ALTER TABLE "public"."note_tag"
    ADD CONSTRAINT "note_tag_pkey" PRIMARY KEY USING INDEX "note_tag_pkey";

ALTER TABLE "public"."priority_settings"
    ADD CONSTRAINT "priority_settings_pkey" PRIMARY KEY USING INDEX "priority_settings_pkey";

ALTER TABLE "public"."priority_user"
    ADD CONSTRAINT "priority_user_pkey" PRIMARY KEY USING INDEX "priority_user_pkey";

SET check_function_bodies = OFF;

CREATE OR REPLACE VIEW "public"."activity_tags" AS
SELECT
    activity_id,
    occurrence,
    jsonb_object_agg(tag_id, actor_ids) FILTER (WHERE ((actor_ids IS NOT NULL)
    AND (jsonb_array_length(actor_ids) > 0))) AS tags,
max(updated_at) AS updated_at,
(array_agg(updated_by ORDER BY sq.updated_at DESC))[1] AS updated_by
FROM (
    SELECT
        at.activity_id,
        at.occurrence,
        at.tag_id,
        jsonb_agg(at.actor_id) FILTER (WHERE (at.archived_at IS NULL)) AS actor_ids,
    max(COALESCE(at.archived_at, at.updated_at)) AS updated_at,
    (array_agg(at.updated_by ORDER BY at.updated_at DESC))[1] AS updated_by
FROM
    activity_tag at
GROUP BY
    at.activity_id,
    at.occurrence,
    at.tag_id) sq
GROUP BY
    activity_id,
    occurrence;

CREATE OR REPLACE FUNCTION public.can_access_priority (_priority_id uuid)
    RETURNS boolean
    LANGUAGE sql
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.user_priority_expanded upe
            WHERE
                upe.user_id = (
                    SELECT
                        auth.uid ())
                    AND upe.priority_id = _priority_id);
$function$;

CREATE OR REPLACE FUNCTION public.can_access_priority (_priority_path ltree)
    RETURNS boolean
    LANGUAGE sql
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.priority_user pu
                JOIN public.priority p ON p.id = pu.priority_id
            WHERE
                pu.user_id = (
                    SELECT
                        auth.uid ())
                    AND pu.archived_at IS NULL
                    AND p.path @> _priority_path);
$function$;

CREATE OR REPLACE VIEW "public"."note_tags" AS
SELECT
    note_id,
    jsonb_object_agg(tag_id, actor_ids) FILTER (WHERE ((actor_ids IS NOT NULL)
    AND (jsonb_array_length(actor_ids) > 0))) AS tags,
max(updated_at) AS updated_at,
(array_agg(updated_by ORDER BY sq.updated_at DESC))[1] AS updated_by
FROM (
    SELECT
        nt.note_id,
        nt.tag_id,
        jsonb_agg(nt.actor_id) FILTER (WHERE (nt.archived_at IS NULL)) AS actor_ids,
    max(COALESCE(nt.archived_at, nt.updated_at)) AS updated_at,
    (array_agg(nt.updated_by ORDER BY nt.updated_at DESC))[1] AS updated_by
FROM
    note_tag nt
GROUP BY
    nt.note_id,
    nt.tag_id) sq
GROUP BY
    note_id;

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

CREATE OR REPLACE VIEW "public"."priority_twist_activity_create" AS
SELECT
    ax.created_by AS priority_twist_id,
    ax.id,
    ax.created_at,
    ax.updated_at,
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
FROM ((((priority_child_twist pct
                JOIN activity_x ax ON (ax.priority_id = pct.priority_child_id))
            LEFT JOIN actor author ON (author.id = ax.author_id))
        LEFT JOIN priority p ON (p.id = ax.priority_id))
    LEFT JOIN activity_tags at ON (((at.activity_id = ax.id)
                AND (at.occurrence IS NULL))))
WHERE ((ax.draft = FALSE)
    AND (pct.id <> ax.created_by)
    AND (ax.archived_at IS NULL)
    AND (pct.archived_at IS NULL)
    AND (ax.created_at > pct.created_at))
ORDER BY
    ax.created_at;

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
FROM ((((priority_child_twist pct
                JOIN activity_x ax ON (ax.priority_id = pct.priority_child_id))
            LEFT JOIN actor author ON (author.id = ax.author_id))
        LEFT JOIN priority p ON (p.id = ax.priority_id))
    LEFT JOIN activity_tags at ON (((at.activity_id = ax.id)
                AND (at.occurrence IS NULL))))
WHERE ((ax.draft = FALSE)
    AND (ax.updated_at > ax.created_at)
    AND (updated_by_uuid (pct.id) <> (ax.updated_by)::numeric)
    AND (pct.archived_at IS NULL)
    AND (ax.updated_at > pct.created_at))
ORDER BY
    ax.updated_at;

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
    ax.priority_id,
    ax.title AS activity_title,
    ax.created_by AS activity_created_by,
    ax.meta AS activity_meta,
    ax.mentions AS activity_mentions,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags,
    fm.first_mentioned_at
FROM (((((priority_child_twist pct
                    JOIN activity_x ax ON (ax.priority_id = pct.priority_child_id))
                JOIN note n ON (n.activity_id = ax.id))
            LEFT JOIN actor author ON (author.id = n.author_id))
        LEFT JOIN note_tags nt ON (nt.note_id = n.id))
    LEFT JOIN LATERAL (
        SELECT
            min(note.created_at) AS first_mentioned_at
        FROM
            note
        WHERE ((note.activity_id = ax.id)
            AND (pct.id = ANY (note.mentions))
            AND (note.archived_at IS NULL))) fm ON (TRUE))
WHERE ((n.draft = FALSE)
    AND (updated_by_uuid (pct.id) <> (n.updated_by)::numeric)
    AND (ax.archived_at IS NULL)
    AND (pct.archived_at IS NULL)
    AND (n.created_at > pct.created_at)
    AND ((ax.created_by = pct.id)
        OR ((fm.first_mentioned_at IS NOT NULL)
            AND (n.created_at >= fm.first_mentioned_at))))
ORDER BY
    n.created_at;

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
    ax.priority_id,
    ax.title AS activity_title,
    ax.created_by AS activity_created_by,
    ax.meta AS activity_meta,
    ax.mentions AS activity_mentions,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
FROM ((((priority_child_twist pct
                JOIN activity_x ax ON (ax.priority_id = pct.priority_child_id))
            JOIN note n ON (ax.id = n.activity_id))
        LEFT JOIN actor author ON (author.id = n.author_id))
    LEFT JOIN note_tags nt ON (nt.note_id = n.id))
WHERE ((n.draft = FALSE)
    AND (n.updated_at > n.created_at)
    AND (updated_by_uuid (pct.id) <> (n.updated_by)::numeric)
    AND (ax.archived_at IS NULL)
    AND (pct.archived_at IS NULL)
    AND (n.updated_at > pct.created_at))
ORDER BY
    n.updated_at;

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
ALTER VIEW "public"."priority_twist_activity_create" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_note_update" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_expanded" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_activity_tag_change" SET ( security_invoker = TRUE);
ALTER VIEW public.priority_member SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);
