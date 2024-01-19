CREATE OR REPLACE VIEW "public"."waitlist_admin" WITH ( security_invoker = FALSE)
-- for formatting
AS
SELECT
    min(w.id) AS id,
    min(w.created_at) AS created_at,
    min(w.email) AS email,
    CASE WHEN min(c.sync_error) IS NOT NULL THEN
        'sync_error'
    WHEN min(w.activated_at) IS NOT NULL THEN
        'active'
    WHEN count(*) FILTER (WHERE a.credentials -> 'refresh_token' IS NOT NULL) > 0 THEN
        'synced'
    ELSE
        'waitlisted'
    END AS "status",
    array_agg(DISTINCT a.email) FILTER (WHERE a.email IS NOT NULL) AS sync_accounts,
    array_agg(c.sync_error) FILTER (WHERE c.sync_error IS NOT NULL) AS sync_error,
    ((array_agg(a.credentials))[0]) -> 'provider' AS provider,
    w.invitation AS invitation,
    count(e.id) AS event_count
FROM
    waitlist w
    LEFT OUTER JOIN account a ON (w.email = a.email
        AND a.credentials IS NOT NULL)
    LEFT OUTER JOIN calendar c ON (c.account_id = a.id)
    LEFT OUTER JOIN event e ON (e.calendar_id = c.id)
GROUP BY
    w.id;

REVOKE ALL ON waitlist_admin FROM PUBLIC;

GRANT SELECT ON waitlist_admin TO internal_admin;

