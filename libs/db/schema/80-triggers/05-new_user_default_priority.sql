CREATE OR REPLACE FUNCTION public.add_default_priority ()
    RETURNS TRIGGER
    SECURITY DEFINER
    SET search_path = public, auth
    AS $$
DECLARE
    _priority_id uuid;
BEGIN
    INSERT INTO public.priority (created_by, name, path)
        VALUES (NEW.id, 'Personal', public.generate_path (NULL))
    RETURNING
        id INTO _priority_id;
    UPDATE
        public.priority_user
    SET
        is_default = TRUE
    WHERE
        user_id = NEW.id
        AND priority_id = _priority_id;
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;

CREATE TRIGGER on_user_created_add_default_priority
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.add_default_priority ();

