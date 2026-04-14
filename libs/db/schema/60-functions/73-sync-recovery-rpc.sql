-- Get stale user sync records (pending updates that haven't synced recently)
-- Used by SyncRecovery to find missed sync notifications
CREATE OR REPLACE FUNCTION public.get_stale_user_syncs (p_stale_threshold timestamp with time zone, p_limit integer DEFAULT 50)
    RETURNS TABLE (
        user_id uuid)
    LANGUAGE sql
    STABLE
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

-- Get stale twist_instance sync records (pending updates that haven't synced recently)
-- Used by SyncRecovery to find missed sync notifications
CREATE OR REPLACE FUNCTION public.get_stale_twist_syncs (p_stale_threshold timestamp with time zone, p_limit integer DEFAULT 50)
    RETURNS TABLE (
        twist_instance_id uuid)
    LANGUAGE sql
    STABLE
    SET search_path TO 'public'
    AS $function$
    SELECT DISTINCT
        pts.twist_instance_id
    FROM
        twist_instance_sync pts
        JOIN twist_instance pt ON pt.id = pts.twist_instance_id
    WHERE
        pts.last_update_at > pts.last_sync_at -- Has pending updates
        AND pts.last_sync_at < p_stale_threshold -- Hasn't synced recently
        AND pt.archived_at IS NULL -- Skip archived twists
    ORDER BY
        pts.twist_instance_id -- Deterministic ordering after DISTINCT
    LIMIT p_limit;
$function$;
