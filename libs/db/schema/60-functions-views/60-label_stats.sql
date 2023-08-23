CREATE OR REPLACE FUNCTION public.label_stats (user_id bigint, during tstzrange)
    RETURNS TABLE (
        label_id bigint,
        "order" integer,
        tag text,
        name text,
        description text,
        response event_response,
        event_count integer,
        minutes integer)
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN query
    SELECT
        l.id AS label_id,
        l.order AS "order",
        l.tag AS tag,
        l.name AS name,
        l.description AS description,
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

CREATE OR REPLACE FUNCTION public.org_stats (user_id bigint, during tstzrange)
    RETURNS TABLE (
        label_id bigint,
        "order" integer,
        tag text,
        name text,
        description text,
        response event_response,
        event_count integer,
        minutes integer)
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN query
    SELECT
        l.id AS label_id,
        l.order AS "order",
        l.tag AS tag,
        l.name AS name,
        l.description AS description,
        e.response,
        count(*)::integer AS event_count,
        sum((e.minutes + 15) * e.invitee_count)::integer AS minutes
    FROM
        event_x e
        JOIN contact c ON c.id = e.organizer
        JOIN event_label le ON le.event_id = e.id
        JOIN label l ON le.label_id = l.id
    WHERE
        e.user_id = org_stats.user_id
        AND e.at && during
        AND c.contact_user_id = e.user_id
        AND e.status != 'cancelled'
        AND l.id != 24 -- initiated
    GROUP BY
        l.id,
        e.status,
        e.response;
END
$function$;

