SET ROLE "postgres";
SET check_function_bodies = false;
CREATE FUNCTION public.ensure_assignee_priority_contact()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    IF NEW.assignee_id IS NULL THEN
        RETURN NULL;
    END IF;
    -- Only create priority_contact if assignee is a contact (not a priority_twist)
    IF EXISTS (
        SELECT
            1
        FROM
            contact
        WHERE
            id = NEW.assignee_id) THEN
    INSERT INTO priority_contact (priority_id, contact_id)
        VALUES (NEW.priority_id, NEW.assignee_id)
    ON CONFLICT (priority_id, contact_id)
        DO NOTHING;
    END IF;
    RETURN NULL;
END;
$function$;
CREATE TRIGGER ensure_assignee_priority_contact_trigger AFTER INSERT OR UPDATE OF assignee_id, priority_id ON public.activity FOR EACH ROW EXECUTE FUNCTION public.ensure_assignee_priority_contact();
CREATE OR REPLACE TRIGGER set_activity_source_priority_root_trigger BEFORE INSERT OR UPDATE OF source, priority_id ON public.activity FOR EACH ROW EXECUTE FUNCTION public.set_activity_source_priority_root();
CREATE OR REPLACE TRIGGER update_activity_last_note_created_at_on_status_change AFTER UPDATE OF draft, archived_at ON public.note FOR EACH ROW WHEN (old.draft IS DISTINCT FROM new.draft OR old.archived_at IS DISTINCT FROM new.archived_at) EXECUTE FUNCTION public.update_activity_on_note_change();

-- Backfill: link existing assignees to their activity's priority
INSERT INTO priority_contact (priority_id, contact_id)
SELECT DISTINCT a.priority_id, a.assignee_id
FROM activity a
JOIN contact c ON c.id = a.assignee_id
WHERE a.assignee_id IS NOT NULL
ON CONFLICT (priority_id, contact_id) DO NOTHING;
