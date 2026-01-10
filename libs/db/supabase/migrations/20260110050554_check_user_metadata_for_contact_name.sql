SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.migrate_existing_users_to_contacts ()
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $function$
DECLARE
    _user_record record;
    _user_name text;
    _contact_id uuid;
    _updated_app_metadata jsonb;
BEGIN
    -- Loop through all existing auth users and create/update corresponding contacts
    FOR _user_record IN
    SELECT
        id,
        email,
        raw_app_meta_data,
        raw_user_meta_data
    FROM
        auth.users
    WHERE
        email IS NOT NULL LOOP
            -- Extract name from user metadata (check both raw_user_meta_data and raw_app_meta_data)
            _user_name := COALESCE(_user_record.raw_user_meta_data ->> 'full_name', _user_record.raw_app_meta_data ->> 'full_name', _user_record.raw_app_meta_data ->> 'name', _user_record.email);
            -- Upsert contact for this user and get contact ID
            _contact_id := public.upsert_user_contact (_user_record.id, _user_record.email, _user_name, _user_record.raw_app_meta_data ->> 'avatar_url');
            -- Update the user's app_metadata with contact_id
            _updated_app_metadata := COALESCE(_user_record.raw_app_meta_data, '{}'::jsonb) || jsonb_build_object('contact_id', _contact_id);
            -- Update the user record with the new app_metadata
            UPDATE
                auth.users
            SET
                raw_app_meta_data = _updated_app_metadata
            WHERE
                id = _user_record.id;
        END LOOP;
    RAISE NOTICE 'Migration completed: synchronized % users with contacts', (
        SELECT
            COUNT(*)
        FROM
            auth.users
        WHERE
            email IS NOT NULL);
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
BEGIN
    -- Extract name from user metadata (check both raw_user_meta_data and raw_app_meta_data)
    _user_name := COALESCE(NEW.raw_user_meta_data ->> 'full_name', NEW.raw_app_meta_data ->> 'full_name', NEW.raw_app_meta_data ->> 'name', NEW.email);
    -- Upsert contact and get the contact ID
    _contact_id := public.upsert_user_contact (NEW.id, NEW.email, _user_name, NEW.raw_app_meta_data ->> 'avatar_url');
    -- Update NEW.raw_app_meta_data directly (no UPDATE needed, prevents recursion)
    NEW.raw_app_meta_data := COALESCE(NEW.raw_app_meta_data, '{}'::jsonb) || jsonb_build_object('contact_id', _contact_id);
    RETURN NEW;
END;
$function$;

-- Update the trigger to watch for raw_user_meta_data.full_name changes
DROP TRIGGER IF EXISTS on_user_updated_sync_contact ON auth.users;

CREATE TRIGGER on_user_updated_sync_contact
    BEFORE UPDATE ON auth.users
    FOR EACH ROW
    WHEN (OLD.email IS DISTINCT FROM NEW.email OR OLD.raw_user_meta_data ->> 'full_name' IS DISTINCT FROM NEW.raw_user_meta_data ->> 'full_name' OR OLD.raw_app_meta_data ->> 'full_name' IS DISTINCT FROM NEW.raw_app_meta_data ->> 'full_name' OR OLD.raw_app_meta_data ->> 'name' IS DISTINCT FROM NEW.raw_app_meta_data ->> 'name' OR OLD.raw_app_meta_data ->> 'avatar_url' IS DISTINCT FROM NEW.raw_app_meta_data ->> 'avatar_url')
    EXECUTE FUNCTION public.sync_user_contact_trigger ();

ALTER VIEW "public"."user_note" SET ( security_invoker = TRUE);
ALTER VIEW "public"."note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_twist" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_exception" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_expanded" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);
