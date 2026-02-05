SET ROLE "postgres";
SET check_function_bodies = false;
CREATE FUNCTION public.contact_clear_primary_on_unlink()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.user_id IS NULL AND OLD.user_id IS NOT NULL AND NEW."primary" = true THEN
        NEW."primary" := false;
    END IF;
    RETURN NEW;
END;
$function$;
CREATE TRIGGER on_contact_user_unlinked BEFORE UPDATE ON public.contact FOR EACH ROW WHEN (old.user_id IS NOT NULL AND new.user_id IS NULL) EXECUTE FUNCTION public.contact_clear_primary_on_unlink();
REVOKE EXECUTE ON FUNCTION public.contact_clear_primary_on_unlink () FROM PUBLIC;
