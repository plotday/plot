-- Protect author_id and created_by from unauthorized changes on notes
-- author_id is always immutable (never changes after creation)
-- created_by is only allowed to change when un-archiving a note
CREATE OR REPLACE FUNCTION public.protect_note_author ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    -- author_id is immutable: always preserve original value
    NEW.author_id := OLD.author_id;
    -- Un-archiving: allow created_by update (for twist re-sync)
    IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NULL THEN
        RETURN NEW;
    END IF;
    -- Otherwise: prevent created_by changes
    NEW.created_by := OLD.created_by;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER protect_note_author_trigger
    BEFORE UPDATE ON public.note
    FOR EACH ROW
    EXECUTE FUNCTION public.protect_note_author ();
