-- Trigger function to set source_priority_root from the thread's priority path
-- This is used for deduplication: one link per (source, source_priority_root) pair
CREATE OR REPLACE FUNCTION public.set_link_source_priority_root ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
DECLARE
    priority_path ltree;
BEGIN
    -- Only set source_priority_root when source is non-null
    IF NEW.source IS NOT NULL THEN
        -- Get the priority path via thread_priority (for the link creator's owner)
        -- or via the link's own priority_id
        SELECT
            p.path INTO priority_path
        FROM
            public.priority p
        WHERE
            p.id = COALESCE(
                (SELECT tp.priority_id
                 FROM public.thread_priority tp
                 WHERE tp.thread_id = NEW.thread_id
                   AND tp.user_id = COALESCE(
                       (SELECT pt.owner_id FROM public.twist_instance pt WHERE pt.id = NEW.created_by),
                       NEW.created_by
                   )
                ),
                NEW.priority_id
            );
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
CREATE OR REPLACE TRIGGER set_link_source_priority_root_trigger
    BEFORE INSERT OR UPDATE OF source,
    thread_id,
    priority_id ON public.link
    FOR EACH ROW
    EXECUTE FUNCTION public.set_link_source_priority_root ();
