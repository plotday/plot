-- Function to sync user_sync state when a client connects
-- This ensures that incremental sync works correctly after reconnection
-- The client pulls full data before connecting, so we set last_sync_at = last_update_at
CREATE OR REPLACE FUNCTION public.sync_user_on_connect (p_user_id uuid)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
BEGIN
    -- Update all user_sync rows for this user
    -- Set last_sync_at to match last_update_at since client has full data
    UPDATE
        user_sync
    SET
        last_sync_at = last_update_at
    WHERE
        user_id = p_user_id;
END;
$function$;

-- Restrict access: only service_role can call this function
-- This function modifies sync state for any user
REVOKE EXECUTE ON FUNCTION public.sync_user_on_connect (uuid) FROM PUBLIC;
