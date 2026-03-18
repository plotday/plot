-- Rename existing @whats-new and @help-feedback keys to @plot.* prefix
UPDATE priority SET key = '@plot.whats-new' WHERE key = '@whats-new';
UPDATE priority SET key = '@plot.help-feedback' WHERE key = '@help-feedback';
UPDATE priority SET key = '@plot.help-feedback-' || substring(key FROM '@help-feedback-(.+)$') WHERE key LIKE '@help-feedback-%';
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
        key = '@plot.help-feedback'
    LIMIT 1;
    IF v_global_priority_id IS NULL THEN
        -- Create global priority
        -- The insert_priority_user trigger will not create a personal entry for priorities with keys like '@plot.help-feedback'
        v_global_priority_path := generate_path (NULL);
        INSERT INTO priority (created_by, title, path, color, key)
            VALUES (v_user_id, 'Help & Feedback', v_global_priority_path, 0, '@plot.help-feedback')
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
        key = '@plot.help-feedback-' || v_user_id::text
        AND path <@ v_global_priority_path
    LIMIT 1;
    IF v_user_priority_id IS NULL THEN
        -- Create user's child priority
        v_user_priority_path := generate_path (v_global_priority_path);
        INSERT INTO priority (created_by, title, path, color, key)
            VALUES (v_user_id, v_user_name, v_user_priority_path, 0, '@plot.help-feedback-' || v_user_id::text)
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
    -- Get or create @plot.whats-new priority
    SELECT
        id, path INTO v_priority_id, v_priority_path
    FROM
        priority
    WHERE
        key = '@plot.whats-new'
    LIMIT 1;

    IF v_priority_id IS NULL THEN
        v_priority_path := generate_path (NULL);
        INSERT INTO priority (created_by, title, path, color, key, updated_by)
            VALUES (p_user_id, 'What''s New', v_priority_path, 7, '@plot.whats-new', 0)
        RETURNING
            id INTO v_priority_id;
        -- The insert_priority_user trigger won't fire for @plot.whats-new since it starts with @
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
