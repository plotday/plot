DROP TRIGGER IF EXISTS "upsert_user_priority" ON "public"."user_priority";

DROP VIEW IF EXISTS "public"."user_activity_exception";

DROP VIEW IF EXISTS "public"."user_activity_tags";

DROP VIEW IF EXISTS "public"."user_activity";

DROP VIEW IF EXISTS "public"."user_priority";

ALTER TABLE "public"."priority_settings"
    ADD COLUMN "order" double precision NOT NULL DEFAULT order_first ();

ALTER TABLE "public"."priority_settings"
    ADD COLUMN "path" ltree;

ALTER TABLE "public"."priority_settings"
    ADD COLUMN "top" boolean NOT NULL DEFAULT FALSE;

ALTER TABLE "public"."priority_user"
    DROP COLUMN "order";

ALTER TABLE "public"."priority_user"
    DROP COLUMN "path";

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.handle_user_priority_upsert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
DECLARE
    _priority_id uuid;
BEGIN
    _priority_id := NEW.id;
    IF (OLD IS NULL OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at OR NEW.title IS DISTINCT FROM OLD.title OR NEW.path IS DISTINCT FROM OLD.path OR NEW.order IS DISTINCT FROM OLD.order OR NEW.updated_by IS DISTINCT FROM OLD.updated_by) THEN
        INSERT INTO priority (id, deleted_at, title, path, "order", created_by, updated_by)
            VALUES (NEW.id, NEW.deleted_at, NEW.title, NEW.path, NEW.order, NEW.created_by, NEW.updated_by)
        ON CONFLICT (id)
            DO UPDATE SET
                deleted_at = NEW.deleted_at,
                title = NEW.title,
                path = NEW.path,
                "order" = NEW.order,
                updated_by = NEW.updated_by
            RETURNING
                id INTO _priority_id;
    END IF;
    IF ((OLD IS NULL AND (NEW."order" IS NOT NULL OR NEW."path" IS NOT NULL OR NEW."top" IS NOT NULL OR NEW."pomodoro" IS NOT NULL OR NEW."color" IS NOT NULL)) OR (OLD IS NOT NULL AND (NEW."order" IS DISTINCT FROM OLD."order" OR NEW."path" IS DISTINCT FROM OLD."path" OR NEW."top" IS DISTINCT FROM OLD."top" OR NEW."pomodoro" IS DISTINCT FROM OLD."pomodoro" OR NEW."color" IS DISTINCT FROM OLD."color"))) THEN
        INSERT INTO priority_settings (user_id, priority_id, "order", path, top, pomodoro, color)
            VALUES (COALESCE(auth.uid (), NEW.user_id), _priority_id, NEW.order, NEW.path, NEW.top, NEW.pomodoro, NEW.color)
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET
                "order" = COALESCE(NEW.order, priority_settings.order),
                path = COALESCE(NEW.path, priority_settings.path),
                top = COALESCE(NEW.top, priority_settings.top),
                pomodoro = COALESCE(NEW.pomodoro, priority_settings.pomodoro),
                color = COALESCE(NEW.color, priority_settings.color);
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE VIEW "public"."user_priority" AS
SELECT
    pu.user_id,
    p.id,
    p.created_at,
    GREATEST (settings.updated_at, pu.updated_at, p.updated_at) AS updated_at,
    GREATEST (pu.deleted_at, p.deleted_at) AS deleted_at,
    p.created_by,
    p.updated_by,
    (root.root
        AND (p.id = root.id)) AS root,
    p.title,
    CASE WHEN root.root THEN
        p.path
    ELSE
        (COALESCE(settings.path, user_root.path) || subpath (p.path, nlevel (root.path)))
    END AS path,
    CASE WHEN (pu.priority_id = p.id) THEN
        COALESCE(settings."order", p."order")
    ELSE
        p."order"
    END AS "order",
    settings.top,
    settings.pomodoro,
    settings.color
FROM ((((priority_user pu
                JOIN priority root ON (pu.priority_id = root.id))
            JOIN priority user_root ON (((pu.user_id = user_root.created_by)
                        AND user_root.root)))
        JOIN priority p ON (root.path @> p.path))
    LEFT JOIN priority_settings settings ON (((settings.user_id = pu.user_id)
                AND (p.id = settings.priority_id))))
WHERE (pu.deleted_at IS NULL);

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

CREATE TRIGGER upsert_user_priority
    INSTEAD OF INSERT OR UPDATE ON public.user_priority
    FOR EACH ROW
    EXECUTE FUNCTION handle_user_priority_upsert ();

ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_children" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_exception" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "admin"."invitation" SET ( security_invoker = FALSE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_agent" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
