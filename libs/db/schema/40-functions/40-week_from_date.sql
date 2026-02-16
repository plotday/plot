CREATE OR REPLACE FUNCTION week_from_date (d date)
    RETURNS daterange
    AS $$
    SELECT
        CASE WHEN d IS NULL THEN
            NULL
        ELSE
            daterange(date_bin ('7 days', d, '2023-1-1'::date)::date, date_bin ('7 days', d, '2023-1-1'::date)::date + 7, '[)'::text)
        END
$$
LANGUAGE sql
STABLE;

