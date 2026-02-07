-- Ensure assignee contacts are linked via priority_contact
-- When an activity has an assignee_id pointing to a contact, that contact must
-- exist in priority_contact for the activity's priority so it syncs to users.
CREATE OR REPLACE FUNCTION public.ensure_assignee_priority_contact ()
    RETURNS TRIGGER
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

CREATE TRIGGER ensure_assignee_priority_contact_trigger
    AFTER INSERT OR UPDATE OF assignee_id, priority_id ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION public.ensure_assignee_priority_contact ();
