-- Trigger function to create priority_contact when priority_user is inserted
CREATE OR REPLACE FUNCTION public.sync_priority_contact_on_insert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_contact_id uuid;
BEGIN
    -- Get the primary contact_id for this user
    v_contact_id := public.get_primary_contact_id (NEW.user_id);
    -- Only create priority_contact if the user has a contact record
    IF v_contact_id IS NOT NULL THEN
        INSERT INTO public.priority_contact (priority_id, contact_id, created_at, archived_at)
            VALUES (NEW.priority_id, v_contact_id, NEW.created_at, NEW.archived_at)
        ON CONFLICT (priority_id, contact_id)
            DO NOTHING;
    END IF;
    RETURN NEW;
END;
$function$;

-- Trigger function to sync archived_at when priority_user is updated
CREATE OR REPLACE FUNCTION public.sync_priority_contact_on_update ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_contact_id uuid;
BEGIN
    -- Only proceed if archived_at changed
    IF OLD.archived_at IS DISTINCT FROM NEW.archived_at THEN
        -- Get the primary contact_id for this user
        v_contact_id := public.get_primary_contact_id (NEW.user_id);
        -- Update the corresponding priority_contact if it exists
        IF v_contact_id IS NOT NULL THEN
            UPDATE
                public.priority_contact
            SET
                archived_at = NEW.archived_at
            WHERE
                priority_id = NEW.priority_id
                AND contact_id = v_contact_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

-- Trigger function to delete priority_contact when priority_user is deleted
CREATE OR REPLACE FUNCTION public.sync_priority_contact_on_delete ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_contact_id uuid;
BEGIN
    -- Get the primary contact_id for this user
    v_contact_id := public.get_primary_contact_id (OLD.user_id);
    -- Delete the corresponding priority_contact if it exists
    IF v_contact_id IS NOT NULL THEN
        DELETE FROM public.priority_contact
        WHERE priority_id = OLD.priority_id
            AND contact_id = v_contact_id;
    END IF;
    RETURN OLD;
END;
$function$;

-- Create triggers on priority_user table
CREATE TRIGGER sync_priority_contact_insert
    AFTER INSERT ON priority_user
    FOR EACH ROW
    EXECUTE FUNCTION sync_priority_contact_on_insert ();

CREATE TRIGGER sync_priority_contact_update
    AFTER UPDATE OF archived_at ON priority_user
    FOR EACH ROW
    EXECUTE FUNCTION sync_priority_contact_on_update ();

CREATE TRIGGER sync_priority_contact_delete
    AFTER DELETE ON priority_user
    FOR EACH ROW
    EXECUTE FUNCTION sync_priority_contact_on_delete ();

