SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.balance (user_id uuid, week daterange)
    RETURNS TABLE (
        id bigint,
        budget integer,
        budget_type budget_type,
        count integer,
        minutes integer,
        tentative_count integer,
        tentative_minutes integer,
        declined_count integer,
        declined_minutes integer)
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN QUERY
    SELECT
        c.id,
        b.budget,
        b.budget_type,
        COALESCE(e.count, 0)::int AS count,
        COALESCE(e.minutes, 0)::int AS minutes,
        COALESCE(e.tentative_count, 0)::int AS tentative_count,
        COALESCE(e.tentative_minutes, 0)::int AS tentative_minutes,
        COALESCE(e.declined_count, 0)::int AS declined_count,
        COALESCE(e.declined_minutes, 0)::int AS declined_minutes
    FROM (
        SELECT
            c.id
        FROM
            context c
        WHERE
            c.user_id = balance.user_id
            -- Include uncategorized events
        UNION ALL
        SELECT
            NULL AS id) AS c
    LEFT JOIN ( SELECT DISTINCT ON (b.context_id)
            b.context_id,
            b.budget,
            b.type AS budget_type
        FROM
            priority b
        WHERE
            b.user_id = balance.user_id
            AND b.budget IS NOT NULL
            AND b.week <= balance.week
            AND (b.type = 'default'
                OR b.week && balance.week)
        ORDER BY
            b.context_id,
            b.week DESC) AS b ON (b.context_id = c.id
            OR (b.context_id IS NULL
                AND c.id IS NULL))
        LEFT JOIN (
            SELECT
                *
            FROM
                expenditure_weekly e
            WHERE
                e.user_id = balance.user_id
                AND e.week && balance.week) AS e ON (e.context_id = c.id
                OR (b.context_id IS NULL
                    AND c.id IS NULL));
END;
$function$;

