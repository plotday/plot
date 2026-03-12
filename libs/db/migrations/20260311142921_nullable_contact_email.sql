-- Modify "contact" table
ALTER TABLE "public"."contact" DROP CONSTRAINT "contact_email_check", ADD CONSTRAINT "contact_email_check" CHECK ((email IS NULL) OR (email = lower(email))), ALTER COLUMN "email" DROP NOT NULL;
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
        (c ->> 'email') IS NOT NULL
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
