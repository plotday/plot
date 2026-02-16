-- Get all user IDs with access to a given priority (via priority_user hierarchy)
CREATE OR REPLACE FUNCTION public.get_users_with_priority_access (target_priority_id uuid)
    RETURNS TABLE (user_id uuid)
    LANGUAGE sql
    STABLE
    SET search_path TO 'public'
    AS $function$
    SELECT DISTINCT
        pu.user_id
    FROM
        priority_user pu
        JOIN priority pp ON pu.priority_id = pp.id
        JOIN priority p ON p.path <@ pp.path
    WHERE
        pu.archived_at IS NULL
        AND p.id = target_priority_id
$function$;
