-- Trigger to broadcast actor sync when priority_contact entries are added
-- Uses FOR EACH STATEMENT for efficient batch processing
CREATE TRIGGER broadcast_priority_contact_insert
    AFTER INSERT ON priority_contact
    REFERENCING NEW TABLE AS new_priority_contacts
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.broadcast_priority_contact_sync ();
