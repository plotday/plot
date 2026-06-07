-- Add or rename a contact in the calling user's address book. Offline-queued
-- via POST /sync/actors.
--
-- Modes:
--   * p_email NOT NULL -> ADD: resolve-or-create the global contact by email.
--     The client-provided p_contact_id is used as the new contact's id when the
--     email is brand new (so the optimistic client row keeps its id and needs no
--     reconciliation); on an existing email the existing contact id wins. The
--     global contact.name is NEVER written here -- user-entered names are a
--     per-user override only, so one user can't rename a contact for everyone.
--   * p_email NULL     -> RENAME: target the existing p_contact_id.
--
-- In both modes the per-user display name is written to user_contact.name with
-- source = 'user' -- the explicit, sticky override that bypasses the connector
-- longest-wins path (see public.upsert_user_contact_name). Inserting the
-- user_contact row is also what makes a brand-new external contact appear in
-- user.actor for this user.
--
-- Returns the resulting user.actor row for this user so the API can hand the
-- canonical contact id back to the client.
CREATE OR REPLACE FUNCTION "user".save_user_contact (
    user_id uuid,
    p_contact_id uuid,
    p_email text,
    p_name text
)
    RETURNS SETOF "user"."actor"
    LANGUAGE plpgsql
    AS $function$
-- The bare `user_id` in `ON CONFLICT (user_id, contact_id)` would otherwise be
-- ambiguous between the (conventionally named) `user_id` parameter and the
-- user_contact.user_id column. Prefer the column there; every other reference
-- in this body is already qualified (save_user_contact.user_id), so this is
-- safe.
#variable_conflict use_column
DECLARE
    v_contact_id uuid;
BEGIN
    IF p_contact_id IS NULL THEN
        RAISE EXCEPTION 'Contact id is required';
    END IF;

    IF p_email IS NOT NULL THEN
        -- Minimal email shape check, mirroring public.upsert_contacts.
        IF p_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
            RAISE EXCEPTION 'Invalid email address';
        END IF;

        -- Resolve-or-create by email. ON CONFLICT returns the EXISTING row's id;
        -- a fresh insert returns p_contact_id. Either way v_contact_id is the
        -- canonical id. We never touch the global name.
        INSERT INTO public.contact (id, email)
        VALUES (p_contact_id, lower(p_email))
        ON CONFLICT ON CONSTRAINT contact_email_unique
            DO UPDATE SET email = EXCLUDED.email
        RETURNING id INTO v_contact_id;
    ELSE
        v_contact_id := p_contact_id;
        IF NOT EXISTS (SELECT 1 FROM public.contact WHERE id = v_contact_id) THEN
            RAISE EXCEPTION 'Contact not found';
        END IF;
    END IF;

    -- Explicit per-user name override. source='user' is sticky vs connectors.
    INSERT INTO public.user_contact (user_id, contact_id, linked, source, name)
    VALUES (save_user_contact.user_id, v_contact_id, false, 'user', p_name)
    ON CONFLICT (user_id, contact_id)
        DO UPDATE SET
            name = EXCLUDED.name,
            source = 'user';

    RETURN QUERY
    SELECT * FROM "user"."actor" a
    WHERE a.user_id = save_user_contact.user_id
      AND a.id = v_contact_id;
END;
$function$;
