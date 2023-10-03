CREATE OR REPLACE VIEW "public"."waitlist_admin" WITH ( security_invoker = FALSE)
-- for formatting
AS
SELECT
    min(u.id) AS id,
    min(u.created_at) AS created_at,
    min(u.email) AS email,
    CASE WHEN min(c.sync_error) IS NOT NULL THEN
        'sync_error'
    WHEN min(u.activated_at) IS NOT NULL THEN
        'active'
    WHEN count(*) FILTER (WHERE a.credentials -> 'refresh_token' IS NOT NULL) > 0 THEN
        'synced'
    ELSE
        'waitlisted'
    END AS "status",
    array_agg(DISTINCT a.email) FILTER (WHERE a.email IS NOT NULL) AS sync_accounts,
    array_agg(c.sync_error) FILTER (WHERE c.sync_error IS NOT NULL) AS sync_error,
    array_agg(DISTINCT a.provider) FILTER (WHERE a.provider IS NOT NULL) AS provider,
    u.invitation AS invitation,
    count(e.id) AS event_count
FROM
    "user" u
    LEFT OUTER JOIN account a ON (u.id = a.user_id
        AND a.credentials IS NOT NULL)
    LEFT OUTER JOIN calendar c ON (c.account_id = a.id)
    LEFT OUTER JOIN event e ON (e.calendar_id = c.id)
GROUP BY
    u.id;

REVOKE ALL ON waitlist_admin FROM PUBLIC;

GRANT SELECT ON waitlist_admin TO internal_admin;

