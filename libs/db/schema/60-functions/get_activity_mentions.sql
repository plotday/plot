-- Retrieve all mentions for an activity.
-- Used by activity_x view to aggregate mentions from notes.
CREATE OR REPLACE FUNCTION public.get_activity_mentions (p_activity_id uuid)
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
        n.activity_id = p_activity_id
        AND n.archived_at IS NULL
        AND n.mentions IS NOT NULL;
$function$;
