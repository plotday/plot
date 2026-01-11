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
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_expanded" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);

-- Add SECURITY DEFINER to get_primary_contact_id function to allow access to auth.users
CREATE OR REPLACE FUNCTION public.get_primary_contact_id (p_user_id uuid)
    RETURNS uuid
    AS $$
DECLARE
    v_preferred_contact_id uuid;
    v_contact_id uuid;
    v_user_email text;
BEGIN
    -- Get user's email and preferred contact_id from app_metadata
    SELECT
        LOWER(email),
        (raw_app_meta_data ->> 'contact_id')::uuid INTO v_user_email,
        v_preferred_contact_id
    FROM
        auth.users
    WHERE
        id = p_user_id;
    -- If user has a preferred contact_id in app_metadata, validate and return it
    IF v_preferred_contact_id IS NOT NULL THEN
        SELECT
            id INTO v_contact_id
        FROM
            contact
        WHERE
            id = v_preferred_contact_id
            AND user_id = p_user_id;
        IF v_contact_id IS NOT NULL THEN
            RETURN v_contact_id;
        END IF;
    END IF;
    -- Fall back to finding contact by matching email
    IF v_user_email IS NOT NULL THEN
        SELECT
            id INTO v_contact_id
        FROM
            contact
        WHERE
            email = v_user_email
            AND user_id = p_user_id;
        RETURN v_contact_id;
    END IF;
    -- No match found
    RETURN NULL;
END;
$$
LANGUAGE plpgsql
STABLE
SECURITY DEFINER;

-- Add SECURITY DEFINER to get_priority_twist_owner_contact function
CREATE OR REPLACE FUNCTION public.get_priority_twist_owner_contact (p_priority_twist_id uuid)
    RETURNS uuid
    AS $$
    SELECT
        public.get_primary_contact_id(pt.owner_id)
    FROM
        priority_twist pt
    WHERE
        pt.id = p_priority_twist_id;
$$
LANGUAGE sql
STABLE
SECURITY DEFINER;
