CREATE OR REPLACE VIEW "public"."event_x" WITH ( security_invoker = TRUE)
-- for formatting
AS
WITH event_x1 AS (
    SELECT
        a.user_id AS user_id,
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
        COALESCE(min(i.response) FILTER (WHERE ct.is_self = TRUE), 'tentative') AS response,
        calc_minutes (e.at) AS minutes,
        count(DISTINCT i.email) FILTER (WHERE (i.response = 'accepted'::event_response))::integer AS attendee_count,
    count(DISTINCT i.email)::integer AS invitee_count,
    CASE WHEN EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) >= 60 * 60 * 23 THEN
        timezone(user_timezone (), timezone('UTC', lower(e.at)))::date
    ELSE
        (lower(e.at) at time zone user_timezone ())::date
    END AS day,
    COALESCE(bool_or(ct.is_self) FILTER (WHERE ct.email = e.organizer_email), FALSE) AS initiated,
    calc_all_day (e.at) AS all_day,
    calc_event_type (e.at, min(e.availability), COALESCE(min(i.response) FILTER (WHERE ct.is_self), 'tentative'), count(DISTINCT i.email)::integer > 1
        OR bool_or(e.invitees_hidden)) AS type,
    calc_internal (count(DISTINCT i.email)::integer, min(ct.domain_id) FILTER (WHERE ct.is_self), array_agg(DISTINCT ct.domain_id)) AS internal,
    array_agg(DISTINCT i.email ORDER BY i.email) AS invitees,
    array_agg(DISTINCT split_part(i.email, '@', 2)
    ORDER BY split_part(i.email, '@', 2)) AS invitee_domains,
    bool_or(e.invitees_hidden) AS invitees_hidden,
    min(e.series) IS NOT NULL AS recurring,
    calc_notice (min(e.created_at), e.at) AS notice,
    calc_speedy (e.at) AS speedy,
    calc_rounded_length (e.at) AS rounded_length,
    calc_meeting_size (count(DISTINCT i.email)::integer) AS size
FROM
    event e
    JOIN calendar c ON (e.calendar_id = c.id)
    JOIN account a ON (c.account_id = a.id)
    JOIN invitee i ON (e.id = i.event_id)
    JOIN contact ct ON (ct.user_id = a.user_id
            AND i.email = ct.email)
    WHERE
        c.enabled = TRUE
    GROUP BY
        a.user_id,
        e.name,
        e.at
)
SELECT
    e.*,
    act.id AS activity_id,
    act.path AS activity_path
FROM
    event_x1 e
    LEFT JOIN LATERAL (
        SELECT
            activity_id,
            CASE WHEN series IS NOT NULL THEN
                128
            ELSE
                0
            END + CASE WHEN name IS NOT NULL THEN
                64
            ELSE
                0
            END + CASE WHEN invitees IS NOT NULL THEN
                32
            ELSE
                0
            END + CASE WHEN invitee_domain IS NOT NULL THEN
                16
            ELSE
                0
            END + CASE WHEN account_id IS NOT NULL THEN
                8
            ELSE
                0
            END + CASE WHEN calendar_id IS NOT NULL THEN
                4
            ELSE
                0
            END + CASE WHEN internal IS NOT NULL THEN
                2
            ELSE
                0
            END + CASE WHEN type IS NOT NULL THEN
                1
            ELSE
                0
            END AS priority
        FROM
            rule r
        WHERE
            e.user_id = r.user_id
            AND (r.series IS NULL
                OR e.series = r.series)
            AND (r.name IS NULL
                OR e.name = r.name)
            AND (r.invitees IS NULL
                OR e.invitees = r.invitees)
            AND (r.invitee_domain IS NULL
                OR e.invitee_domains @> ARRAY[r.invitee_domain])
            AND (r.account_id IS NULL
                OR e.account_id = r.account_id)
            AND (r.calendar_id IS NULL
                OR e.calendar_id = r.calendar_id)
            AND (r.internal IS NULL
                OR e.internal = r.internal)
            AND (r.type IS NULL
                OR e.type = r.type)
        ORDER BY
            priority DESC,
            created_at DESC
        LIMIT 1) r ON TRUE
    LEFT JOIN activity act ON (e.user_id = act.user_id
            AND r.activity_id = act.id);

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

