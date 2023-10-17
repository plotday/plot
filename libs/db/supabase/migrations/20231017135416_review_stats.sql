CREATE OR REPLACE VIEW "public"."prep_monthly" AS
SELECT
    e.user_id,
    (date_trunc('month'::text, (e.day)::timestamp with time zone))::date AS month,
    count(*) FILTER (WHERE (lower(e.at) < CURRENT_TIMESTAMP)) AS past_count,
count(*) FILTER (WHERE ((lower(e.at) < CURRENT_TIMESTAMP)
AND (e.ready < lower(e.at)))) AS past_ready_count,
count(*) FILTER (WHERE ((upper(e.at) < CURRENT_TIMESTAMP)
AND (e.reviewed < (upper(e.at) + '2 days'::interval)))) AS past_reviewed_count,
round((avg(EXTRACT(epoch FROM (COALESCE(e.reviewed, CURRENT_TIMESTAMP) - upper(e.at)))) FILTER (WHERE (upper(e.at) < CURRENT_TIMESTAMP)) / (60)::numeric)) AS review_time
FROM
    event_x e
WHERE (e.type = 'meeting'::event_type)
GROUP BY
    e.user_id,
    ((date_trunc('month'::text, (e.day)::timestamp with time zone))::date);

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
