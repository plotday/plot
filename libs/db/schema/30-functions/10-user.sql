CREATE OR REPLACE FUNCTION user_timezone ()
    RETURNS text
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN COALESCE((auth.jwt () -> 'app_metadata' -> 'timezone')::text, 'America/New_York');
END;
$$;

