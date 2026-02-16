-- Check if a user has access to a priority (via priority_user hierarchy)
CREATE OR REPLACE FUNCTION public.user_has_priority_access (p_user_id uuid, p_priority_id uuid)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SET search_path TO 'public'
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                priority_user pu
                JOIN priority pp ON pu.priority_id = pp.id
                JOIN priority p ON p.path <@ pp.path
            WHERE
                pu.user_id = p_user_id
                AND pu.archived_at IS NULL
                AND p.id = p_priority_id)
$function$;
