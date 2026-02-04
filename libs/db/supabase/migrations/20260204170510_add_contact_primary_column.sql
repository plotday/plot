SET ROLE "postgres";
SET check_function_bodies = false;
CREATE OR REPLACE FUNCTION public.get_primary_contact_id(p_user_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
    v_preferred_contact_id uuid;
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
$function$;
CREATE OR REPLACE FUNCTION public.upsert_user_contact(user_id uuid, user_email text, user_name text, avatar_url text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
    _contact_id uuid;
BEGIN
    -- Upsert contact record for the user
    INSERT INTO public.contact (email, name, avatar_url, user_id)
        VALUES (user_email, user_name, avatar_url, user_id)
    ON CONFLICT (email)
        DO UPDATE SET
            name = COALESCE(EXCLUDED.name, contact.name),
            avatar_url = COALESCE(EXCLUDED.avatar_url, contact.avatar_url),
            user_id = COALESCE(EXCLUDED.user_id, contact.user_id),
            updated_at = now()
        RETURNING
            id INTO _contact_id;
    -- Ensure user has a primary contact
    IF NOT EXISTS (
        SELECT 1 FROM public.contact c
        WHERE c.user_id = upsert_user_contact.user_id AND c."primary" = true
    ) THEN
        UPDATE public.contact SET "primary" = true WHERE id = _contact_id;
    END IF;
    RETURN _contact_id;
END;
$function$;
ALTER TABLE public.contact ADD COLUMN "primary" boolean DEFAULT false NOT NULL;
ALTER TABLE public.contact ADD CONSTRAINT contact_primary_requires_user CHECK (NOT "primary" OR user_id IS NOT NULL);
CREATE UNIQUE INDEX contact_user_primary_unique ON public.contact (user_id) WHERE "primary" = true;

-- Data migration: set primary = true for existing users' contacts
UPDATE public.contact c
SET "primary" = true
FROM auth.users u
WHERE c.user_id = u.id
  AND c.id = COALESCE(
    (u.raw_app_meta_data->>'contact_id')::uuid,
    (SELECT c2.id FROM public.contact c2 WHERE c2.email = LOWER(u.email) AND c2.user_id = u.id LIMIT 1)
  );
