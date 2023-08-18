DROP FUNCTION label_stats;

CREATE OR REPLACE FUNCTION public.label_stats (user_id bigint, during tstzrange)
    RETURNS TABLE (
        label_id bigint,
        name text,
        response event_response,
        event_count integer,
        minutes integer)
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN query
    SELECT
        l.id AS label_id,
        l.name AS name,
        e.response,
        count(*)::integer AS event_count,
        sum(e.minutes)::integer AS minutes
    FROM
        event_x e
        JOIN event_label le ON le.event_id = e.id
        JOIN label l ON le.label_id = l.id
    WHERE
        e.user_id = label_stats.user_id
        AND e.at && during
        AND e.status != 'cancelled'
    GROUP BY
        l.id,
        e.status,
        e.response;
END
$function$;

