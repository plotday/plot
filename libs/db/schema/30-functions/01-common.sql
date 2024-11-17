CREATE OR REPLACE FUNCTION update_modified_at ()
    RETURNS TRIGGER
    AS $$
BEGIN
    NEW.modified_at = now();
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION update_created_by ()
    RETURNS TRIGGER
    AS $$
BEGIN
    NEW.created_by = auth.uid ();
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

