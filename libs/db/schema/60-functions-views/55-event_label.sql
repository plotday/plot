CREATE OR REPLACE FUNCTION event_label_matches (e event_x)
    RETURNS SETOF bigint
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF e.type <> 'meeting' THEN
        RETURN;
    END IF;
    IF e.initiated = TRUE THEN
        RETURN NEXT 1;
    END IF;
    RETURN NEXT CASE WHEN e.invitee_count = 2 THEN
        2
    WHEN e.invitee_count <= 4 THEN
        3
    WHEN e.invitee_count <= 7 THEN
        4
    WHEN e.invitee_count <= 15 THEN
        5
    WHEN e.invitee_count <= 30 THEN
        6
    ELSE
        7
    END;
    IF e.internal = 'internal'::event_internal THEN
        RETURN NEXT 8;
    END IF;
    IF e.internal = 'external'::event_internal THEN
        RETURN NEXT 9;
    END IF;
    RETURN NEXT CASE WHEN e.minutes <= 20 THEN
        10
    WHEN e.minutes < 40 THEN
        11
    WHEN e.minutes < 50 THEN
        12
    WHEN e.minutes < 75 THEN
        13
    WHEN e.minutes < 101 THEN
        14
    WHEN e.minutes < 131 THEN
        15
    WHEN e.minutes < 161 THEN
        16
    WHEN e.minutes <= 180 THEN
        17
    WHEN e.minutes <= 300 THEN
        18
    WHEN e.minutes <= 420 THEN
        19
    ELSE
        20
    END;
    IF e.series IS NOT NULL THEN
        RETURN NEXT 21;
    END IF;
    IF e.created_at IS NOT NULL AND EXTRACT(EPOCH FROM (LOWER(e.at) - e.created_at)) < 18 * 60 * 60 THEN
        RETURN NEXT 22;
    END IF;
    IF e.minutes < 30 OR (MOD(e.minutes, 30) >= 10 AND MOD(e.minutes, 30) <= 15) THEN
        RETURN NEXT 23;
    END IF;
    IF e.initiated = TRUE THEN
        RETURN NEXT 24;
    END IF;
    -- RETURN QUERY
    -- SELECT
    --     *
    -- FROM
    --     event_label
    -- WHERE
    --     provider_id = e.provider_id;
    RETURN;
END;
$$;

CREATE OR REPLACE VIEW "public"."event_label" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    e.id AS event_id,
    l AS label_id
FROM
    event_x e
    CROSS JOIN LATERAL event_label_matches (e) AS l;

CREATE OR REPLACE FUNCTION public.label (event_x)
    RETURNS SETOF label
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        label.*
    FROM
        label
        JOIN event_label ON label.id = event_label.label_id
    WHERE
        event_label.event_id = $1.id
$function$;

