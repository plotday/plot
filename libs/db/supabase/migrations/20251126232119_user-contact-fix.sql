SET check_function_bodies = OFF;

ALTER TABLE "public"."contact"
    DROP CONSTRAINT "contact_user_id_fkey";

ALTER TABLE "public"."contact"
    ADD CONSTRAINT "contact_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED NOT valid;

ALTER TABLE "public"."contact" validate CONSTRAINT "contact_user_id_fkey";

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
    -- Extract name from user metadata
    _user_name := COALESCE(NEW.raw_app_meta_data ->> 'full_name', NEW.raw_app_meta_data ->> 'name', NEW.email);
    -- Upsert contact and get the contact ID
    _contact_id := public.upsert_user_contact (NEW.id, NEW.email, _user_name, NEW.raw_app_meta_data ->> 'avatar_url');
    -- Update NEW.raw_app_meta_data directly (no UPDATE needed, prevents recursion)
    NEW.raw_app_meta_data := COALESCE(NEW.raw_app_meta_data, '{}'::jsonb) || jsonb_build_object('contact_id', _contact_id);
    RETURN NEW;
END;
$function$;

DROP TRIGGER on_user_created_sync_contact ON auth.users;

DROP TRIGGER on_user_updated_sync_contact ON auth.users;

-- Create triggers for insert and update on auth.users
-- Using BEFORE triggers allows us to modify NEW directly without causing recursion
CREATE TRIGGER on_user_created_sync_contact
    BEFORE INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_user_contact_trigger ();

CREATE TRIGGER on_user_updated_sync_contact
    BEFORE UPDATE ON auth.users
    FOR EACH ROW
    WHEN (OLD.email IS DISTINCT FROM NEW.email OR OLD.raw_app_meta_data ->> 'full_name' IS DISTINCT FROM NEW.raw_app_meta_data ->> 'full_name' OR OLD.raw_app_meta_data ->> 'name' IS DISTINCT FROM NEW.raw_app_meta_data ->> 'name' OR OLD.raw_app_meta_data ->> 'avatar_url' IS DISTINCT FROM NEW.raw_app_meta_data ->> 'avatar_url')
    EXECUTE FUNCTION public.sync_user_contact_trigger ();

ALTER VIEW "public"."activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_children" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_exception" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_settings_inherited" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority" SET (security_invoker = TRUE);

ALTER VIEW "public"."actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child_twist" SET (security_invoker = TRUE);

