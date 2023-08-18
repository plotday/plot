CREATE OR REPLACE FUNCTION public.link_account_to_domain ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
BEGIN
    IF NEW.email IS NULL THEN
        RETURN NEW;
    END IF;
    UPDATE
        public.account
    SET
        domain_id = (
            SELECT
                public.get_or_create_domain_id (NEW.email))
    WHERE
        id = NEW.id;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.link_contact_to_domain ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
BEGIN
    IF NEW.email IS NOT NULL THEN
        NEW.domain_id = (
            SELECT
                public.get_or_create_domain_id (NEW.email));
    END IF;
    RETURN NEW;
END
$function$;

CREATE TRIGGER on_account_created
    AFTER INSERT ON public.account
    FOR EACH ROW
    EXECUTE FUNCTION link_account_to_domain ();

CREATE TRIGGER on_contact_created
    BEFORE INSERT ON public.contact
    FOR EACH ROW
    EXECUTE FUNCTION link_contact_to_domain ();

