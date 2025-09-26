CREATE OR REPLACE FUNCTION count_not_null (val anyelement)
    RETURNS integer
    LANGUAGE SQL
    IMMUTABLE
    AS $$
    SELECT
        CASE WHEN val IS NULL THEN
            0
        ELSE
            1
        END;
$$;

