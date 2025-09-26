DROP TRIGGER IF EXISTS "on_account_created" ON "public"."account";

DROP TRIGGER IF EXISTS "set_account_updated_at" ON "public"."account";

DROP POLICY "Users can read their accounts" ON "public"."account";

ALTER TABLE "public"."contact"
    DROP CONSTRAINT IF EXISTS "contact_account_id_fkey";

ALTER TABLE "public"."account"
    DROP CONSTRAINT "account_user_id_fkey";

ALTER TABLE "public"."account"
    DROP CONSTRAINT "account_user_id_email_key";

ALTER TABLE "public"."account"
    DROP CONSTRAINT "account_email_check";

DROP FUNCTION IF EXISTS "public"."account" (calendar);

DROP FUNCTION IF EXISTS "public"."calendars" (account);

DROP FUNCTION IF EXISTS "public"."organization" (account);

DROP FUNCTION IF EXISTS "public"."upsert_contacts" (_contacts contact_upsert[]);

DROP TYPE IF EXISTS "public"."contact_upsert";

ALTER TABLE "public"."account"
    DROP CONSTRAINT "account_pkey";

DROP INDEX IF EXISTS "public"."account_user_id_idx";

DROP INDEX IF EXISTS "public"."account_user_id_email_key";

DROP INDEX IF EXISTS "public"."account_pkey";

DROP TABLE "public"."account" CASCADE;

-- Update admin views that referenced account
DROP VIEW IF EXISTS "admin"."sync";

DROP VIEW IF EXISTS "admin"."user";

DROP FUNCTION IF EXISTS "public"."notify_user_for_account" ();

CREATE TYPE "public"."contact_upsert" AS (
    "calendar_id" bigint,
    "email" text,
    "name" text,
    "avatar_url" text
);

CREATE OR REPLACE FUNCTION public.upsert_contacts (_contacts contact_upsert[])
    RETURNS void
    LANGUAGE plpgsql
    AS $function$
BEGIN
    INSERT INTO contact (user_id, email, name, avatar_url) (
        SELECT
            a.user_id,
            vals.email,
            min(vals.name),
            min(vals.avatar_url)
        FROM
            unnest(_contacts) AS vals (calendar_id,
                email,
                name,
                avatar_url)
            JOIN calendar c ON vals.calendar_id = c.id
            JOIN account a ON c.account_id = a.id
        GROUP BY
            a.user_id,
            vals.email)
ON CONFLICT (user_id,
    email)
    DO UPDATE SET
        name = COALESCE(contact.name, EXCLUDED.name),
        avatar_url = COALESCE(contact.avatar_url, EXCLUDED.avatar_url);
END;
$function$;


