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

    RETURN jsonb_build_object('activated', TRUE, 'already_active', FALSE, 'root_priority_id', v_root_priority_id);
END;
$function$;
