CREATE TABLE "public"."activity_read" (
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "activity_path" ltree NOT NULL,
    "read_at" timestamp with time zone NOT NULL DEFAULT now()
);

ALTER TABLE "public"."activity_read" ENABLE ROW LEVEL SECURITY;

CREATE UNIQUE INDEX activity_read_unique ON public.activity_read USING btree (user_id, activity_path);

CREATE INDEX idx_activity_read_user_path ON public.activity_read USING btree (user_id, activity_path);

ALTER TABLE "public"."activity_read"
    ADD CONSTRAINT "activity_read_single_level" CHECK ((nlevel (activity_path) = 1)) NOT valid;

ALTER TABLE "public"."activity_read" validate CONSTRAINT "activity_read_single_level";

ALTER TABLE "public"."activity_read"
    ADD CONSTRAINT "activity_read_unique" UNIQUE USING INDEX "activity_read_unique";

ALTER TABLE "public"."activity_read"
    ADD CONSTRAINT "activity_read_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."activity_read" validate CONSTRAINT "activity_read_user_id_fkey";

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
    a.source,
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
FROM ((activity a
        JOIN user_priority up ON (a.priority_id = up.id))
    LEFT JOIN user_activity_unread uau ON (((uau.user_id = up.user_id)
                AND (uau.activity_id = a.id))))
WHERE (up.archived_at IS NULL);

CREATE POLICY "Users can delete their own activity read records" ON "public"."activity_read" AS permissive
    FOR DELETE TO public
        USING ((user_id = auth.uid ()));

CREATE POLICY "Users can insert their own activity read records" ON "public"."activity_read" AS permissive
    FOR INSERT TO public
        WITH CHECK ((user_id = auth.uid ()));

CREATE POLICY "Users can update their own activity read records" ON "public"."activity_read" AS permissive
    FOR UPDATE TO public
        USING ((user_id = auth.uid ()));

CREATE POLICY "Users can view their own activity read records" ON "public"."activity_read" AS permissive
    FOR SELECT TO public
        USING ((user_id = auth.uid ()));

CREATE TRIGGER set_activity_read_updated_at
    BEFORE UPDATE ON public.activity_read
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

ALTER VIEW "public"."activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_children" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_exception" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "admin"."invitation" SET (security_invoker = FALSE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_settings_inherited" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child_agent" SET (security_invoker = TRUE);

ALTER VIEW "public"."actor" SET (security_invoker = TRUE);

