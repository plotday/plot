-- Retrieve all mentions for a thread.
-- Used by thread_x view to aggregate mentions from notes.
CREATE OR REPLACE FUNCTION public.get_thread_mentions (p_thread_id uuid)
    RETURNS uuid[]
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        ARRAY_AGG(DISTINCT mention)
    FROM
        note n,
        LATERAL unnest(n.mentions) AS mention
    WHERE
        n.thread_id = p_thread_id
        AND n.archived_at IS NULL
        AND n.mentions IS NOT NULL;
$function$;
