ALTER TABLE "public"."calendar"
    ADD COLUMN "full_sync_at" timestamp with time zone;

ALTER TABLE "public"."calendar"
    ADD COLUMN "full_sync_started_at" timestamp with time zone;

ALTER TABLE "public"."calendar"
    ADD COLUMN "sync_error" text;

ALTER TABLE "public"."calendar"
    ADD COLUMN "synced_at" timestamp with time zone;

SET check_function_bodies = OFF;

CREATE OR REPLACE VIEW "public"."sync_admin" AS
SELECT
    a.email,
    a.id AS account_id,
    a.provider,
    c.provider_id AS calendar_provider_id,
    c.created_at AS first_synced_at,
    c.full_sync_at,
    c.synced_at AS updated_at,
    c.sync_error AS error,
    CASE WHEN (c.full_sync_at IS NULL) THEN
        NULL::numeric
    ELSE
        EXTRACT(epoch FROM (COALESCE(c.full_sync_at, now()) - c.full_sync_started_at))
    END AS sync_seconds
FROM (account a
    JOIN calendar c ON (c.account_id = a.id));

CREATE OR REPLACE FUNCTION public.all_views_secure ()
    RETURNS boolean
    LANGUAGE plpgsql
    AS $function$
DECLARE
    VIEW text;
BEGIN
    SELECT
        relname INTO VIEW
    FROM
        pg_class
        JOIN pg_catalog.pg_namespace n ON n.oid = pg_class.relnamespace
    WHERE
        n.nspname = 'public'
        AND relname NOT LIKE '%_admin'
        AND relkind = 'v'
        AND (lower(reloptions::text)::text[] && ARRAY['security_invoker=1', 'security_invoker=true', 'security_invoker=on']) IS NULL;
    IF FOUND THEN
        RAISE EXCEPTION 'Found view without security_invoker: %', VIEW;
    END IF;
    RETURN TRUE;
END
$function$;

REVOKE ALL ON sync_admin FROM PUBLIC;

GRANT SELECT ON sync_admin TO internal_admin;

