-- Upsert contacts from the Plot tool (the connector import path).
--
-- The shared contact.name uses LONGEST-WINS: a later observation replaces the
-- stored name only when it is strictly longer (treating a fuller name as more
-- complete), never with a shorter or equal one, and never with NULL. This
-- enhances the shared name (e.g. "Beth" -> "Beth Round") without letting a
-- partial name from another source degrade it. The global name is the
-- cross-viewer fallback for viewers with no per-user override (user.actor
-- COALESCE(uc.name, a.name)); per-user names live in user_contact.name (see
-- upsert_user_contact_name) and are resolved per-viewer in user.actor.
--
-- avatar_url stays FIRST-TOUCH-ONLY (no length notion): fill only when NULL.
--
-- This is the connector path. An explicit user rename must go through a
-- separate API that bypasses longest-wins, so a user can set any name.
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
        -- Longest-wins: upgrade to a strictly longer name, never downgrade,
        -- never overwrite with NULL. Ties keep the existing value so no
        -- needless seq bump / re-sync.
        name = CASE
            WHEN EXCLUDED.name IS NOT NULL
                AND length(EXCLUDED.name) > length(COALESCE(contact.name, ''))
            THEN EXCLUDED.name
            ELSE contact.name
        END,
        -- avatar stays first-touch: fill only when NULL.
        avatar_url = COALESCE(contact.avatar_url, EXCLUDED.avatar_url)
    RETURNING
        contact.id,
        contact.email,
        contact.name,
        contact.user_id;
END;
$function$;

-- Sets/updates a single user's display-name override for a contact from the
-- connector import path. Connectors call this (via addContacts, attributed to
-- the connector OWNER) so an observed name shows only in THAT user's view —
-- never globally. Creates a visibility row (linked = false) if none exists yet.
--
-- LONGEST-WINS: an existing observed name is upgraded only when the incoming
-- name is strictly longer; a shorter/equal name is ignored, and NULL never
-- overwrites. This is what stops a partial name from one source (e.g. Slack's
-- "Beth") from degrading a fuller one from another (Gmail's "Beth Round").
--
-- An explicit user rename (source = 'user', set by a separate rename API) is
-- sticky: this connector path never changes it, even with a longer name.
-- It also never touches a user's own linked identity row (linked = true).
--
-- The set_user_contact_updated_at trigger bumps user_contact.seq, so user.actor
-- (GREATEST(uc.seq, a.seq)) re-emits the row to the client.
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
            name = EXCLUDED.name
        WHERE EXCLUDED.name IS NOT NULL
            -- Never override the name on a user's own linked identity row.
            AND user_contact.linked = false
            -- Never override a name the user set explicitly.
            AND user_contact.source IS DISTINCT FROM 'user'
            -- Longest-wins: fill when empty, else only upgrade to a longer name.
            AND (user_contact.name IS NULL
                OR length(EXCLUDED.name) > length(user_contact.name));
$function$;
