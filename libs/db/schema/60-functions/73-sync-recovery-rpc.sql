-- Get stale user sync records (pending updates that haven't synced recently).
-- "Pending" = either watermark advanced past its sync point. The seq watermark
-- catches cases where the timestamp cursor falsely registers "synced" after
-- a long-transaction race -- see workers/api/src/app/sync/helpers.ts.
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
        (us.last_update_at > us.last_sync_at OR us.last_update_seq > us.last_sync_seq)
        AND us.last_sync_at < p_stale_threshold
    ORDER BY
        us.user_id
    LIMIT p_limit;
$function$;

-- Get stale twist_instance sync records. Same dual-watermark logic as
-- get_stale_user_syncs.
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
        (pts.last_update_at > pts.last_sync_at OR pts.last_update_seq > pts.last_sync_seq)
        AND pts.last_sync_at < p_stale_threshold
        AND pt.archived_at IS NULL
    ORDER BY
        pts.twist_instance_id
    LIMIT p_limit;
$function$;
