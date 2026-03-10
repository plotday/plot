-- Create/join @whats-new priority for a user as a viewer member
-- The first user to activate creates the global priority; subsequent users just join
-- Positions under @plot via priority_settings
CREATE OR REPLACE FUNCTION public.setup_whats_new_priority (p_user_id uuid)
    RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
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
            INSERT INTO priority_settings (user_id, priority_id, path, title)
                VALUES (p_user_id, v_priority_id, v_override_path, 'What''s New')
            ON CONFLICT (user_id, priority_id)
                DO UPDATE SET
                    path = EXCLUDED.path,
                    title = EXCLUDED.title;
        END IF;
    END IF;

    RETURN jsonb_build_object('success', TRUE, 'priority_id', v_priority_id);
END;
$function$;
