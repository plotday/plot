-- Ensure priority_user entries have a corresponding priority_contact
-- When a user is added to a priority (priority_user INSERT), create a priority_contact
-- entry using their primary contact so they appear in the actor list.
CREATE OR REPLACE FUNCTION public.ensure_priority_user_contact ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
BEGIN
    INSERT INTO priority_contact (priority_id, contact_id)
    SELECT
        NEW.priority_id,
        c.id
    FROM
        contact c
    WHERE
        c.user_id = NEW.user_id
        AND c."primary" = TRUE
        AND c.archived_at IS NULL
    ON CONFLICT (priority_id, contact_id)
        DO NOTHING;
    RETURN NULL;
END;
$function$;

CREATE TRIGGER ensure_priority_user_contact_trigger
    AFTER INSERT ON public.priority_user
    FOR EACH ROW
    EXECUTE FUNCTION public.ensure_priority_user_contact ();
