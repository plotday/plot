-- Upsert contacts from the Plot tool.
--
-- The shared contact.name / avatar_url are FIRST-TOUCH-ONLY: a later
-- observation never overwrites an already-populated value. The global name is
-- only a fallback for viewers with no per-user override; letting every
-- connector observation overwrite it churns the shared name across all users
-- (e.g. a Google Group whose DMARC-rewritten From names renamed the contact
-- for everyone). Per-user names live in user_contact.name (see
-- upsert_user_contact_name) and are resolved per-viewer in user.actor.
--
-- Rejects malformed email values (missing @, stray punctuation like
-- `undisclosed-recipients:;`, fragments from a broken quoted-name split
-- like `"bayne`) so garbage from upstream parsers never becomes a contact.
CREATE OR REPLACE FUNCTION public.upsert_contacts (contacts jsonb)
    RETURNS TABLE (
        id uuid,
        email text,
        name text,
        user_id uuid)
    LANGUAGE plpgsql
    AS $function$
BEGIN
    -- Deduplicate by email and sort so concurrent callers acquire row
    -- locks in the same order. Without this, two sessions each upserting
    -- overlapping email sets in different orders can deadlock on the
    -- ON CONFLICT DO UPDATE row locks.
    RETURN QUERY INSERT INTO contact (email, name, avatar_url)
    SELECT DISTINCT ON (email_lower)
        email_lower,
        name_val,
        avatar_val
    FROM (
        SELECT
            lower((c ->> 'email')::text) AS email_lower,
            (c ->> 'name')::text AS name_val,
            (c ->> 'avatar_url')::text AS avatar_val
        FROM
            jsonb_array_elements(contacts) AS c
        WHERE
            -- Minimum valid email shape: non-empty local, one @, non-empty
            -- domain with at least one dot. This is not full RFC 5322 — just
            -- enough to filter out obviously broken header fragments.
            (c ->> 'email') ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
    ) deduped
    ORDER BY email_lower
ON CONFLICT ON CONSTRAINT contact_email_unique
    DO UPDATE SET
        -- First-touch only: keep an existing value, fill only when NULL.
        name = COALESCE(contact.name, EXCLUDED.name),
        avatar_url = COALESCE(contact.avatar_url, EXCLUDED.avatar_url)
    RETURNING
        contact.id,
        contact.email,
        contact.name,
        contact.user_id;
END;
$function$;

-- Sets/updates a single user's display-name override for a contact. Connectors
-- call this (via addContacts, attributed to the connector OWNER) so an observed
-- name shows only in THAT user's view — never globally. Creates a visibility
-- row (linked = false) if none exists yet; never clobbers an existing non-null
-- name with NULL. The set_user_contact_updated_at trigger bumps user_contact.seq,
-- so user.actor (GREATEST(uc.seq, a.seq)) re-emits the row to the client.
CREATE OR REPLACE FUNCTION public.upsert_user_contact_name (
    p_user_id uuid,
    p_contact_id uuid,
    p_name text)
    RETURNS void
    LANGUAGE sql
    AS $function$
    INSERT INTO public.user_contact (user_id, contact_id, linked, source, name)
        VALUES (p_user_id, p_contact_id, false, 'observed', p_name)
    ON CONFLICT (user_id, contact_id)
        DO UPDATE SET
            name = COALESCE(EXCLUDED.name, user_contact.name)
        WHERE EXCLUDED.name IS NOT NULL
            AND EXCLUDED.name IS DISTINCT FROM user_contact.name
            -- Never override the name on a user's own linked identity row.
            AND user_contact.linked = false;
$function$;
