-- Create "notify_displaced_priority_users" function
CREATE FUNCTION "public"."notify_displaced_priority_users" ("p_priority_id" uuid, "p_old_path" public.ltree, "p_new_parent_path" public.ltree) RETURNS TABLE ("displaced_user_id" uuid) LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_priority_label text;
    v_new_path ltree;
    v_user_id uuid;
BEGIN
    -- Compute the new path for the priority after the move
    v_priority_label := ltree2text(subpath(p_old_path, -1));
    IF p_new_parent_path IS NULL THEN
        v_new_path := text2ltree(v_priority_label);
    ELSE
        v_new_path := text2ltree(ltree2text(p_new_parent_path) || '.' || v_priority_label);
    END IF;

    -- Find users who had access via the old root but not the new root
    FOR v_user_id IN
        WITH old_access AS (
            -- Users with a priority_user entry for the old tree's root priority
            SELECT DISTINCT pu.user_id
            FROM priority_user pu
            JOIN priority p ON p.id = pu.priority_id
            WHERE p.path = subltree(p_old_path, 0, 1)
              AND pu.archived_at IS NULL
        ),
        new_access AS (
            -- Users with a priority_user entry for the new tree's root priority
            SELECT DISTINCT pu.user_id
            FROM priority_user pu
            JOIN priority p ON p.id = pu.priority_id
            WHERE p.path = subltree(v_new_path, 0, 1)
              AND pu.archived_at IS NULL
        )
        SELECT oa.user_id
        FROM old_access oa
        LEFT JOIN new_access na ON na.user_id = oa.user_id
        WHERE na.user_id IS NULL  -- had old access, does not have new access
    LOOP
        -- Archive the priority_user entry to signal the client to delete local data
        INSERT INTO priority_user (user_id, priority_id, personal, archived_at)
            VALUES (v_user_id, p_priority_id, FALSE, now())
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET archived_at = now(), updated_at = now();

        -- Update user_sync so this user receives a real-time WebSocket push
        INSERT INTO user_sync (user_id, entity, last_update_at)
            VALUES (v_user_id, 'priority_user', now())
        ON CONFLICT (user_id, entity)
            DO UPDATE SET last_update_at = GREATEST(user_sync.last_update_at, EXCLUDED.last_update_at);

        RETURN NEXT;
    END LOOP;
END;
$$;
-- Modify "upsert_priority" function
CREATE OR REPLACE FUNCTION "user"."upsert_priority" ("user_id" uuid, "p_priority" jsonb) RETURNS "user"."priority" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
#variable_conflict use_column
DECLARE
    _input "user"."priority";
    _old "user"."priority";
    v_row "user"."priority";
    _priority_id uuid;
    _is_creator boolean;
    _priority_default_color integer;
    _parent_visual_path ltree;
    _label text;
    _parent_actual_path ltree;
    _actual_path ltree;
    _is_move boolean;
    _is_visual_move boolean := FALSE;
    _user_personal_root_path ltree;
    _old_is_personal boolean;
    _new_is_personal boolean;
    _aliased_root_id uuid;
    _within_aliased_tree boolean;
    _priority_exists boolean;
    _old_actual_path ltree;
BEGIN
    -- Extract input fields from JSONB into the view's row type
    _input := jsonb_populate_record(NULL::"user"."priority", p_priority || jsonb_build_object('user_id', upsert_priority.user_id));
    _is_creator := (_input.created_by = upsert_priority.user_id);
    -- Check if priority already exists (to distinguish INSERT from UPDATE)
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                priority
            WHERE
                id = _input.id) INTO _priority_exists;
    -- Look up existing row from view if it exists (replaces OLD trigger variable)
    IF _priority_exists THEN
        SELECT
            * INTO _old
        FROM
            "user".priority up
        WHERE
            up.user_id = upsert_priority.user_id
            AND up.id = _input.id;
    END IF;
    -- For existing priorities, compute what the new actual path would be
    -- This is needed for move detection since global_path is a computed column
    IF _priority_exists THEN
        _old_actual_path := _old.global_path;
        IF _old_actual_path IS NULL THEN
            SELECT
                path INTO _old_actual_path
            FROM
                priority
            WHERE
                id = _input.id;
        END IF;
        IF nlevel (_input.path) > 1 THEN
            -- Extract parent path and label from visual path
            _parent_visual_path := subpath (_input.path, 0, nlevel (_input.path) - 1);
            _label := text(subpath (_input.path, nlevel (_input.path) - 1, 1));
            -- Look up parent's ID and actual path from visual path
            SELECT
                global_path INTO _parent_actual_path
            FROM
                "user".priority
            WHERE
                user_id = upsert_priority.user_id
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
            _actual_path := _input.path;
        END IF;
    END IF;
    -- Detect if this is a move (actual path changed on existing priority)
    _is_move := (_priority_exists
        AND _actual_path IS NOT NULL
        AND _old_actual_path IS DISTINCT FROM _actual_path);
    IF _is_move THEN
        -- Block moving root priorities
        IF _input.root THEN
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
            pu.user_id = upsert_priority.user_id
            AND pu.personal = TRUE
            AND pu.archived_at IS NULL
        LIMIT 1;
        -- Determine if old and new locations are under personal root
        _old_is_personal := (_user_personal_root_path @> _old_actual_path);
        _new_is_personal := (_user_personal_root_path @> _actual_path);
        -- Prevent circular reference
        IF _actual_path <@ _old_actual_path OR _actual_path = _old_actual_path THEN
            RAISE EXCEPTION 'Cannot move priority to be a descendant of itself'
                USING HINT = 'old_path=' || _old_actual_path::text || ', new_path=' || _actual_path::text;
        END IF;
        -- Check if move is within an aliased tree
        _within_aliased_tree := FALSE;
        _aliased_root_id := NULL;
        IF NOT _old_is_personal AND _new_is_personal THEN
            -- Find deepest ancestor where both old and new paths are under the aliased root
            SELECT
                ps.priority_id INTO _aliased_root_id
            FROM
                priority_settings ps
                JOIN priority p ON ps.priority_id = p.id
            WHERE
                ps.user_id = upsert_priority.user_id
                AND ps.path IS NOT NULL
                AND _input.path <@ ps.path
                AND _old.path <@ ps.path
                AND ps.path != p.path
                AND _old_actual_path <@ p.path
                AND _actual_path <@ p.path
            ORDER BY
                nlevel (ps.path) DESC
            LIMIT 1;
            IF _aliased_root_id IS NOT NULL THEN
                _within_aliased_tree := TRUE;
            END IF;
        END IF;
        -- Determine move type and execute appropriate action
        IF _old_is_personal AND _new_is_personal THEN
            -- Type 1a: Actual move within personal tree
            PERFORM
                move_priority (_input.id, _parent_actual_path);
            _actual_path := NULL;
        ELSIF NOT _old_is_personal AND NOT _new_is_personal THEN
            -- Type 1b: Actual move within/between shared trees
            -- Notify users who lose access if the priority moves to a different shared tree
            PERFORM
                notify_displaced_priority_users (_input.id, _old_actual_path, _parent_actual_path);
            PERFORM
                move_priority (_input.id, _parent_actual_path);
            _actual_path := NULL;
        ELSIF NOT _old_is_personal
                AND _new_is_personal
                AND _within_aliased_tree THEN
                -- Type 3: Actual move within aliased tree (no displacement - same root)
                PERFORM
                    move_priority (_input.id, _parent_actual_path);
            _actual_path := NULL;
        ELSIF NOT _old_is_personal
                AND _new_is_personal THEN
                -- Type 4: Actual move from shared tree into personal tree
                -- (was Type 2: visual alias; now corrected to a real path move)
                PERFORM
                    notify_displaced_priority_users (_input.id, _old_actual_path, _parent_actual_path);
                PERFORM
                    move_priority (_input.id, _parent_actual_path);
                _actual_path := NULL;
                -- Clear any existing visual alias now that priority is in the personal tree
                UPDATE
                    priority_settings
                SET
                    path = NULL
                WHERE
                    user_id = upsert_priority.user_id
                    AND priority_id = _input.id;
        ELSIF _old_is_personal
                AND NOT _new_is_personal THEN
                RAISE EXCEPTION 'Cannot move personal priority into shared tree'
                USING HINT = 'Use Share dialog to share a personal priority';
        END IF;
    END IF;
    -- Translate visual path to actual path for new sub-priorities
    IF _is_move IS NOT TRUE AND NOT _priority_exists AND nlevel (_input.path) > 1 THEN
        _parent_visual_path := subpath (_input.path, 0, nlevel (_input.path) - 1);
        _label := text(subpath (_input.path, nlevel (_input.path) - 1, 1));
        SELECT
            global_path INTO _parent_actual_path
        FROM
            "user".priority
        WHERE
            user_id = upsert_priority.user_id
            AND path = _parent_visual_path
        LIMIT 1;
        IF _parent_actual_path IS NOT NULL THEN
            _actual_path := _parent_actual_path || _label::ltree;
        ELSE
            _actual_path := _input.path;
        END IF;
    ELSIF _is_move IS NOT TRUE THEN
        _actual_path := _input.path;
    END IF;
    -- Get the priority's default color for initializing new priority_settings
    SELECT
        color INTO _priority_default_color
    FROM
        priority
    WHERE
        id = _input.id;
    -- Update priority table
    IF _actual_path IS NOT NULL THEN
        INSERT INTO priority (id, archived_at, title, color, path, created_by, updated_by)
            VALUES (_input.id, _input.archived_at, _input.title, CASE WHEN _is_creator THEN
                    _input.color
                ELSE
                    NULL
                END, _actual_path, _input.created_by, _input.updated_by)
        ON CONFLICT (id)
            DO UPDATE SET
                archived_at = _input.archived_at,
                title = _input.title,
                color = CASE WHEN _is_creator THEN
                    _input.color
                ELSE
                    priority.color
                END,
                updated_by = _input.updated_by
            RETURNING
                id INTO _priority_id;
    ELSE
        -- For moves, just update non-path fields
        UPDATE
            priority
        SET
            archived_at = _input.archived_at,
            title = _input.title,
            color = CASE WHEN _is_creator THEN
                _input.color
            ELSE
                priority.color
            END,
            updated_by = _input.updated_by
        WHERE
            id = _input.id
        RETURNING
            id INTO _priority_id;
    END IF;
    -- Update priority_settings for user-specific fields
    IF _is_visual_move THEN
        -- Visual move: create/update path alias
        INSERT INTO priority_settings (user_id, priority_id, path, top_order, "order", pomodoro, color)
            VALUES (upsert_priority.user_id, _priority_id, _input.path, _input.top_order, _input.order, _input.pomodoro, COALESCE(_input.color, _priority_default_color))
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET
                path = _input.path,
                top_order = _input.top_order,
                "order" = _input.order,
                pomodoro = _input.pomodoro,
                color = _input.color;
    ELSIF NOT _is_move
            AND (_input."top_order" IS NOT NULL
                OR _input."order" IS NOT NULL
                OR _input."pomodoro" IS NOT NULL
                OR _input."color" IS NOT NULL) THEN
            INSERT INTO priority_settings (user_id, priority_id, path, top_order, "order", pomodoro, color)
                VALUES (upsert_priority.user_id, _priority_id, NULL, _input.top_order, _input.order, _input.pomodoro, COALESCE(_input.color, _priority_default_color))
            ON CONFLICT (user_id, priority_id)
                DO UPDATE SET
                    top_order = _input.top_order,
                    "order" = _input.order,
                    pomodoro = _input.pomodoro,
                    color = _input.color;
    END IF;
    -- Return the updated row from the view
    SELECT
        * INTO v_row
    FROM
        "user".priority up
    WHERE
        up.user_id = upsert_priority.user_id
        AND up.id = _input.id;
    RETURN v_row;
END;
$$;
