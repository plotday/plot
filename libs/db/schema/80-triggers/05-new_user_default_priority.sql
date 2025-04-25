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
    INSERT INTO public.priority_settings (user_id, priority_id, is_default)
        VALUES (NEW.id, _priority_id, TRUE);
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;

CREATE TRIGGER on_user_created_add_default_priority
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.add_default_priority ();

