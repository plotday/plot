CREATE OR REPLACE FUNCTION update_modified_at ()
    RETURNS TRIGGER
    AS $$
BEGIN
    NEW.modified_at = now();
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;

