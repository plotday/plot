-- Ensure assignee contacts are linked via priority_contact when set on a link
-- When a link has an assignee_id pointing to a contact, that contact must
-- exist in priority_contact for the link's thread's priority so it syncs to users.
CREATE OR REPLACE FUNCTION public.ensure_link_assignee_priority_contact ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_priority_id uuid;
BEGIN
    IF NEW.assignee_id IS NULL THEN
        RETURN NULL;
    END IF;
    -- Get the priority_id from the thread or direct link priority
    IF NEW.thread_id IS NOT NULL THEN
        SELECT
            t.priority_id INTO v_priority_id
        FROM
            thread t
        WHERE
            t.id = NEW.thread_id;
    ELSE
        v_priority_id := NEW.priority_id;
    END IF;
    IF v_priority_id IS NULL THEN
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
        VALUES (v_priority_id, NEW.assignee_id)
    ON CONFLICT (priority_id, contact_id)
        DO NOTHING;
    END IF;
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE TRIGGER ensure_link_assignee_priority_contact_trigger
    AFTER INSERT OR UPDATE OF assignee_id, thread_id ON public.link
    FOR EACH ROW
    EXECUTE FUNCTION public.ensure_link_assignee_priority_contact ();
