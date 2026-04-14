-- Returns the user(s) with access to a priority. In the per-user
-- priority model this is always exactly one user: the priority's owner.
CREATE OR REPLACE FUNCTION public.get_users_with_priority_access (target_priority_id uuid)
    RETURNS TABLE (user_id uuid)
    LANGUAGE sql
    STABLE
    SET search_path TO 'public'
    AS $function$
    SELECT p.user_id
    FROM priority p
    WHERE p.id = target_priority_id
      AND p.archived_at IS NULL
$function$;
