CREATE OR REPLACE VIEW "public"."event_invitees" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    i.event_id AS event_id,
    MAX(i.modified_at) AS modified_at,
    count(i.email)::integer AS invitee_count,
    count(i.email) FILTER (WHERE (i.response = 'accepted'::event_response))::integer AS attendee_count,
array_agg(i.email) AS invitees,
array_agg(DISTINCT d.name) AS invitee_domains,
COALESCE(array_agg(DISTINCT d.organization_id) FILTER (WHERE d.organization_id IS NOT NULL), ARRAY[]::bigint[]) AS invitee_organization_ids,
COUNT(i.email) FILTER (WHERE d.organization_id IS NULL) > 0 AS freemail_invitees,
calc_meeting_size (count(i.email)::integer) AS size
FROM
    invitee i
    LEFT OUTER JOIN "domain" d ON (d.name = get_domain (i.email))
GROUP BY
    i.event_id;

CREATE OR REPLACE VIEW "public"."event_x" WITH ( security_invoker = TRUE)
-- for formatting
AS
WITH event_x1 AS (
    SELECT
        e.id AS id,
        e.user_id AS user_id,
        e.name,
        (
            CASE WHEN calc_all_day (e.at) THEN
                tstzrange(timezone(user_timezone (), timezone('UTC', lower(e.at))), timezone(user_timezone (), timezone('UTC', upper(e.at))), '[)'::text)
            ELSE
                e.at
            END) AS at,
        c.account_id AS account_id,
        e.calendar_id AS calendar_id,
        e.provider_id AS provider_id,
        COALESCE(e.series, e.provider_id) AS series,
        e.created_at AS created_at,
        GREATEST (e.modified_at, i.modified_at) AS modified_at,
        e.status AS status,
        e.provider_link AS provider_link,
        e.summary AS summary,
        e.description AS description,
        e.visibility AS visibility,
        e.availability AS availability,
        e.conferencing_url AS conferencing_url,
        e.organizer_email AS organizer_email,
        e.response AS response,
        calc_seconds (e.at) AS seconds,
        CASE WHEN EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) >= 60 * 60 * 23 THEN
            timezone(user_timezone (), timezone('UTC', lower(e.at)))::date
        ELSE
            (lower(e.at) at time zone user_timezone ())::date
        END AS day,
        a.email = e.organizer_email AS initiated,
        calc_all_day (e.at) AS all_day,
        calc_event_type (e.at, e.availability, COALESCE(e.response, 'tentative'), i.invitee_count > 1
            OR e.invitees_hidden) AS type,
        d.organization_id IS NOT NULL
        AND (i.freemail_invitees
            OR NOT (d.organization_id = ALL (i.invitee_organization_ids))) AS external,
        e.invitees_hidden AS invitees_hidden,
        e.series IS NOT NULL AS recurring,
        calc_notice (e.created_at, e.at) AS notice,
        calc_speedy (e.at) AS speedy,
        calc_rounded_length (e.at) AS rounded_length,
        s.embedding AS embedding,
        i.attendee_count AS attendee_count,
        i.invitee_count AS invitee_count,
        i.invitees AS invitees,
        i.invitee_domains AS invitee_domains,
        i.size AS size
    FROM
        event e
        LEFT OUTER JOIN calendar c ON (e.calendar_id = c.id)
        LEFT OUTER JOIN account a ON (c.account_id = a.id)
        LEFT OUTER JOIN "domain" d ON (d.name = get_domain (a.email))
        LEFT OUTER JOIN "series" s ON (s.user_id = e.user_id
                AND s.series = e.series)
        LEFT OUTER JOIN event_invitees i ON (e.id = i.event_id)
    WHERE
        e.calendar_id IS NULL
        OR c.enabled = TRUE
)
SELECT
    e.*,
    ctx.id AS activity_id,
    ctx.path AS activity_path
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
    LEFT JOIN activity ctx ON ctx.id = s.activity_id;

CREATE OR REPLACE FUNCTION handle_event_x_upsert ()
    RETURNS TRIGGER
    AS $$
DECLARE
    invitee text;
BEGIN
    INSERT INTO event (id, user_id, name, at, calendar_id, status, provider_link, summary, description, visibility, availability, conferencing_url, organizer_email, response, series, invitees_hidden)
        VALUES (NEW.id, NEW.user_id, NEW.name, NEW.at, NEW.calendar_id, NEW.status, NEW.provider_link, NEW.summary, NEW.description, NEW.visibility, NEW.availability, NEW.conferencing_url, NEW.organizer_email, NEW.response, NEW.series, NEW.invitees_hidden)
    ON CONFLICT (id)
        DO UPDATE SET
            name = NEW.name, at = NEW.at, calendar_id = NEW.calendar_id, status = NEW.status, provider_link = NEW.provider_link, summary = NEW.summary, description = NEW.description, visibility = NEW.visibility, availability = NEW.availability, conferencing_url = NEW.conferencing_url, organizer_email = NEW.organizer_email, response = NEW.response, series = NEW.series, invitees_hidden = NEW.invitees_hidden;
    IF OLD.invitees IS NOT NULL THEN
        -- Delete those invitees that are no longer present
        FOREACH invitee IN ARRAY OLD.invitees LOOP
            IF NOT invitee = ANY (NEW.invitees) THEN
                DELETE FROM invitee
                WHERE event_id = OLD.id
                    AND email = invitee;
            END IF;
        END LOOP;
    END IF;
    IF NEW.invitees IS NOT NULL THEN
        -- Insert new invitees
        FOREACH invitee IN ARRAY NEW.invitees LOOP
            INSERT INTO invitee (event_id, email)
                VALUES (NEW.id, invitee)
            ON CONFLICT (event_id, email)
                DO NOTHING;
        END LOOP;
    END IF;
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;

CREATE TRIGGER upsert_event_x
    INSTEAD OF INSERT OR UPDATE ON event_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_event_x_upsert ();

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

