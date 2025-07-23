DROP TRIGGER IF EXISTS "on_user_created_add_default_priority" ON "auth"."users";

DROP TRIGGER IF EXISTS "upsert_activity_x" ON "public"."activity_x";

DROP TRIGGER IF EXISTS "upsert_event_x" ON "public"."event_x";

DROP TRIGGER IF EXISTS "upsert_priority_x" ON "public"."priority_x";

DROP FUNCTION IF EXISTS "public"."add_default_priority" ();

DROP FUNCTION IF EXISTS "public"."calendar" (event_x);

DROP FUNCTION IF EXISTS "public"."invitee" (event_x);

DROP VIEW IF EXISTS "public"."activity_children";

DROP VIEW IF EXISTS "public"."activity_x";

DROP VIEW IF EXISTS "public"."agent_x";

DROP VIEW IF EXISTS "public"."balance";

DROP VIEW IF EXISTS "public"."balance_without_children";

DROP VIEW IF EXISTS "public"."calendar_x";

DROP VIEW IF EXISTS "public"."gap_daily";

DROP VIEW IF EXISTS "public"."gap_monthly";

DROP VIEW IF EXISTS "public"."insight";

DROP VIEW IF EXISTS "public"."priority_children";

DROP VIEW IF EXISTS "public"."priority_x";

DROP VIEW IF EXISTS "public"."gap";

DROP VIEW IF EXISTS "public"."event_x";

ALTER TABLE "public"."account"
    ADD COLUMN "updated_by" integer NOT NULL DEFAULT 0;

ALTER TABLE "public"."activity"
    ADD COLUMN "updated_by" integer NOT NULL DEFAULT 0;

ALTER TABLE "public"."calendar"
    ADD COLUMN "updated_by" integer NOT NULL DEFAULT 0;

ALTER TABLE "public"."event"
    ADD COLUMN "updated_by" integer NOT NULL DEFAULT 0;

ALTER TABLE "public"."priority"
    ADD COLUMN "updated_by" integer NOT NULL DEFAULT 0;

ALTER TABLE "public"."session"
    ADD COLUMN "updated_by" integer NOT NULL DEFAULT 0;

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.add_default_priority (user_id uuid)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $function$
DECLARE
    _priority_id uuid;
    payload jsonb;
    _onboarding_agent_id uuid;
    _priority_agent_id uuid;
BEGIN
    INSERT INTO public.priority (created_by, title, path, root)
        VALUES (user_id, 'Everything', public.generate_path (NULL), TRUE)
    RETURNING
        id INTO _priority_id;
    INSERT INTO public.priority_settings (user_id, priority_id)
        VALUES (user_id, _priority_id);
    -- SELECT public.create_onboarding_priority(NEW.id) INTO _onboarding_priority_id;
    -- Activate agent
    SELECT
        id INTO _onboarding_agent_id
    FROM
        public.agent
    WHERE
        public_id = 'onboarding'
    LIMIT 1;
    -- Add onboarding agent to the priority if agent exists
    IF _onboarding_agent_id IS NOT NULL THEN
        INSERT INTO public.priority_agent (priority_id, agent_id, name)
            VALUES (_priority_id, _onboarding_agent_id, 'Plot')
        RETURNING
            id INTO _priority_agent_id;
    END IF;
    -- INSERT INTO public.priority_agent (priority_id, agent_id, name, config);
    payload := jsonb_build_object('public_id', 'onboarding', 'priority_agent_id', _priority_agent_id, 'priority_id', _priority_id);
    PERFORM
        net.http_post (url := public.get_api_root () || '/activate', body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net'));
END;
$function$;

CREATE OR REPLACE FUNCTION public.add_default_priority_trigger ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $function$
BEGIN
    PERFORM
        public.add_default_priority (NEW.id);
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE VIEW "public"."activity_x" AS
SELECT
    a.id,
    pu.user_id,
    a.created_at,
    a.updated_at,
    a.updated_by,
    a.deleted_at,
    a.created_by,
    a.priority_id,
    a.path,
    a.draft,
    a.private,
    a.pinned,
    a.do_at,
    a.done_at,
    a.title,
    a.note,
    a.event_series,
    a."order",
    (COALESCE(a.done_at, (a.do_at)::timestamp with time zone, a.created_at))::date AS day
FROM ((priority_user pu
        JOIN priority p ON (((pu.priority_id = p.id)
                    OR (p.path <@ (
                            SELECT
                                priority.path
                            FROM
                                priority
                        WHERE (priority.id = pu.priority_id))))))
    JOIN activity a ON (a.priority_id = p.id))
WHERE ((pu.deleted_at IS NULL)
    AND (p.deleted_at IS NULL));

CREATE OR REPLACE FUNCTION public.agent_uuid ()
    RETURNS uuid
    LANGUAGE plpgsql
    AS $function$
DECLARE
    random_bytes bytea;
    uuid_text text;
BEGIN
    SELECT
        encode(extensions.gen_random_bytes(12), 'hex') INTO uuid_text;
    RETURN (uuid ('ab07ab07' || '-' || substring(uuid_text FROM 1 FOR 4) || '-' || substring(uuid_text FROM 3 FOR 4) || '-' || substring(uuid_text FROM 5 FOR 4) || '-' || substring(uuid_text FROM 7 FOR 12)));
END;
$function$;

CREATE OR REPLACE VIEW "public"."calendar_x" AS
SELECT
    calendar.id,
    calendar.created_at,
    calendar.updated_at,
    calendar.deleted_at,
    calendar.account_id,
    calendar.priority_id,
    calendar.provider_id,
    calendar.synced_dates,
    calendar.sync_state,
    calendar.watch_id,
    calendar.watch_secret,
    calendar.watch_expires_at,
    calendar.sequence,
    calendar.full_sync_at,
    calendar.synced_at,
    calendar.sync_error,
    calendar.full_sync_started_at,
    calendar.name,
    calendar.enabled,
    calendar.ready,
    calendar.updated_by,
    account.user_id
FROM (calendar
    JOIN account ON (calendar.account_id = account.id));

CREATE OR REPLACE VIEW "public"."event_x" AS
WITH event_x1 AS (
    SELECT
        e_1.id,
        COALESCE(a.user_id, e_1.user_id) AS user_id,
        e_1.name,
        CASE WHEN calc_all_day (e_1.at) THEN
            tstzrange(timezone(user_timezone (), timezone('UTC'::text, lower(e_1.at))), timezone(user_timezone (), timezone('UTC'::text, upper(e_1.at))), '[)'::text)
        ELSE
            e_1.at
        END AS at,
        c_1.account_id,
        e_1.calendar_id,
        e_1.provider_id,
        COALESCE(e_1.series, e_1.provider_id) AS series,
        e_1.created_at,
        GREATEST (e_1.updated_at, i.updated_at) AS updated_at,
        GREATEST (e_1.deleted_at, i.deleted_at) AS deleted_at,
        e_1.draft,
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
                    LEFT JOIN calendar c_1 ON (e_1.calendar_id = c_1.id))
                LEFT JOIN account a ON (c_1.account_id = a.id))
            LEFT JOIN DOMAIN d ON ((d.name = get_domain (a.email))))
        LEFT JOIN series s_1 ON (((s_1.user_id = e_1.user_id)
                    AND (s_1.series = e_1.series))))
        LEFT JOIN event_invitees i ON (e_1.id = i.event_id))
    WHERE ((e_1.calendar_id IS NULL)
        OR (c_1.enabled = TRUE)))
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
    e.deleted_at,
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
    ctx.id AS priority_id,
    ctx.path AS priority_path
FROM (((event_x1 e
        LEFT JOIN calendar c ON (c.id = e.calendar_id))
    LEFT JOIN LATERAL (
        SELECT
            series.priority_id
        FROM
            series
        WHERE ((series.user_id = e.user_id)
            AND (series.priority_id IS NOT NULL))
    ORDER BY
        (series.series = e.series) DESC,
        (series.invitees = e.invitees) DESC,
        (series.embedding <-> e.embedding) DESC
    LIMIT 1) s ON (TRUE))
    LEFT JOIN priority ctx ON ((ctx.id = COALESCE(s.priority_id, c.priority_id))));

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

CREATE OR REPLACE FUNCTION public.get_api_root ()
    RETURNS text
    LANGUAGE plpgsql
    STABLE
    AS $function$
BEGIN
    RETURN COALESCE(current_setting('plot.api_root', TRUE), 'http://host.docker.internal:8787/_');
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
    -- Insert or update the activity
    INSERT INTO activity (id, updated_by, deleted_at, priority_id, path, draft, private, pinned, do_at, done_at, "order", title, note, event_series)
        VALUES (NEW.id, NEW.updated_by, NEW.deleted_at, NEW.priority_id, NEW.path, NEW.draft, NEW.private, NEW.pinned, NEW.do_at, NEW.done_at, NEW.order, NEW.title, NEW.note, NEW.event_series)
    ON CONFLICT (id)
        DO UPDATE SET
            updated_by = NEW.updated_by, deleted_at = NEW.deleted_at, priority_id = NEW.priority_id, path = NEW.path, draft = NEW.draft, private = NEW.private, pinned = NEW.pinned, do_at = NEW.do_at, done_at = NEW.done_at, "order" = NEW.order, title = NEW.title, note = NEW.note, event_series = NEW.event_series
        RETURNING
            id INTO _activity_id;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.handle_priority_x_upsert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
DECLARE
    _priority_id uuid;
BEGIN
    _priority_id := NEW.id;
    IF (OLD IS NULL OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at OR NEW.title IS DISTINCT FROM OLD.title OR NEW.path IS DISTINCT FROM OLD.path OR NEW.order IS DISTINCT FROM OLD.order OR NEW.updated_by IS DISTINCT FROM OLD.updated_by) THEN
        INSERT INTO priority (id, deleted_at, title, path, "order", updated_by)
            VALUES (NEW.id, NEW.deleted_at, NEW.title, NEW.path, NEW.order, NEW.updated_by)
        ON CONFLICT (id)
            DO UPDATE SET
                deleted_at = NEW.deleted_at, title = NEW.title, path = NEW.path, "order" = NEW.order, updated_by = NEW.updated_by
            RETURNING
                id INTO _priority_id;
    END IF;
    IF ((OLD IS NULL AND NEW."order" IS NOT NULL) OR (OLD IS NOT NULL AND NEW."order" IS DISTINCT FROM OLD."order")) THEN
        UPDATE
            priority_user
        SET
            "order" = NEW.order
        WHERE
            user_id = COALESCE(auth.uid (), NEW.user_id)
            AND priority_id = _priority_id;
    END IF;
    -- TODO handle path update
    IF ((OLD IS NULL AND (NEW."pomodoro" IS NOT NULL OR NEW."color" IS NOT NULL)) OR (OLD IS NOT NULL AND (NEW."pomodoro" IS DISTINCT FROM OLD."pomodoro" OR NEW."color" IS DISTINCT FROM OLD."color"))) THEN
        INSERT INTO priority_settings (user_id, priority_id, pomodoro, color)
            VALUES (COALESCE(auth.uid (), NEW.user_id), _priority_id, NEW.pomodoro, NEW.color)
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET
                pomodoro = COALESCE(NEW.pomodoro, priority_settings.pomodoro), color = COALESCE(NEW.color, priority_settings.color);
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE VIEW "public"."insight" AS
SELECT
    e.user_id,
    e.day,
    text2ltree (min(ltree2text (e.priority_path))) AS priority_path,
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
    e.priority_path,
    e.type,
    e.response,
    nv.name,
    nv.value;

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_activity ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    event_type text;
    payload jsonb;
    api_url text;
BEGIN
    IF TG_OP = 'INSERT' THEN
        event_type := 'created';
    ELSIF TG_OP = 'UPDATE' THEN
        event_type := 'updated';
    ELSIF TG_OP = 'DELETE' THEN
        event_type := 'deleted';
    END IF;
    -- Build the payload
    payload := jsonb_build_object('type', 'activity', 'event', event_type, 'item', CASE WHEN TG_OP = 'DELETE' THEN
            to_jsonb (OLD)
        ELSE
            to_jsonb (NEW)
        END, 'agents', (
            SELECT
                jsonb_agg(jsonb_build_object('public_id', public_id, 'priority_agent_id', id, 'config', config)) AS agents_jsonb FROM agent_x
            WHERE
                priority_child_id = COALESCE(NEW.priority_id, OLD.priority_id)
                AND id != COALESCE(NEW.created_by, OLD.created_by)), 'timestamp', extract(epoch FROM now()), 'table', 'activity');
    api_url := get_api_root () || '/update';
    PERFORM
        net.http_post (url := api_url, body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net'));
    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_user_for_account ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
BEGIN
    PERFORM
        realtime.send (jsonb_build_object('table', 'account', 'updated_by', COALESCE(NEW.updated_by, OLD.updated_by)), -- JSONB Payload
            'sync', -- Event name
            'user:' || COALESCE(NEW.user_id, OLD.user_id)::text, -- Topic
            FALSE -- Public / Private flag
);
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_user_for_activity ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
BEGIN
    PERFORM
        realtime.send (jsonb_build_object('table', 'activity', 'updated_by', COALESCE(NEW.updated_by, OLD.updated_by)), -- JSONB Payload
            'sync', -- Event name
            'user:' || COALESCE(NEW.created_by, OLD.created_by)::text, -- Topic
            FALSE -- Public / Private flag
);
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_user_for_calendar ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
BEGIN
    PERFORM
        realtime.send (jsonb_build_object('table', 'calendar', 'updated_by', COALESCE(NEW.updated_by, OLD.updated_by)), 'sync', 'user:' || (
                SELECT
                    user_id
                FROM account
                WHERE
                    id = COALESCE(NEW.account_id, OLD.account_id))::text, FALSE);
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_user_for_event ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
BEGIN
    PERFORM
        realtime.send (jsonb_build_object('table', 'event', 'updated_by', COALESCE(NEW.updated_by, OLD.updated_by)), -- JSONB Payload
            'sync', -- Event name
            'user:' || COALESCE(NEW.user_id, OLD.user_id)::text, -- Topic
            FALSE -- Public / Private flag
);
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_user_for_priority ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
BEGIN
    PERFORM
        realtime.send (jsonb_build_object('table', 'priority', 'updated_by', COALESCE(NEW.updated_by, OLD.updated_by)), -- JSONB Payload
            'sync', -- Event name
            'user:' || COALESCE(NEW.created_by, OLD.created_by)::text, -- Topic
            FALSE -- Public / Private flag
);
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_user_for_session ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
BEGIN
    PERFORM
        realtime.send (jsonb_build_object('table', 'session', 'updated_by', COALESCE(NEW.updated_by, OLD.updated_by)), -- JSONB Payload
            'sync', -- Event name
            'user:' || COALESCE(NEW.user_id, OLD.user_id)::text, -- Topic
            FALSE -- Public / Private flag
);
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE VIEW "public"."priority_x" AS
SELECT
    p.id,
    pu.user_id,
    p.created_at,
    GREATEST (settings.updated_at, pu.updated_at, p.updated_at) AS updated_at,
    GREATEST (pu.deleted_at, p.deleted_at) AS deleted_at,
    p.created_by,
    p.updated_by,
    (root.root
        AND (p.id = root.id)) AS root,
    p.title,
    CASE WHEN root.root THEN
        p.path
    ELSE
        (COALESCE(pu.path, user_root.path) || subpath (p.path, nlevel (root.path)))
    END AS path,
    CASE WHEN (pu.priority_id = p.id) THEN
        COALESCE(pu."order", p."order")
    ELSE
        p."order"
    END AS "order",
    settings.pomodoro,
    settings.color,
    tags.tags
FROM (((((priority_user pu
                    JOIN priority root ON (pu.priority_id = root.id))
                JOIN priority user_root ON (((pu.user_id = user_root.created_by)
                            AND user_root.root)))
            JOIN priority p ON (root.path @> p.path))
        LEFT JOIN priority_settings settings ON (((settings.user_id = pu.user_id)
                    AND (p.id = settings.priority_id))))
    LEFT JOIN priority_tags tags ON (tags.priority_id = pu.priority_id));

CREATE OR REPLACE VIEW "public"."activity_children" AS
SELECT
    a.id,
    c.id AS child_id
FROM (activity_x a
    JOIN activity c ON (c.path <@ a.path));

CREATE OR REPLACE VIEW "public"."balance_without_children" AS
SELECT
    event_x.user_id,
    event_x.day,
    event_x.priority_id,
    CASE WHEN (event_x.response IS NULL) THEN
        'tentative'::text
    ELSE
        (event_x.response)::text
    END AS type,
    count(*) AS count,
    sum(event_x.seconds) AS seconds,
    max(event_x.updated_at) AS updated_at
FROM
    event_x
WHERE ((event_x.status <> 'cancelled'::event_status)
    AND (event_x.all_day = FALSE))
GROUP BY
    event_x.user_id,
    event_x.day,
    event_x.priority_id,
    event_x.response
UNION ALL
SELECT
    session.user_id,
    ((lower(session.at) AT TIME ZONE user_timezone ()))::date AS day,
    session.priority_id,
    'session'::text AS type,
    count(*) AS count,
    (sum(EXTRACT(epoch FROM (upper(session.at) - lower(session.at)))))::integer AS seconds,
    max(session.updated_at) AS updated_at
FROM
    session
GROUP BY
    session.user_id,
    (((lower(session.at) AT TIME ZONE user_timezone ()))::date),
    session.priority_id
UNION ALL
SELECT
    priority_user.user_id,
    ((COALESCE(activity.done_at, (activity.do_at)::timestamp with time zone) AT TIME ZONE user_timezone ()))::date AS day,
    activity.priority_id,
    CASE WHEN (activity.done_at IS NULL) THEN
        'todo'::text
    ELSE
        'done'::text
    END AS type,
    count(*) AS count,
    0 AS seconds,
    max(activity.updated_at) AS updated_at
FROM (activity
    JOIN priority_user ON (priority_user.priority_id = activity.priority_id))
WHERE ((activity.draft = FALSE)
    AND ((activity.do_at IS NOT NULL)
        OR (activity.done_at IS NOT NULL)))
GROUP BY
    priority_user.user_id,
    (((COALESCE(activity.done_at, (activity.do_at)::timestamp with time zone) AT TIME ZONE user_timezone ()))::date),
    activity.priority_id,
    CASE WHEN (activity.done_at IS NULL) THEN
        'todo'::text
    ELSE
        'done'::text
    END;

CREATE OR REPLACE VIEW "public"."priority_children" AS
SELECT
    a.id,
    c.id AS child_id
FROM (priority_x a
    JOIN priority c ON (c.path <@ a.path));

CREATE OR REPLACE VIEW "public"."agent_x" AS
SELECT
    pa.id,
    pa.priority_id,
    pa.agent_id,
    pa.name,
    pa.config,
    pa.created_at,
    pa.updated_at,
    pa.deleted_at,
    pc.child_id AS priority_child_id,
    a.public_id
FROM ((priority_agent pa
        JOIN priority_children pc ON (pa.priority_id = pc.id))
    JOIN agent a ON (pa.agent_id = a.id));

CREATE OR REPLACE VIEW "public"."balance" AS
SELECT
    b.user_id,
    b.day,
    NULL::uuid AS priority_id,
    b.type,
    sum(b.count) AS count,
    (sum(b.seconds))::integer AS seconds,
    max(b.updated_at) AS updated_at
FROM
    balance_without_children b
WHERE (b.priority_id IS NULL)
GROUP BY
    b.user_id,
    b.day,
    b.type
UNION ALL
SELECT
    b.user_id,
    b.day,
    b.priority_id,
    b.type,
    sum(b.count) AS count,
    (sum(b.seconds))::integer AS seconds,
    max(b.updated_at) AS updated_at
FROM (balance_without_children b
    JOIN priority_children ac ON (b.priority_id = ac.child_id))
WHERE (b.priority_id IS NOT NULL)
GROUP BY
    b.user_id,
    b.day,
    b.priority_id,
    b.type;

CREATE TRIGGER upsert_activity_x
    INSTEAD OF INSERT OR UPDATE ON public.activity_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_activity_x_upsert ();

CREATE TRIGGER upsert_event_x
    INSTEAD OF INSERT OR UPDATE ON public.event_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_event_x_upsert ();

CREATE TRIGGER upsert_priority_x
    INSTEAD OF INSERT OR UPDATE ON public.priority_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_priority_x_upsert ();

CREATE TRIGGER on_user_created_add_default_priority
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.add_default_priority_trigger ();

ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_children" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_children" SET ( security_invoker = TRUE);
ALTER VIEW public.calendar_x SET ( security_invoker = TRUE);
ALTER VIEW "public"."event_invitees" SET ( security_invoker = TRUE);
ALTER VIEW "public"."event_x" SET ( security_invoker = TRUE);
ALTER VIEW gap SET ( security_invoker = TRUE);
ALTER VIEW gap_monthly SET ( security_invoker = TRUE);
ALTER VIEW gap_daily SET ( security_invoker = TRUE);
ALTER VIEW balance_without_children SET ( security_invoker = TRUE);
ALTER VIEW balance SET ( security_invoker = TRUE);
ALTER VIEW insight SET ( security_invoker = TRUE);
ALTER VIEW "public"."agent_x" SET ( security_invoker = TRUE);
ALTER VIEW "admin"."invitation" SET ( security_invoker = FALSE);
ALTER VIEW "admin"."sync" SET ( security_invoker = FALSE);
ALTER VIEW "admin"."user" SET ( security_invoker = FALSE);
