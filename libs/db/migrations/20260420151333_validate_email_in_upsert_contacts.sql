-- Modify "upsert_contacts" function
CREATE OR REPLACE FUNCTION "public"."upsert_contacts" ("contacts" jsonb) RETURNS TABLE ("id" uuid, "email" text, "name" text, "user_id" uuid) LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY INSERT INTO contact (email, name, avatar_url)
    SELECT
        (c ->> 'email')::text,
        (c ->> 'name')::text,
        (c ->> 'avatar_url')::text
    FROM
        jsonb_array_elements(contacts) AS c
    WHERE
        -- Minimum valid email shape: non-empty local, one @, non-empty
        -- domain with at least one dot. This is not full RFC 5322 — just
        -- enough to filter out obviously broken header fragments.
        (c ->> 'email') ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
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
$$;
-- Clean up existing garbage contacts whose email is not a valid address
-- (e.g. `undisclosed-recipients:;`, `"bayne` from a broken quoted-name split).
-- Keep the rows so any FK references remain valid, but hide them from all
-- contact pickers and @-mentions by flipping inviteable=false.
UPDATE "public"."contact"
SET "inviteable" = false
WHERE "inviteable" = true
  AND "email" IS NOT NULL
  AND "email" !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$';
