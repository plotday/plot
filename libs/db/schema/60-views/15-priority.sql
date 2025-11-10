CREATE OR REPLACE VIEW "public"."priority_tags" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    a.priority_id,
    at.tag_id,
    COUNT(*) AS count,
    MAX(COALESCE(at.archived_at, at.updated_at)) AS updated_at
FROM
    "public"."activity_tag" at
    JOIN "public"."activity" a ON at.activity_id = a.id
WHERE
    at.archived_at IS NULL
    AND a.archived_at IS NULL
    AND nlevel (a.path) = 1
GROUP BY
    a.priority_id,
    at.tag_id;

CREATE OR REPLACE VIEW "public"."priority_child" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    p.id AS priority_id,
    c.id AS child_id
FROM
    "public"."priority" p
    JOIN "public"."priority" c ON c.path <@ p.path;

CREATE OR REPLACE VIEW "public"."priority_settings_inherited" WITH ( security_invoker = TRUE)
-- for formatting
AS SELECT DISTINCT ON (ps.user_id, p.id)
    ps.user_id,
    p.id AS priority_id,
    CASE WHEN nlevel (p.path) > nlevel (parent.path)
        AND subpath (p.path, nlevel (parent.path)) != '' THEN
        ps.path || subpath (p.path, nlevel (parent.path))
    ELSE
        ps.path
    END AS path,
    ps.pomodoro,
    ps.color
FROM
    priority_settings ps
    JOIN priority parent ON ps.priority_id = parent.id
    JOIN priority p ON p.path <@ parent.path
WHERE
    ps.path IS NOT NULL
    OR ps.pomodoro IS NOT NULL
    OR ps.color IS NOT NULL
ORDER BY
    ps.user_id,
    p.id,
    -- Closest ancestor first (by path distance)
    nlevel (p.path) - nlevel (parent.path) ASC;

-- While priority_user defines the priority roots for a user,
-- user_priority has a row for every priority (including children)
-- the user can access.
CREATE OR REPLACE VIEW "public"."user_priority" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    pu.user_id,
    p.id,
    p.created_at,
    GREATEST (settings.updated_at, pu.updated_at, p.updated_at, coalesce(activity_max.updated_at, 'epoch'), coalesce(ar_max.updated_at, 'epoch')) AS updated_at,
    GREATEST (pu.archived_at, p.archived_at) AS archived_at,
    p.created_by,
    p.updated_by,
    root.root
    AND p.id = root.id AS root,
    p.title,
    CASE WHEN inherited_settings.path IS NOT NULL THEN
        inherited_settings.path
    WHEN user_root.path @> p.path THEN
        p.path
    ELSE
        user_root.path || p.path
    END AS path,
    settings.top_order,
    inherited_settings.pomodoro,
    inherited_settings.color,
    COALESCE(unread.unread, FALSE) AS unread
FROM
    priority_user pu
    LEFT JOIN contact c ON c.user_id = pu.user_id
    JOIN priority root ON pu.priority_id = root.id
    JOIN priority user_root ON pu.user_id = user_root.created_by
        AND user_root.root
    JOIN priority p ON root.path @> p.path
    LEFT JOIN priority_settings settings ON settings.user_id = pu.user_id
        AND p.id = settings.priority_id
    LEFT JOIN priority_settings_inherited inherited_settings ON inherited_settings.user_id = pu.user_id
        AND p.id = inherited_settings.priority_id
        -- Latest updated_at in descendant activities
    LEFT JOIN LATERAL (
        SELECT
            MAX(a.updated_at) AS updated_at
        FROM
            activity a
            JOIN priority ap ON ap.id = a.priority_id
        WHERE
            ap.path <@ p.path
            AND a.archived_at IS NULL) activity_max ON TRUE
    -- Latest updated_at in user's activity_reads
    LEFT JOIN LATERAL (
        SELECT
            MAX(ar.updated_at) AS updated_at
        FROM
            activity_read ar
        WHERE
            ar.user_id = pu.user_id
            AND ar.activity_path <@ p.path) ar_max ON TRUE
    -- Unread exists for this user and priority tree
    LEFT JOIN LATERAL (
        SELECT
            TRUE AS unread
        FROM
            activity a
            JOIN priority ap ON ap.id = a.priority_id
            LEFT JOIN activity_read ar ON ar.user_id = pu.user_id
                AND ar.activity_path = subpath (a.path, 0, 1)
        WHERE
            ap.path <@ p.path
            AND a.archived_at IS NULL
            AND a.author_id <> c.id
            AND (ar.read_at IS NULL
                OR a.created_at > ar.read_at)
        LIMIT 1) unread ON TRUE
WHERE
    pu.archived_at IS NULL;

CREATE OR REPLACE FUNCTION public.handle_user_priority_upsert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
DECLARE
    _priority_id uuid;
BEGIN
    _priority_id := NEW.id;
    IF (OLD IS NULL OR NEW.archived_at IS DISTINCT FROM OLD.archived_at OR NEW.title IS DISTINCT FROM OLD.title OR NEW.path IS DISTINCT FROM OLD.path OR NEW.updated_by IS DISTINCT FROM OLD.updated_by) THEN
        INSERT INTO priority (id, archived_at, title, path, created_by, updated_by)
            VALUES (NEW.id, NEW.archived_at, NEW.title, NEW.path, NEW.created_by, NEW.updated_by)
        ON CONFLICT (id)
            DO UPDATE SET
                archived_at = NEW.archived_at,
                title = NEW.title,
                path = NEW.path,
                updated_by = NEW.updated_by
            RETURNING
                id INTO _priority_id;
    END IF;
    IF ((OLD IS NULL AND (NEW."path" IS NOT NULL OR NEW."top_order" IS NOT NULL OR NEW."pomodoro" IS NOT NULL OR NEW."color" IS NOT NULL)) OR (OLD IS NOT NULL AND (NEW."path" IS DISTINCT FROM OLD."path" OR NEW."top_order" IS DISTINCT FROM OLD."top_order" OR NEW."pomodoro" IS DISTINCT FROM OLD."pomodoro" OR NEW."color" IS DISTINCT FROM OLD."color"))) THEN
        INSERT INTO priority_settings (user_id, priority_id, path, top_order, pomodoro, color)
            VALUES (COALESCE(auth.uid (), NEW.user_id), _priority_id, NEW.path, NEW.top_order, NEW.pomodoro, NEW.color)
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET
                path = COALESCE(NEW.path, priority_settings.path),
                top_order = COALESCE(NEW.top_order, priority_settings.top_order),
                pomodoro = COALESCE(NEW.pomodoro, priority_settings.pomodoro),
                color = COALESCE(NEW.color, priority_settings.color);
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER upsert_user_priority
    INSTEAD OF INSERT OR UPDATE ON user_priority
    FOR EACH ROW
    EXECUTE FUNCTION handle_user_priority_upsert ();

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.get_accessible_twists (p_priority_id uuid)
    RETURNS SETOF twist
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    AS $function$
    SELECT DISTINCT
        twist.*
    FROM
        twist
    LEFT JOIN twist_admin ON twist.id = twist_admin.id
WHERE
    twist.environment = 'public'
    OR (twist.environment = 'personal'
        AND twist.user_id = auth.uid ())
    OR can_access_priority (twist_admin.priority_id)
$function$;

CREATE OR REPLACE FUNCTION public.is_accessible_twist (p_twist_id uuid, p_twist_environment twist_environment, p_priority_id uuid)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                twist
            LEFT JOIN twist_admin ON twist.id = twist_admin.id
        WHERE
            twist.id = p_twist_id
            AND twist.environment = p_twist_environment
            AND (twist.environment = 'public'
                OR (twist.environment = 'personal'
                    AND twist.user_id = auth.uid ())
                OR can_access_priority (twist_admin.priority_id)))
$function$;

