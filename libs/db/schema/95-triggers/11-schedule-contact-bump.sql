-- When schedule_contact rows are inserted or updated, bump the parent schedule's updated_at
-- so that the schedule sync picks up the change.
CREATE OR REPLACE FUNCTION bump_schedule_updated_at ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
BEGIN
    UPDATE schedule
    SET updated_at = now()
    WHERE id IN (SELECT DISTINCT schedule_id FROM new_table);
    RETURN NULL;
END;
$function$;

CREATE TRIGGER schedule_contact_bump_schedule_insert
    AFTER INSERT ON schedule_contact
    REFERENCING NEW TABLE AS new_table
    FOR EACH STATEMENT
    EXECUTE FUNCTION bump_schedule_updated_at ();

CREATE TRIGGER schedule_contact_bump_schedule_update
    AFTER UPDATE ON schedule_contact
    REFERENCING NEW TABLE AS new_table
    FOR EACH STATEMENT
    EXECUTE FUNCTION bump_schedule_updated_at ();
