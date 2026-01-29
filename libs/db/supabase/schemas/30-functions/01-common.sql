CREATE OR REPLACE FUNCTION update_updated_at ()
    RETURNS TRIGGER
    AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.set_created_at ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    NEW.created_at = now();
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION update_created_by ()
    RETURNS TRIGGER
    AS $$
BEGIN
    NEW.created_by = COALESCE(auth.uid (), NEW.created_by);
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;

