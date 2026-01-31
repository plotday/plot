-- Get or create an invitation token for a contact.
-- Returns the token, sent_at timestamp, and whether it's a new token.
-- The API decides whether to send based on the sent_at timestamp.
CREATE OR REPLACE FUNCTION public.get_invitation_token (
    p_contact_id uuid,
    p_new_token text
)
    RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_token text;
    v_sent_at timestamptz;
BEGIN
    -- Check if invitation already exists
    SELECT
        token,
        sent_at INTO v_token,
        v_sent_at
    FROM
        public.contact_invitation
    WHERE
        contact_id = p_contact_id;
    IF v_token IS NOT NULL THEN
        -- Return existing token and sent_at
        RETURN jsonb_build_object('token', v_token, 'sent_at', v_sent_at, 'is_new', FALSE);
    END IF;
    -- Create new invitation with provided token
    INSERT INTO public.contact_invitation (contact_id, token, sent_at)
        VALUES (p_contact_id, p_new_token, now())
    RETURNING
        token, sent_at INTO v_token, v_sent_at;
    RETURN jsonb_build_object('token', v_token, 'sent_at', v_sent_at, 'is_new', TRUE);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.get_invitation_token (uuid, text) FROM PUBLIC;

-- Update the sent_at timestamp after sending an email for an existing invitation.
CREATE OR REPLACE FUNCTION public.update_invitation_sent_at (
    p_contact_id uuid
)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
BEGIN
    UPDATE
        public.contact_invitation
    SET
        sent_at = now()
    WHERE
        contact_id = p_contact_id;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.update_invitation_sent_at (uuid) FROM PUBLIC;

-- Redeem an invitation token after a user signs up or signs in.
-- Links the contact to the user, accepts pending priority invitations,
-- and deletes the token (one-time use).
CREATE OR REPLACE FUNCTION public.redeem_invitation_token (
    p_user_id uuid,
    p_token text
)
    RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_contact_id uuid;
    v_contact_user_id uuid;
    v_redeemed_by uuid;
BEGIN
    -- Find contact_invitation with this token
    SELECT
        ci.contact_id,
        ci.redeemed_by,
        c.user_id INTO v_contact_id,
        v_redeemed_by,
        v_contact_user_id
    FROM
        public.contact_invitation ci
        JOIN public.contact c ON c.id = ci.contact_id
    WHERE
        ci.token = p_token;
    IF v_contact_id IS NULL THEN
        RETURN jsonb_build_object('success', FALSE, 'error', 'invalid_token');
    END IF;
    -- Check if already redeemed
    IF v_redeemed_by IS NOT NULL THEN
        IF v_redeemed_by = p_user_id THEN
            -- Same user re-clicking - return success (idempotent)
            RETURN jsonb_build_object('success', TRUE, 'already_redeemed', TRUE, 'contact_id', v_contact_id);
        ELSE
            -- Different user attempting to use redeemed token
            RETURN jsonb_build_object('success', FALSE, 'error', 'already_redeemed_by_different_user');
        END IF;
    END IF;
    -- Check if contact already linked to a DIFFERENT user
    IF v_contact_user_id IS NOT NULL AND v_contact_user_id != p_user_id THEN
        RETURN jsonb_build_object('success', FALSE, 'error', 'contact_linked_to_other_user');
    END IF;
    -- Link contact to user (if not already linked)
    UPDATE
        public.contact
    SET
        user_id = p_user_id
    WHERE
        id = v_contact_id
        AND (user_id IS NULL
            OR user_id = p_user_id);
    -- Mark invitation as redeemed instead of deleting
    UPDATE
        public.contact_invitation
    SET
        redeemed_at = now(),
        redeemed_by = p_user_id
    WHERE
        contact_id = v_contact_id;
    -- Accept any pending invitations for this contact (from priority_contact)
    INSERT INTO public.priority_user (user_id, priority_id)
    SELECT
        p_user_id,
        pc.priority_id
    FROM
        public.priority_contact pc
    WHERE
        pc.contact_id = v_contact_id
        AND pc.invited_at IS NOT NULL
    ON CONFLICT
        DO NOTHING;
    -- Note: priority_contact remains - status changes from 'invited' to 'accepted' in priority_member view
    -- Activate the user (creates root priority, settings, sets status to active)
    -- This is idempotent and safe to call multiple times
    PERFORM
        public.activate_invited_user (p_user_id);
    RETURN jsonb_build_object('success', TRUE, 'already_redeemed', FALSE, 'contact_id', v_contact_id);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.redeem_invitation_token (uuid, text) FROM PUBLIC;
