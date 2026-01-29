-- Activate a user who was invited to a priority
-- Creates root priority, priority settings, and sets user status to active
-- Idempotent - safe to call multiple times
CREATE OR REPLACE FUNCTION public.activate_invited_user (
    p_user_id uuid
)
    RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $function$
DECLARE
    v_current_status text;
    v_root_priority_id uuid;
    v_root_priority_path ltree;
    v_new_path ltree;
    v_activation_performed boolean := FALSE;
BEGIN
    -- Check if user is already active
    SELECT
        raw_app_meta_data ->> 'status' INTO v_current_status
    FROM
        auth.users
    WHERE
        id = p_user_id;
    -- If already active, return early
    IF v_current_status = 'active' THEN
        -- Find existing root priority
        SELECT
            priority_id INTO v_root_priority_id
        FROM
            public.priority_user
        WHERE
            user_id = p_user_id
            AND personal = TRUE
        LIMIT 1;
        RETURN jsonb_build_object('activated', FALSE, 'already_active', TRUE, 'root_priority_id', v_root_priority_id);
    END IF;
    -- User is not active, proceed with activation
    v_activation_performed := TRUE;
    -- Check if root priority already exists
    SELECT
        priority_id INTO v_root_priority_id
    FROM
        public.priority_user
    WHERE
        user_id = p_user_id
        AND personal = TRUE
    LIMIT 1;
    IF v_root_priority_id IS NULL THEN
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
    END IF;
    -- Create priority settings if they don't exist
    INSERT INTO public.priority_settings (user_id, priority_id)
        VALUES (p_user_id, v_root_priority_id)
    ON CONFLICT (user_id, priority_id)
        DO NOTHING;
    -- Set user status to active
    UPDATE
        auth.users
    SET
        raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb) || jsonb_build_object('status', 'active')
    WHERE
        id = p_user_id;
    RETURN jsonb_build_object('activated', TRUE, 'already_active', FALSE, 'root_priority_id', v_root_priority_id);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.activate_invited_user (uuid) FROM PUBLIC;
