ALTER VIEW "public"."user_note" SET ( security_invoker = TRUE);
ALTER VIEW "public"."note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_twist" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_exception" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_activity_update" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_note_create" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_activity_create" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_note_update" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_expanded" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_activity_tag_change" SET ( security_invoker = TRUE);
ALTER VIEW public.priority_member SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);

-- Fix auto-activation bug: only activate users with pending invitations
CREATE OR REPLACE FUNCTION public.accept_invitations_on_signup ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $function$
DECLARE
    v_contact_id uuid;
    v_invitation_count integer := 0;
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
        -- Get count of how many invitations were processed
        GET DIAGNOSTICS v_invitation_count = ROW_COUNT;
        -- Note: priority_contact remains - status changes from 'invited' to 'accepted' in priority_member view
        -- Only activate if user had pending invitations
        -- This prevents auto-activation for users with contact records but no invitations
        IF v_invitation_count > 0 THEN
            -- Activate the user (creates root priority, settings, sets status to active)
            -- This is idempotent and safe to call multiple times
            PERFORM
                public.activate_invited_user (NEW.id);
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;
