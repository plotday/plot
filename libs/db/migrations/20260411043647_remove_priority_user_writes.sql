-- Drop "priority_insert_trigger" trigger
DROP TRIGGER "priority_insert_trigger" ON "public"."priority";
-- Modify "activate_invited_user" function
CREATE OR REPLACE FUNCTION "public"."activate_invited_user" ("p_user_id" uuid) RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_root_priority_id uuid;
    v_new_path ltree;
BEGIN
    -- Already has a root priority?
    SELECT id INTO v_root_priority_id
    FROM public.priority
    WHERE user_id = p_user_id
      AND nlevel(path) = 1
    ORDER BY created_at ASC
    LIMIT 1;

    IF v_root_priority_id IS NOT NULL THEN
        RETURN jsonb_build_object('activated', FALSE, 'already_active', TRUE, 'root_priority_id', v_root_priority_id);
    END IF;

    -- Create the root priority. default_priority_user_id fills user_id
    -- from created_by, so the new row is fully owned by the user.
    v_new_path := generate_path(NULL);
    INSERT INTO public.priority (created_by, user_id, title, path, color)
        VALUES (p_user_id, p_user_id, 'Everything', v_new_path, 0)
    RETURNING id INTO v_root_priority_id;

    RETURN jsonb_build_object('activated', TRUE, 'already_active', FALSE, 'root_priority_id', v_root_priority_id);
END;
$$;
-- Modify "accept_invitations_on_signup" function
CREATE OR REPLACE FUNCTION "public"."accept_invitations_on_signup" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
BEGIN
    PERFORM public.activate_invited_user (NEW.id);
    RETURN NEW;
END;
$$;
-- Modify "match_priority_for_user" function
CREATE OR REPLACE FUNCTION "public"."match_priority_for_user" ("p_user_id" uuid, "query_embedding" text DEFAULT NULL::text, "p_thread_data" jsonb DEFAULT '{}', "p_required_filters" jsonb DEFAULT '{}', "p_scored_fields" jsonb DEFAULT '{}', "p_similarity_threshold" double precision DEFAULT 0.7) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    v_matched_priority_id uuid;
    v_root_priority_id uuid;
BEGIN
    -- 1. Try matching against the user's own filed threads.
    SELECT m.priority_id INTO v_matched_priority_id
    FROM public.find_matching_threads_scored(
        query_embedding,
        NULL,
        p_required_filters,
        p_scored_fields,
        p_thread_data,
        p_similarity_threshold,
        p_user_id
    ) m;

    IF v_matched_priority_id IS NOT NULL THEN
        RETURN v_matched_priority_id;
    END IF;

    -- 2. Fall back to the user's personal root priority.
    SELECT p.id INTO v_root_priority_id
    FROM public.priority p
    WHERE p.user_id = p_user_id
      AND nlevel(p.path) = 1
      AND p.archived_at IS NULL
    ORDER BY p.created_at ASC
    LIMIT 1;

    RETURN v_root_priority_id;
END;
$$;
-- Modify "assert_priority_access" function
CREATE OR REPLACE FUNCTION "user"."assert_priority_access" ("user_id" uuid, "priority_id" uuid) RETURNS void LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
BEGIN
    IF priority_id IS NULL THEN
        RAISE EXCEPTION 'priority_id must be provided';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM priority p
        WHERE p.id = assert_priority_access.priority_id
          AND p.user_id = assert_priority_access.user_id
          AND p.archived_at IS NULL
    ) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;
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
        -- Root priorities: visual-only move (per-user alias, no actual path change)
        IF _input.root THEN
            -- Get user's personal root path (own top-level priority)
            SELECT path INTO _user_personal_root_path
            FROM priority
            WHERE user_id = upsert_priority.user_id
              AND nlevel(path) = 1
              AND archived_at IS NULL
            ORDER BY created_at ASC
            LIMIT 1;
            -- Compute default visual path (team root as direct child of personal root)
            DECLARE
                _default_visual_path ltree;
            BEGIN
                _default_visual_path := _user_personal_root_path || subpath(_old_actual_path, 0, 1);
                IF _input.path = _default_visual_path THEN
                    -- Reset to default: remove any existing alias
                    DELETE FROM priority_setting
                    WHERE user_id = upsert_priority.user_id
                        AND priority_id = _input.id
                        AND key = 'path';
                ELSE
                    -- Create/update visual alias
                    INSERT INTO priority_setting (user_id, priority_id, key, value)
                    VALUES (upsert_priority.user_id, _input.id, 'path', to_jsonb(text(_input.path)))
                    ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
                END IF;
            END;
            -- Not an actual move — clear move flags so title/color/order updates still apply
            _is_move := FALSE;
            _actual_path := NULL;
        ELSE
        -- Get user's personal root path (own top-level priority)
        SELECT path INTO _user_personal_root_path
        FROM priority
        WHERE user_id = upsert_priority.user_id
          AND nlevel(path) = 1
          AND archived_at IS NULL
        ORDER BY created_at ASC
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
                priority_setting ps
                JOIN priority p ON ps.priority_id = p.id
            WHERE
                ps.user_id = upsert_priority.user_id
                AND ps.key = 'path'
                AND _input.path <@ (ps.value #>> '{}')::ltree
                AND _old.path <@ (ps.value #>> '{}')::ltree
                AND (ps.value #>> '{}')::ltree != p.path
                AND _old_actual_path <@ p.path
                AND _actual_path <@ p.path
            ORDER BY
                nlevel ((ps.value #>> '{}')::ltree) DESC
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
            -- Type 1b: Actual move within/between shared trees. In the
            -- per-user model this branch is dead — every priority is
            -- personal — but we keep the move call as a safety net.
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
                -- Type 4: Move from shared tree into personal tree. In the
                -- per-user model priorities are never shared, so this is
                -- always an actual move.
                PERFORM
                    move_priority (_input.id, _parent_actual_path);
                _actual_path := NULL;
                -- Clear any existing visual alias now that priority is in the personal tree
                DELETE FROM priority_setting
                WHERE user_id = upsert_priority.user_id AND priority_id = _input.id AND key = 'path';
        ELSIF _old_is_personal
                AND NOT _new_is_personal THEN
                RAISE EXCEPTION 'Cannot move personal priority into shared tree'
                USING HINT = 'Use Share dialog to share a personal priority';
        END IF;
        END IF; -- END root vs non-root branch
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
        INSERT INTO priority (id, user_id, archived_at, title, color, path, created_by, updated_by, inherit_members, team_id)
            VALUES (_input.id, upsert_priority.user_id, _input.archived_at, _input.title, CASE WHEN _is_creator THEN
                    _input.color
                ELSE
                    NULL
                END, _actual_path, _input.created_by, _input.updated_by, COALESCE(_input.inherit_members, TRUE),
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
                inherit_members = COALESCE(_input.inherit_members, priority.inherit_members),
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
            inherit_members = COALESCE(_input.inherit_members, priority.inherit_members),
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
    -- Update priority_setting for user-specific fields
    IF _is_visual_move THEN
        -- Visual move: create/update path alias
        INSERT INTO priority_setting (user_id, priority_id, key, value)
        VALUES (upsert_priority.user_id, _priority_id, 'path', to_jsonb(text(_input.path)))
        ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
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
-- Drop "insert_priority_user" function
DROP FUNCTION "public"."insert_priority_user";
