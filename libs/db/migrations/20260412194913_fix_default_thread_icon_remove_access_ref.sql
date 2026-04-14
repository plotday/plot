-- Modify "apply_default_thread_icon" function
CREATE OR REPLACE FUNCTION "public"."apply_default_thread_icon" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_default_icon text;
BEGIN
    -- Apply when icon is unset or is a default sub-type auto-assigned by the app
    IF (NEW.icon IS NULL OR NEW.icon IN ('notes', 'discussion')) AND NEW.draft = FALSE THEN
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
