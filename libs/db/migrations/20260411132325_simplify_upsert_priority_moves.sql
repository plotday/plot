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
    _priority_exists boolean;
    _old_actual_path ltree;
    _old_team_id bigint;
    _new_team_id bigint;
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
    -- Viewer enforcement: viewers cannot create new priorities
    -- For existing priorities, allow through (only priority_settings changes like reordering)
    IF NOT _priority_exists AND nlevel(_input.path) > 1 THEN
        DECLARE
            _parent_priority_id uuid;
            _parent_path ltree;
        BEGIN
            _parent_path := subpath(_input.path, 0, nlevel(_input.path) - 1);
            SELECT up.id INTO _parent_priority_id
            FROM "user".priority up
            WHERE up.user_id = upsert_priority.user_id AND up.path = _parent_path
            LIMIT 1;
            IF _parent_priority_id IS NOT NULL AND "user".get_effective_role(upsert_priority.user_id, _parent_priority_id) = 'viewer' THEN
                RAISE EXCEPTION 'Viewer members cannot create priorities';
            END IF;
        END;
    END IF;
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
    -- If the visual path hasn't changed, this is not a move.
    -- The visual-to-actual path resolution can produce false positives for shared
    -- root priorities (where visual path includes personal root prefix or alias).
    IF _is_move AND _old IS NOT NULL AND _input.path IS NOT DISTINCT FROM _old.path THEN
        _is_move := FALSE;
        _actual_path := _old_actual_path;
    END IF;
    IF _is_move THEN
        -- Prevent circular reference
        IF _actual_path <@ _old_actual_path OR _actual_path = _old_actual_path THEN
            RAISE EXCEPTION 'Cannot move priority to be a descendant of itself'
                USING HINT = 'old_path=' || _old_actual_path::text || ', new_path=' || _actual_path::text;
        END IF;
        -- In the per-user model every priority belongs to a single user's
        -- tree, so every actual move is a straight ltree relocation. The
        -- old shared-tree / aliased-tree / visual-alias branches are dead.
        PERFORM move_priority (_input.id, _parent_actual_path);
        _actual_path := NULL;
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
        INSERT INTO priority (id, user_id, archived_at, title, color, path, created_by, updated_by, team_id)
            VALUES (_input.id, upsert_priority.user_id, _input.archived_at, _input.title, CASE WHEN _is_creator THEN
                    _input.color
                ELSE
                    NULL
                END, _actual_path, _input.created_by, _input.updated_by,
                CASE WHEN _is_creator THEN _input.team_id ELSE NULL END)
        ON CONFLICT (id)
            DO UPDATE SET
                archived_at = _input.archived_at,
                title = _input.title,
                color = CASE WHEN _is_creator THEN
                    _input.color
                ELSE
                    priority.color
                END,
                updated_by = _input.updated_by,
                team_id = CASE WHEN _is_creator THEN _input.team_id ELSE priority.team_id END
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
            updated_by = _input.updated_by,
            team_id = CASE WHEN _is_creator THEN _input.team_id ELSE priority.team_id END
        WHERE
            id = _input.id
        RETURNING
            id INTO _priority_id;
    END IF;
    -- Handle team_id changes: authorization, promote-to-root, and descendant propagation
    IF _is_creator THEN
        SELECT team_id INTO _old_team_id FROM priority WHERE id = _priority_id;
        _new_team_id := _input.team_id;
        -- Only act when team_id actually changed
        IF _old_team_id IS DISTINCT FROM _new_team_id THEN
            -- Removing from team: require admin role
            IF _old_team_id IS NOT NULL AND (_new_team_id IS NULL OR _new_team_id != _old_team_id) THEN
                IF NOT EXISTS (
                    SELECT 1 FROM team_user
                    WHERE team_id = _old_team_id
                    AND user_id = upsert_priority.user_id
                    AND role = 'admin'
                ) THEN
                    RAISE EXCEPTION 'Only team admins can remove a priority from the team';
                END IF;
            END IF;
            -- Setting team: require membership
            IF _new_team_id IS NOT NULL THEN
                IF NOT EXISTS (
                    SELECT 1 FROM team_user
                    WHERE team_id = _new_team_id
                    AND user_id = upsert_priority.user_id
                ) THEN
                    RAISE EXCEPTION 'Must be a member of the team';
                END IF;
            END IF;
            -- Auto-promote to root: if setting team_id on a non-root priority, move it to root level
            IF _new_team_id IS NOT NULL THEN
                DECLARE
                    _current_path ltree;
                    _new_root_path ltree;
                    _priority_label text;
                BEGIN
                    SELECT path INTO _current_path FROM priority WHERE id = _priority_id;
                    IF nlevel(_current_path) > 1 THEN
                        -- Generate a random root-level path (12 chars, ltree-safe)
                        _new_root_path := text2ltree(
                            substring(md5(random()::text || clock_timestamp()::text) from 1 for 12)
                        );
                        -- Move the priority and all descendants to the new root path
                        UPDATE priority
                        SET path = CASE
                            WHEN id = _priority_id THEN _new_root_path
                            ELSE _new_root_path || subpath(path, nlevel(_current_path))
                        END
                        WHERE path <@ _current_path;
                        -- No priority_user write needed — priority.user_id
                        -- already encodes ownership.
                    END IF;
                END;
            END IF;
            -- Propagate team_id to all descendants
            UPDATE priority
            SET team_id = _new_team_id
            WHERE path <@ (SELECT path FROM priority WHERE id = _priority_id)
            AND id != _priority_id;
        END IF;
    END IF;
    -- Always upsert top_order, order, pomodoro, color if provided
    IF NOT _is_move THEN
        IF _input.top_order IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (upsert_priority.user_id, _priority_id, 'top_order', to_jsonb(_input.top_order))
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE user_id = upsert_priority.user_id AND priority_id = _priority_id AND key = 'top_order';
        END IF;
        IF _input."order" IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (upsert_priority.user_id, _priority_id, 'order', to_jsonb(_input."order"))
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        END IF;
        IF _input.pomodoro IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (upsert_priority.user_id, _priority_id, 'pomodoro', to_jsonb(_input.pomodoro))
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE user_id = upsert_priority.user_id AND priority_id = _priority_id AND key = 'pomodoro';
        END IF;
        IF _input.color IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (upsert_priority.user_id, _priority_id, 'color', to_jsonb(COALESCE(_input.color, _priority_default_color)))
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        END IF;
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
-- Drop "notify_displaced_priority_users" function
DROP FUNCTION "public"."notify_displaced_priority_users";
