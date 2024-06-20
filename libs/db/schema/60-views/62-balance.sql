CREATE OR REPLACE FUNCTION balance (user_id uuid, week daterange)
    RETURNS TABLE (
        id bigint,
        budget int,
        "budget_type" budget_type,
        count int,
        minutes int,
        tentative_count int,
        tentative_minutes int,
        declined_count int,
        declined_minutes int
    )
    AS $$
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
            c.user_id = priorities_for_week.user_id
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
            b.user_id = priorities_for_week.user_id
            AND b.budget IS NOT NULL
            AND b.week <= priorities_for_week.week
            AND (b.type = 'default'
                OR b.week && priorities_for_week.week)
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
                e.user_id = priorities_for_week.user_id
                AND e.week && priorities_for_week.week) AS e ON (e.context_id = c.id
                OR (b.context_id IS NULL
                    AND c.id IS NULL));
END;
$$
LANGUAGE plpgsql;

