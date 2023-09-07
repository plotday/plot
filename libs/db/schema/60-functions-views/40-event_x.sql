CREATE OR REPLACE VIEW "public"."event_x" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    u.id AS user_id,
    min(e.id) AS id,
    e.name,
    (
        CASE WHEN EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) >= 60 * 60 * 23 THEN
            tstzrange(timezone(u.timezone, timezone('UTC', lower(e.at))), timezone(u.timezone, timezone('UTC', upper(e.at))), '[)'::text)
        ELSE
            e.at
        END) AS at,
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
    COALESCE(min(er.response), min(i.response) FILTER (WHERE (ct.contact_user_id = u.id)), 'tentative') AS response,
    (round((EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) / (60)::numeric)))::integer AS minutes,
    count(DISTINCT i.contact_id) FILTER (WHERE (i.response = 'accepted'::event_response)) AS attendee_count,
count(DISTINCT i.contact_id) AS invitee_count,
bool_or(er.ready) AS ready,
bool_or(er.reviewed) AS reviewed
FROM
    event e
    JOIN calendar c ON (e.calendar_id = c.id)
    JOIN account a ON (c.account_id = a.id)
    JOIN "user" u ON (a.user_id = u.id)
    LEFT OUTER JOIN response er ON (u.id = er.user_id
            AND e.provider_id = er.provider_id)
    JOIN invitee i ON (e.id = i.event_id)
    JOIN contact ct ON (i.contact_id = ct.id)
GROUP BY
    u.id,
    e.name,
    e.at;

-- Define a computed relation for PostgREST joins
-- https://postgrest.org/en/stable/references/api/resource_embedding.html#computed-relationships
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

