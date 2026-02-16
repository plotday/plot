-- Get the primary contact ID for a user
-- Priority: 1) primary column, 2) email match with public."user"
CREATE OR REPLACE FUNCTION public.get_primary_contact_id (p_user_id uuid)
    RETURNS uuid
    AS $$
DECLARE
    v_contact_id uuid;
    v_user_email text;
BEGIN
    -- Check for contact marked as primary
    SELECT
        id INTO v_contact_id
    FROM
        contact
    WHERE
        user_id = p_user_id
        AND "primary" = true;
    IF v_contact_id IS NOT NULL THEN
        RETURN v_contact_id;
    END IF;
    -- Get user's email from public."user"
    SELECT
        LOWER(email) INTO v_user_email
    FROM
        public."user"
    WHERE
        id = p_user_id;
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
STABLE;
