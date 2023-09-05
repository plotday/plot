DROP VIEW "public"."waitlist_admin";

CREATE OR REPLACE VIEW "public"."waitlist_admin" WITH ( security_invoker = FALSE)
-- for formatting
AS
SELECT
    min(w.id) AS id,
    min(w.created_at) AS created_at,
    min(w.email) AS email,
    CASE WHEN min(u.invitation) IS NOT NULL THEN
        'active'
    WHEN min(w.sync_error) IS NOT NULL THEN
        'sync_error'
    WHEN count(*) FILTER (WHERE a.email IS NOT NULL) > 0 THEN
        'synced'
    ELSE
        'waitlisted'
    END AS "status",
    array_agg(a.email) FILTER (WHERE a.email IS NOT NULL) AS sync_accounts,
    min(w.sync_error) AS sync_error,
    min(w.provider) AS provider,
    min(u.invitation) AS invitation,
    count(e.id) AS event_count
FROM
    waitlist w
    LEFT OUTER JOIN "user" u ON (u.id = w.user_id
        OR LOWER(u.email) = LOWER(w.email))
    LEFT OUTER JOIN account a ON (u.id = a.user_id
        AND a.credentials IS NOT NULL)
    LEFT OUTER JOIN calendar c ON (c.account_id = a.id)
    LEFT OUTER JOIN event e ON (e.calendar_id = c.id)
GROUP BY
    w.id;

REVOKE ALL ON waitlist_admin FROM PUBLIC;

GRANT SELECT ON waitlist_admin TO internal_admin;

