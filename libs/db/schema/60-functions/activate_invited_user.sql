-- Ensure user has root priority and settings
-- Creates root priority and priority settings if they don't exist
-- Idempotent - safe to call multiple times
CREATE OR REPLACE FUNCTION public.activate_invited_user (
    p_user_id uuid
)
    RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
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
        -- Ensure priority settings exist
        INSERT INTO public.priority_settings (user_id, priority_id)
            VALUES (p_user_id, v_root_priority_id)
        ON CONFLICT (user_id, priority_id)
            DO NOTHING;
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
    -- Create priority settings if they don't exist
    INSERT INTO public.priority_settings (user_id, priority_id)
        VALUES (p_user_id, v_root_priority_id)
    ON CONFLICT (user_id, priority_id)
        DO NOTHING;
    RETURN jsonb_build_object('activated', TRUE, 'already_active', FALSE, 'root_priority_id', v_root_priority_id);
END;
$function$;
