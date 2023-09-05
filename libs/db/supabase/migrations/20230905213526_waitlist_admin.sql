DROP VIEW IF EXISTS "public"."waitlist_admin";

ALTER TABLE "public"."waitlist"
    ADD COLUMN "provider" provider;

ALTER TABLE "public"."waitlist"
    ADD COLUMN "sync_error" text;

ALTER TABLE "public"."waitlist"
    ADD COLUMN "user_id" bigint;

ALTER TABLE "public"."waitlist"
    ADD CONSTRAINT "waitlist_user_id_fkey" FOREIGN KEY (user_id) REFERENCES "user" (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."waitlist" validate CONSTRAINT "waitlist_user_id_fkey";

CREATE OR REPLACE VIEW "public"."waitlist_admin" AS
SELECT
    min(w.id) AS id,
    min(w.created_at) AS created_at,
    min(w.email) AS email,
    CASE WHEN (min(u.invitation) IS NOT NULL) THEN
        'active'::text
    WHEN (min(w.sync_error) IS NOT NULL) THEN
        'sync_error'::text
    WHEN (count(*) FILTER (WHERE (a.email IS NOT NULL)) > 0) THEN
        'synced'::text
    ELSE
        'waitlisted'::text
    END AS status,
    array_agg(a.email) FILTER (WHERE (a.email IS NOT NULL)) AS sync_accounts,
min(w.sync_error) AS sync_error,
min(w.provider) AS provider,
min(u.invitation) AS invitation,
count(e.id) AS event_count
FROM ((((waitlist w
            LEFT JOIN "user" u ON (((u.id = w.user_id)
                        OR (lower(u.email) = lower(w.email)))))
        LEFT JOIN account a ON (((u.id = a.user_id)
                    AND (a.credentials IS NOT NULL))))
    LEFT JOIN calendar c ON (c.account_id = a.id))
    LEFT JOIN event e ON (e.calendar_id = c.id))
GROUP BY
    w.id;

