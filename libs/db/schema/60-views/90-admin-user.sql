CREATE OR REPLACE VIEW "admin"."user" WITH ( security_invoker = FALSE)
-- for formatting
AS
SELECT
    u.id,
    min(u.email) AS email,
    min(u.created_at) AS created_at,
    min(u.last_sign_in_at) AS last_sign_in_at,
    CASE WHEN min(c.sync_error) IS NOT NULL THEN
        'sync_error'
    WHEN count(*) FILTER (WHERE a.credentials -> 'refresh_token' IS NOT NULL) > 0 THEN
        'synced'
    ELSE
        'not_synced'
    END AS "status",
    array_agg(DISTINCT a.email) FILTER (WHERE a.email IS NOT NULL) AS accounts,
    array_agg(DISTINCT a.credentials -> 'provider') AS providers,
    count(e.id) AS event_count
FROM
    auth.users u
    LEFT OUTER JOIN account a ON (u.email = a.email
        AND a.credentials IS NOT NULL)
    LEFT OUTER JOIN calendar c ON (c.account_id = a.id)
    LEFT OUTER JOIN event e ON (e.calendar_id = c.id)
GROUP BY
    u.id;

