SET ROLE "postgres";

-- Fix existing activities with done_at set but type != 'action'
-- activity_action_assignee constraint: actions need assignee OR (at IS NULL AND on IS NULL)
-- Use author_id as fallback assignee for scheduled done activities
UPDATE activity SET
    type = 'action',
    assignee_id = CASE
        WHEN assignee_id IS NULL AND (at IS NOT NULL OR "on" IS NOT NULL)
        THEN author_id
        ELSE assignee_id
    END
WHERE done_at IS NOT NULL AND type != 'action';

ALTER TABLE public.activity ADD CONSTRAINT activity_done_requires_action CHECK (done_at IS NULL OR type = 'action'::public.activity_type);
CREATE OR REPLACE TRIGGER ensure_assignee_priority_contact_trigger AFTER INSERT OR UPDATE OF assignee_id, priority_id ON public.activity FOR EACH ROW EXECUTE FUNCTION public.ensure_assignee_priority_contact();
CREATE OR REPLACE TRIGGER set_activity_source_priority_root_trigger BEFORE INSERT OR UPDATE OF source, priority_id ON public.activity FOR EACH ROW EXECUTE FUNCTION public.set_activity_source_priority_root();
CREATE OR REPLACE TRIGGER update_activity_last_note_created_at_on_status_change AFTER UPDATE OF draft, archived_at ON public.note FOR EACH ROW WHEN (old.draft IS DISTINCT FROM new.draft OR old.archived_at IS DISTINCT FROM new.archived_at) EXECUTE FUNCTION public.update_activity_on_note_change();
