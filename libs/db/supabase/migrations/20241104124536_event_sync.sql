DROP VIEW IF EXISTS "public"."balance";

DROP VIEW IF EXISTS "public"."gap_daily";

DROP VIEW IF EXISTS "public"."gap_monthly";

DROP VIEW IF EXISTS "public"."insight";

DROP VIEW IF EXISTS "public"."gap";

DROP VIEW IF EXISTS "public"."event_x" CASCADE;

DROP VIEW IF EXISTS "public"."event_invitees";

ALTER TABLE "public"."invitee"
    ADD COLUMN "updated_at" timestamp with time zone NOT NULL DEFAULT now();

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.handle_event_x_upsert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
DECLARE
    invitee text;
BEGIN
    INSERT INTO event (id, user_id, name, at, calendar_id, provider_id, created_at, status, provider_link, summary, description, visibility, availability, conferencing_url, organizer_email, response, series, invitees_hidden)
        VALUES (NEW.id, NEW.user_id, NEW.name, NEW.at, NEW.calendar_id, NEW.provider_id, NEW.created_at, NEW.status, NEW.provider_link, NEW.summary, NEW.description, NEW.visibility, NEW.availability, NEW.conferencing_url, NEW.organizer_email, NEW.response, NEW.series, NEW.invitees_hidden)
    ON CONFLICT (id)
        DO UPDATE SET
            name = NEW.name, at = NEW.at, calendar_id = NEW.calendar_id, provider_id = NEW.provider_id, status = NEW.status, provider_link = NEW.provider_link, summary = NEW.summary, description = NEW.description, visibility = NEW.visibility, availability = NEW.availability, conferencing_url = NEW.conferencing_url, organizer_email = NEW.organizer_email, response = NEW.response, series = NEW.series, invitees_hidden = NEW.invitees_hidden;
    IF TG_OP = 'UPDATE' THEN
        -- Delete those invitees that are no longer present
        FOREACH invitee IN ARRAY OLD.invitees LOOP
            IF NOT invitee = ANY (NEW.invitees) THEN
                DELETE FROM invitee
                WHERE event_id = OLD.id
                    AND email = invitee;
            END IF;
        END LOOP;
    END IF;
    -- Insert new invitees
    FOREACH invitee IN ARRAY NEW.invitees LOOP
        INSERT INTO invitee (event_id, email)
            VALUES (NEW.id, invitee)
        ON CONFLICT (event_id, email)
            DO NOTHING;
    END LOOP;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE VIEW "public"."event_invitees" AS
SELECT
    i.event_id,
    max(i.updated_at) AS updated_at,
    (count(i.email))::integer AS invitee_count,
    (count(i.email) FILTER (WHERE (i.response = 'accepted'::event_response)))::integer AS attendee_count,
array_agg(i.email) AS invitees,
array_agg(DISTINCT d.name) AS invitee_domains,
COALESCE(array_agg(DISTINCT d.organization_id) FILTER (WHERE (d.organization_id IS NOT NULL)), ARRAY[]::bigint[]) AS invitee_organization_ids,
(count(i.email) FILTER (WHERE (d.organization_id IS NULL)) > 0) AS freemail_invitees,
calc_meeting_size ((count(i.email))::integer) AS size
FROM (invitee i
    LEFT JOIN DOMAIN d ON ((d.name = get_domain (i.email))))
GROUP BY
    i.event_id;

CREATE OR REPLACE VIEW "public"."event_x" AS
WITH event_x1 AS (
    SELECT
        e_1.id,
        e_1.user_id,
        e_1.name,
        CASE WHEN calc_all_day (e_1.at) THEN
            tstzrange(timezone(user_timezone (), timezone('UTC'::text, lower(e_1.at))), timezone(user_timezone (), timezone('UTC'::text, upper(e_1.at))), '[)'::text)
        ELSE
            e_1.at
        END AS at,
        c.account_id,
        e_1.calendar_id,
        e_1.provider_id,
        COALESCE(e_1.series, e_1.provider_id) AS series,
        e_1.created_at,
        GREATEST (e_1.updated_at, i.updated_at) AS updated_at,
        e_1.status,
        e_1.provider_link,
        e_1.summary,
        e_1.description,
        e_1.visibility,
        e_1.availability,
        e_1.conferencing_url,
        e_1.organizer_email,
        e_1.response,
        calc_seconds (e_1.at) AS seconds,
        CASE WHEN (EXTRACT(epoch FROM (upper(e_1.at) - lower(e_1.at))) >= (((60 * 60) * 23))::numeric) THEN
            (timezone(user_timezone (), timezone('UTC'::text, lower(e_1.at))))::date
        ELSE
            ((lower(e_1.at) AT TIME ZONE user_timezone ()))::date
        END AS day,
        (a.email = e_1.organizer_email) AS initiated,
        calc_all_day (e_1.at) AS all_day,
        calc_event_type (e_1.at, e_1.availability, COALESCE(e_1.response, 'tentative'::event_response), ((i.invitee_count > 1)
            OR e_1.invitees_hidden)) AS type,
        ((d.organization_id IS NOT NULL)
        AND (i.freemail_invitees
            OR (NOT (d.organization_id = ALL (i.invitee_organization_ids))))) AS external,
        e_1.invitees_hidden,
        (e_1.series IS NOT NULL) AS recurring,
        calc_notice (e_1.created_at, e_1.at) AS notice,
        calc_speedy (e_1.at) AS speedy,
        calc_rounded_length (e_1.at) AS rounded_length,
        s_1.embedding,
        i.attendee_count,
        i.invitee_count,
        i.invitees,
        i.invitee_domains,
        i.size
    FROM (((((event e_1
                    LEFT JOIN calendar c ON (e_1.calendar_id = c.id))
                LEFT JOIN account a ON (c.account_id = a.id))
            LEFT JOIN DOMAIN d ON ((d.name = get_domain (a.email))))
        LEFT JOIN series s_1 ON (((s_1.user_id = e_1.user_id)
                    AND (s_1.series = e_1.series))))
        LEFT JOIN event_invitees i ON (e_1.id = i.event_id))
    WHERE ((e_1.calendar_id IS NULL)
        OR (c.enabled = TRUE)))
SELECT
    e.id,
    e.user_id,
    e.name,
    e.at,
    e.account_id,
    e.calendar_id,
    e.provider_id,
    e.series,
    e.created_at,
    e.updated_at,
    e.status,
    e.provider_link,
    e.summary,
    e.description,
    e.visibility,
    e.availability,
    e.conferencing_url,
    e.organizer_email,
    e.response,
    e.seconds,
    e.day,
    e.initiated,
    e.all_day,
    e.type,
    e.external,
    e.invitees_hidden,
    e.recurring,
    e.notice,
    e.speedy,
    e.rounded_length,
    e.embedding,
    e.attendee_count,
    e.invitee_count,
    e.invitees,
    e.invitee_domains,
    e.size,
    ctx.id AS activity_id,
    ctx.path AS activity_path
FROM ((event_x1 e
    LEFT JOIN LATERAL (
        SELECT
            series.activity_id
        FROM
            series
        WHERE ((series.user_id = e.user_id)
            AND (series.activity_id IS NOT NULL))
    ORDER BY
        (series.series = e.series) DESC,
        (series.invitees = e.invitees) DESC,
        (series.embedding <-> e.embedding) DESC
    LIMIT 1) s ON (TRUE))
    LEFT JOIN activity ctx ON (ctx.id = s.activity_id));

CREATE OR REPLACE VIEW "public"."gap" AS
SELECT
    gap.user_id,
    gap.day,
    (gap.at * tstzrange(((gap.day + work_day_start ()) AT TIME ZONE user_timezone ()), ((gap.day + work_day_end ()) AT TIME ZONE user_timezone ()), '[]'::text)) AS at,
    calc_seconds ((gap.at * tstzrange(((gap.day + work_day_start ()) AT TIME ZONE user_timezone ()), ((gap.day + work_day_end ()) AT TIME ZONE user_timezone ()), '[]'::text))) AS seconds
FROM (
    SELECT
        e.user_id,
        e.day,
        CASE WHEN ((EXTRACT(isodow FROM e.day) <= (5)::numeric)
            AND (max(upper(e.at)) OVER start_window < lower(e.at))) THEN
            tstzrange(max(upper(e.at)) OVER start_window, lower(e.at), '[)'::text)
        ELSE
            NULL::tstzrange
        END AS at
    FROM (
        SELECT
            event_x.user_id,
            event_x.day,
            event_x.at
        FROM
            event_x
        WHERE ((event_x.type = 'meeting'::event_type)
            AND (event_x.status <> 'cancelled'::event_status)
            AND (event_x.response = 'accepted'::event_response))
    UNION
    SELECT DISTINCT
        auth.uid () AS id,
        days.day,
        tstzrange(((days.day + '1 day'::interval) AT TIME ZONE user_timezone ()), ((days.day + '1 day'::interval) AT TIME ZONE user_timezone ()), '[]'::text) AS at
    FROM (
        SELECT
            (generate_series(((min(lower(event.at)))::date)::timestamp with time zone, ((max(upper(event.at)))::date)::timestamp with time zone, '1 day'::interval))::date AS day
        FROM
            event) days) e
WINDOW start_window AS (PARTITION BY e.user_id ORDER BY (lower(e.at)),
    (upper(e.at))
    ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)) gap
WHERE (gap.at IS NOT NULL);

CREATE OR REPLACE VIEW "public"."gap_daily" AS
SELECT
    gap.user_id,
    gap.day,
    sum(gap.seconds) AS total,
    sum(gap.seconds) FILTER (WHERE (gap.seconds >= 60)) AS focus
FROM
    gap
GROUP BY
    gap.user_id,
    gap.day;

CREATE OR REPLACE VIEW "public"."gap_monthly" AS
SELECT
    gap.user_id,
    (date_trunc('month'::text, (gap.day)::timestamp with time zone))::date AS month,
    sum(gap.seconds) AS total,
    sum(gap.seconds) FILTER (WHERE (gap.seconds >= 60)) AS focus
FROM
    gap
GROUP BY
    gap.user_id,
    ((date_trunc('month'::text, (gap.day)::timestamp with time zone))::date);

CREATE OR REPLACE VIEW "public"."insight" AS
SELECT
    e.user_id,
    e.day,
    text2ltree (min(ltree2text (e.activity_path))) AS activity_path,
    e.type,
    e.response,
    nv.name,
    nv.value,
    (count(*))::integer AS count,
    (sum(e.seconds))::integer AS seconds
FROM (event_x e
    CROSS JOIN LATERAL (
        VALUES ('Total'::text, NULL::text),
            ('Length'::text, (e.rounded_length)::text),
            ('Size'::text, e.size),
            ('Organizer'::text, CASE WHEN e.initiated THEN
                    'You'::text
                ELSE
                    e.organizer_email
                END),
            ('External'::text, CASE WHEN (e.external = TRUE) THEN
                    'External'::text
                ELSE
                    'Internal'::text
                END),
            ('Recurring'::text, CASE WHEN e.recurring THEN
                    'Recurring'::text
                ELSE
                    'Ad hoc'::text
                END),
            ('Notice'::text, CASE WHEN (e.notice < 12) THEN
                    '< 12 hours'::text
                WHEN (e.notice < 24) THEN
                    '< 24 hours'::text
                WHEN (e.notice < (24 * 7)) THEN
                    '< week'::text
                ELSE
                    '> week'::text
                END)) nv (name, value))
WHERE (e.status <> 'cancelled'::event_status)
GROUP BY
    e.user_id,
    e.day,
    e.activity_path,
    e.type,
    e.response,
    nv.name,
    nv.value;

CREATE OR REPLACE VIEW "public"."balance" AS
SELECT
    COALESCE(ex.user_id, s.user_id) AS user_id,
    COALESCE(ex.day, s.day) AS day,
    COALESCE(ex.activity_id, s.activity_id) AS activity_id,
    ex.type,
    COALESCE((COALESCE(ex.events, (0)::bigint) + COALESCE(s.events, (0)::bigint))) AS events,
    COALESCE((COALESCE(ex.seconds, (0)::bigint) + COALESCE(s.seconds, 0))) AS seconds
FROM ((
        SELECT
            event_x.user_id,
            event_x.day,
            event_x.activity_id,
            'accepted'::text AS type,
            COALESCE(count(*) FILTER (WHERE ((event_x.response <> 'declined'::event_response)
                AND (event_x.response <> 'tentative'::event_response)
            AND (event_x.response IS NOT NULL))), (0)::bigint) AS events,
            COALESCE(sum(event_x.seconds) FILTER (WHERE ((event_x.response <> 'declined'::event_response)
                AND (event_x.response <> 'tentative'::event_response)
            AND (event_x.response IS NOT NULL))), (0)::bigint) AS seconds
        FROM
            event_x
        WHERE ((event_x.status <> 'cancelled'::event_status)
            AND (event_x.all_day = FALSE))
    GROUP BY
        event_x.user_id,
        event_x.day,
        event_x.activity_id
    UNION ALL
    SELECT
        event_x.user_id,
        event_x.day,
        event_x.activity_id,
        'tentative'::text AS type,
        COALESCE(count(*) FILTER (WHERE ((event_x.response = 'tentative'::event_response)
            OR (event_x.response IS NULL))), (0)::bigint) AS events,
        COALESCE(sum(event_x.seconds) FILTER (WHERE ((event_x.response = 'tentative'::event_response)
            OR (event_x.response IS NULL))), (0)::bigint) AS seconds
    FROM
        event_x
    WHERE ((event_x.status <> 'cancelled'::event_status)
        AND (event_x.all_day = FALSE))
GROUP BY
    event_x.user_id,
    event_x.day,
    event_x.activity_id
UNION ALL
SELECT
    event_x.user_id,
    event_x.day,
    event_x.activity_id,
    'declined'::text AS type,
    COALESCE(count(*) FILTER (WHERE (event_x.response = 'declined'::event_response)), (0)::bigint) AS events,
    COALESCE(sum(event_x.seconds) FILTER (WHERE (event_x.response = 'declined'::event_response)), (0)::bigint) AS seconds
FROM
    event_x
WHERE ((event_x.status <> 'cancelled'::event_status)
    AND (event_x.all_day = FALSE))
GROUP BY
    event_x.user_id,
    event_x.day,
    event_x.activity_id) ex
    FULL JOIN (
        SELECT
            session.user_id,
            ((lower(session.at) AT TIME ZONE user_timezone ()))::date AS day,
            session.activity_id,
            'accepted'::text AS type,
            count(*) AS events,
            (sum((EXTRACT(epoch FROM (upper(session.at) - lower(session.at))) / (60)::numeric)))::integer AS seconds
        FROM
            session
        GROUP BY
            session.user_id,
            (((lower(session.at) AT TIME ZONE user_timezone ()))::date),
            session.activity_id) s ON (((ex.user_id = s.user_id)
                AND (ex.day = s.day)
                AND (ex.activity_id = s.activity_id)
                AND (ex.type = s.type))));

CREATE TRIGGER upsert_event_x
    INSTEAD OF INSERT OR UPDATE ON public.event_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_event_x_upsert ();

CREATE TRIGGER set_invitee_updated_at
    BEFORE UPDATE ON public.invitee
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE OR REPLACE FUNCTION public.calendar (event_x)
    RETURNS SETOF calendar
    LANGUAGE sql
    STABLE ROWS 1
    AS $function$
    SELECT
        calendar.*
    FROM
        calendar
    WHERE
        calendar.id = $1.calendar_id
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

ALTER VIEW note_x SET (security_invoker = TRUE);

ALTER VIEW gap SET (security_invoker = TRUE);

ALTER VIEW gap_monthly SET (security_invoker = TRUE);

ALTER VIEW gap_daily SET (security_invoker = TRUE);

ALTER VIEW insight SET (security_invoker = TRUE);

-- ALTER VIEW insight_weekly SET ( security_invoker = TRUE);
ALTER VIEW "public"."invitation_admin" SET (security_invoker = FALSE);

ALTER VIEW "public"."event_invitees" SET (security_invoker = TRUE);

ALTER VIEW "public"."event_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."waitlist_admin" SET (security_invoker = FALSE);

ALTER VIEW "public"."activity_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."sync_admin" SET (security_invoker = FALSE);

