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
DECLARE
    seed_mode text;
BEGIN
    -- Check if plot.seed_mode is set (for seed scripts only)
    seed_mode := current_setting('plot.seed_mode', TRUE);
    IF seed_mode IS NOT NULL AND NEW.created_at IS NOT NULL THEN
        -- Seed mode: preserve the provided created_at timestamp
        RETURN NEW;
    ELSE
        -- Normal mode: set created_at to current time
        NEW.created_at = now();
        RETURN NEW;
    END IF;
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

