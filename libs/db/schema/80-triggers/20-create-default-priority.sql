CREATE FUNCTION public.create_default_priority ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = ''
    AS $$
DECLARE
    priority_id bigint;
BEGIN
    INSERT INTO "public"."priority" ("name", "path", "created_by")
        VALUES ('Personal', generate_path (), NEW.id)
    RETURNING
        id INTO priority_id;
    INSERT INTO "public"."priority_user" ("user_id", "priority_id")
        VALUES (NEW.id, priority_id);
    INSERT INTO "public"."priority_settings" ("user_id", "priority_id", "order", "is_default")
        VALUES (NEW.id, priority_id, 0, TRUE);
    RETURN new;
END;
$$;

CREATE TRIGGER create_default_priority_on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE PROCEDURE public.create_default_priority ();

