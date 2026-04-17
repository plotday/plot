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

    -- Create Using Plot (@plot.app)
    INSERT INTO public.priority (created_by, user_id, title, path, color, key, default_thread_icon)
    VALUES (p_user_id, p_user_id, 'Using Plot', v_new_path || generate_path(NULL), 7, '@plot.app', 'https://plot.day/assets/plot-icon.svg');

    -- Twist Development (@plot.twist-dev) is created lazily on first deploy
    -- via ensure_twist_dev_priority, so users who never develop twists don't
    -- carry an unused priority.

    -- Onboarding routing is now learned from user moves (thread_priority.user_moved).
    -- New users start with no training examples; incoming threads land in the
    -- root priority until the user moves one into "Using Plot". classify_thread_for_user
    -- then picks that priority up automatically for similar future threads.

    RETURN jsonb_build_object('activated', TRUE, 'already_active', FALSE, 'root_priority_id', v_root_priority_id);
END;
$$;
