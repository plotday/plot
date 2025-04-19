CREATE OR REPLACE FUNCTION public.add_default_priority ()
    RETURNS TRIGGER
    SECURITY DEFINER
    SET search_path = public, auth
    AS $$
DECLARE
    _priority_id uuid;
BEGIN
    RAISE LOG 'Inserting into priority table for user_id: %', NEW.id;
    INSERT INTO public.priority (created_by, name, path)
        VALUES (NEW.id, 'Personal', public.generate_path (NULL))
    RETURNING
        id INTO _priority_id;
    RAISE LOG 'Inserted priority_id: %', _priority_id;
    INSERT INTO public.priority_settings (user_id, priority_id, "order", is_default)
        VALUES (NEW.id, _priority_id, public.order_first (), TRUE);
    RAISE LOG 'Inserted priority_settings for priority_id: %', _priority_id;
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;

CREATE TRIGGER on_user_created_add_default_priority
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.add_default_priority ();

