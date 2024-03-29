CREATE OR REPLACE FUNCTION priorities_for_week (user_id uuid, week daterange)
    RETURNS TABLE (
        activity_id bigint,
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
        a.id AS activity_id,
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
            id
        FROM
            activity a
        WHERE
            a.user_id = priorities_for_week.user_id
        UNION ALL
        SELECT
            NULL AS id) AS a
    LEFT JOIN ( SELECT DISTINCT ON (p.activity_id)
            p.activity_id,
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
            p.activity_id,
            p.week DESC) AS b ON (b.activity_id = a.id
            OR (b.activity_id IS NULL
                AND a.id IS NULL))
        LEFT JOIN ( SELECT DISTINCT ON (p.activity_id)
                p.activity_id,
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
                p.activity_id,
                p.week DESC) AS o ON (o.activity_id = a.id
                OR (b.activity_id IS NULL
                    AND a.id IS NULL))
            LEFT JOIN (
                SELECT
                    *
                FROM
                    expenditure_weekly e
                WHERE
                    e.user_id = priorities_for_week.user_id
                    AND e.week && priorities_for_week.week) AS e ON (e.activity_id = a.id
                    OR (b.activity_id IS NULL
                        AND a.id IS NULL));
END;
$$
LANGUAGE plpgsql;

