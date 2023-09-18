DROP FUNCTION public.label (expenditure_monthly);

DROP FUNCTION public.label (event_x);

DROP FUNCTION public.invitee (event_x);

DROP VIEW IF EXISTS "public"."expenditure_monthly";

DROP VIEW IF EXISTS "public"."expenditure_rolling";

DROP VIEW IF EXISTS "public"."expenditure";

DROP VIEW IF EXISTS "public"."event_x";

DROP FUNCTION IF EXISTS "public"."calc_attendance" (attendance event_attendance, response event_response);

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.calc_attendance (attendance event_attendance, response event_response, invitee_count integer)
    RETURNS event_attendance
    LANGUAGE plpgsql
    AS $function$
BEGIN
    IF response = 'declined'::event_response THEN
        RETURN 'skip'::event_attendance;
    END IF;
    IF invitee_count < 2 AND response = 'accepted' THEN
        RETURN 'attend'::event_attendance;
    END IF;
    IF attendance IS NULL THEN
        RETURN NULL;
    END IF;
    IF response = 'accepted'::event_response THEN
        RETURN 'attend'::event_attendance;
    END IF;
    IF attendance = 'attend'::event_attendance AND response = 'tentative'::event_response THEN
        RETURN 'skip'::event_attendance;
    END IF;
    RETURN attendance;
END;
$function$;

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
bool_or(er.ready) AS ready,
bool_or(er.reviewed) AS reviewed,
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

CREATE OR REPLACE VIEW "public"."expenditure" AS
SELECT
    e.user_id,
    e.day,
    el.label_id,
    e.response,
    (count(*))::integer AS event_count,
    (sum(e.minutes))::integer AS minutes,
    (count(*) FILTER (WHERE (e.initiated
            AND (el.label_id <> 24))))::integer AS org_event_count,
(sum(e.minutes * e.invitee_count) FILTER (WHERE (e.initiated
        AND (el.label_id <> 24))))::integer AS org_minutes
FROM (event_x e
    JOIN event_label el ON (e.id = el.event_id))
WHERE (e.status <> 'cancelled'::event_status)
GROUP BY
    e.user_id,
    e.day,
    el.label_id,
    e.response;

CREATE OR REPLACE VIEW "public"."expenditure_monthly" AS
SELECT
    e.user_id,
    (date_trunc('month'::text, (e.day)::timestamp with time zone))::date AS month,
    e.label_id,
    e.response,
    sum(e.event_count) AS event_count,
    sum(e.minutes) AS minutes,
    sum(e.org_event_count) AS org_event_count,
    sum(e.org_minutes) AS org_minutes
FROM
    expenditure e
GROUP BY
    e.user_id,
    ((date_trunc('month'::text, (e.day)::timestamp with time zone))::date),
    e.label_id,
    e.response;

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

CREATE OR REPLACE FUNCTION public.label (expenditure_monthly)
    RETURNS SETOF label ROWS 1
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        *
    FROM
        label
    WHERE
        id = $1.label_id
$function$;

CREATE OR REPLACE FUNCTION public.label (event_x)
    RETURNS SETOF label
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        label.*
    FROM
        label
        JOIN event_label ON label.id = event_label.label_id
    WHERE
        event_label.event_id = $1.id
$function$;

CREATE OR REPLACE FUNCTION public.invitee (event_x)
    RETURNS SETOF invitee
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        *
    FROM
        invitee
    WHERE
        event_id = $1.id
$function$;

ALTER VIEW "public"."invitation_admin" SET (security_invoker = FALSE);

ALTER VIEW "public"."event_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."waitlist_admin" SET (security_invoker = FALSE);

ALTER VIEW expenditure SET (security_invoker = TRUE);

ALTER VIEW expenditure_monthly SET (security_invoker = TRUE);

ALTER VIEW expenditure_rolling SET (security_invoker = TRUE);

ALTER VIEW "public"."sync_admin" SET (security_invoker = FALSE);

