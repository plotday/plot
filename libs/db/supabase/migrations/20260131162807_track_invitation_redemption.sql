SET ROLE "postgres";
SET check_function_bodies = false;
DROP INDEX public.idx_contact_invitation_token;
CREATE OR REPLACE FUNCTION public.redeem_invitation_token(p_user_id uuid, p_token text)
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
ALTER TABLE public.contact_invitation ADD COLUMN redeemed_at timestamp with time zone;
ALTER TABLE public.contact_invitation ADD COLUMN redeemed_by uuid;
ALTER TABLE public.contact_invitation ADD CONSTRAINT contact_invitation_redeemed_by_fkey FOREIGN KEY (redeemed_by) REFERENCES auth.users(id) ON DELETE SET NULL;
CREATE INDEX idx_contact_invitation_token_redeemed ON public.contact_invitation (token, redeemed_at);
CREATE OR REPLACE TRIGGER set_activity_source_priority_root_trigger BEFORE INSERT OR UPDATE OF source, priority_id ON public.activity FOR EACH ROW EXECUTE FUNCTION public.set_activity_source_priority_root();
CREATE OR REPLACE TRIGGER update_activity_last_note_created_at_on_status_change AFTER UPDATE OF draft, archived_at ON public.note FOR EACH ROW WHEN (old.draft IS DISTINCT FROM new.draft OR old.archived_at IS DISTINCT FROM new.archived_at) EXECUTE FUNCTION public.update_activity_on_note_change();

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
