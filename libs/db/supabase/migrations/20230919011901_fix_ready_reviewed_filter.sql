CREATE OR REPLACE VIEW "public"."event_x" AS
SELECT
    u.id AS user_id,
    min(e.id) AS id,
    e.name,
    CASE WHEN (EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) >= (((60 * 60) * 23))::numeric) THEN
        tstzrange(timezone(u.timezone, timezone('UTC'::text, lower(e.at))), timezone(u.timezone, timezone('UTC'::text, upper(e.at))), '[)'::text)
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
    min(e.organizer) AS organizer,
    COALESCE(min(i.response) FILTER (WHERE (ct.contact_user_id = u.id)), 'tentative'::event_response) AS response,
    calc_attendance (min(er.attendance), min(i.response) FILTER (WHERE (ct.contact_user_id = u.id)), (count(DISTINCT i.contact_id))::integer) AS attendance,
    (round((EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) / (60)::numeric)))::integer AS minutes,
    (count(DISTINCT i.contact_id) FILTER (WHERE (i.response = 'accepted'::event_response)))::integer AS attendee_count,
(count(DISTINCT i.contact_id))::integer AS invitee_count,
COALESCE(bool_or(er.ready), FALSE) AS ready,
COALESCE(bool_or(er.reviewed), FALSE) AS reviewed,
(timezone(u.timezone, timezone('UTC'::text, lower(e.at))))::date AS day,
COALESCE((u.id = min(ct.contact_user_id) FILTER (WHERE (ct.id = e.organizer))), FALSE) AS initiated
FROM ((((((event e
                        JOIN calendar c ON (e.calendar_id = c.id))
                    JOIN account a ON (c.account_id = a.id))
                JOIN "user" u ON (a.user_id = u.id))
            LEFT JOIN response er ON (((u.id = er.user_id)
                        AND (e.provider_id = er.provider_id))))
        JOIN invitee i ON (e.id = i.event_id))
    JOIN contact ct ON (i.contact_id = ct.id))
GROUP BY
    u.id,
    e.name,
    e.at;

ALTER VIEW "public"."invitation_admin" SET ( security_invoker = FALSE);
ALTER VIEW "public"."event_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."waitlist_admin" SET ( security_invoker = FALSE);
ALTER VIEW expenditure SET ( security_invoker = TRUE);
ALTER VIEW expenditure_monthly SET ( security_invoker = TRUE);
ALTER VIEW expenditure_rolling SET ( security_invoker = TRUE);
ALTER VIEW "public"."sync_admin" SET ( security_invoker = FALSE);
