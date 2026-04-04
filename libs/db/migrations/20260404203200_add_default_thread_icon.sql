-- Modify "priority" table
ALTER TABLE "public"."priority" ADD COLUMN "default_thread_icon" text NULL;
-- Create "apply_default_thread_icon" function
CREATE FUNCTION "public"."apply_default_thread_icon" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_default_icon text;
BEGIN
    IF NEW.icon IS NULL AND NEW.private = FALSE THEN
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
-- Create trigger "apply_default_thread_icon_trigger"
CREATE TRIGGER "apply_default_thread_icon_trigger" BEFORE INSERT ON "public"."thread" FOR EACH ROW EXECUTE FUNCTION "public"."apply_default_thread_icon"();
-- Set default_thread_icon for @plot.app priority
UPDATE priority
SET default_thread_icon = 'https://plot.day/assets/plot-icon.svg'
WHERE key = '@plot.app';
-- Retroactively set icon on existing onboarding threads
UPDATE thread
SET icon = 'https://plot.day/assets/plot-icon.svg'
WHERE priority_id IN (SELECT id FROM priority WHERE key = '@plot.app')
  AND icon IS NULL
  AND private = FALSE;
