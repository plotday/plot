CREATE OR REPLACE FUNCTION tstzrange_to_daterange (p_range tstzrange, p_timezone text DEFAULT 'UTC')
    RETURNS daterange
    LANGUAGE plpgsql
    IMMUTABLE
    AS $$
BEGIN
    RETURN daterange((lower(p_range) AT TIME ZONE p_timezone)::date, (upper(p_range) AT TIME ZONE p_timezone)::date,
    -- preserve inclusive/exclusive bounds of original p_range
    CASE WHEN lower_inc(p_range)
        AND upper_inc(p_range) THEN
        '[]'
    WHEN lower_inc(p_range) THEN
        '[)'
    WHEN upper_inc(p_range) THEN
        '(]'
    ELSE
        '()'
    END)::daterange;
END;
$$;

