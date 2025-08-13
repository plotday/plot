-- Rename do_at column to do_on in activity table
ALTER TABLE public.activity RENAME COLUMN do_at TO do_on;

-- Rename the associated index
DROP INDEX IF EXISTS idx_activity_do_at;

CREATE INDEX idx_activity_do_on ON public.activity (do_on);

DROP TRIGGER IF EXISTS "upsert_activity_x" ON "public"."activity_x";

DROP VIEW IF EXISTS "public"."activity_children";

DROP VIEW IF EXISTS "public"."activity_x";

SET check_function_bodies = OFF;

CREATE OR REPLACE VIEW "public"."activity_x" AS
SELECT
    a.id,
    pu.user_id,
    a.created_at,
    GREATEST (a.updated_at, COALESCE(tags.updated_at, a.updated_at)) AS updated_at,
    CASE WHEN (COALESCE(tags.updated_at, a.updated_at) > a.updated_at) THEN
        tags.updated_by
    ELSE
        a.updated_by
    END AS updated_by,
    a.deleted_at,
    a.created_by,
    a.priority_id,
    a.path,
    a.draft,
    a.private,
    a.do_on,
    a.done_at,
    a.title,
    a.note,
    a.event_series,
    a."order",
    (COALESCE(a.done_at, (a.do_on)::timestamp with time zone, a.created_at))::date AS day,
    tags.tags
FROM (((priority_user pu
            JOIN priority p ON (((pu.priority_id = p.id)
                        OR (p.path <@ (
                                SELECT
                                    priority.path
                                FROM
                                    priority
                            WHERE (priority.id = pu.priority_id))))))
        JOIN activity a ON (a.priority_id = p.id))
    LEFT JOIN activity_tags tags ON (tags.activity_id = a.id))
WHERE ((pu.deleted_at IS NULL)
    AND (p.deleted_at IS NULL));

CREATE OR REPLACE FUNCTION public.handle_activity_x_upsert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
DECLARE
    _activity_id uuid;
BEGIN
    _activity_id := NEW.id;
    -- Insert or update the activity
    INSERT INTO activity (id, updated_by, deleted_at, priority_id, path, draft, private, do_on, done_at, "order", title, note, event_series)
        VALUES (NEW.id, NEW.updated_by, NEW.deleted_at, NEW.priority_id, NEW.path, NEW.draft, NEW.private, NEW.do_on, NEW.done_at, NEW.order, NEW.title, NEW.note, NEW.event_series)
    ON CONFLICT (id)
        DO UPDATE SET
            updated_by = NEW.updated_by,
            deleted_at = NEW.deleted_at,
            priority_id = NEW.priority_id,
            path = NEW.path,
            draft = NEW.draft,
            private = NEW.private,
            do_on = NEW.do_on,
            done_at = NEW.done_at,
            "order" = NEW.order,
            title = NEW.title,
            note = NEW.note,
            event_series = NEW.event_series
        RETURNING
            id INTO _activity_id;
    -- Call update_activity_tags if tags is not null
    IF NEW.tags IS NOT NULL THEN
        PERFORM
            update_activity_tags (NEW.id, auth.uid (), NEW.updated_by, NEW.tags);
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE VIEW "public"."activity_children" AS
SELECT
    a.id,
    c.id AS child_id
FROM (activity_x a
    JOIN activity c ON (c.path <@ a.path));

CREATE TRIGGER upsert_activity_x
    INSTEAD OF INSERT OR UPDATE ON public.activity_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_activity_x_upsert ();


