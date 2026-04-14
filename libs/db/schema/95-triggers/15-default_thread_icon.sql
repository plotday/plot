-- Apply default thread icon from the priority's default_thread_icon setting.
-- Since thread no longer has priority_id (per-user filing via thread_priority),
-- this trigger is a no-op. Default icons are applied by the API layer instead.
CREATE OR REPLACE FUNCTION public.apply_default_thread_icon ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN NEW;
END;
$$;

CREATE TRIGGER apply_default_thread_icon_trigger
    BEFORE INSERT ON "public"."thread"
    FOR EACH ROW
    EXECUTE FUNCTION apply_default_thread_icon ();
