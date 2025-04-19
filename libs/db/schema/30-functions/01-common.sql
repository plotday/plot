CREATE OR REPLACE FUNCTION update_updated_at ()
    RETURNS TRIGGER
    AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION update_created_by ()
    RETURNS TRIGGER
    AS $$
BEGIN
    NEW.created_by = COALESCE(auth.uid (), NEW.created_by);
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION server_timestamp ()
    RETURNS timestamptz
    AS $$
BEGIN
    RETURN now();
END;
$$
LANGUAGE plpgsql;

