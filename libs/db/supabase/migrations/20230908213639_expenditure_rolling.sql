CREATE OR REPLACE VIEW "public"."expenditure_rolling" AS
SELECT
    COALESCE(expenditure.user_id, expenditure_expiries.user_id) AS user_id,
    COALESCE(expenditure.day, expenditure_expiries.day) AS day,
    COALESCE(expenditure.label_id, expenditure_expiries.label_id) AS label_id,
    COALESCE(expenditure.response, expenditure_expiries.response) AS response,
    sum(COALESCE(expenditure.event_count, 0)) OVER w AS event_count,
    sum(COALESCE(expenditure.minutes, 0)) OVER w AS minutes,
    sum(COALESCE(expenditure.org_event_count, 0)) OVER w AS org_event_count,
    sum(COALESCE(expenditure.org_minutes, 0)) OVER w AS org_minutes
FROM (expenditure
    FULL JOIN (
        SELECT
            expenditure_1.user_id, (expenditure_1.day + '28 days'::interval)::date AS day,
            expenditure_1.label_id,
            expenditure_1.response
        FROM
            expenditure expenditure_1) expenditure_expiries ON (((expenditure.user_id = expenditure_expiries.user_id)
                    AND (expenditure.day = expenditure_expiries.day)
                    AND (expenditure.label_id = expenditure_expiries.label_id)
                    AND (expenditure.response = expenditure_expiries.response))))
WINDOW w AS (PARTITION BY COALESCE(expenditure.user_id, expenditure_expiries.user_id),
    COALESCE(expenditure.label_id, expenditure_expiries.label_id),
    COALESCE(expenditure.response, expenditure_expiries.response)
ORDER BY
    COALESCE(expenditure.day, expenditure_expiries.day)
    RANGE BETWEEN '27 days'::interval PRECEDING AND CURRENT ROW)
ORDER BY
    COALESCE(expenditure.day, expenditure_expiries.day);

ALTER VIEW "public"."invitation_admin" SET ( security_invoker = FALSE);
ALTER VIEW "public"."event_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."waitlist_admin" SET ( security_invoker = FALSE);
ALTER VIEW expenditure SET ( security_invoker = TRUE);
ALTER VIEW expenditure_monthly SET ( security_invoker = TRUE);
ALTER VIEW expenditure_rolling SET ( security_invoker = TRUE);
ALTER VIEW "public"."sync_admin" SET ( security_invoker = FALSE);
