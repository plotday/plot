-- Get stale user sync records (pending updates that haven't synced recently)
-- Used by SyncRecovery to find missed sync notifications
CREATE OR REPLACE FUNCTION public.get_stale_user_syncs (p_stale_threshold timestamp with time zone, p_limit integer DEFAULT 50)
    RETURNS TABLE (
        user_id uuid)
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
    SELECT DISTINCT
        us.user_id
    FROM
        user_sync us
    WHERE
        us.last_update_at > us.last_sync_at -- Has pending updates
        AND us.last_sync_at < p_stale_threshold -- Hasn't synced recently
    ORDER BY
        us.user_id -- Deterministic ordering after DISTINCT
    LIMIT p_limit;
$function$;

-- Get stale priority_twist sync records (pending updates that haven't synced recently)
-- Used by SyncRecovery to find missed sync notifications
CREATE OR REPLACE FUNCTION public.get_stale_twist_syncs (p_stale_threshold timestamp with time zone, p_limit integer DEFAULT 50)
    RETURNS TABLE (
        priority_twist_id uuid)
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
    SELECT DISTINCT
        pts.priority_twist_id
    FROM
        priority_twist_sync pts
        JOIN priority_twist pt ON pt.id = pts.priority_twist_id
    WHERE
        pts.last_update_at > pts.last_sync_at -- Has pending updates
        AND pts.last_sync_at < p_stale_threshold -- Hasn't synced recently
        AND pt.archived_at IS NULL -- Skip archived twists
    ORDER BY
        pts.priority_twist_id -- Deterministic ordering after DISTINCT
    LIMIT p_limit;
$function$;

-- Restrict access: only service_role can call these functions
-- These functions expose sync state information
REVOKE EXECUTE ON FUNCTION public.get_stale_user_syncs (timestamp with time zone, integer) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.get_stale_twist_syncs (timestamp with time zone, integer) FROM PUBLIC;
