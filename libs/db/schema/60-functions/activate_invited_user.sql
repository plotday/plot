-- Ensures a user has their own root priority. Idempotent — safe to call
-- multiple times. In the per-user model the root is just a priority
-- with nlevel(path) = 1 and user_id = the user, so we don't touch
-- priority_user at all.
CREATE OR REPLACE FUNCTION public.activate_invited_user (
    p_user_id uuid
)
    RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
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

    -- Create Twist Development (@plot.twist-dev)
    INSERT INTO public.priority (created_by, user_id, title, path, color, key)
    VALUES (p_user_id, p_user_id, 'Twist Development', v_new_path || generate_path(NULL), 3, '@plot.twist-dev');

    -- Add priority rules for auto-filing
    -- 1. Everyone topic -> Using Plot
    INSERT INTO public.priority_rule (user_id, priority_id, type, criteria, precedence)
    SELECT p_user_id, p.id, 'contact_topics', jsonb_build_object('topics', ARRAY[t.id::text]), 100
    FROM public.priority p
    CROSS JOIN public.topic t
    WHERE p.user_id = p_user_id AND p.key = '@plot.app'
      AND t.auto_maintained = TRUE AND t.team_id IS NULL AND t.name = 'Everyone';

    -- 2. User topic -> Using Plot
    INSERT INTO public.priority_rule (user_id, priority_id, type, criteria, precedence)
    SELECT p_user_id, p.id, 'contact_topics', jsonb_build_object('topics', ARRAY[t.id::text]), 100
    FROM public.priority p
    CROSS JOIN public.topic t
    WHERE p.user_id = p_user_id AND p.key = '@plot.app'
      AND t.auto_user_id = p_user_id;

    -- 3. Team admin topics -> Using Plot
    INSERT INTO public.priority_rule (user_id, priority_id, type, criteria, precedence)
    SELECT p_user_id, p.id, 'contact_topics', jsonb_build_object('topics', ARRAY[t.id::text]), 100
    FROM public.priority p
    CROSS JOIN public.topic t
    JOIN public.team_user tu ON tu.team_id = t.auto_team_admin_team_id AND tu.user_id = p_user_id
    WHERE p.user_id = p_user_id AND p.key = '@plot.app'
      AND t.auto_team_admin_team_id IS NOT NULL;

    -- 4. Twist/Connector admin topics -> Twist Development
    INSERT INTO public.priority_rule (user_id, priority_id, type, criteria, precedence)
    SELECT p_user_id, p.id, 'contact_topics', jsonb_build_object('topics', ARRAY[t.id::text]), 100
    FROM public.priority p
    CROSS JOIN public.topic t
    JOIN public.twist_admin ta ON ta.id = t.auto_twist_admin_id AND ta.user_id = p_user_id
    WHERE p.user_id = p_user_id AND p.key = '@plot.twist-dev'
      AND t.auto_twist_admin_id IS NOT NULL;

    RETURN jsonb_build_object('activated', TRUE, 'already_active', FALSE, 'root_priority_id', v_root_priority_id);
END;
$function$;
