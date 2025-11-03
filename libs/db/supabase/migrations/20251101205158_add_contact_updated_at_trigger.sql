CREATE TRIGGER set_contact_updated_at
    BEFORE UPDATE ON public.contact
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

