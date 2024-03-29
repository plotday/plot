CREATE OR REPLACE VIEW "public"."event_x" WITH ( security_invoker = TRUE)
-- for formatting
AS
WITH event_x1 AS (
    SELECT
        e.user_id AS user_id,
        min(e.id) AS id,
        e.name,
        (
            CASE WHEN calc_all_day (e.at) THEN
                tstzrange(timezone(user_timezone (), timezone('UTC', lower(e.at))), timezone(user_timezone (), timezone('UTC', upper(e.at))), '[)'::text)
            ELSE
                e.at
            END) AS at,
        min(c.account_id) AS account_id,
        min(e.calendar_id) AS calendar_id,
        min(e.provider_id) AS provider_id,
        COALESCE(min(e.series), min(e.provider_id)) AS series,
        min(e.created_at) AS created_at,
        min(e.status) AS status,
        min(e.provider_link) AS provider_link,
        min(e.summary) AS summary,
        min(e.description) AS description,
        min(e.visibility) AS visibility,
        min(e.availability) AS availability,
        min(e.conferencing_url) AS conferencing_url,
        min(e.organizer_email) AS organizer_email,
        min(e.response) AS response,
        calc_minutes (e.at) AS minutes,
        count(DISTINCT i.email) FILTER (WHERE (i.response = 'accepted'::event_response))::integer AS attendee_count,
    count(DISTINCT i.email)::integer AS invitee_count,
    CASE WHEN EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) >= 60 * 60 * 23 THEN
        timezone(user_timezone (), timezone('UTC', lower(e.at)))::date
    ELSE
        (lower(e.at) at time zone user_timezone ())::date
    END AS day,
    array_agg(a.email) && array_agg(e.organizer_email) AS initiated,
    calc_all_day (e.at) AS all_day,
    calc_event_type (e.at, min(e.availability), COALESCE(min(e.response), 'tentative'), count(DISTINCT i.email)::integer > 1
        OR bool_or(e.invitees_hidden)) AS type,
    min(d.organization_id) IS NOT NULL
    AND COUNT(i.email) FILTER (WHERE get_domain (i.email) != get_domain (a.email)) > 0 AS external,
    array_remove(array_agg(DISTINCT i.email ORDER BY i.email), NULL) AS invitees,
    array_remove(array_agg(DISTINCT split_part(i.email, '@', 2)
        ORDER BY split_part(i.email, '@', 2)), NULL) AS invitee_domains,
    bool_or(e.invitees_hidden) AS invitees_hidden,
    min(e.series) IS NOT NULL AS recurring,
    calc_notice (min(e.created_at), e.at) AS notice,
    calc_speedy (e.at) AS speedy,
    calc_rounded_length (e.at) AS rounded_length,
    calc_meeting_size (count(DISTINCT i.email)::integer) AS size,
    (array_agg(s.embedding))[1] AS embedding
FROM
    event e
    LEFT OUTER JOIN invitee i ON (e.id = i.event_id)
    LEFT OUTER JOIN calendar c ON (e.calendar_id = c.id)
        LEFT OUTER JOIN account a ON (c.account_id = a.id)
        LEFT OUTER JOIN "domain" d ON (d.name = get_domain (a.email))
        LEFT OUTER JOIN "series" s ON (s.user_id = e.user_id
                AND s.series = e.series)
    WHERE
        e.calendar_id IS NULL
        OR c.enabled = TRUE
    GROUP BY
        e.user_id,
        e.name,
        e.at
)
SELECT
    e.*,
    act.id AS activity_id,
    ctx.path AS context_path
FROM
    event_x1 e
    LEFT JOIN LATERAL (
        SELECT
            activity_id
        FROM
            series
        WHERE
            user_id = e.user_id
            AND activity_id IS NOT NULL
        ORDER BY
            series = e.series DESC,
            invitees = e.invitees DESC,
            embedding <-> e.embedding DESC
        LIMIT 1) AS s ON TRUE
    LEFT JOIN activity act ON (e.user_id = act.user_id
            AND s.activity_id = act.id)
    LEFT JOIN context ctx ON (e.user_id = act.user_id
            AND ctx.id = act.context_id);

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

CREATE OR REPLACE FUNCTION public.calendar (event_x)
    RETURNS SETOF calendar ROWS 1
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        calendar.*
    FROM
        calendar
    WHERE
        calendar.id = $1.calendar_id
$function$;

CREATE OR REPLACE FUNCTION public.account (calendar)
    RETURNS SETOF account ROWS 1
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        account.*
    FROM
        account
    WHERE
        account.id = $1.account_id
$function$;

