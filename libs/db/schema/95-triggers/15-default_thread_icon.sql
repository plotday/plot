CREATE OR REPLACE FUNCTION public.apply_default_thread_icon ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_default_icon text;
BEGIN
    -- Apply when icon is unset or is a default sub-type auto-assigned by the app
    IF (NEW.icon IS NULL OR NEW.icon IN ('notes', 'discussion')) AND NEW.private = FALSE THEN
        SELECT
            default_thread_icon INTO v_default_icon
        FROM
            priority
        WHERE
            id = NEW.priority_id;
        IF v_default_icon IS NOT NULL THEN
            NEW.icon := v_default_icon;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER apply_default_thread_icon_trigger
    BEFORE INSERT ON "public"."thread"
    FOR EACH ROW
    EXECUTE FUNCTION apply_default_thread_icon ();
