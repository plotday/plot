SET ROLE "postgres";
SET check_function_bodies = false;
CREATE FUNCTION public.accept_invitations_on_contact_linked()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
BEGIN
    INSERT INTO public.priority_user (user_id, priority_id)
    SELECT
        NEW.user_id,
        pc.priority_id
    FROM
        public.priority_contact pc
    WHERE
        pc.contact_id = NEW.id
        AND pc.invited_at IS NOT NULL
    ON CONFLICT
        DO NOTHING;
    PERFORM
        public.activate_invited_user (NEW.user_id);
    RETURN NEW;
END;
$function$;
CREATE TRIGGER on_contact_user_linked AFTER UPDATE ON public.contact FOR EACH ROW WHEN (old.user_id IS NULL AND new.user_id IS NOT NULL) EXECUTE FUNCTION public.accept_invitations_on_contact_linked();
REVOKE EXECUTE ON FUNCTION public.accept_invitations_on_contact_linked () FROM PUBLIC;

-- Data migration: fix existing broken invitations where contact is linked
-- but priority_user entry was never created
INSERT INTO public.priority_user (user_id, priority_id)
SELECT c.user_id, pc.priority_id
FROM public.priority_contact pc
JOIN public.contact c ON c.id = pc.contact_id
WHERE c.user_id IS NOT NULL
  AND c.archived_at IS NULL
  AND pc.invited_at IS NOT NULL
ON CONFLICT (user_id, priority_id) DO NOTHING;
