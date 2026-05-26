-- When contact_external_account rows are inserted, updated, or deleted,
-- bump the parent contact's updated_at so the actor sync picks up the change.
-- This ensures the aggregated external_accounts column in user.actor re-syncs
-- to Flutter clients whenever messaging account mappings change.
CREATE OR REPLACE FUNCTION bump_contact_updated_at_from_cea ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
BEGIN
    UPDATE contact
    SET updated_at = now()
    WHERE id IN (SELECT DISTINCT contact_id FROM new_table);
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION bump_contact_updated_at_from_cea_delete ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
BEGIN
    UPDATE contact
    SET updated_at = now()
    WHERE id IN (SELECT DISTINCT contact_id FROM old_table);
    RETURN NULL;
END;
$function$;

CREATE TRIGGER contact_external_account_bump_contact_insert
    AFTER INSERT ON contact_external_account
    REFERENCING NEW TABLE AS new_table
    FOR EACH STATEMENT
    EXECUTE FUNCTION bump_contact_updated_at_from_cea ();

CREATE TRIGGER contact_external_account_bump_contact_update
    AFTER UPDATE ON contact_external_account
    REFERENCING NEW TABLE AS new_table
    FOR EACH STATEMENT
    EXECUTE FUNCTION bump_contact_updated_at_from_cea ();

CREATE TRIGGER contact_external_account_bump_contact_delete
    AFTER DELETE ON contact_external_account
    REFERENCING OLD TABLE AS old_table
    FOR EACH STATEMENT
    EXECUTE FUNCTION bump_contact_updated_at_from_cea_delete ();
