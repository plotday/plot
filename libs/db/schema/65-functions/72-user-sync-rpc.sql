-- Get pending user sync entities (where last_update_at > last_sync_at)
CREATE OR REPLACE FUNCTION public.get_pending_user_sync (p_user_id uuid)
    RETURNS TABLE (
        entity text,
        last_update_at timestamp with time zone)
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
    SELECT
        entity,
        last_update_at
    FROM
        user_sync
    WHERE
        user_id = p_user_id
        AND last_update_at > last_sync_at;
$function$;

-- Restrict access: only service_role can call this function
-- This function accesses sync state for any user
REVOKE EXECUTE ON FUNCTION public.get_pending_user_sync (uuid) FROM PUBLIC;
