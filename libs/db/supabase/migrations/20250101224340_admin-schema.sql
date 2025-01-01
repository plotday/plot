CREATE SCHEMA IF NOT EXISTS "admin";

CREATE EXTENSION IF NOT EXISTS "pgtap" WITH SCHEMA "extensions" version '1.2.0';

CREATE EXTENSION IF NOT EXISTS "plpgsql_check" WITH SCHEMA "extensions" version '2.2';

DROP POLICY "internal_admin can edit the wailist" ON "public"."waitlist";

DROP VIEW IF EXISTS "public"."invitation_admin";

DROP VIEW IF EXISTS "public"."sync_admin";

DROP VIEW IF EXISTS "public"."waitlist_admin";

ALTER TABLE "public"."waitlist"
    DROP CONSTRAINT "waitlist_pkey";

DROP INDEX IF EXISTS "public"."waitlist_pkey";

DROP TABLE "public"."waitlist";

CREATE OR REPLACE VIEW "admin"."invitation" AS
SELECT
    min(i.id) AS id,
    min(i.created_at) AS created_at,
    min(i.code) AS code,
    min(i.remaining) AS remaining
FROM
    invitation i
GROUP BY
    i.id;

CREATE OR REPLACE VIEW "admin"."sync" AS
SELECT
    min(a.email) AS email,
    min(a.id) AS account_id,
    ((array_agg(a.credentials))[0] -> 'provider'::text) AS provider,
    c.provider_id AS calendar_provider_id,
    c.created_at AS first_synced_at,
    c.full_sync_at,
    c.synced_at,
    c.sync_error AS error,
    CASE WHEN ((c.full_sync_at IS NULL)
        OR (c.sync_error IS NOT NULL)) THEN
        NULL::numeric
    ELSE
        round(EXTRACT(epoch FROM (COALESCE(c.full_sync_at, now()) - c.full_sync_started_at)))
    END AS sync_seconds,
    count(e.id) AS event_count
FROM ((account a
    LEFT JOIN calendar c ON (c.account_id = a.id))
    LEFT JOIN event e ON (e.calendar_id = c.id))
GROUP BY
    c.id;

CREATE OR REPLACE VIEW "admin"."user" AS
SELECT
    u.id,
    min((u.email)::text) AS email,
    min(u.created_at) AS created_at,
    min(u.last_sign_in_at) AS last_sign_in_at,
    CASE WHEN (min(c.sync_error) IS NOT NULL) THEN
        'sync_error'::text
    WHEN (count(*) FILTER (WHERE ((a.credentials -> 'refresh_token'::text) IS NOT NULL)) > 0) THEN
        'synced'::text
    ELSE
        'not_synced'::text
    END AS status,
    array_agg(DISTINCT a.email) FILTER (WHERE (a.email IS NOT NULL)) AS accounts,
array_agg(DISTINCT (a.credentials -> 'provider'::text)) AS providers,
count(e.id) AS event_count
FROM (((auth.users u
        LEFT JOIN account a ON ((((u.email)::text = a.email)
                    AND (a.credentials IS NOT NULL))))
    LEFT JOIN calendar c ON (c.account_id = a.id))
    LEFT JOIN event e ON (e.calendar_id = c.id))
GROUP BY
    u.id;

ALTER VIEW note_x SET (security_invoker = TRUE);

ALTER VIEW gap SET (security_invoker = TRUE);

ALTER VIEW gap_monthly SET (security_invoker = TRUE);

ALTER VIEW gap_daily SET (security_invoker = TRUE);

ALTER VIEW insight SET (security_invoker = TRUE);

-- ALTER VIEW insight_weekly SET ( security_invoker = TRUE);
ALTER VIEW "admin"."sync" SET (security_invoker = FALSE);

ALTER VIEW "admin"."invitation" SET (security_invoker = FALSE);

ALTER VIEW "public"."event_invitees" SET (security_invoker = TRUE);

ALTER VIEW "public"."event_x" SET (security_invoker = TRUE);

ALTER VIEW "admin"."user" SET (security_invoker = FALSE);

ALTER VIEW "public"."activity_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_children" SET (security_invoker = TRUE);

ALTER VIEW balance_without_children SET (security_invoker = TRUE);

ALTER VIEW balance SET (security_invoker = TRUE);

