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
array_agg(DISTINCT a.provider) FILTER (WHERE (a.provider IS NOT NULL)) AS provider,
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

ALTER VIEW gap SET ( security_invoker = TRUE);
ALTER VIEW gap_monthly SET ( security_invoker = TRUE);
ALTER VIEW gap_daily SET ( security_invoker = TRUE);
ALTER VIEW "public"."invitation_admin" SET ( security_invoker = FALSE);
ALTER VIEW "public"."event_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."waitlist_admin" SET ( security_invoker = FALSE);
ALTER VIEW expenditure SET ( security_invoker = TRUE);
ALTER VIEW expenditure_monthly SET ( security_invoker = TRUE);
ALTER VIEW expenditure_rolling SET ( security_invoker = TRUE);
ALTER VIEW prep_monthly SET ( security_invoker = TRUE);
ALTER VIEW "public"."sync_admin" SET ( security_invoker = FALSE);
