DROP TABLE "public"."activity" CASCADE;

ALTER TYPE "public"."activity_type" RENAME TO "activity_type__old_version_to_be_dropped";

CREATE TYPE "public"."activity_type" AS enum (
    'action',
    'event',
    'note'
);

CREATE TABLE "public"."activity" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid_v7 (),
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "author_id" uuid NOT NULL,
    "created_by" uuid NOT NULL,
    "assignee_id" uuid,
    "updated_by" integer NOT NULL DEFAULT 0,
    "archived_at" timestamp with time zone,
    "priority_id" uuid NOT NULL,
    "type" activity_type NOT NULL DEFAULT 'note' ::activity_type,
    "path" ltree NOT NULL DEFAULT generate_path (NULL::LTREE),
    "order" double precision NOT NULL DEFAULT order_first (),
    "draft" boolean NOT NULL DEFAULT FALSE,
    "private" boolean NOT NULL DEFAULT FALSE,
    "title" text,
    "note" text,
    "links" jsonb,
    "at" tstzrange,
    "on" daterange,
    "duration" interval,
    "done_at" timestamp with time zone,
    "recurrence_rule" text,
    "recurrence_exdates" timestamp with time zone[],
    "recurrence_dates" timestamp with time zone[],
    "meta" jsonb,
    "mentions" uuid[],
    "embedding" halfvec (384),
    "pick_priority" jsonb
);

ALTER TABLE "public"."activity" ENABLE ROW LEVEL SECURITY;

DROP TYPE "public"."activity_type__old_version_to_be_dropped";

CREATE INDEX activity_embedding_idx ON public.activity USING hnsw (embedding halfvec_cosine_ops);

CREATE UNIQUE INDEX activity_pkey ON public.activity USING btree (id);

CREATE INDEX idx_activity_at ON public.activity USING gist (at);

CREATE INDEX idx_activity_done_at ON public.activity USING btree (done_at);

CREATE INDEX idx_activity_on ON public.activity USING gist ("on");

CREATE INDEX idx_activity_path ON public.activity USING gist (path);

CREATE INDEX idx_activity_priority_id ON public.activity USING btree (priority_id);

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_pkey" PRIMARY KEY USING INDEX "activity_pkey";

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_no_complete_recurrence" CHECK (((recurrence_rule IS NULL) OR (done_at IS NULL))) NOT valid;

ALTER TABLE "public"."activity" validate CONSTRAINT "activity_no_complete_recurrence";

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_priority_id_fkey" FOREIGN KEY (priority_id) REFERENCES priority (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."activity" validate CONSTRAINT "activity_priority_id_fkey";

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_recurrence_on_or_at" CHECK (((recurrence_rule IS NULL) OR (at IS NOT NULL) OR ("on" IS NOT NULL))) NOT valid;

ALTER TABLE "public"."activity" validate CONSTRAINT "activity_recurrence_on_or_at";

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_scheduled" CHECK ((((recurrence_rule IS NULL) AND (type <> ALL (ARRAY['action'::activity_type, 'event'::activity_type]))) OR (at IS NOT NULL) OR ("on" IS NOT NULL))) NOT valid;

ALTER TABLE "public"."activity" validate CONSTRAINT "activity_scheduled";

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_single_schedule" CHECK (((at IS NULL) OR ("on" IS NULL))) NOT valid;

ALTER TABLE "public"."activity" validate CONSTRAINT "activity_single_schedule";

ALTER TABLE "public"."activity_exception"
    ADD CONSTRAINT "activity_exception_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES activity (id) NOT valid;

ALTER TABLE "public"."activity_exception" validate CONSTRAINT "activity_exception_activity_id_fkey";

ALTER TABLE "public"."activity_tag"
    ADD CONSTRAINT "activity_tag_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES activity (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."activity_tag" validate CONSTRAINT "activity_tag_activity_id_fkey";

SET check_function_bodies = OFF;

CREATE OR REPLACE VIEW "public"."activity_children" AS
SELECT
    a.id,
    c.id AS child_id
FROM (activity a
    JOIN activity c ON (c.path <@ a.path));

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

CREATE OR REPLACE FUNCTION public.actor (activity)
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

CREATE POLICY "Users can insert activities in their accessible priorities" ON "public"."activity" AS permissive
    FOR INSERT TO public
        WITH CHECK (((author_id = user_contact_id ()) AND user_has_priority_access (auth.uid (), priority_id)));

CREATE POLICY "Users can update activities in their accessible priorities" ON "public"."activity" AS permissive
    FOR UPDATE TO public
        USING (user_has_priority_access (auth.uid (), priority_id))
        WITH CHECK (user_has_priority_access (auth.uid (), priority_id));

CREATE POLICY "Users can view activities in their accessible priorities" ON "public"."activity" AS permissive
    FOR SELECT TO public
        USING (user_has_priority_access (auth.uid (), priority_id));

CREATE POLICY "Users can insert activity exceptions for accessible activities" ON "public"."activity_exception" AS permissive
    FOR INSERT TO public
        WITH CHECK ((EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = activity_exception.activity_id) AND user_has_priority_access (auth.uid (), activity.priority_id)))));

CREATE POLICY "Users can update activity exceptions for their own activities" ON "public"."activity_exception" AS permissive
    FOR UPDATE TO public
        USING ((EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = activity_exception.activity_id) AND user_has_priority_access (auth.uid (), activity.priority_id)))))
        WITH CHECK ((EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = activity_exception.activity_id) AND user_has_priority_access (auth.uid (), activity.priority_id)))));

CREATE POLICY "Users can view activity exceptions for accessible activities" ON "public"."activity_exception" AS permissive
    FOR SELECT TO public
        USING ((EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = activity_exception.activity_id) AND user_has_priority_access (auth.uid (), activity.priority_id)))));

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

CREATE TRIGGER activity_change_api_call
    AFTER INSERT OR UPDATE ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION notify_internal_api_for_activity ();

CREATE TRIGGER activity_propagate_mentions_to_parent
    AFTER INSERT OR UPDATE OF mentions ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION propagate_mentions_to_parent ();

CREATE TRIGGER set_activity_author_and_created_by
    BEFORE INSERT ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION update_author_and_created_by ();

CREATE TRIGGER set_activity_updated_at
    BEFORE UPDATE ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER upsert_user_priority
    INSTEAD OF INSERT OR UPDATE ON public.user_priority
    FOR EACH ROW
    EXECUTE FUNCTION handle_user_priority_upsert ();

CREATE OR REPLACE FUNCTION public.move_priority (p_priority_id uuid, p_new_parent_path ltree)
    RETURNS void
    LANGUAGE plpgsql
    AS $function$
DECLARE
    v_old_path ltree;
    v_new_path ltree;
    v_priority_label text;
BEGIN
    -- Get the current path of the priority being moved
    SELECT
        path INTO v_old_path
    FROM
        public.priority
    WHERE
        id = p_priority_id;
    -- If priority doesn't exist, raise an exception
    IF v_old_path IS NULL THEN
        RAISE EXCEPTION 'Priority with id % not found', p_priority_id;
    END IF;
    -- Prevent moving a priority to be a descendant of itself
    IF p_new_parent_path IS NOT NULL AND (p_new_parent_path <@ v_old_path OR p_new_parent_path = v_old_path) THEN
        RAISE EXCEPTION 'Cannot move priority to be a descendant of itself';
    END IF;
    -- Extract the last label from the current path (the priority's own identifier)
    v_priority_label := ltree2text (subpath (v_old_path, -1));
    -- Calculate the new path
    IF p_new_parent_path IS NULL THEN
        -- Moving to root level
        v_new_path := text2ltree (v_priority_label);
    ELSE
        -- Moving under a parent
        v_new_path := text2ltree (ltree2text (p_new_parent_path) || '.' || v_priority_label);
    END IF;
    -- Update all priorities whose path starts with the old path
    -- This includes the priority itself and all its descendants
    UPDATE
        public.priority
    SET
        path = CASE
        -- For the priority itself, use the new path directly
        WHEN path = v_old_path THEN
            v_new_path
            -- For descendants, replace the old path prefix with the new path
        ELSE
            text2ltree (ltree2text (v_new_path) || ltree2text (subpath (path, nlevel (v_old_path))))
        END
    WHERE
        path <@ v_old_path
        OR path = v_old_path;
END;
$function$;

ALTER VIEW "public"."activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_children" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_exception" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_settings_inherited" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority" SET (security_invoker = TRUE);

ALTER VIEW "public"."actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child_twist" SET (security_invoker = TRUE);

