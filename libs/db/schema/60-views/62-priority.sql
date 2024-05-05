CREATE OR REPLACE FUNCTION priorities_for_week (user_id uuid, week daterange)
    RETURNS TABLE (
        id bigint,
        budget int,
        "budget_type" budget_type,
        "order" text,
        order_type budget_type,
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
        o.order,
        o.order_type,
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
    LEFT JOIN ( SELECT DISTINCT ON (p.context_id)
            p.context_id,
            p.budget,
            p.type AS budget_type
        FROM
            priority p
        WHERE
            p.user_id = priorities_for_week.user_id
            AND p.budget IS NOT NULL
            AND p.week <= priorities_for_week.week
            AND (p.type = 'default'
                OR p.week && priorities_for_week.week)
        ORDER BY
            p.context_id,
            p.week DESC) AS b ON (b.context_id = c.id
            OR (b.context_id IS NULL
                AND c.id IS NULL))
        LEFT JOIN ( SELECT DISTINCT ON (p.context_id)
                p.context_id,
                p.order,
                p.type AS order_type
            FROM
                priority p
            WHERE
                p.user_id = priorities_for_week.user_id
                AND p.order IS NOT NULL
                AND p.week <= priorities_for_week.week
                AND (p.type = 'default'
                    OR p.week && priorities_for_week.week)
            ORDER BY
                p.context_id,
                p.week DESC) AS o ON (o.context_id = c.id
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

