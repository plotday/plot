ALTER VIEW "public"."user_note" SET ( security_invoker = TRUE);
ALTER VIEW "public"."note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_twist" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_exception" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_activity_update" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_note_create" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_activity_create" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_note_update" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_expanded" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_activity_tag_change" SET ( security_invoker = TRUE);
ALTER VIEW public.priority_member SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);

-- Fix insert_priority_user trigger to not create personal entries for global priorities
CREATE OR REPLACE FUNCTION insert_priority_user ()
    RETURNS TRIGGER
    AS $$
BEGIN
    -- Only create entry for new, top-level priorities, and mark them as personal
    -- Skip global priorities (those with keys starting with @, except @plot which is user-specific)
    IF nlevel (NEW.path) = 1 AND (NEW.key IS NULL OR NEW.key = '@plot' OR NOT NEW.key LIKE '@%') THEN
        INSERT INTO public.priority_user (user_id, priority_id, personal)
            VALUES (NEW.created_by, NEW.id, TRUE);
    END IF;
    RETURN NEW;
END;
$$
LANGUAGE plpgsql
SECURITY DEFINER;

-- Update help_feedback function to remove unnecessary DELETE
CREATE OR REPLACE FUNCTION public.setup_help_feedback_priority (
    p_user_name text DEFAULT NULL
)
    RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
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
    -- Get current user ID from auth context
    v_user_id := auth.uid ();

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'User not authenticated';
    END IF;

    -- Get user's email and name from auth.users
    SELECT
        email,
        COALESCE(raw_user_meta_data ->> 'name', raw_user_meta_data ->> 'full_name') INTO v_user_email,
        v_user_name
    FROM
        auth.users
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
        -- Upsert priority_settings
        INSERT INTO priority_settings (user_id, priority_id, path, title)
            VALUES (v_user_id, v_user_priority_id, v_override_path, 'Help & Feedback')
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET
                path = EXCLUDED.path, title = EXCLUDED.title, updated_at = now();
    END IF;

    -- Return success with created IDs
    RETURN jsonb_build_object(
        'success', TRUE,
        'global_priority_id', v_global_priority_id,
        'user_priority_id', v_user_priority_id,
        'has_plot_override', v_plot_priority_id IS NOT NULL
    );
END;
$function$;
