-- Runs on user signup. In the per-user model priority sharing via
-- priority_contact / priority_user is gone, so the only remaining job
-- is to make sure the new user has a root priority by calling
-- activate_invited_user. Cross-user visibility now flows through
-- thread.contacts + user_contact.
CREATE OR REPLACE FUNCTION public.accept_invitations_on_signup ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
BEGIN
    PERFORM public.activate_invited_user (NEW.id);
    RETURN NEW;
END;
$function$;

CREATE TRIGGER accept_invitations_after_user_created
    AFTER INSERT ON public."user"
    FOR EACH ROW
    EXECUTE FUNCTION public.accept_invitations_on_signup ();
