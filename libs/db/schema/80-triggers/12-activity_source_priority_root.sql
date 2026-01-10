-- Trigger function to set source_priority_root from the priority path
-- This is used for deduplication: one activity per (source, source_priority_root) pair
CREATE OR REPLACE FUNCTION public.set_activity_source_priority_root ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
DECLARE
    priority_path ltree;
BEGIN
    -- Only set source_priority_root when source is non-null
    IF NEW.source IS NOT NULL THEN
        -- Get the priority path
        SELECT
            p.path INTO priority_path
        FROM
            public.priority p
        WHERE
            p.id = NEW.priority_id;
        -- Extract the root element (first segment) of the priority path
        IF priority_path IS NOT NULL THEN
            NEW.source_priority_root := subpath (priority_path, 0, 1);
        END IF;
    ELSE
        -- Clear source_priority_root when source is null
        NEW.source_priority_root := NULL;
    END IF;
    RETURN NEW;
END;
$function$;

-- Create trigger to set source_priority_root on insert or update
CREATE TRIGGER set_activity_source_priority_root_trigger
    BEFORE INSERT OR UPDATE OF source,
    priority_id ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION public.set_activity_source_priority_root ();

