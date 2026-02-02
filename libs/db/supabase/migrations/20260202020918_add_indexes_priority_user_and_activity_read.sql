SET ROLE "postgres";

CREATE INDEX idx_activity_read_activity_id ON public.activity_read (activity_id);

CREATE INDEX idx_priority_user_priority_id ON public.priority_user (priority_id);

CREATE OR REPLACE TRIGGER set_activity_source_priority_root_trigger
    BEFORE INSERT OR UPDATE OF source,
    priority_id ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION public.set_activity_source_priority_root ();

CREATE OR REPLACE TRIGGER update_activity_last_note_created_at_on_status_change
    AFTER UPDATE OF draft,
    archived_at ON public.note
    FOR EACH ROW
    WHEN (old.draft IS DISTINCT FROM new.draft OR old.archived_at IS DISTINCT FROM new.archived_at)
    EXECUTE FUNCTION public.update_activity_on_note_change ();

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

ALTER VIEW "public"."priority_twist_activity_update" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_twist_note_create" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_twist_activity_create" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_twist_note_update" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_expanded" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_settings_inherited" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_twist_activity_tag_change" SET (security_invoker = TRUE);

ALTER VIEW public.priority_member SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child_twist" SET (security_invoker = TRUE);

ANALYZE;

