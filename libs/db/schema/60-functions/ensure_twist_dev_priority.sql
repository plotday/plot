-- Idempotently ensure the user has a Twist Development (@plot.twist-dev)
-- priority and return its id. Called from the twist deploy / logs flow so
-- the priority appears the first time a user develops a twist or connector
-- (rather than for every user at activation).
--
-- Returns NULL if the user has no root priority yet (not activated).
CREATE OR REPLACE FUNCTION public.ensure_twist_dev_priority (
    p_user_id uuid
)
    RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_priority_id uuid;
    v_root_path ltree;
BEGIN
    SELECT id INTO v_priority_id
    FROM public.priority
    WHERE user_id = p_user_id
      AND key = '@plot.twist-dev'
      AND archived_at IS NULL
    LIMIT 1;

    IF v_priority_id IS NOT NULL THEN
        RETURN v_priority_id;
    END IF;

    SELECT path INTO v_root_path
    FROM public.priority
    WHERE user_id = p_user_id
      AND nlevel(path) = 1
      AND archived_at IS NULL
    ORDER BY created_at ASC
    LIMIT 1;

    IF v_root_path IS NULL THEN
        RETURN NULL;
    END IF;

    INSERT INTO public.priority (created_by, user_id, title, path, color, key)
    VALUES (p_user_id, p_user_id, 'Twist Development', v_root_path || generate_path(NULL), 3, '@plot.twist-dev')
    RETURNING id INTO v_priority_id;

    RETURN v_priority_id;
END;
$function$;
