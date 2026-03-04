-- Enforce draft state rules:
-- 1. Update created_at when publishing (draft: true -> false)
-- 2. Prevent unpublishing (draft: false -> true)
CREATE OR REPLACE FUNCTION public.enforce_draft_rules ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    -- Prevent unpublishing: draft cannot go from false to true
    IF OLD.draft = FALSE AND NEW.draft = TRUE THEN
        RAISE EXCEPTION 'Cannot change draft from false to true';
    END IF;
    -- Update created_at when publishing (draft: true -> false)
    IF OLD.draft = TRUE AND NEW.draft = FALSE THEN
        NEW.created_at = now();
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER enforce_thread_draft_rules_trigger
    BEFORE UPDATE ON public.thread
    FOR EACH ROW
    WHEN (OLD.draft IS DISTINCT FROM NEW.draft)
    EXECUTE FUNCTION public.enforce_draft_rules ();

CREATE TRIGGER enforce_note_draft_rules_trigger
    BEFORE UPDATE ON public.note
    FOR EACH ROW
    WHEN (OLD.draft IS DISTINCT FROM NEW.draft)
    EXECUTE FUNCTION public.enforce_draft_rules ();

