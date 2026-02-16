-- Function to auto-accept pending invitations and set up user on signup
CREATE OR REPLACE FUNCTION public.accept_invitations_on_signup ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_contact_id uuid;
BEGIN
    -- Get the contact_id for this user (by email)
    SELECT
        id INTO v_contact_id
    FROM
        public.contact
    WHERE
        email = NEW.email
        AND archived_at IS NULL;
    IF v_contact_id IS NOT NULL THEN
        -- Create priority_user entries for pending invitations (from priority_contact)
        INSERT INTO public.priority_user (user_id, priority_id)
        SELECT
            NEW.id,
            pc.priority_id
        FROM
            public.priority_contact pc
        WHERE
            pc.contact_id = v_contact_id
            AND pc.invited_at IS NOT NULL
        ON CONFLICT
            DO NOTHING;
        -- Note: priority_contact remains - status changes from 'invited' to 'accepted' in priority_member view
    END IF;
    -- Always set up the user with root priority and settings
    PERFORM
        public.activate_invited_user (NEW.id);
    RETURN NEW;
END;
$function$;

-- Create trigger that runs after user is created (after contact sync)
CREATE TRIGGER accept_invitations_after_user_created
    AFTER INSERT ON public."user"
    FOR EACH ROW
    EXECUTE FUNCTION public.accept_invitations_on_signup ();
