CREATE OR REPLACE FUNCTION is_lower (text)
    RETURNS boolean
    LANGUAGE 'plpgsql'
    IMMUTABLE
    AS $$
BEGIN
    RETURN $1 = lower($1);
END;
$$;
