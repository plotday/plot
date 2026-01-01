-- Fix trigger timing: change from AFTER to BEFORE triggers
-- This ensures contact_id is in raw_app_meta_data before the JWT is issued
DROP TRIGGER IF EXISTS on_user_created_sync_contact ON auth.users;

DROP TRIGGER IF EXISTS on_user_updated_sync_contact ON auth.users;

CREATE TRIGGER on_user_created_sync_contact
    BEFORE INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_user_contact_trigger ();

CREATE TRIGGER on_user_updated_sync_contact
    BEFORE UPDATE ON auth.users
    FOR EACH ROW
    WHEN (OLD.email IS DISTINCT FROM NEW.email OR OLD.raw_app_meta_data ->> 'full_name' IS DISTINCT FROM NEW.raw_app_meta_data ->> 'full_name' OR OLD.raw_app_meta_data ->> 'name' IS DISTINCT FROM NEW.raw_app_meta_data ->> 'name' OR OLD.raw_app_meta_data ->> 'avatar_url' IS DISTINCT FROM NEW.raw_app_meta_data ->> 'avatar_url')
    EXECUTE FUNCTION public.sync_user_contact_trigger ();

ALTER VIEW "public"."user_note" SET (security_invoker = TRUE);

ALTER VIEW "public"."note_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_note_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_twist" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_exception" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_expanded" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_settings_inherited" SET (security_invoker = TRUE);

ALTER VIEW "public"."actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child_twist" SET (security_invoker = TRUE);

