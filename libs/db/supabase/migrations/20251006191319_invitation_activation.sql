SET check_function_bodies = OFF;

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
        code = invitation_code
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

CREATE OR REPLACE FUNCTION public.sync_user_contact_trigger ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $function$
DECLARE
    _user_name text;
    _contact_id uuid;
    _updated_app_metadata jsonb;
BEGIN
    -- Extract name from user metadata
    _user_name := COALESCE(NEW.raw_app_meta_data ->> 'full_name', NEW.raw_app_meta_data ->> 'name', NEW.email);
    -- Upsert contact and get the contact ID
    _contact_id := public.upsert_user_contact (NEW.id, NEW.email, _user_name, NEW.raw_app_meta_data ->> 'avatar_url');
    -- Update the user's app_metadata with contact_id
    _updated_app_metadata := COALESCE(NEW.raw_app_meta_data, '{}'::jsonb) || jsonb_build_object('contact_id', _contact_id);
    -- Update the user record with the new app_metadata
    UPDATE
        auth.users
    SET
        raw_app_meta_data = _updated_app_metadata
    WHERE
        id = NEW.id;
    RETURN NEW;
END;
$function$;

ALTER VIEW "public"."activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_children" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_exception" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "admin"."invitation" SET (security_invoker = FALSE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_settings_inherited" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child_agent" SET (security_invoker = TRUE);

ALTER VIEW "public"."actor" SET (security_invoker = TRUE);

