DROP TRIGGER IF EXISTS "upsert_activity_x" ON "public"."activity_x";

DROP TRIGGER IF EXISTS "upsert_event_x" ON "public"."event_x";

DROP FUNCTION IF EXISTS public.calendar (event_x);

DROP FUNCTION IF EXISTS public.invitee (event_x);

DROP VIEW IF EXISTS "public"."activity_x";

DROP VIEW IF EXISTS "public"."balance";

DROP VIEW IF EXISTS "public"."gap_daily";

DROP VIEW IF EXISTS "public"."gap_monthly";

DROP VIEW IF EXISTS "public"."insight";

DROP VIEW IF EXISTS "public"."note_x";

DROP VIEW IF EXISTS "public"."sync_admin";

DROP VIEW IF EXISTS "public"."waitlist_admin";

DROP VIEW IF EXISTS "public"."gap";

DROP VIEW IF EXISTS "public"."event_x";

ALTER TABLE "public"."activity"
    ADD COLUMN "draft" boolean NOT NULL DEFAULT FALSE;

ALTER TABLE "public"."event"
    ADD COLUMN "draft" boolean NOT NULL DEFAULT FALSE;

ALTER TABLE "public"."note"
    ADD COLUMN "draft" boolean NOT NULL DEFAULT FALSE;

CREATE OR REPLACE VIEW "public"."activity_x" AS
SELECT
    c2.id,
    cu.user_id,
    c2.created_at,
    c2.draft,
    GREATEST (cs.modified_at, cu.modified_at, c2.modified_at) AS modified_at,
    c2.name,
    replace_parent_path (c1.path, c2.path, COALESCE(cu.path, c1.path)) AS path,
    COALESCE(cs."order", (((EXTRACT(epoch FROM CURRENT_TIMESTAMP) * (1000)::numeric))::double precision * (10)::double precision)) AS "order",
    COALESCE(cs.pomodoro, 25) AS pomodoro
FROM (((activity_user cu
            JOIN activity c1 ON (cu.activity_id = c1.id))
        JOIN activity c2 ON (c1.path @> c2.path))
    LEFT JOIN activity_settings cs ON (((cs.user_id = cu.user_id)
                AND (c2.id = cs.activity_id))));

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
        GREATEST (e_1.modified_at, i.modified_at) AS modified_at,
        e_1.draft AS draft,
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
    e.modified_at,
    e.draft,
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

CREATE OR REPLACE VIEW "public"."note_x" AS
SELECT
    note.id,
    note.created_at,
    note.modified_at,
    note.draft,
    note.archived_at,
    note.user_id,
    note.activity_id,
    note.topic_id,
    note.body,
    note.root,
    note.pinned,
    note."order",
    note.ordered_at,
    note.private,
    note.do_at,
    note.done_at,
    activity.path AS activity_path,
    COALESCE(jsonb_object_agg(tag_users.emoji, tag_users.user_ids) FILTER (WHERE (tag_users.emoji IS NOT NULL)), '{}'::jsonb) AS tags
FROM ((note
    LEFT JOIN activity ON (note.activity_id = activity.id))
    LEFT JOIN (
        SELECT
            tag.note_id,
            tag.emoji,
            array_agg(tag.user_id ORDER BY tag.user_id) AS user_ids
        FROM
            tag
        GROUP BY
            tag.note_id,
            tag.emoji) tag_users ON (note.id = tag_users.note_id))
GROUP BY
    note.id,
    activity.path;

CREATE OR REPLACE VIEW "public"."sync_admin" AS
SELECT
    min(a.email) AS email,
    min(a.id) AS account_id,
    ((array_agg(a.credentials))[0] -> 'provider'::text) AS provider,
    c.provider_id AS calendar_provider_id,
    c.created_at AS first_synced_at,
    c.full_sync_at,
    c.synced_at,
    c.sync_error AS error,
    CASE WHEN ((c.full_sync_at IS NULL)
        OR (c.sync_error IS NOT NULL)) THEN
        NULL::numeric
    ELSE
        round(EXTRACT(epoch FROM (COALESCE(c.full_sync_at, now()) - c.full_sync_started_at)))
    END AS sync_seconds,
    count(e.id) AS event_count
FROM ((account a
    LEFT JOIN calendar c ON (c.account_id = a.id))
    LEFT JOIN event e ON (e.calendar_id = c.id))
GROUP BY
    c.id;

CREATE OR REPLACE VIEW "public"."waitlist_admin" AS
SELECT
    min(w.id) AS id,
    min(w.created_at) AS created_at,
    min(w.email) AS email,
    CASE WHEN (min(c.sync_error) IS NOT NULL) THEN
        'sync_error'::text
    WHEN (min(w.activated_at) IS NOT NULL) THEN
        'active'::text
    WHEN (count(*) FILTER (WHERE ((a.credentials -> 'refresh_token'::text) IS NOT NULL)) > 0) THEN
        'synced'::text
    ELSE
        'waitlisted'::text
    END AS status,
    array_agg(DISTINCT a.email) FILTER (WHERE (a.email IS NOT NULL)) AS sync_accounts,
array_agg(c.sync_error) FILTER (WHERE (c.sync_error IS NOT NULL)) AS sync_error,
((array_agg(a.credentials))[0] -> 'provider'::text) AS provider,
w.invitation,
count(e.id) AS event_count
FROM (((waitlist w
        LEFT JOIN account a ON (((w.email = a.email)
                    AND (a.credentials IS NOT NULL))))
    LEFT JOIN calendar c ON (c.account_id = a.id))
    LEFT JOIN event e ON (e.calendar_id = c.id))
GROUP BY
    w.id;

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

CREATE OR REPLACE FUNCTION public.handle_event_x_upsert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
DECLARE
    invitee text;
BEGIN
    INSERT INTO event (id, user_id, name, at, calendar_id, status, provider_link, summary, description, visibility, availability, conferencing_url, organizer_email, response, series, invitees_hidden, draft)
        VALUES (NEW.id, NEW.user_id, NEW.name, NEW.at, NEW.calendar_id, NEW.status, NEW.provider_link, NEW.summary, NEW.description, NEW.visibility, NEW.availability, NEW.conferencing_url, NEW.organizer_email, NEW.response, NEW.series, NEW.invitees_hidden, NEW.draft)
    ON CONFLICT (id)
        DO UPDATE SET
            name = NEW.name, at = NEW.at, calendar_id = NEW.calendar_id, status = NEW.status, provider_link = NEW.provider_link, summary = NEW.summary, description = NEW.description, visibility = NEW.visibility, availability = NEW.availability, conferencing_url = NEW.conferencing_url, organizer_email = NEW.organizer_email, response = NEW.response, series = NEW.series, invitees_hidden = NEW.invitees_hidden, draft = NEW.draft;
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
$function$;

CREATE OR REPLACE FUNCTION public.handle_activity_x_upsert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
DECLARE
    _activity_id uuid;
BEGIN
    _activity_id := NEW.id;
    IF (OLD IS NULL OR (NEW.name IS DISTINCT FROM OLD.name OR NEW.path IS DISTINCT FROM OLD.path)) THEN
        INSERT INTO activity (id, name, path, draft, created_by)
            VALUES (NEW.id, NEW.name, NEW.path, NEW.draft, auth.uid ())
        ON CONFLICT (id)
            DO UPDATE SET
                name = NEW.name, path = NEW.path, draft = NEW.draft
            RETURNING
                id INTO _activity_id;
    END IF;
    IF (OLD IS NULL AND (NEW.order IS NOT NULL OR NEW.pomodoro IS NOT NULL)) OR (OLD IS NOT NULL AND (NEW."order" IS DISTINCT FROM OLD."order" OR NEW.pomodoro IS DISTINCT FROM OLD.pomodoro)) THEN
        INSERT INTO activity_settings (user_id, activity_id, "order", pomodoro)
            VALUES (auth.uid (), _activity_id, NEW.order, COALESCE(NEW.pomodoro, 25))
        ON CONFLICT (user_id, activity_id)
            DO UPDATE SET
                "order" = COALESCE(NEW.order, activity_settings."order"), pomodoro = COALESCE(NEW.pomodoro, activity_settings.pomodoro);
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER upsert_activity_x
    INSTEAD OF INSERT OR UPDATE ON public.activity_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_activity_x_upsert ();

CREATE TRIGGER upsert_event_x
    INSTEAD OF INSERT OR UPDATE ON public.event_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_event_x_upsert ();

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

ALTER VIEW balance SET (security_invoker = TRUE);

ALTER VIEW "public"."sync_admin" SET (security_invoker = FALSE);

