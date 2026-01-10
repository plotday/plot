SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.set_activity_order_on_start ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    -- If activity has a start time (at or on) but no explicit order,
    -- set order to current timestamp for stable sorting
    IF (NEW.at IS NOT NULL OR NEW. "on" IS NOT NULL) AND NEW. "order" IS NULL THEN
        NEW. "order" := public.order_first ();
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER set_activity_order_on_start_trigger
    BEFORE INSERT OR UPDATE ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION set_activity_order_on_start ();

