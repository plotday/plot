-- Function to upsert contact when a user is created or updated
CREATE OR REPLACE FUNCTION public.upsert_user_contact (user_id uuid, user_email text, user_name text, avatar_url text)
    RETURNS uuid
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $function$
DECLARE
    _contact_id uuid;
BEGIN
    -- Upsert contact record for the user
    INSERT INTO public.contact (email, name, avatar_url, user_id)
        VALUES (user_email, user_name, avatar_url, user_id)
    ON CONFLICT (email)
        DO UPDATE SET
            name = COALESCE(EXCLUDED.name, contact.name),
            avatar_url = COALESCE(EXCLUDED.avatar_url, contact.avatar_url),
            user_id = COALESCE(EXCLUDED.user_id, contact.user_id),
            updated_at = now()
        RETURNING
            id INTO _contact_id;
    RETURN _contact_id;
END;
$function$;

-- Trigger function to automatically create/update contact when user is inserted/updated
CREATE OR REPLACE FUNCTION public.sync_user_contact_trigger ()
    RETURNS TRIGGER
    SECURITY DEFINER
    SET search_path = public, auth
    LANGUAGE plpgsql
    AS $function$
DECLARE
    _user_name text;
    _contact_id uuid;
BEGIN
    -- Extract name from user metadata (check both raw_user_meta_data and raw_app_meta_data)
    -- If no name in metadata, will be NULL (displayName generated from email in app)
    _user_name := COALESCE(NEW.raw_user_meta_data ->> 'full_name', NEW.raw_app_meta_data ->> 'full_name', NEW.raw_app_meta_data ->> 'name');
    -- Upsert contact and get the contact ID
    _contact_id := public.upsert_user_contact (NEW.id, NEW.email, _user_name, NEW.raw_app_meta_data ->> 'avatar_url');
    -- Update NEW.raw_app_meta_data directly (no UPDATE needed, prevents recursion)
    NEW.raw_app_meta_data := COALESCE(NEW.raw_app_meta_data, '{}'::jsonb) || jsonb_build_object('contact_id', _contact_id);
    RETURN NEW;
END;
$function$;

-- Create triggers for insert and update on auth.users
-- Using BEFORE triggers allows us to modify NEW directly without causing recursion
CREATE TRIGGER on_user_created_sync_contact
    BEFORE INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_user_contact_trigger ();

CREATE TRIGGER on_user_updated_sync_contact
    BEFORE UPDATE ON auth.users
    FOR EACH ROW
    WHEN (OLD.email IS DISTINCT FROM NEW.email OR OLD.raw_user_meta_data ->> 'full_name' IS DISTINCT FROM NEW.raw_user_meta_data ->> 'full_name' OR OLD.raw_app_meta_data ->> 'full_name' IS DISTINCT FROM NEW.raw_app_meta_data ->> 'full_name' OR OLD.raw_app_meta_data ->> 'name' IS DISTINCT FROM NEW.raw_app_meta_data ->> 'name' OR OLD.raw_app_meta_data ->> 'avatar_url' IS DISTINCT FROM NEW.raw_app_meta_data ->> 'avatar_url')
    EXECUTE FUNCTION public.sync_user_contact_trigger ();

-- Restrict access: only service_role can call these functions
-- These functions modify contacts and access auth.users
REVOKE EXECUTE ON FUNCTION public.upsert_user_contact (uuid, text, text, text) FROM PUBLIC;

-- Trigger function cannot be called via RPC, but REVOKE for defense-in-depth
REVOKE EXECUTE ON FUNCTION public.sync_user_contact_trigger () FROM PUBLIC;

