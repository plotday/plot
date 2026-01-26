SET check_function_bodies = OFF;

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

CREATE OR REPLACE FUNCTION public.handle_user_priority_upsert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
DECLARE
    _priority_id uuid;
    _is_creator boolean;
    _priority_default_color integer;
    _parent_visual_path ltree;
    _label text;
    _parent_id uuid;
    _parent_actual_path ltree;
    _actual_path ltree;
BEGIN
    _priority_id := NEW.id;
    _is_creator := (NEW.created_by = COALESCE(auth.uid (), NEW.user_id));
    -- Translate visual path to actual path for new sub-priorities
    -- For root priorities or existing priorities, use path as-is
    IF OLD IS NULL AND nlevel (NEW.path) > 1 THEN
        -- Extract parent path and label from visual path
        _parent_visual_path := subpath (NEW.path, 0, nlevel (NEW.path) - 1);
        _label := text(subpath (NEW.path, nlevel (NEW.path) - 1, 1));
        -- Look up parent priority ID via user_priority view (which has visual paths)
        SELECT
            id INTO _parent_id
        FROM
            user_priority
        WHERE
            user_id = COALESCE(auth.uid (), NEW.user_id)
            AND path = _parent_visual_path
        LIMIT 1;
        -- Get parent's ACTUAL path from priority table
        IF _parent_id IS NOT NULL THEN
            SELECT
                path INTO _parent_actual_path
            FROM
                priority
            WHERE
                id = _parent_id;
            -- Compute actual path for new priority
            _actual_path := _parent_actual_path || _label::ltree;
        ELSE
            -- Fallback: parent not found, use path as-is (shouldn't happen)
            _actual_path := NEW.path;
        END IF;
    ELSE
        -- Use provided path as-is (root priority or existing priority)
        _actual_path := NEW.path;
    END IF;
    -- Get the priority's default color for initializing new priority_settings
    SELECT
        color INTO _priority_default_color
    FROM
        priority
    WHERE
        id = NEW.id;
    -- Update priority table fields (title, path, archived_at, updated_by)
    -- If creator is updating color, also update priority.color
    -- Note: path is only set on INSERT, never updated (removed path check from condition)
    IF (OLD IS NULL OR NEW.archived_at IS DISTINCT FROM OLD.archived_at OR NEW.title IS DISTINCT FROM OLD.title OR NEW.updated_by IS DISTINCT FROM OLD.updated_by OR (_is_creator AND NEW.color IS DISTINCT FROM OLD.color)) THEN
        INSERT INTO priority (id, archived_at, title, color, path, created_by, updated_by)
            VALUES (NEW.id, NEW.archived_at, NEW.title, CASE WHEN _is_creator THEN
                    NEW.color
                ELSE
                    NULL
                END, _actual_path, NEW.created_by, NEW.updated_by)
        ON CONFLICT (id)
            DO UPDATE SET
                archived_at = NEW.archived_at,
                title = NEW.title,
                color = CASE WHEN _is_creator THEN
                    NEW.color
                ELSE
                    priority.color
                END,
                -- path is intentionally NOT updated - it never changes after creation
                updated_by = NEW.updated_by
            RETURNING
                id INTO _priority_id;
    END IF;
    -- Update priority_settings for user-specific inherited fields
    -- Always update priority_settings.color when color changes (for all users)
    -- Initialize color from priority.color if not provided by user
    IF ((OLD IS NULL AND (NEW."path" IS NOT NULL OR NEW."top_order" IS NOT NULL OR NEW."order" IS NOT NULL OR NEW."pomodoro" IS NOT NULL OR NEW."color" IS NOT NULL)) OR (OLD IS NOT NULL AND (NEW."path" IS DISTINCT FROM OLD."path" OR NEW."top_order" IS DISTINCT FROM OLD."top_order" OR NEW."order" IS DISTINCT FROM OLD."order" OR NEW."pomodoro" IS DISTINCT FROM OLD."pomodoro" OR NEW."color" IS DISTINCT FROM OLD."color"))) THEN
        INSERT INTO priority_settings (user_id, priority_id, path, top_order, "order", pomodoro, color)
            VALUES (COALESCE(auth.uid (), NEW.user_id), _priority_id, NEW.path, NEW.top_order, NEW.order, NEW.pomodoro, COALESCE(NEW.color, _priority_default_color))
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET
                path = COALESCE(NEW.path, priority_settings.path),
                top_order = COALESCE(NEW.top_order, priority_settings.top_order),
                "order" = COALESCE(NEW.order, priority_settings.order),
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
    GREATEST (settings.updated_at, pu.updated_at, p.updated_at, COALESCE(upu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    GREATEST (pu.archived_at, p.archived_at) AS archived_at,
    p.created_by,
    p.updated_by,
    ((pu.personal = TRUE)
    AND (p.id = root.id)) AS root,
    COALESCE(settings.title, p.title) AS title,
    CASE WHEN (inherited_settings.path IS NOT NULL) THEN
        inherited_settings.path
    WHEN (user_root.path @> p.path) THEN
        p.path
    WHEN (parent_inherited_settings.path IS NOT NULL) THEN
        (parent_inherited_settings.path || ((subpath (p.path, (nlevel (p.path) - 1), 1))::text)::ltree)
    ELSE
        (user_root.path || p.path)
    END AS path,
    settings.top_order,
    COALESCE(settings."order", ((EXTRACT(epoch FROM p.created_at) * (1000)::numeric))::double precision) AS "order",
    inherited_settings.pomodoro,
    inherited_settings.color,
    COALESCE(upu.unread, FALSE) AS unread
FROM (((((((((priority_user pu
                                    JOIN priority root ON (pu.priority_id = root.id))
                                JOIN priority_user pu_root ON (((pu.user_id = pu_root.user_id)
                                            AND (pu_root.personal = TRUE))))
                            JOIN priority user_root ON (pu_root.priority_id = user_root.id))
                        JOIN priority p ON (root.path @> p.path))
                    LEFT JOIN priority parent_p ON (((nlevel (p.path) > 1)
                                AND (parent_p.path = subpath (p.path, 0, (nlevel (p.path) - 1))))))
                LEFT JOIN priority_settings_inherited parent_inherited_settings ON (((parent_inherited_settings.user_id = pu.user_id)
                            AND (parent_p.id = parent_inherited_settings.priority_id))))
            LEFT JOIN priority_settings settings ON (((settings.user_id = pu.user_id)
                        AND (p.id = settings.priority_id))))
        LEFT JOIN priority_settings_inherited inherited_settings ON (((inherited_settings.user_id = pu.user_id)
                    AND (p.id = inherited_settings.priority_id))))
    LEFT JOIN user_priority_unread upu ON (((upu.user_id = pu.user_id)
                AND (upu.priority_id = p.id))))
WHERE (pu.archived_at IS NULL);

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
