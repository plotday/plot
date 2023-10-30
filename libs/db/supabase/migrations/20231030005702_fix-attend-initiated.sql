CREATE OR REPLACE VIEW "public"."event_x" AS
SELECT
    u.id AS user_id,
    min(e.id) AS id,
    e.name,
    CASE WHEN (EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) >= (((60 * 60) * 23))::numeric) THEN
        tstzrange(timezone(COALESCE(u.timezone, 'America/New_York'::text), timezone('UTC'::text, lower(e.at))), timezone(COALESCE(u.timezone, 'America/New_York'::text), timezone('UTC'::text, upper(e.at))), '[)'::text)
    ELSE
        e.at
    END AS at,
    min(e.calendar_id) AS calendar_id,
    min(e.provider_id) AS provider_id,
    min(e.series) AS series,
    min(e.created_at) AS created_at,
    min(e.status) AS status,
    min(e.provider_link) AS provider_link,
    min(e.summary) AS summary,
    min(e.description) AS description,
    min(e.visibility) AS visibility,
    min(e.availability) AS availability,
    min(e.conferencing_url) AS conferencing_url,
    min(e.organizer_email) AS organizer_email,
    COALESCE(min(i.response) FILTER (WHERE (ct.contact_user_id = u.id)), 'tentative'::event_response) AS response,
    calc_attendance (min(er.attendance), min(i.response) FILTER (WHERE (ct.contact_user_id = u.id)), (count(DISTINCT i.email))::integer, lower(e.at), ((count(DISTINCT i.email) < 2)
    AND COALESCE((u.id = min(ct.contact_user_id) FILTER (WHERE (ct.email = e.organizer_email))), FALSE)
AND (min(e.series) IS NULL))) AS attendance,
    (round((EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) / (60)::numeric)))::integer AS minutes,
    (count(DISTINCT i.email) FILTER (WHERE (i.response = 'accepted'::event_response)))::integer AS attendee_count,
(count(DISTINCT i.email))::integer AS invitee_count,
min(er.ready) AS ready,
CASE WHEN (min(upper(e.at)) < u.activated_at) THEN
    upper(e.at)
ELSE
    min(er.reviewed)
END AS reviewed,
CASE WHEN (EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) >= (((60 * 60) * 23))::numeric) THEN
    (timezone(COALESCE(u.timezone, 'America/New_York'::text), timezone('UTC'::text, lower(e.at))))::date
ELSE
    ((lower(e.at) AT TIME ZONE COALESCE(u.timezone, 'America/New_York'::text)))::date
END AS day,
COALESCE((u.id = min(ct.contact_user_id) FILTER (WHERE (ct.email = e.organizer_email))), FALSE) AS initiated,
(EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) >= (((60 * 60) * 23))::numeric) AS all_day,
calc_event_type (e.at, min(e.availability), COALESCE(min(i.response) FILTER (WHERE (ct.contact_user_id = u.id)), 'tentative'::event_response), (((count(DISTINCT i.email))::integer > 1)
    OR bool_or(e.invitees_hidden))) AS type,
calc_internal ((count(DISTINCT i.email))::integer, min(ct.domain_id) FILTER (WHERE (ct.contact_user_id = u.id)), array_agg(DISTINCT ct.domain_id)) AS internal,
CASE WHEN (count(el.label_id) > 0) THEN
    array_agg(DISTINCT el.label_id) FILTER (WHERE (el.label_id IS NOT NULL))
ELSE
    ARRAY[]::bigint[]
END AS labels,
bool_or(e.invitees_hidden) AS invitees_hidden
FROM (((((((event e
                            JOIN calendar c ON (e.calendar_id = c.id))
                        JOIN account a ON (c.account_id = a.id))
                    JOIN "user" u ON (a.user_id = u.id))
                LEFT JOIN response er ON (((u.id = er.user_id)
                            AND (e.provider_id = er.provider_id))))
            JOIN invitee i ON (e.id = i.event_id))
        JOIN contact ct ON (((ct.user_id = u.id)
                    AND (i.email = ct.email))))
    LEFT JOIN event_label el ON (e.id = el.event_id))
WHERE (c.enabled = TRUE)
GROUP BY
    u.id,
    e.name,
    e.at;

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
