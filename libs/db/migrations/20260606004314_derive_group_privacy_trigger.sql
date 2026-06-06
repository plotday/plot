-- Create "derive_group_privacy" function
CREATE FUNCTION "public"."derive_group_privacy" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.type = 'announce' THEN
        NEW.privacy := 'private';
    ELSE
        -- Only set open if caller left it at the column default or if type changed
        -- away from announce. Explicit admin override (future) can set privacy
        -- independently, but for now type drives the value.
        IF NEW.privacy = 'private' AND NEW.type != 'announce' THEN
            NEW.privacy := 'open';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
-- Create trigger "derive_group_privacy"
CREATE TRIGGER "derive_group_privacy" BEFORE INSERT OR UPDATE OF "type" ON "public"."group" FOR EACH ROW EXECUTE FUNCTION "public"."derive_group_privacy"();
