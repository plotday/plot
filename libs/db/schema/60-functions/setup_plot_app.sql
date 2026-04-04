-- Create/join @plot.app priority for a user as a viewer member
-- The first call creates the global priority; subsequent calls just join the user
-- Positions under user's root priority via priority_settings
CREATE OR REPLACE FUNCTION public.setup_plot_app_priority (p_user_id uuid)
    RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_priority_id uuid;
    v_priority_path ltree;
    v_contact_id uuid;
    v_user_root_path ltree;
    v_override_path ltree;
BEGIN
    -- Get or create @plot.app priority
    SELECT
        id, path INTO v_priority_id, v_priority_path
    FROM
        priority
    WHERE
        key = '@plot.app'
    LIMIT 1;

    IF v_priority_id IS NULL THEN
        v_priority_path := generate_path (NULL);
        INSERT INTO priority (created_by, title, path, color, key, updated_by)
            VALUES (p_user_id, 'Plot App', v_priority_path, 7, '@plot.app', 0)
        RETURNING
            id INTO v_priority_id;
        -- Clean up any auto-created personal entry
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

    -- Position under user's root via priority_settings
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
        v_override_path := generate_path (v_user_root_path);
        INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (p_user_id, v_priority_id, 'path', to_jsonb(ltree2text(v_override_path)))
        ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (p_user_id, v_priority_id, 'title', to_jsonb('Plot App'::text))
        ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
    END IF;

    RETURN jsonb_build_object('success', TRUE, 'priority_id', v_priority_id);
END;
$function$;
