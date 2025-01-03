CREATE OR REPLACE FUNCTION public.insert_email_domain ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
BEGIN
    IF NEW.email IS NULL THEN
        RETURN NEW;
    END IF;
    PERFORM
        public.insert_domain (NEW.email);
    RETURN NEW;
END;
$function$;

CREATE TRIGGER on_account_created
    AFTER INSERT ON public.account
    FOR EACH ROW
    EXECUTE FUNCTION insert_email_domain ();

CREATE TRIGGER on_contact_created
    AFTER INSERT ON public.contact
    FOR EACH ROW
    EXECUTE FUNCTION insert_email_domain ();

CREATE TRIGGER on_invitee_created
    AFTER INSERT ON public.invitee
    FOR EACH ROW
    EXECUTE FUNCTION insert_email_domain ();

