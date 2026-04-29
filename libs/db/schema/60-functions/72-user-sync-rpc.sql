-- Get pending user sync entities. Returns both the timestamp watermark
-- (`last_update_at`) and the new xid8 watermark (`last_update_seq`) so the
-- UserSync DO can broadcast on whichever cursor model the client is on.
-- Pending = either watermark advanced past its corresponding sync point.
CREATE OR REPLACE FUNCTION public.get_pending_user_sync (p_user_id uuid)
    RETURNS TABLE (
        entity text,
        last_update_at timestamp with time zone,
        last_update_seq xid8)
    LANGUAGE sql
    STABLE
    SET search_path TO 'public'
    AS $function$
    SELECT
        entity,
        last_update_at,
        last_update_seq
    FROM
        user_sync
    WHERE
        user_id = p_user_id
        AND (last_update_at > last_sync_at OR last_update_seq > last_sync_seq);
$function$;
