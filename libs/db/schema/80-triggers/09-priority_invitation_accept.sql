-- Function to auto-accept pending invitations when a user creates an account
CREATE OR REPLACE FUNCTION public.accept_invitations_on_signup ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
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
        -- Create priority_user entries for pending invitations
        INSERT INTO public.priority_user (user_id, priority_id)
        SELECT
            NEW.id,
            pi.priority_id
        FROM
            public.priority_invitation pi
        WHERE
            pi.contact_id = v_contact_id
            AND pi.archived_at IS NULL
        ON CONFLICT
            DO NOTHING;
        -- Archive the invitations
        UPDATE
            public.priority_invitation
        SET
            archived_at = now()
        WHERE
            contact_id = v_contact_id
            AND archived_at IS NULL;
        -- Activate the user (creates root priority, settings, sets status to active)
        -- This is idempotent and safe to call multiple times
        PERFORM
            public.activate_invited_user (NEW.id);
    END IF;
    RETURN NEW;
END;
$function$;

-- Create trigger that runs after user is created (after contact sync)
-- Using AFTER trigger since we need the contact to exist first
CREATE TRIGGER accept_invitations_after_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.accept_invitations_on_signup ();

-- Restrict access: only service_role can call this function
REVOKE EXECUTE ON FUNCTION public.accept_invitations_on_signup () FROM PUBLIC;

