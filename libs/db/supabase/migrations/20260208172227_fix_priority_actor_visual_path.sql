SET ROLE "postgres";
CREATE OR REPLACE VIEW public.user_priority_actor WITH (security_invoker=true) AS SELECT user_id,
    priority_path,
    actor_id,
    created_at,
    updated_at,
    archived_at
   FROM ( SELECT upe.user_id,
            up.path AS priority_path,
            pc.contact_id AS actor_id,
            LEAST(COALESCE(pc.created_at, c.created_at), COALESCE(c.created_at, pc.created_at)) AS created_at,
            GREATEST(pc.updated_at, c.updated_at) AS updated_at,
                CASE
                    WHEN ((pc.invited_by IS NOT NULL) AND (pc.invited_at IS NULL)) THEN pc.updated_at
                    ELSE c.archived_at
                END AS archived_at
           FROM (((public.user_priority_expanded upe
             JOIN public.priority_contact pc ON ((pc.priority_id = upe.priority_id)))
             JOIN public.contact c ON ((c.id = pc.contact_id)))
             JOIN public.user_priority up ON (((up.user_id = upe.user_id) AND (up.id = upe.priority_id))))
        UNION ALL
         SELECT upe.user_id,
            up.path AS priority_path,
            pt.id AS actor_id,
            pt.created_at,
            pt.updated_at,
            pt.archived_at
           FROM ((public.user_priority_expanded upe
             JOIN public.priority_twist pt ON ((pt.priority_id = upe.priority_id)))
             JOIN public.user_priority up ON (((up.user_id = upe.user_id) AND (up.id = upe.priority_id))))) actors;
CREATE OR REPLACE TRIGGER ensure_assignee_priority_contact_trigger AFTER INSERT OR UPDATE OF assignee_id, priority_id ON public.activity FOR EACH ROW EXECUTE FUNCTION public.ensure_assignee_priority_contact();
CREATE OR REPLACE TRIGGER set_activity_source_priority_root_trigger BEFORE INSERT OR UPDATE OF source, priority_id ON public.activity FOR EACH ROW EXECUTE FUNCTION public.set_activity_source_priority_root();
CREATE OR REPLACE TRIGGER update_activity_last_note_created_at_on_status_change AFTER UPDATE OF draft, archived_at ON public.note FOR EACH ROW WHEN (old.draft IS DISTINCT FROM new.draft OR old.archived_at IS DISTINCT FROM new.archived_at) EXECUTE FUNCTION public.update_activity_on_note_change();
