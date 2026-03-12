-- Modify "setup_help_feedback_priority" function
CREATE OR REPLACE FUNCTION "public"."setup_help_feedback_priority" ("p_user_name" text DEFAULT NULL::text, "p_user_id" uuid DEFAULT NULL::uuid) RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_user_id uuid;
    v_user_email text;
    v_user_name text;
    v_global_priority_id uuid;
    v_global_priority_path ltree;
    v_user_priority_id uuid;
    v_user_priority_path ltree;
    v_plot_priority_id uuid;
    v_plot_priority_path ltree;
    v_override_path ltree;
    v_user_root_path ltree;
    v_user_root_path_part text;
BEGIN
    -- Get user ID from parameter or auth context
    v_user_id := p_user_id;
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'User not authenticated';
    END IF;
    -- Get user's email and name from public."user"
    SELECT
        email,
        name INTO v_user_email,
        v_user_name
    FROM
        public."user"
    WHERE
        id = v_user_id;
    -- Use provided name, or fall back to user metadata, or email
    v_user_name := COALESCE(p_user_name, v_user_name, v_user_email, 'User Feedback');
    -- Step 1: Get or create global Help & Feedback priority
    SELECT
        id,
        path INTO v_global_priority_id,
        v_global_priority_path
    FROM
        priority
    WHERE
        key = '@help-feedback'
    LIMIT 1;
    IF v_global_priority_id IS NULL THEN
        -- Create global priority
        -- The insert_priority_user trigger will not create a personal entry for priorities with keys like '@help-feedback'
        v_global_priority_path := generate_path (NULL);
        INSERT INTO priority (created_by, title, path, color, key)
            VALUES (v_user_id, 'Help & Feedback', v_global_priority_path, 0, '@help-feedback')
        RETURNING
            id INTO v_global_priority_id;
    END IF;
    -- Step 2: Get user's root priority path for finding their @plot priority
    SELECT
        p.path INTO v_user_root_path
    FROM
        priority_user pu
        JOIN priority p ON pu.priority_id = p.id
    WHERE
        pu.user_id = v_user_id
        AND pu.personal = TRUE
    LIMIT 1;
    IF v_user_root_path IS NULL THEN
        RAISE EXCEPTION 'User has no root priority';
    END IF;
    -- Extract root path part for filtering
    v_user_root_path_part := split_part(v_user_root_path::text, '.', 1);
    -- Step 3: Find user's @plot priority for path override
    SELECT
        id,
        path INTO v_plot_priority_id,
        v_plot_priority_path
    FROM
        priority
    WHERE
        key = '@plot'
        AND path::text LIKE v_user_root_path_part || '%'
    LIMIT 1;
    -- Step 4: Check if user's Help & Feedback priority already exists
    SELECT
        id INTO v_user_priority_id
    FROM
        priority
    WHERE
        key = '@help-feedback-' || v_user_id::text
        AND path <@ v_global_priority_path
    LIMIT 1;
    IF v_user_priority_id IS NULL THEN
        -- Create user's child priority
        v_user_priority_path := generate_path (v_global_priority_path);
        INSERT INTO priority (created_by, title, path, color, key)
            VALUES (v_user_id, v_user_name, v_user_priority_path, 0, '@help-feedback-' || v_user_id::text)
        RETURNING
            id INTO v_user_priority_id;
        -- Create priority_user entry to give user access
        INSERT INTO priority_user (user_id, priority_id, personal)
            VALUES (v_user_id, v_user_priority_id, FALSE)
        ON CONFLICT (user_id, priority_id)
            DO NOTHING;
    END IF;
    -- Step 5: Create/update priority_settings for path and title override
    IF v_plot_priority_id IS NOT NULL THEN
        -- Generate override path under user's @plot priority
        v_override_path := generate_path (v_plot_priority_path);
        -- Upsert priority_setting
        INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (v_user_id, v_user_priority_id, 'path', to_jsonb(ltree2text(v_override_path)))
        ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (v_user_id, v_user_priority_id, 'title', to_jsonb('Help & Feedback'::text))
        ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
    END IF;
    -- Return success with created IDs
    RETURN jsonb_build_object('success', TRUE, 'global_priority_id', v_global_priority_id, 'user_priority_id', v_user_priority_id, 'has_plot_override', v_plot_priority_id IS NOT NULL);
END;
$$;
-- Create "priority_setting" table
CREATE TABLE "public"."priority_setting" (
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  "user_id" uuid NOT NULL,
  "priority_id" uuid NOT NULL,
  "key" text NOT NULL,
  "value" jsonb NOT NULL,
  PRIMARY KEY ("user_id", "priority_id", "key"),
  CONSTRAINT "priority_setting_priority_id_fkey" FOREIGN KEY ("priority_id") REFERENCES "public"."priority" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "priority_setting_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Create trigger "set_priority_setting_updated_at"
CREATE TRIGGER "set_priority_setting_updated_at" BEFORE INSERT OR UPDATE ON "public"."priority_setting" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Modify "activate_invited_user" function
CREATE OR REPLACE FUNCTION "public"."activate_invited_user" ("p_user_id" uuid) RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_root_priority_id uuid;
    v_root_priority_path ltree;
    v_new_path ltree;
BEGIN
    -- Check if root priority already exists
    SELECT
        priority_id INTO v_root_priority_id
    FROM
        public.priority_user
    WHERE
        user_id = p_user_id
        AND personal = TRUE
    LIMIT 1;
    IF v_root_priority_id IS NOT NULL THEN
        -- Root priority already exists
        RETURN jsonb_build_object('activated', FALSE, 'already_active', TRUE, 'root_priority_id', v_root_priority_id);
    END IF;
    -- Create root priority
    -- Generate path
    v_new_path := generate_path (NULL);
    -- Insert priority
    INSERT INTO public.priority (created_by, title, path, color)
        VALUES (p_user_id, 'Everything', v_new_path, 0)
    RETURNING
        id, path INTO v_root_priority_id, v_root_priority_path;
    -- Mark the priority_user entry as personal (root)
    -- The insert_priority_user trigger already created a priority_user entry
    UPDATE
        public.priority_user
    SET
        personal = TRUE
    WHERE
        user_id = p_user_id
        AND priority_id = v_root_priority_id;
    RETURN jsonb_build_object('activated', TRUE, 'already_active', FALSE, 'root_priority_id', v_root_priority_id);
END;
$$;
-- Modify "setup_whats_new_priority" function
CREATE OR REPLACE FUNCTION "public"."setup_whats_new_priority" ("p_user_id" uuid) RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_priority_id uuid;
    v_priority_path ltree;
    v_contact_id uuid;
    v_plot_priority_path ltree;
    v_user_root_path ltree;
    v_override_path ltree;
    v_user_root_path_part text;
BEGIN
    -- Get or create @whats-new priority
    SELECT
        id, path INTO v_priority_id, v_priority_path
    FROM
        priority
    WHERE
        key = '@whats-new'
    LIMIT 1;

    IF v_priority_id IS NULL THEN
        v_priority_path := generate_path (NULL);
        INSERT INTO priority (created_by, title, path, color, key, updated_by)
            VALUES (p_user_id, 'What''s New', v_priority_path, 7, '@whats-new', 0)
        RETURNING
            id INTO v_priority_id;
        -- The insert_priority_user trigger won't fire for @whats-new since it starts with @
        -- and isn't @plot, but clean up any personal entry just in case
        DELETE FROM priority_user
        WHERE user_id = p_user_id
            AND priority_id = v_priority_id
            AND personal = TRUE;
    END IF;

    -- Get user's contact_id
    SELECT
        id INTO v_contact_id
    FROM
        contact
    WHERE
        user_id = p_user_id
        AND "primary" = TRUE
    LIMIT 1;

    -- Add priority_contact (idempotent)
    IF v_contact_id IS NOT NULL THEN
        INSERT INTO priority_contact (priority_id, contact_id)
            VALUES (v_priority_id, v_contact_id)
        ON CONFLICT (priority_id, contact_id)
            DO NOTHING;
    END IF;

    -- Add priority_user with viewer role (idempotent - don't overwrite existing role)
    INSERT INTO priority_user (user_id, priority_id, personal, role)
        VALUES (p_user_id, v_priority_id, FALSE, 'viewer')
    ON CONFLICT (user_id, priority_id)
        DO NOTHING;

    -- Position under @plot via priority_settings
    SELECT
        p.path INTO v_user_root_path
    FROM
        priority_user pu
        JOIN priority p ON pu.priority_id = p.id
    WHERE
        pu.user_id = p_user_id
        AND pu.personal = TRUE
    LIMIT 1;

    IF v_user_root_path IS NOT NULL THEN
        v_user_root_path_part := split_part(v_user_root_path::text, '.', 1);
        SELECT
            p.path INTO v_plot_priority_path
        FROM
            priority p
        WHERE
            key = '@plot'
            AND p.path::text LIKE v_user_root_path_part || '%'
        LIMIT 1;

        IF v_plot_priority_path IS NOT NULL THEN
            v_override_path := generate_path (v_plot_priority_path);
            INSERT INTO priority_setting (user_id, priority_id, key, value)
                VALUES (p_user_id, v_priority_id, 'path', to_jsonb(ltree2text(v_override_path)))
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
            INSERT INTO priority_setting (user_id, priority_id, key, value)
                VALUES (p_user_id, v_priority_id, 'title', to_jsonb('What''s New'::text))
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        END IF;
    END IF;

    RETURN jsonb_build_object('success', TRUE, 'priority_id', v_priority_id);
END;
$$;
-- Modify "share_priority" function
CREATE OR REPLACE FUNCTION "public"."share_priority" ("p_user_id" uuid, "p_priority_id" uuid, "p_add_actor_ids" uuid[], "p_remove_actor_ids" uuid[], "p_role" text DEFAULT 'member') RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_priority record;
    v_root_priority_id uuid;
    v_is_under_personal boolean := FALSE;
    v_old_path ltree;
    v_new_path ltree;
    v_extracted boolean := FALSE;
    v_actor_id uuid;
    v_contact record;
    v_priority_label text;
    v_recipient_org_root record;
BEGIN
    -- Validate user has access to the priority
    IF NOT public.user_has_priority_access (p_user_id, p_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;
    -- Get priority details
    SELECT
        * INTO v_priority
    FROM
        public.priority
    WHERE
        id = p_priority_id;
    IF v_priority IS NULL THEN
        RAISE EXCEPTION 'Priority not found';
    END IF;
    v_old_path := v_priority.path;
    -- Check if extraction is needed:
    -- 1. Priority is NOT at top level (nlevel > 1)
    -- 2. Top-level priority is user's personal root
    IF nlevel (v_priority.path) > 1 THEN
        -- Get the root priority ID
        SELECT
            p.id INTO v_root_priority_id
        FROM
            public.priority p
        WHERE
            p.path = subltree (v_priority.path, 0, 1);
        -- Check if root is user's personal priority or an org root
        IF v_root_priority_id IS NOT NULL THEN
            SELECT
                EXISTS (
                    SELECT
                        1
                    FROM
                        public.priority_user pu
                        JOIN public.priority rp ON rp.id = pu.priority_id
                    WHERE
                        pu.priority_id = v_root_priority_id
                        AND pu.user_id = p_user_id
                        AND (pu.personal = TRUE OR rp.organization_id IS NOT NULL)
                        AND pu.archived_at IS NULL) INTO v_is_under_personal;
        END IF;
    END IF;
    -- Perform extraction if needed
    IF v_is_under_personal THEN
        -- Generate new top-level path
        v_new_path := public.generate_path (NULL);
        -- Update priority and all descendants
        -- Extract the last label from the current path (the priority's own identifier)
        v_priority_label := ltree2text (subpath (v_old_path, -1));
        -- The new root path is the generated path for the priority itself
        -- For descendants, append their relative path from the old location
        UPDATE
            public.priority
        SET
            path = CASE WHEN path = v_old_path THEN
                v_new_path
            ELSE
                -- For descendants, replace the old path prefix with the new path
                text2ltree (ltree2text (v_new_path) || ltree2text (subpath (path, nlevel (v_old_path))))
            END
        WHERE
            path <@ v_old_path
            OR path = v_old_path;
        -- Create priority_setting with old path to preserve visual location
        INSERT INTO public.priority_setting (user_id, priority_id, key, value)
            VALUES (p_user_id, p_priority_id, 'path', to_jsonb(ltree2text(v_old_path)))
        ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        -- Create priority_user for current user (non-personal) for the extracted priority
        INSERT INTO public.priority_user (user_id, priority_id, personal)
            VALUES (p_user_id, p_priority_id, FALSE)
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET
                archived_at = NULL;
        v_extracted := TRUE;
    END IF;
    -- Ensure the sharer's own contact is in priority_contact
    INSERT INTO priority_contact (priority_id, contact_id)
    SELECT p_priority_id, c.id
    FROM contact c
    WHERE c.user_id = p_user_id AND c."primary" = TRUE AND c.archived_at IS NULL
    ON CONFLICT (priority_id, contact_id) DO NOTHING;
    -- Process additions
    IF p_add_actor_ids IS NOT NULL THEN
        FOREACH v_actor_id IN ARRAY p_add_actor_ids LOOP
            -- Get contact info to check if user_id is set
            SELECT
                * INTO v_contact
            FROM
                public.contact
            WHERE
                id = v_actor_id
                AND archived_at IS NULL;
            IF v_contact IS NULL THEN
                -- Skip invalid actor_ids
                CONTINUE;
            END IF;
            -- Create priority_contact for all contacts (both users and non-users)
            INSERT INTO public.priority_contact (priority_id, contact_id, invited_by, invited_at)
                VALUES (p_priority_id, v_actor_id, p_user_id, now())
            ON CONFLICT (priority_id, contact_id)
                DO UPDATE SET
                    invited_at = now(),
                    invited_by = COALESCE(priority_contact.invited_by, EXCLUDED.invited_by);
            -- Reset invitation sent_at if this is a re-invitation after full removal
            -- Only reset if the contact has no other active priority invitations
            WITH other_invitations AS (
                SELECT COUNT(*) as count
                FROM public.priority_contact
                WHERE contact_id = v_actor_id
                  AND invited_at IS NOT NULL
                  AND priority_id != p_priority_id
            )
            UPDATE public.contact_invitation
            SET sent_at = now()
            WHERE contact_id = v_actor_id
              AND (SELECT count FROM other_invitations) = 0;
            IF v_contact.user_id IS NOT NULL THEN
                -- Contact is an existing user - also create priority_user
                INSERT INTO public.priority_user (user_id, priority_id, personal, role)
                    VALUES (v_contact.user_id, p_priority_id, FALSE, p_role)
                ON CONFLICT (user_id, priority_id)
                    DO UPDATE SET
                        archived_at = NULL;
                -- If this is an org priority and recipient is an org member,
                -- create priority_settings to map it under their org root
                IF v_priority.organization_id IS NOT NULL THEN
                    SELECT
                        p.id, p.path INTO v_recipient_org_root
                    FROM
                        public.priority p
                        JOIN public.priority_user pu ON pu.priority_id = p.id
                    WHERE
                        p.organization_id = v_priority.organization_id
                        AND pu.user_id = v_contact.user_id
                        AND pu.archived_at IS NULL
                        AND nlevel (p.path) = 1;
                    IF v_recipient_org_root IS NOT NULL THEN
                        -- Map shared priority visually under recipient's org root
                        INSERT INTO public.priority_setting (user_id, priority_id, key, value)
                            VALUES (v_contact.user_id, p_priority_id, 'path', to_jsonb(ltree2text(text2ltree(ltree2text(v_recipient_org_root.path) || '.' || ltree2text(subpath((SELECT path FROM public.priority WHERE id = p_priority_id), -1))))))
                        ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
                    END IF;
                END IF;
            END IF;
        END LOOP;
    END IF;
    -- Process removals
    IF p_remove_actor_ids IS NOT NULL THEN
        FOREACH v_actor_id IN ARRAY p_remove_actor_ids LOOP
            -- Get contact info
            SELECT
                * INTO v_contact
            FROM
                public.contact
            WHERE
                id = v_actor_id;
            IF v_contact IS NULL THEN
                -- Skip invalid actor_ids
                CONTINUE;
            END IF;
            -- Cancel invitation for priority_contact (set invited_at to NULL)
            UPDATE
                public.priority_contact
            SET
                invited_at = NULL
            WHERE
                contact_id = v_actor_id
                AND priority_id = p_priority_id
                AND invited_at IS NOT NULL;
            IF v_contact.user_id IS NOT NULL THEN
                -- Archive priority_user for users
                UPDATE
                    public.priority_user
                SET
                    archived_at = now()
                WHERE
                    user_id = v_contact.user_id
                    AND priority_id = p_priority_id
                    AND archived_at IS NULL;
            END IF;
        END LOOP;
    END IF;
    -- Return result
    RETURN jsonb_build_object('id', p_priority_id, 'extracted', v_extracted, 'oldPath', CASE WHEN v_extracted THEN
            ltree2text (v_old_path)
        ELSE
            NULL
        END, 'newPath', CASE WHEN v_extracted THEN
            ltree2text (v_new_path)
        ELSE
            ltree2text (v_old_path)
        END);
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
                DELETE FROM priority_setting
                WHERE user_id = upsert_priority.user_id AND priority_id = _input.id AND key = 'path';
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
-- Create "upsert_priority_response_time" function
CREATE FUNCTION "user"."upsert_priority_response_time" ("user_id" uuid, "p_priority_id" uuid, "p_response_window" jsonb DEFAULT NULL::jsonb, "p_turnaround" jsonb DEFAULT NULL::jsonb, "p_set_response_window" boolean DEFAULT false, "p_set_turnaround" boolean DEFAULT false) RETURNS void LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
BEGIN
    PERFORM "user".assert_priority_access(
        upsert_priority_response_time.user_id, p_priority_id);
    IF p_set_response_window THEN
        IF p_response_window IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (upsert_priority_response_time.user_id, p_priority_id, 'response_window', p_response_window)
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE user_id = upsert_priority_response_time.user_id
              AND priority_id = p_priority_id AND key = 'response_window';
        END IF;
    END IF;
    IF p_set_turnaround THEN
        IF p_turnaround IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (upsert_priority_response_time.user_id, p_priority_id, 'turnaround', p_turnaround)
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE user_id = upsert_priority_response_time.user_id
              AND priority_id = p_priority_id AND key = 'turnaround';
        END IF;
    END IF;
END;
$$;
-- Create "priority_setting_inherited" view
CREATE VIEW "public"."priority_setting_inherited" (
  "user_id",
  "priority_id",
  "key",
  "value",
  "source_path"
) AS WITH all_sources AS (
         SELECT ps.user_id,
            p.id AS priority_id,
            ps.key,
            ps.value,
            parent.path AS source_path,
            public.nlevel(p.path) - public.nlevel(parent.path) AS distance,
            0 AS source_type
           FROM public.priority_setting ps
             JOIN public.priority parent ON ps.priority_id = parent.id
             JOIN public.priority p ON p.path OPERATOR(public.<@) parent.path
          WHERE ps.key = ANY (ARRAY['pomodoro'::text, 'color'::text, 'path'::text, 'response_window'::text, 'turnaround'::text])
        UNION ALL
         SELECT pu.user_id,
            p.id AS priority_id,
            'color'::text AS key,
            to_jsonb(parent.color) AS value,
            parent.path AS source_path,
            public.nlevel(p.path) - public.nlevel(parent.path) AS distance,
            1 AS source_type
           FROM public.priority_user pu
             JOIN public.priority root ON pu.priority_id = root.id
             JOIN public.priority p ON p.path OPERATOR(public.<@) root.path
             JOIN public.priority parent ON p.path OPERATOR(public.<@) parent.path
          WHERE parent.color IS NOT NULL
        )
 SELECT DISTINCT ON (user_id, priority_id, key) user_id,
    priority_id,
    key,
    value,
    source_path
   FROM all_sources
  ORDER BY user_id, priority_id, key, distance, source_type;
-- Modify "priority" view
CREATE OR REPLACE VIEW "user"."priority" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "archived_at",
  "created_by",
  "updated_by",
  "root",
  "personal",
  "title",
  "path",
  "global_path",
  "top_order",
  "order",
  "pomodoro",
  "color",
  "key",
  "organization_id",
  "unread",
  "role",
  "response_window",
  "turnaround",
  "response_window_set",
  "turnaround_set"
) AS SELECT pu.user_id,
    p.id,
    p.created_at,
    GREATEST(settings.updated_at, pu.updated_at, p.updated_at, COALESCE(upu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    GREATEST(pu.archived_at, p.archived_at) AS archived_at,
    p.created_by,
    p.updated_by,
    (pu.personal = true OR p.organization_id IS NOT NULL) AND p.id = root.id AS root,
    user_root.path OPERATOR(public.@>) p.path AS personal,
    COALESCE(settings.title, p.title) AS title,
        CASE
            WHEN inherited.path_value IS NOT NULL THEN
            CASE
                WHEN inherited.path_source IS NOT NULL AND p.path OPERATOR(public.<>) inherited.path_source::public.ltree AND public.subpath(p.path, public.nlevel(inherited.path_source::public.ltree)) OPERATOR(public.<>) ''::public.ltree THEN inherited.path_value::public.ltree OPERATOR(public.||) public.subpath(p.path, public.nlevel(inherited.path_source::public.ltree))
                ELSE inherited.path_value::public.ltree
            END
            WHEN user_root.path OPERATOR(public.@>) p.path THEN p.path
            ELSE user_root.path OPERATOR(public.||) p.path
        END AS path,
    p.path AS global_path,
    settings.top_order,
    COALESCE(settings."order", (EXTRACT(epoch FROM p.created_at) * 1000::numeric)::double precision) AS "order",
    inherited.pomodoro,
    inherited.color,
    p.key,
    p.organization_id,
    COALESCE(upu.unread, false) AS unread,
    "user".get_effective_role(pu.user_id, p.id) AS role,
    inherited.response_window,
    inherited.turnaround,
    COALESCE(settings.response_window_set, false) AS response_window_set,
    COALESCE(settings.turnaround_set, false) AS turnaround_set
   FROM public.priority_user pu
     JOIN public.priority root ON pu.priority_id = root.id
     JOIN public.priority_user pu_root ON pu.user_id = pu_root.user_id AND pu_root.personal = true
     JOIN public.priority user_root ON pu_root.priority_id = user_root.id
     JOIN public.priority p ON root.path OPERATOR(public.@>) p.path
     LEFT JOIN ( SELECT priority_setting.user_id,
            priority_setting.priority_id,
            max(
                CASE
                    WHEN priority_setting.key = 'top_order'::text THEN (priority_setting.value #>> '{}'::text[])::double precision
                    ELSE NULL::double precision
                END) AS top_order,
            max(
                CASE
                    WHEN priority_setting.key = 'order'::text THEN (priority_setting.value #>> '{}'::text[])::double precision
                    ELSE NULL::double precision
                END) AS "order",
            max(
                CASE
                    WHEN priority_setting.key = 'title'::text THEN priority_setting.value #>> '{}'::text[]
                    ELSE NULL::text
                END) AS title,
            max(
                CASE
                    WHEN priority_setting.key = 'response_window'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS response_window_set,
            max(
                CASE
                    WHEN priority_setting.key = 'turnaround'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS turnaround_set,
            max(priority_setting.updated_at) AS updated_at
           FROM public.priority_setting
          GROUP BY priority_setting.user_id, priority_setting.priority_id) settings ON settings.user_id = pu.user_id AND settings.priority_id = p.id
     LEFT JOIN ( SELECT priority_setting_inherited.user_id,
            priority_setting_inherited.priority_id,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'pomodoro'::text THEN (priority_setting_inherited.value #>> '{}'::text[])::integer
                    ELSE NULL::integer
                END) AS pomodoro,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'color'::text THEN (priority_setting_inherited.value #>> '{}'::text[])::integer
                    ELSE NULL::integer
                END) AS color,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'response_window'::text THEN priority_setting_inherited.value::text
                    ELSE NULL::text
                END)::jsonb AS response_window,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'turnaround'::text THEN priority_setting_inherited.value::text
                    ELSE NULL::text
                END)::jsonb AS turnaround,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'path'::text THEN priority_setting_inherited.value #>> '{}'::text[]
                    ELSE NULL::text
                END) AS path_value,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'path'::text THEN priority_setting_inherited.source_path::text
                    ELSE NULL::text
                END) AS path_source
           FROM public.priority_setting_inherited
          GROUP BY priority_setting_inherited.user_id, priority_setting_inherited.priority_id) inherited ON inherited.user_id = pu.user_id AND inherited.priority_id = p.id
     LEFT JOIN "user".priority_unread upu ON upu.user_id = pu.user_id AND upu.priority_id = p.id
  WHERE pu.archived_at IS NULL;
-- Modify "priority_expanded" view
CREATE OR REPLACE VIEW "user"."priority_expanded" (
  "user_id",
  "priority_id",
  "joined_at",
  "archived_at",
  "role",
  "path"
) AS WITH base AS (
         SELECT pu.user_id,
            c.child_id AS priority_id,
            min(pu.created_at) AS joined_at,
            LEAST(min(pu.archived_at), min(c.archived_at)) AS archived_at,
                CASE
                    WHEN bool_or(pu.role = 'member'::text) THEN 'member'::text
                    ELSE 'viewer'::text
                END AS role
           FROM public.priority_user pu
             JOIN public.priority_child c ON pu.priority_id = c.priority_id
          GROUP BY pu.user_id, c.child_id
        )
 SELECT b.user_id,
    b.priority_id,
    b.joined_at,
    b.archived_at,
    b.role,
        CASE
            WHEN inherited.path_value IS NOT NULL THEN
            CASE
                WHEN inherited.path_source IS NOT NULL AND p.path OPERATOR(public.<>) inherited.path_source::public.ltree AND public.subpath(p.path, public.nlevel(inherited.path_source::public.ltree)) OPERATOR(public.<>) ''::public.ltree THEN inherited.path_value::public.ltree OPERATOR(public.||) public.subpath(p.path, public.nlevel(inherited.path_source::public.ltree))
                ELSE inherited.path_value::public.ltree
            END
            WHEN user_root.path OPERATOR(public.@>) p.path THEN p.path
            ELSE user_root.path OPERATOR(public.||) p.path
        END AS path
   FROM base b
     LEFT JOIN public.priority p ON p.id = b.priority_id
     LEFT JOIN public.priority_user pu_root ON b.user_id = pu_root.user_id AND pu_root.personal = true
     LEFT JOIN public.priority user_root ON pu_root.priority_id = user_root.id
     LEFT JOIN ( SELECT priority_setting_inherited.user_id,
            priority_setting_inherited.priority_id,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'path'::text THEN priority_setting_inherited.value #>> '{}'::text[]
                    ELSE NULL::text
                END) AS path_value,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'path'::text THEN priority_setting_inherited.source_path::text
                    ELSE NULL::text
                END) AS path_source
           FROM public.priority_setting_inherited
          GROUP BY priority_setting_inherited.user_id, priority_setting_inherited.priority_id) inherited ON inherited.user_id = b.user_id AND inherited.priority_id = b.priority_id;
-- Migrate existing data from priority_settings to priority_setting
INSERT INTO "public"."priority_setting" (user_id, priority_id, key, value, updated_at)
SELECT user_id, priority_id, 'top_order', to_jsonb(top_order), updated_at
FROM "public"."priority_settings" WHERE top_order IS NOT NULL
UNION ALL
SELECT user_id, priority_id, 'order', to_jsonb("order"), updated_at
FROM "public"."priority_settings" WHERE "order" IS NOT NULL
UNION ALL
SELECT user_id, priority_id, 'path', to_jsonb(text(path)), updated_at
FROM "public"."priority_settings" WHERE path IS NOT NULL
UNION ALL
SELECT user_id, priority_id, 'pomodoro', to_jsonb(pomodoro), updated_at
FROM "public"."priority_settings" WHERE pomodoro IS NOT NULL
UNION ALL
SELECT user_id, priority_id, 'color', to_jsonb(color), updated_at
FROM "public"."priority_settings" WHERE color IS NOT NULL
UNION ALL
SELECT user_id, priority_id, 'title', to_jsonb(title), updated_at
FROM "public"."priority_settings" WHERE title IS NOT NULL
ON CONFLICT (user_id, priority_id, key) DO NOTHING;
-- Drop "priority_settings_inherited" view
DROP VIEW "public"."priority_settings_inherited";
-- Drop "priority_settings" table
DROP TABLE "public"."priority_settings";
