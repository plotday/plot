-- Protect author_id and created_by from unauthorized changes
-- author_id is always immutable (never changes after creation)
-- created_by is only allowed to change when un-archiving an activity
CREATE OR REPLACE FUNCTION public.protect_activity_created_by ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    -- author_id is immutable: always preserve original value
    NEW.author_id := OLD.author_id;
    -- Un-archiving: allow created_by update
    IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NULL THEN
        IF NEW.created_by IS DISTINCT FROM OLD.created_by THEN
            -- Derive created_by_twist_id from new created_by
            SELECT
                pt.twist_id INTO NEW.created_by_twist_id
            FROM
                priority_twist pt
            WHERE
                pt.id = NEW.created_by;
        END IF;
        RETURN NEW;
    END IF;
    -- Not archived: prevent created_by changes
    IF OLD.archived_at IS NULL THEN
        NEW.created_by := OLD.created_by;
        NEW.created_by_twist_id := OLD.created_by_twist_id;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER protect_activity_created_by_trigger
    BEFORE UPDATE ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION public.protect_activity_created_by ();
