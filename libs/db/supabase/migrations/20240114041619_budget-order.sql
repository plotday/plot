SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.budget_week (user_id uuid, week daterange)
    RETURNS TABLE (
        activity_id bigint,
        "order" text,
        budget integer)
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN QUERY
    SELECT
        b.activity_id,
        COALESCE(b.order, b2.order) AS "order",
        COALESCE(b.budget, b2.budget) AS budget
    FROM (
        SELECT
            *
        FROM
            budget bi
        WHERE
            bi.user_id = budget_week.user_id
            AND bi.week && budget_week.week) b
    FULL OUTER JOIN (
    SELECT
        *
    FROM
        budget bi
    WHERE
        bi.user_id = budget_week.user_id
        AND bi.week IS NULL) b2 ON b.activity_id = b2.activity_id
ORDER BY
    coalesce(b.order, b2.order);
END;
$function$;

CREATE OR REPLACE FUNCTION public.is_week (p_week daterange)
    RETURNS boolean
    LANGUAGE plpgsql
    IMMUTABLE
    AS $function$
BEGIN
    RETURN p_week IS NULL
        OR EXTRACT(DOW FROM lower(p_week)) = 0
        AND upper(p_week) - lower(p_week) = 7;
END;
$function$;

