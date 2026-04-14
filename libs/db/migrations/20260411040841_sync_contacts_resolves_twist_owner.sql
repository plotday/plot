-- Modify "sync_thread_contacts" function
CREATE OR REPLACE FUNCTION "public"."sync_thread_contacts" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    _author_user_id uuid;
    _author_contact_id uuid;
    _contacts uuid[];
BEGIN
    -- Start from access_contacts (legacy source of truth) and fall back
    -- to an empty array. Cast to uuid[] to normalise NULL.
    _contacts := COALESCE(NEW.access_contacts, ARRAY[]::uuid[]);

    -- Resolve created_by to a user: either it's a user already or it's
    -- a priority_twist instance whose owner_id is the user.
    IF EXISTS (SELECT 1 FROM "public"."user" WHERE id = NEW.created_by) THEN
        _author_user_id := NEW.created_by;
    ELSE
        SELECT pt.owner_id INTO _author_user_id
        FROM public.priority_twist pt
        WHERE pt.id = NEW.created_by;
    END IF;

    IF _author_user_id IS NOT NULL THEN
        _author_contact_id := "user".user_contact_id(_author_user_id);
        IF _author_contact_id IS NOT NULL
           AND NOT (_author_contact_id = ANY(_contacts)) THEN
            _contacts := _contacts || _author_contact_id;
        END IF;
    END IF;

    NEW.contacts := _contacts;
    RETURN NEW;
END;
$$;
