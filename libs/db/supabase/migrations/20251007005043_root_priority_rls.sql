SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.prevent_priority_root_change ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    -- Check if root column is being changed
    IF OLD.root IS DISTINCT FROM NEW.root THEN
        RAISE EXCEPTION 'Cannot change the root column of a priority after creation';
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER prevent_priority_root_change_trigger
    BEFORE UPDATE ON public.priority
    FOR EACH ROW
    EXECUTE FUNCTION prevent_priority_root_change ();

