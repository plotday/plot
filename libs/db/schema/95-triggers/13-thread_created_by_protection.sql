-- Protect created_by from unauthorized changes
-- created_by is only allowed to change when un-archiving a thread
CREATE OR REPLACE FUNCTION public.protect_thread_created_by ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    -- Un-archiving: allow created_by update
    IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NULL THEN
        RETURN NEW;
    END IF;
    -- Not archived: prevent created_by changes
    IF OLD.archived_at IS NULL THEN
        NEW.created_by := OLD.created_by;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER protect_thread_created_by_trigger
    BEFORE UPDATE ON public.thread
    FOR EACH ROW
    EXECUTE FUNCTION public.protect_thread_created_by ();
