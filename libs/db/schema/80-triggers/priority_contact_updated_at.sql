CREATE TRIGGER set_priority_contact_updated_at
    BEFORE UPDATE ON public.priority_contact
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();
