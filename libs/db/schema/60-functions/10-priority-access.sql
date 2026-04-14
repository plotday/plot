-- Check if a user has access to a priority. In the per-user priority
-- model every priority has exactly one owner (priority.user_id), so
-- access is a single equality check. The legacy inherit_members
-- boundary walk is gone with shared subtrees.
CREATE OR REPLACE FUNCTION public.user_has_priority_access (p_user_id uuid, p_priority_id uuid)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SET search_path TO 'public'
    AS $function$
    SELECT EXISTS (
        SELECT 1
        FROM priority p
        WHERE p.id = p_priority_id
          AND p.user_id = p_user_id
          AND p.archived_at IS NULL
    )
$function$;
