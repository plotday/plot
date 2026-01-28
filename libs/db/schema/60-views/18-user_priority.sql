-- While priority_user defines the priority roots for a user,
-- user_priority has a row for every priority (including children)
-- the user can access, with unread status.
CREATE OR REPLACE VIEW "public"."user_priority" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    pu.user_id,
    p.id,
    p.created_at,
    GREATEST (settings.updated_at, pu.updated_at, p.updated_at, coalesce(upu.updated_at, 'epoch')) AS updated_at,
    GREATEST (pu.archived_at, p.archived_at) AS archived_at,
    p.created_by,
    p.updated_by,
    pu.personal = TRUE
    AND p.id = root.id AS root,
    COALESCE(settings.title, p.title) AS title,
    CASE
    -- Priority has explicit inherited settings
    WHEN inherited_settings.path IS NOT NULL THEN
        inherited_settings.path
        -- Priority's actual path is already under user's personal root
    WHEN user_root.path @> p.path THEN
        p.path
        -- Priority's parent has inherited settings - use parent's visual path + this priority's label
    WHEN parent_inherited_settings.path IS NOT NULL THEN
        parent_inherited_settings.path || text(subpath (p.path, nlevel (p.path) - 1, 1))::ltree
        -- Fallback: concatenate user root + actual path
    ELSE
        user_root.path || p.path
    END AS path,
    p.path AS global_path,
    settings.top_order,
    COALESCE(settings."order", extract(epoch FROM p.created_at) * 1000) AS "order",
    inherited_settings.pomodoro,
    inherited_settings.color,
    p.key,
    COALESCE(upu.unread, FALSE) AS unread
FROM
    priority_user pu
    JOIN priority root ON pu.priority_id = root.id
    JOIN priority_user pu_root ON pu.user_id = pu_root.user_id
        AND pu_root.personal = TRUE
    JOIN priority user_root ON pu_root.priority_id = user_root.id
    JOIN priority p ON root.path @> p.path
    -- Join parent priority to get its inherited settings for visual path computation
    LEFT JOIN priority parent_p ON nlevel (p.path) > 1
        AND parent_p.path = subpath (p.path, 0, nlevel (p.path) - 1)
    LEFT JOIN priority_settings_inherited parent_inherited_settings ON parent_inherited_settings.user_id = pu.user_id
        AND parent_p.id = parent_inherited_settings.priority_id
    LEFT JOIN priority_settings settings ON settings.user_id = pu.user_id
        AND p.id = settings.priority_id
    LEFT JOIN priority_settings_inherited inherited_settings ON inherited_settings.user_id = pu.user_id
        AND p.id = inherited_settings.priority_id
        -- Latest updated_at in descendant activities
    LEFT JOIN user_priority_unread upu ON upu.user_id = pu.user_id
        AND upu.priority_id = p.id
WHERE
    pu.archived_at IS NULL;

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
    -- Variables for move detection
    _is_move boolean;
    _is_visual_move boolean := FALSE;
    _user_personal_root_path ltree;
    _old_is_personal boolean;
    _new_is_personal boolean;
    _aliased_root_id uuid;
    _aliased_root_visual_path ltree;
    _aliased_root_actual_path ltree;
    _within_aliased_tree boolean;
    _priority_exists boolean;
    _old_actual_path ltree;
    -- For storing OLD path when OLD.global_path is NULL
BEGIN
    _priority_id := NEW.id;
    _is_creator := (NEW.created_by = COALESCE(auth.uid (), NEW.user_id));
    -- Check if priority already exists (to distinguish INSERT from UPDATE)
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                priority
            WHERE
                id = NEW.id) INTO _priority_exists;
    -- For existing priorities, compute what the new actual path would be
    -- This is needed for move detection since NEW.global_path is NULL (computed column)
    -- Also get OLD path if not available (happens with INSERT ... ON CONFLICT)
    IF _priority_exists THEN
        -- Get the old actual path from the database if OLD.global_path is NULL
        -- This happens when using INSERT ... ON CONFLICT (upsert)
        _old_actual_path := OLD.global_path;
        IF _old_actual_path IS NULL THEN
            SELECT
                path INTO _old_actual_path
            FROM
                priority
            WHERE
                id = NEW.id;
        END IF;
        IF nlevel (NEW.path) > 1 THEN
            -- Extract parent path and label from visual path
            _parent_visual_path := subpath (NEW.path, 0, nlevel (NEW.path) - 1);
            _label := text(subpath (NEW.path, nlevel (NEW.path) - 1, 1));
            -- Look up parent's ID and actual path from visual path
            SELECT
                id,
                global_path INTO _parent_id,
                _parent_actual_path
            FROM
                user_priority
            WHERE
                user_id = COALESCE(auth.uid (), NEW.user_id)
                AND path = _parent_visual_path
            LIMIT 1;
            IF _parent_actual_path IS NULL THEN
                RAISE EXCEPTION 'Parent priority not found'
                    USING HINT = 'parent_visual_path=' || _parent_visual_path::text;
                END IF;
                -- Compute what the new actual path would be
                _actual_path := _parent_actual_path || _label::ltree;
            ELSE
                -- Root level priority (nlevel = 1)
                _actual_path := NEW.path;
            END IF;
        END IF;
        -- Detect if this is a move (actual path changed on existing priority)
        -- Use computed actual path instead of NEW.global_path (which is NULL)
        _is_move := (_priority_exists
            AND _actual_path IS NOT NULL
            AND _old_actual_path IS DISTINCT FROM _actual_path);
        IF _is_move THEN
            -- This is a move operation
            -- Block moving root priorities
            IF NEW.root THEN
                RAISE EXCEPTION 'Cannot move root priority'
                    USING HINT = 'Root priorities define access boundaries and cannot be moved';
                END IF;
                -- Get user's personal root path (actual path)
                SELECT
                    p.path INTO _user_personal_root_path
                FROM
                    priority_user pu
                    JOIN priority p ON pu.priority_id = p.id
                WHERE
                    pu.user_id = COALESCE(auth.uid (), NEW.user_id)
                    AND pu.personal = TRUE
                    AND pu.archived_at IS NULL
                LIMIT 1;
                -- Determine if old and new locations are under personal root using global_path
                _old_is_personal := (_user_personal_root_path @> _old_actual_path);
                -- Determine if new location is under personal root using computed actual path
                -- (actual path was already computed before move detection)
                _new_is_personal := (_user_personal_root_path @> _actual_path);
                -- Prevent circular reference
                IF _actual_path <@ _old_actual_path OR _actual_path = _old_actual_path THEN
                    RAISE EXCEPTION 'Cannot move priority to be a descendant of itself'
                        USING HINT = 'old_path=' || _old_actual_path::text || ', new_path=' || _actual_path::text;
                    END IF;
                    -- Check if move is within an aliased tree
                    -- Find the deepest ancestor with priority_settings that creates an alias
                    _within_aliased_tree := FALSE;
                    _aliased_root_id := NULL;
                    IF NOT _old_is_personal AND _new_is_personal THEN
                        -- Look for aliased ancestor by checking priority_settings
                        -- Find deepest ancestor where both old and new global paths are under the aliased root's actual path
                        SELECT
                            ps.priority_id,
                            ps.path,
                            p.path INTO _aliased_root_id,
                            _aliased_root_visual_path,
                            _aliased_root_actual_path
                        FROM
                            priority_settings ps
                            JOIN priority p ON ps.priority_id = p.id
                        WHERE
                            ps.user_id = COALESCE(auth.uid (), NEW.user_id)
                            AND ps.path IS NOT NULL
                            AND NEW.path <@ ps.path
                            -- New visual path is under this aliased path
                            AND OLD.path <@ ps.path
                            -- Old visual path is also under this aliased path
                            AND ps.path != p.path
                            -- Visual path differs from actual (indicates alias)
                            AND _old_actual_path <@ p.path
                            -- Old actual path is under the aliased root's actual path
                            AND _actual_path <@ p.path
                            -- New actual path is also under the aliased root's actual path
                        ORDER BY
                            nlevel (ps.path) DESC
                            -- Deepest first
                        LIMIT 1;
                        IF _aliased_root_id IS NOT NULL THEN
                            _within_aliased_tree := TRUE;
                        END IF;
                    END IF;
                    -- Determine move type and execute appropriate action
                    IF (_old_is_personal AND _new_is_personal) OR (NOT _old_is_personal AND NOT _new_is_personal) THEN
                        -- Type 1: Actual move (within personal tree or within/between shared trees)
                        PERFORM
                            move_priority (NEW.id, _parent_actual_path);
                        _actual_path := NULL;
                        -- Path updated by move_priority, don't update priority_settings.path
                    ELSIF NOT _old_is_personal
                            AND _new_is_personal
                            AND _within_aliased_tree THEN
                            -- Type 3: Actual move within aliased tree
                            -- Both old and new are under the same aliased root
                            -- This is a real organizational change within the shared tree
                            PERFORM
                                move_priority (NEW.id, _parent_actual_path);
                        _actual_path := NULL;
                        -- Path updated by move_priority, don't update priority_settings.path
                    ELSIF NOT _old_is_personal
                            AND _new_is_personal THEN
                            -- Type 2: Visual move (aliasing shared priority under personal root)
                            -- Set priority_settings.path to create visual alias
                            -- Actual path remains unchanged
                            -- This happens in the priority_settings update section below
                            _actual_path := NULL;
                        _is_visual_move := TRUE;
                        -- Don't change actual path, but DO update priority_settings.path with NEW.path
                    ELSIF _old_is_personal
                            AND NOT _new_is_personal THEN
                            -- Moving personal priority into shared tree - block this
                            RAISE EXCEPTION 'Cannot move personal priority into shared tree'
                            USING HINT = 'Use Share dialog to share a personal priority';
                        END IF;
                    END IF;
                    -- Translate visual path to actual path for new sub-priorities
                    -- For root priorities or existing priorities, use path as-is
                    IF _is_move IS NOT TRUE AND NOT _priority_exists AND nlevel (NEW.path) > 1 THEN
                        -- Extract parent path and label from visual path
                        _parent_visual_path := subpath (NEW.path, 0, nlevel (NEW.path) - 1);
                        _label := text(subpath (NEW.path, nlevel (NEW.path) - 1, 1));
                        -- Look up parent's actual path via user_priority view (which has global_path)
                        SELECT
                            global_path INTO _parent_actual_path
                        FROM
                            user_priority
                        WHERE
                            user_id = COALESCE(auth.uid (), NEW.user_id)
                            AND path = _parent_visual_path
                        LIMIT 1;
                        IF _parent_actual_path IS NOT NULL THEN
                            -- Compute actual path for new priority
                            _actual_path := _parent_actual_path || _label::ltree;
                        ELSE
                            -- Fallback: parent not found, use path as-is (shouldn't happen)
                            _actual_path := NEW.path;
                        END IF;
                    ELSIF _is_move IS NOT TRUE THEN
                        -- Use provided path as-is (root priority or existing non-move update)
                        _actual_path := NEW.path;
                    END IF;
                    -- Get the priority's default color for initializing new priority_settings
                    SELECT
                        color INTO _priority_default_color
                    FROM
                        priority
                    WHERE
                        id = NEW.id;
                    -- Update priority table fields (title, archived_at, updated_by, color)
                    -- Note: For moves, path was already updated by move_priority()
                    -- We always update for new priorities, moves, or when any fields are provided
                    IF TRUE THEN
                        -- Only insert/update if path was computed (for new priorities)
                        -- For moves, path was already updated by move_priority()
                        IF _actual_path IS NOT NULL THEN
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
                                    updated_by = NEW.updated_by
                                RETURNING
                                    id INTO _priority_id;
                        ELSE
                            -- For moves, just update non-path fields
                            UPDATE
                                priority
                            SET
                                archived_at = NEW.archived_at,
                                title = NEW.title,
                                color = CASE WHEN _is_creator THEN
                                    NEW.color
                                ELSE
                                    priority.color
                                END,
                                updated_by = NEW.updated_by
                            WHERE
                                id = NEW.id
                            RETURNING
                                id INTO _priority_id;
                        END IF;
                    END IF;
                    -- Update priority_settings for user-specific inherited fields
                    -- Only update when:
                    -- 1. This is a visual move (Type 2) - always update path
                    -- 2. Explicit settings are provided AND this is not a non-visual move
                    IF _is_visual_move THEN
                        -- Visual move: create/update path alias
                        INSERT INTO priority_settings (user_id, priority_id, path, top_order, "order", pomodoro, color)
                            VALUES (COALESCE(auth.uid (), NEW.user_id), _priority_id, NEW.path, NEW.top_order, NEW.order, NEW.pomodoro, COALESCE(NEW.color, _priority_default_color))
                        ON CONFLICT (user_id, priority_id)
                            DO UPDATE SET
                                path = NEW.path,
                                top_order = COALESCE(NEW.top_order, priority_settings.top_order),
                                "order" = COALESCE(NEW.order, priority_settings.order),
                                pomodoro = COALESCE(NEW.pomodoro, priority_settings.pomodoro),
                                color = COALESCE(NEW.color, priority_settings.color);
                    ELSIF NOT _is_move
                            AND (NEW."top_order" IS NOT NULL
                                OR NEW."order" IS NOT NULL
                                OR NEW."pomodoro" IS NOT NULL
                                OR NEW."color" IS NOT NULL) THEN
                            -- Non-move update with explicit settings
                            INSERT INTO priority_settings (user_id, priority_id, path, top_order, "order", pomodoro, color)
                                VALUES (COALESCE(auth.uid (), NEW.user_id), _priority_id, NULL, NEW.top_order, NEW.order, NEW.pomodoro, COALESCE(NEW.color, _priority_default_color))
                            ON CONFLICT (user_id, priority_id)
                                DO UPDATE SET
                                    top_order = COALESCE(NEW.top_order, priority_settings.top_order),
                                    "order" = COALESCE(NEW.order, priority_settings.order),
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

