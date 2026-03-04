-- Shared function for defaulting author_id from created_by on INSERT.
-- Used by note table (thread no longer has author_id).
CREATE OR REPLACE FUNCTION public.update_author_and_created_by ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    IF NEW.created_by IS NULL THEN
        RAISE EXCEPTION 'created_by must be provided';
    END IF;
    IF NEW.author_id IS NULL THEN
        NEW.author_id := NEW.created_by;
    END IF;
    RETURN NEW;
END;
$function$;
