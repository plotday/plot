-- Get the primary contact ID for a user
-- Priority: 1) app_metadata contact_id preference, 2) email match with auth.users
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
