CREATE OR REPLACE FUNCTION public.actor ("user".activity)
    RETURNS SETOF actor
    LANGUAGE sql
    STABLE ROWS 1
    AS $function$
    SELECT
        actor.*
    FROM
        actor
    WHERE
        actor.id = $1.author_id
$function$;
