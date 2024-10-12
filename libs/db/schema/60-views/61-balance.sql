CREATE OR REPLACE VIEW balance WITH ( security_invoker = TRUE
) AS
SELECT
    COALESCE(
        ex.user_id, s.user_id
) AS user_id,
    COALESCE(
        ex.day, s.day
) AS day,
    COALESCE(
        ex.context_id, s.context_id
) AS context_id,
    ex.type,
    COALESCE(
        COALESCE(
            ex.events, 0
) + COALESCE(
            s.events, 0
)
) AS events,
    COALESCE(
        COALESCE(
            ex.seconds, 0
) + COALESCE(
            s.seconds, 0
)
) AS seconds
FROM (
    SELECT
        user_id,
        day,
        context_id,
        'accepted' AS type,
        COALESCE(
            count(
                *
) FILTER ( WHERE response != 'declined'
            AND response != 'tentative'
            AND response IS NOT NULL), 0) AS events,
        COALESCE(sum(seconds) FILTER (WHERE response != 'declined'
                AND response != 'tentative'
                AND response IS NOT NULL), 0) AS seconds
    FROM
        event_x
    WHERE
        status != 'cancelled'
        AND all_day = FALSE
    GROUP BY
        user_id,
        day,
        context_id
    UNION ALL
    SELECT
        user_id,
        day,
        context_id,
        'tentative' AS type,
        COALESCE(count(*) FILTER (WHERE response = 'tentative'
                OR response IS NULL), 0) AS events,
        COALESCE(sum(seconds) FILTER (WHERE response = 'tentative'
                OR response IS NULL), 0) AS seconds
    FROM
        event_x
    WHERE
        status != 'cancelled'
        AND all_day = FALSE
    GROUP BY
        user_id,
        day,
        context_id
    UNION ALL
    SELECT
        user_id,
        day,
        context_id,
        'declined' AS type,
        COALESCE(count(*) FILTER (WHERE response = 'declined'), 0) AS events,
        COALESCE(sum(seconds) FILTER (WHERE response = 'declined'), 0) AS seconds
    FROM
        event_x
    WHERE
        status != 'cancelled'
        AND all_day = FALSE
    GROUP BY
        user_id,
        day,
        context_id
) AS ex
    FULL JOIN (
        SELECT
            user_id,
            (lower(at) at time zone user_timezone ())::date AS day,
            context_id,
            'accepted' AS type,
            count(*) AS events,
            sum(EXTRACT(epoch FROM upper(at) - lower(at)) / 60)::integer AS seconds
        FROM
            session
        GROUP BY
            user_id,
            day,
            context_id) AS s ON ex.user_id = s.user_id
    AND ex.day = s.day
    AND ex.context_id = s.context_id
    AND ex.type = s.type;

