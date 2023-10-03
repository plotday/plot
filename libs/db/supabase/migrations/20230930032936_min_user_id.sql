CREATE TYPE "public"."user_status" AS enum (
    'waitlisted',
    'active'
);

DROP POLICY "internal_admin can access full waitlist" ON "public"."waitlist";

ALTER TABLE "public"."waitlist"
    DROP CONSTRAINT "waitlist_email_key";

ALTER TABLE "public"."waitlist"
    DROP CONSTRAINT "waitlist_user_id_fkey";

DROP VIEW IF EXISTS "public"."waitlist_admin";

ALTER TABLE "public"."waitlist"
    DROP CONSTRAINT "waitlist_pkey";

DROP INDEX IF EXISTS "public"."waitlist_email_key";

DROP INDEX IF EXISTS "public"."waitlist_pkey";

DROP TABLE "public"."waitlist";

CREATE OR REPLACE FUNCTION public.random_code ()
    RETURNS text
    LANGUAGE plpgsql
    AS $function$
DECLARE
    alphabet text := 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    rand_index integer;
    random_code text := '';
BEGIN
    FOR i IN 1..8 LOOP
        rand_index := ceil(random() * length(alphabet));
        random_code := random_code || substr(alphabet, rand_index, 1);
    END LOOP;
    RETURN random_code;
END;
$function$;

ALTER TABLE "public"."user"
    ADD COLUMN "code" text NOT NULL DEFAULT random_code ();

ALTER TABLE "public"."user"
    ADD COLUMN "status" user_status NOT NULL DEFAULT 'waitlisted'::user_status;

ALTER TABLE "public"."user"
    ALTER COLUMN "name" DROP NOT NULL;

CREATE UNIQUE INDEX user_code_key ON public."user" USING btree (code);

SET check_function_bodies = OFF;

CREATE OR REPLACE VIEW "public"."waitlist_admin" AS
SELECT
    min(u.id) AS id,
    min(u.created_at) AS created_at,
    min(u.email) AS email,
    CASE WHEN (min(u.invitation) IS NOT NULL) THEN
        'active'::text
    WHEN (min(c.sync_error) IS NOT NULL) THEN
        'sync_error'::text
    WHEN (count(*) FILTER (WHERE (a.email IS NOT NULL)) > 0) THEN
        'synced'::text
    ELSE
        'waitlisted'::text
    END AS status,
    array_agg(DISTINCT a.email) FILTER (WHERE (a.email IS NOT NULL)) AS sync_accounts,
array_agg(c.sync_error) FILTER (WHERE (c.sync_error IS NOT NULL)) AS sync_error,
array_agg(DISTINCT a.provider) AS provider,
u.invitation,
count(e.id) AS event_count,
u.code
FROM ((("user" u
        LEFT JOIN account a ON (((u.id = a.user_id)
                    AND (a.credentials IS NOT NULL))))
    LEFT JOIN calendar c ON (c.account_id = a.id))
    LEFT JOIN event e ON (e.calendar_id = c.id))
GROUP BY
    u.id;

SELECT
    setval(pg_get_serial_sequence('user', 'id'), 10000);

ALTER VIEW gap SET (security_invoker = TRUE);

ALTER VIEW gap_monthly SET (security_invoker = TRUE);

ALTER VIEW gap_daily SET (security_invoker = TRUE);

ALTER VIEW "public"."invitation_admin" SET (security_invoker = FALSE);

ALTER VIEW "public"."event_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."waitlist_admin" SET (security_invoker = FALSE);

ALTER VIEW expenditure SET (security_invoker = TRUE);

ALTER VIEW expenditure_monthly SET (security_invoker = TRUE);

ALTER VIEW expenditure_rolling SET (security_invoker = TRUE);

ALTER VIEW prep_monthly SET (security_invoker = TRUE);

ALTER VIEW "public"."sync_admin" SET (security_invoker = FALSE);

