CREATE OR REPLACE VIEW "public"."activity_tags" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    sq.activity_id,
    jsonb_object_agg(sq.tag_id, sq.user_ids) AS tags,
    sq.updated_at,
    sq.updated_by
FROM (
    SELECT
        at.activity_id,
        at.tag_id,
        jsonb_agg(at.user_id) AS user_ids,
        MAX(COALESCE(at.deleted_at, at.updated_at)) AS updated_at,
        (array_agg(at.updated_by ORDER BY COALESCE(at.deleted_at, at.updated_at) DESC))[1] AS updated_by
    FROM
        "public"."activity_tag" at
    WHERE
        at.deleted_at IS NULL
    GROUP BY
        at.activity_id,
        at.tag_id) sq
GROUP BY
    sq.activity_id,
    sq.updated_at,
    sq.updated_by;

CREATE OR REPLACE VIEW "public"."activity_x" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    a.id,
    pu.user_id,
    a.created_at,
    GREATEST (a.updated_at, COALESCE(tags.updated_at, a.updated_at)) AS updated_at,
    CASE WHEN COALESCE(tags.updated_at, a.updated_at) > a.updated_at THEN
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
    a.order,
    COALESCE(a.done_at, a.do_on, a.created_at)::date AS day,
    tags.tags AS tags
FROM
    -- User access to priorities
    priority_user pu
    -- Priority root of the activity's priority
    JOIN priority p ON pu.priority_id = p.id
        OR (p.path <@ (
                SELECT
                    path
                FROM
                    priority
            WHERE
                id = pu.priority_id))
    -- Activities under accessible priorities
    JOIN activity a ON a.priority_id = p.id
    LEFT JOIN activity_tags tags ON tags.activity_id = a.id
WHERE
    pu.deleted_at IS NULL
    AND p.deleted_at IS NULL;

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

CREATE TRIGGER upsert_activity_x
    INSTEAD OF INSERT OR UPDATE ON activity_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_activity_x_upsert ();

CREATE OR REPLACE VIEW "public"."activity_children" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    a.id,
    c.id AS child_id
FROM
    "public"."activity_x" a
    JOIN "public"."activity" c ON c.path <@ a.path;

