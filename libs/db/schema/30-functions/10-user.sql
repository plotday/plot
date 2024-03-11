CREATE OR REPLACE FUNCTION user_timezone ()
    RETURNS text
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN COALESCE((auth.jwt () -> 'app_metadata' -> 'timezone')::text, 'America/New_York');
END;
$$;

CREATE OR REPLACE FUNCTION is_lower (text)
    RETURNS boolean
    LANGUAGE 'plpgsql'
    IMMUTABLE
    AS $$
BEGIN
    RETURN $1 = lower($1);
END;
$$;

