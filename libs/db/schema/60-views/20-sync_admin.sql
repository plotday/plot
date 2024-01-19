CREATE OR REPLACE VIEW "public"."sync_admin" WITH ( security_invoker = FALSE)
-- for formatting
AS
SELECT
    min(a.email) AS email,
    min(a.id) AS account_id,
    ((array_agg(a.credentials))[0]) -> 'provider' AS provider,
    c.provider_id AS calendar_provider_id,
    c.created_at AS first_synced_at,
    c.full_sync_at AS full_sync_at,
    c.synced_at AS synced_at,
    c.sync_error AS error,
    CASE WHEN c.full_sync_at IS NULL
        OR c.sync_error IS NOT NULL THEN
        NULL
    ELSE
        ROUND(EXTRACT(EPOCH FROM (COALESCE(c.full_sync_at, NOW()) - c.full_sync_started_at)))
    END AS sync_seconds,
    COUNT(e.id) AS event_count
FROM
    account a
    LEFT OUTER JOIN calendar c ON (c.account_id = a.id)
    LEFT OUTER JOIN event e ON (e.calendar_id = c.id)
GROUP BY
    c.id;

REVOKE ALL ON sync_admin FROM PUBLIC;

GRANT SELECT ON sync_admin TO internal_admin;

