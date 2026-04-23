-- Upsert contacts from the Plot tool
-- Uses COALESCE to preserve existing name/avatar when new value is null.
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
        name = COALESCE(EXCLUDED.name, contact.name),
        avatar_url = COALESCE(EXCLUDED.avatar_url, contact.avatar_url)
    RETURNING
        contact.id,
        contact.email,
        contact.name,
        contact.user_id;
END;
$function$;
