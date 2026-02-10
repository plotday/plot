SET ROLE "postgres";
CREATE TABLE public.contact_external_account (contact_id uuid NOT NULL, provider text NOT NULL, account_id text NOT NULL, data_fetched_at timestamp with time zone DEFAULT now() NOT NULL, last_reported_at timestamp with time zone);
ALTER TABLE public.contact_external_account ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contact_external_account ADD CONSTRAINT contact_external_account_contact_id_fkey FOREIGN KEY (contact_id) REFERENCES public.contact(id) ON DELETE CASCADE;
ALTER TABLE public.contact_external_account ADD CONSTRAINT contact_external_account_pkey PRIMARY KEY (provider, account_id);
CREATE INDEX idx_cea_contact ON public.contact_external_account (contact_id);
CREATE INDEX idx_cea_reporting ON public.contact_external_account (provider, last_reported_at);

-- Seed: "Removed Contact" sentinel for privacy compliance (Atlassian account closure)
INSERT INTO public.contact (email, name, avatar_url, user_id)
VALUES ('removed@system.plot.day', 'Removed Contact', NULL, NULL)
ON CONFLICT (email) DO NOTHING;

CREATE OR REPLACE TRIGGER ensure_assignee_priority_contact_trigger AFTER INSERT OR UPDATE OF assignee_id, priority_id ON public.activity FOR EACH ROW EXECUTE FUNCTION public.ensure_assignee_priority_contact();
CREATE OR REPLACE TRIGGER set_activity_source_priority_root_trigger BEFORE INSERT OR UPDATE OF source, priority_id ON public.activity FOR EACH ROW EXECUTE FUNCTION public.set_activity_source_priority_root();
CREATE OR REPLACE TRIGGER update_activity_last_note_created_at_on_status_change AFTER UPDATE OF draft, archived_at ON public.note FOR EACH ROW WHEN (old.draft IS DISTINCT FROM new.draft OR old.archived_at IS DISTINCT FROM new.archived_at) EXECUTE FUNCTION public.update_activity_on_note_change();

ALTER VIEW "public"."note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_twist" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_activity_update" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_note_create" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_activity_create" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_note_update" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_expanded" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_activity_tag_change" SET ( security_invoker = TRUE);
ALTER VIEW public.priority_member SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);
