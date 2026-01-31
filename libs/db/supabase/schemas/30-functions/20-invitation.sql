-- Function to set user status in app_metadata
CREATE OR REPLACE FUNCTION public.set_user_status (user_id uuid, status text)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $function$
BEGIN
    -- Atomically update the user's app_metadata with status
    -- This avoids race conditions by doing the read and write in one operation
    UPDATE
        auth.users
    SET
        raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb) || jsonb_build_object('status', status)
    WHERE
        id = user_id;
END;
$function$;

-- Restrict access: only service_role can call this function
REVOKE EXECUTE ON FUNCTION set_user_status (uuid, text) FROM PUBLIC;

-- Function to redeem an invitation code (atomic operation)
CREATE OR REPLACE FUNCTION public.redeem_invitation_code (invitation_code text, user_id uuid)
    RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $function$
DECLARE
    _remaining numeric;
BEGIN
    -- Atomically decrement the invitation code's remaining count
    -- Returns NULL if code doesn't exist or has no remaining uses
    UPDATE
        public.invitation
    SET
        remaining = remaining - 1
    WHERE
        LOWER(code) = LOWER(invitation_code)
        AND remaining > 0
    RETURNING
        remaining INTO _remaining;
    -- Check if update was successful
    IF _remaining IS NULL THEN
        -- Either code doesn't exist or has no remaining uses
        RETURN jsonb_build_object('success', FALSE, 'error', 'invalid_or_exhausted');
    END IF;
    RETURN jsonb_build_object('success', TRUE, 'remaining', _remaining);
END;
$function$;

-- Restrict access: only service_role can call this function
REVOKE EXECUTE ON FUNCTION redeem_invitation_code (text, uuid) FROM PUBLIC;

