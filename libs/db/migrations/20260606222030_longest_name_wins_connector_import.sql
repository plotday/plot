-- Modify "upsert_contacts" function
CREATE OR REPLACE FUNCTION "public"."upsert_contacts" ("contacts" jsonb) RETURNS TABLE ("id" uuid, "email" text, "name" text, "user_id" uuid) LANGUAGE plpgsql AS $$
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
$$;
-- Modify "upsert_user_contact_name" function
CREATE OR REPLACE FUNCTION "public"."upsert_user_contact_name" ("p_user_id" uuid, "p_contact_id" uuid, "p_name" text) RETURNS void LANGUAGE sql AS $$
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
$$;
