-- Function to upsert contact when a user is created or updated
CREATE OR REPLACE FUNCTION public.upsert_user_contact (user_id uuid, user_email text, user_name text, avatar_url text)
    RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    _contact_id uuid;
    _existing_user_id uuid;
BEGIN
    -- Check if this email is already linked to a different user
    SELECT c.user_id INTO _existing_user_id
    FROM public.contact c
    WHERE c.email = user_email;

    IF _existing_user_id IS NOT NULL
       AND upsert_user_contact.user_id IS NOT NULL
       AND _existing_user_id IS DISTINCT FROM upsert_user_contact.user_id THEN
        RAISE EXCEPTION 'email_already_linked: This email is already associated with another account'
            USING ERRCODE = 'unique_violation';
    END IF;

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

-- When user_id is set to NULL (e.g. user deletion), ensure primary is also cleared
CREATE OR REPLACE FUNCTION public.contact_clear_primary_on_unlink()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    IF NEW.user_id IS NULL AND OLD.user_id IS NOT NULL AND NEW."primary" = true THEN
        NEW."primary" := false;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER on_contact_user_unlinked
    BEFORE UPDATE ON public.contact
    FOR EACH ROW
    WHEN (OLD.user_id IS NOT NULL AND NEW.user_id IS NULL)
    EXECUTE FUNCTION public.contact_clear_primary_on_unlink();
