DROP TRIGGER IF EXISTS "set_activity_created_by" ON "public"."activity";

DROP POLICY "Users can delete their own activities" ON "public"."activity";

DROP POLICY "Users can insert activities in their accessible priorities" ON "public"."activity";

DROP POLICY "Users can update their own activities" ON "public"."activity";

DROP POLICY "Users can insert activity_tag for activities in their accessibl" ON "public"."activity_tag";

DROP POLICY "Users can update activity_tag for activities in their accessibl" ON "public"."activity_tag";

DROP POLICY "Users can view activity_tag in their accessible priorities" ON "public"."activity_tag";

DROP POLICY "Users can view their contact" ON "public"."contact";

ALTER TABLE "public"."activity_tag"
    DROP CONSTRAINT "activity_tag_user_id_activity_id_tag_id_key";

ALTER TABLE "public"."activity_tag"
    DROP CONSTRAINT "activity_tag_user_id_fkey";

ALTER TABLE "public"."contact"
    DROP CONSTRAINT "contact_user_id_fkey";

ALTER TABLE "public"."contact"
    DROP CONSTRAINT "contact_user_email_unique";

DROP VIEW IF EXISTS "public"."activity_children";

DROP VIEW IF EXISTS "public"."priority_tags";

DROP VIEW IF EXISTS "public"."user_activity_exception";

DROP VIEW IF EXISTS "public"."user_activity_tags";

DROP VIEW IF EXISTS "public"."activity_tags";

DROP VIEW IF EXISTS "public"."user_activity";

DROP INDEX IF EXISTS "public"."activity_tag_user_id_activity_id_tag_id_key";

DROP INDEX IF EXISTS "public"."contact_user_email_unique";

ALTER TABLE "public"."activity"
    ADD COLUMN "assignee_id" uuid;

ALTER TABLE "public"."activity" RENAME COLUMN "created_by" TO "author_id";

ALTER TABLE "public"."activity_exception"
    DROP COLUMN "created_by";

ALTER TABLE "public"."activity_tag" RENAME COLUMN "user_id" TO "actor_id";

ALTER TABLE "public"."contact"
    DROP COLUMN "user_id";

CREATE UNIQUE INDEX activity_tag_actor_id_activity_id_tag_id_key ON public.activity_tag USING btree (actor_id, activity_id, tag_id);

CREATE UNIQUE INDEX contact_user_email_unique ON public.contact USING btree (email);

ALTER TABLE "public"."activity_tag"
    ADD CONSTRAINT "activity_tag_actor_id_activity_id_tag_id_key" UNIQUE USING INDEX "activity_tag_actor_id_activity_id_tag_id_key";

ALTER TABLE "public"."contact"
    ADD CONSTRAINT "contact_user_email_unique" UNIQUE USING INDEX "contact_user_email_unique";

SET check_function_bodies = OFF;

CREATE OR REPLACE VIEW "public"."actor" AS
SELECT
    (u.id)::text AS id,
    'user'::text AS type,
    COALESCE((u.raw_user_meta_data ->> 'full_name'::text), (u.raw_user_meta_data ->> 'name'::text), (u.email)::text) AS name,
    u.email,
    (u.raw_user_meta_data ->> 'avatar_url'::text) AS avatar_url
FROM
    auth.users u
WHERE (u.deleted_at IS NULL)
UNION ALL
SELECT
    (c.id)::text AS id,
    'contact'::text AS type,
    COALESCE(c.name, c.email) AS name,
    c.email,
    c.avatar_url
FROM
    contact c
WHERE (c.deleted_at IS NULL)
UNION ALL
SELECT
    (pa.id)::text AS id,
    'priority_agent'::text AS type,
    pa.name,
    NULL::text AS email,
    NULL::text AS avatar_url
FROM
    priority_agent pa
WHERE (pa.deleted_at IS NULL);

CREATE OR REPLACE FUNCTION public.update_author_id ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    NEW.author_id = COALESCE(auth.uid (), NEW.author_id);
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE VIEW "public"."activity_children" AS
SELECT
    a.id,
    c.id AS child_id
FROM (activity a
    JOIN activity c ON (c.path <@ a.path));

CREATE OR REPLACE VIEW "public"."activity_tags" AS
SELECT
    sq.activity_id,
    sq.occurrence,
    jsonb_object_agg(sq.tag_id, sq.actor_ids) FILTER (WHERE ((sq.actor_ids IS NOT NULL)
    AND (jsonb_array_length(sq.actor_ids) > 0))) AS tags,
max(sq.updated_at) AS updated_at,
(array_agg(sq.updated_by ORDER BY sq.updated_at DESC))[1] AS updated_by
FROM (
    SELECT
        at.activity_id,
        at.occurrence,
        at.tag_id,
        jsonb_agg(at.actor_id) FILTER (WHERE (at.deleted_at IS NULL)) AS actor_ids,
    max(COALESCE(at.deleted_at, at.updated_at)) AS updated_at,
    (array_agg(at.updated_by ORDER BY at.updated_at DESC))[1] AS updated_by
FROM
    activity_tag at
GROUP BY
    at.activity_id,
    at.occurrence,
    at.tag_id) sq
GROUP BY
    sq.activity_id,
    sq.occurrence;

CREATE OR REPLACE VIEW "public"."priority_tags" AS
SELECT
    a.priority_id,
    at.tag_id,
    count(*) AS count,
    max(COALESCE(at.deleted_at, at.updated_at)) AS updated_at
FROM (activity_tag at
    JOIN activity a ON (at.activity_id = a.id))
WHERE ((at.deleted_at IS NULL)
    AND (a.deleted_at IS NULL)
    AND (nlevel (a.path) = 1))
GROUP BY
    a.priority_id,
    at.tag_id;

CREATE OR REPLACE VIEW "public"."user_activity" AS
SELECT
    up.user_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.author_id,
    a.assignee_id,
    a.updated_by,
    a.deleted_at,
    a.priority_id,
    a.type,
    a.path,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.note,
    a.at,
    a."on",
    a.duration,
    a.done_at,
    a.recurrence_rule,
    a.recurrence_exdates,
    a.recurrence_dates,
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
    END AS range_on
FROM (activity a
    JOIN user_priority up ON (a.priority_id = up.id))
WHERE (up.deleted_at IS NULL);

CREATE OR REPLACE VIEW "public"."user_activity_exception" AS
SELECT
    ua.user_id,
    ua.id,
    ae.occurrence,
    ae.updated_at,
    ua.range_at,
    ua.range_on,
    CASE WHEN (ae.deleted_at IS NULL) THEN
        ae.at
    ELSE
        NULL::tstzrange
    END AS at,
    CASE WHEN (ae.deleted_at IS NULL) THEN
        ae."on"
    ELSE
        NULL::daterange
    END AS "on",
    CASE WHEN (ae.deleted_at IS NULL) THEN
        ae.title
    ELSE
        NULL::text
    END AS title,
    CASE WHEN (ae.deleted_at IS NULL) THEN
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
    ua.range_at,
    ua.range_on,
    at.tags
FROM (activity_tags at
    JOIN user_activity ua ON (ua.id = at.activity_id));

CREATE POLICY "Users can delete their own activities" ON "public"."activity" AS permissive
    FOR DELETE TO public
        USING (((author_id = auth.uid ()) AND user_has_priority_access (auth.uid (), priority_id)));

CREATE POLICY "Users can insert activities in their accessible priorities" ON "public"."activity" AS permissive
    FOR INSERT TO public
        WITH CHECK (((author_id = auth.uid ()) AND user_has_priority_access (auth.uid (), priority_id)));

CREATE POLICY "Users can update their own activities" ON "public"."activity" AS permissive
    FOR UPDATE TO public
        USING (((author_id = auth.uid ()) AND user_has_priority_access (auth.uid (), priority_id)));

CREATE POLICY "Users can insert activity_tag for activities in their accessibl" ON "public"."activity_tag" AS permissive
    FOR INSERT TO public
        WITH CHECK (((actor_id = auth.uid ()) AND (EXISTS (
            SELECT
                1
            FROM
                activity a
            WHERE ((a.id = activity_tag.activity_id) AND user_has_priority_access (auth.uid (), a.priority_id))))));

CREATE POLICY "Users can update activity_tag for activities in their accessibl" ON "public"."activity_tag" AS permissive
    FOR UPDATE TO public
        USING (((actor_id = auth.uid ()) OR (EXISTS (
            SELECT
                1
            FROM
                activity a
            WHERE ((a.id = activity_tag.activity_id) AND user_has_priority_access (auth.uid (), a.priority_id) AND (get_tag_type (activity_tag.tag_id) = 'toggle'::tag_type))))))
        WITH CHECK ((actor_id = auth.uid ()));

CREATE POLICY "Users can view activity_tag in their accessible priorities" ON "public"."activity_tag" AS permissive
    FOR SELECT TO public
        USING (((actor_id = auth.uid ()) OR (EXISTS (
            SELECT
                1
            FROM
                activity a
            WHERE ((a.id = activity_tag.activity_id) AND user_has_priority_access (auth.uid (), a.priority_id))))));

CREATE POLICY "Users can view their contact" ON "public"."contact" AS permissive
    FOR SELECT TO authenticated
        USING (TRUE);

CREATE TRIGGER set_activity_author_id
    BEFORE INSERT ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION update_author_id ();

ALTER VIEW "public"."activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_children" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_exception" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "admin"."invitation" SET (security_invoker = FALSE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child_agent" SET (security_invoker = TRUE);

ALTER VIEW "public"."actor" SET (security_invoker = TRUE);

