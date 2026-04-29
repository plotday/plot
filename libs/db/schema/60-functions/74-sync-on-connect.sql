-- Function to sync user_sync state when a client connects
-- This ensures that incremental sync works correctly after reconnection
-- The client pulls full data before connecting, so we set last_sync_at = last_update_at
CREATE OR REPLACE FUNCTION public.sync_user_on_connect (p_user_id uuid)
    RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
BEGIN
    -- Update all user_sync rows for this user. Set both watermarks
    -- (timestamp + seq) to match their respective `last_update_*` since the
    -- client has full data after the connect-time pull. Both columns are
    -- maintained during the expand-contract rollout; readers may consult
    -- either or both.
    UPDATE
        user_sync
    SET
        last_sync_at = last_update_at,
        last_sync_seq = last_update_seq
    WHERE
        user_id = p_user_id;
END;
$function$;
