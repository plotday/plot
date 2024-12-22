ALTER TABLE "public"."context" RENAME TO "activity";

ALTER TABLE "public"."context_user" RENAME TO "activity_user";

ALTER TABLE "public"."context_settings" RENAME TO "activity_settings";

DROP TRIGGER IF EXISTS "context_insert_trigger" ON "public"."activity";

DROP TRIGGER IF EXISTS "set_context_created_by" ON "public"."activity";

DROP TRIGGER IF EXISTS "set_context_updated_at" ON "public"."activity";

DROP TRIGGER IF EXISTS "set_context_settings_updated_at" ON "public"."activity_settings";

DROP TRIGGER IF EXISTS "set_context_user_updated_at" ON "public"."activity_user";

DROP TRIGGER IF EXISTS "upsert_context_x" ON "public"."context_x";

DROP POLICY "Users can access their contexts" ON "public"."activity";

DROP POLICY "Users can create new contexts in their contexts" ON "public"."activity";

DROP POLICY "Users can create new root contexts" ON "public"."activity";

DROP POLICY "Users can update their contexts" ON "public"."activity";

DROP POLICY "Users can read/write their context settings" ON "public"."activity_settings";

DROP POLICY "Users can see who shares their contexts" ON "public"."activity_user";

ALTER TABLE "public"."activity"
    DROP CONSTRAINT "context_created_by_fkey";

ALTER TABLE "public"."activity"
    DROP CONSTRAINT "context_path_key";

ALTER TABLE "public"."activity_settings"
    DROP CONSTRAINT "context_settings_context_id_fkey";

ALTER TABLE "public"."activity_settings"
    DROP CONSTRAINT "context_settings_user_id_fkey";

ALTER TABLE "public"."activity_settings"
    DROP CONSTRAINT "user_context_unique";

ALTER TABLE "public"."activity_user"
    DROP CONSTRAINT "context_user_context_id_fkey";

ALTER TABLE "public"."activity_user"
    DROP CONSTRAINT "context_user_user_id_fkey";

ALTER TABLE "public"."activity_user"
    DROP CONSTRAINT "context_user_user_path_unique";

ALTER TABLE "public"."budget"
    DROP CONSTRAINT "budget_context_id_fkey";

ALTER TABLE "public"."budget"
    DROP CONSTRAINT "priority_user_context_week_unique";

ALTER TABLE "public"."note"
    DROP CONSTRAINT "note_context_id_fkey";

ALTER TABLE "public"."series"
    DROP CONSTRAINT "series_context_id_fkey";

ALTER TABLE "public"."session"
    DROP CONSTRAINT "session_context_id_fkey";

DROP FUNCTION IF EXISTS "public"."can_access_context" (_context_id uuid);

DROP FUNCTION IF EXISTS "public"."can_access_context" (_context_path ltree);

DROP VIEW IF EXISTS "public"."context_x";

DROP FUNCTION IF EXISTS "public"."handle_context_x_upsert" ();

DROP FUNCTION IF EXISTS "public"."insert_context_user" ();

DROP VIEW IF EXISTS "public"."balance";

DROP VIEW IF EXISTS "public"."gap_daily";

DROP VIEW IF EXISTS "public"."gap_monthly";

DROP VIEW IF EXISTS "public"."insight";

DROP VIEW IF EXISTS "public"."note_x";

DROP VIEW IF EXISTS "public"."gap";

DROP VIEW IF EXISTS "public"."event_x" CASCADE;

ALTER TABLE "public"."activity"
    DROP CONSTRAINT "context_pkey";

DROP INDEX IF EXISTS "public"."context_path_key";

DROP INDEX IF EXISTS "public"."context_pkey";

DROP INDEX IF EXISTS "public"."context_user_user_path_unique";

DROP INDEX IF EXISTS "public"."priority_user_context_week_unique";

DROP INDEX IF EXISTS "public"."user_context_unique";

DROP INDEX IF EXISTS "public"."note_order_root";

DROP INDEX IF EXISTS "public"."note_order_topic";

DROP INDEX IF EXISTS "public"."note_topic_root";

ALTER TABLE "public"."activity_settings" RENAME COLUMN "context_id" TO "activity_id";

ALTER TABLE "public"."activity_user" RENAME COLUMN "context_id" TO "activity_id";

ALTER TABLE "public"."budget" RENAME COLUMN "context_id" TO "activity_id";

ALTER TABLE "public"."note" RENAME COLUMN "context_id" TO "activity_id";

ALTER TABLE "public"."series" RENAME COLUMN "context_id" TO "activity_id";

ALTER TABLE "public"."session" RENAME COLUMN "context_id" TO "activity_id";

CREATE UNIQUE INDEX activity_path_key ON public.activity USING btree (path);

CREATE UNIQUE INDEX activity_pkey ON public.activity USING btree (id);

CREATE UNIQUE INDEX activity_user_user_path_unique ON public.activity_user USING btree (user_id, path);

CREATE UNIQUE INDEX priority_user_activity_week_unique ON public.budget USING btree (user_id, activity_id, week) NULLS NOT DISTINCT;

CREATE UNIQUE INDEX user_activity_unique ON public.activity_settings USING btree (user_id, activity_id);

CREATE UNIQUE INDEX note_order_root ON public.note USING btree (activity_id, "order")
WHERE (root = TRUE);

CREATE UNIQUE INDEX note_order_topic ON public.note USING btree (activity_id, topic_id, "order")
WHERE (root = FALSE);

CREATE UNIQUE INDEX note_topic_root ON public.note USING btree (activity_id, topic_id)
WHERE (root = TRUE);

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_pkey" PRIMARY KEY USING INDEX "activity_pkey";

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_created_by_fkey" FOREIGN KEY (created_by) REFERENCES auth.users (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."activity" validate CONSTRAINT "activity_created_by_fkey";

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_path_key" UNIQUE USING INDEX "activity_path_key";

ALTER TABLE "public"."activity_settings"
    ADD CONSTRAINT "activity_settings_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES activity (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."activity_settings" validate CONSTRAINT "activity_settings_activity_id_fkey";

ALTER TABLE "public"."activity_settings"
    ADD CONSTRAINT "activity_settings_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."activity_settings" validate CONSTRAINT "activity_settings_user_id_fkey";

ALTER TABLE "public"."activity_settings"
    ADD CONSTRAINT "user_activity_unique" UNIQUE USING INDEX "user_activity_unique";

ALTER TABLE "public"."activity_user"
    ADD CONSTRAINT "activity_user_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES activity (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."activity_user" validate CONSTRAINT "activity_user_activity_id_fkey";

ALTER TABLE "public"."activity_user"
    ADD CONSTRAINT "activity_user_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."activity_user" validate CONSTRAINT "activity_user_user_id_fkey";

ALTER TABLE "public"."activity_user"
    ADD CONSTRAINT "activity_user_user_path_unique" UNIQUE USING INDEX "activity_user_user_path_unique";

ALTER TABLE "public"."budget"
    ADD CONSTRAINT "budget_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES activity (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."budget" validate CONSTRAINT "budget_activity_id_fkey";

ALTER TABLE "public"."budget"
    ADD CONSTRAINT "priority_user_activity_week_unique" UNIQUE USING INDEX "priority_user_activity_week_unique";

ALTER TABLE "public"."note"
    ADD CONSTRAINT "note_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES activity (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."note" validate CONSTRAINT "note_activity_id_fkey";

ALTER TABLE "public"."series"
    ADD CONSTRAINT "series_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES activity (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."series" validate CONSTRAINT "series_activity_id_fkey";

ALTER TABLE "public"."session"
    ADD CONSTRAINT "session_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES activity (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."session" validate CONSTRAINT "session_activity_id_fkey";

SET check_function_bodies = OFF;

CREATE OR REPLACE VIEW "public"."activity_x" AS
SELECT
    c2.id,
    cu.user_id,
    c2.created_at,
    GREATEST (cs.updated_at, cu.updated_at, c2.updated_at) AS updated_at,
    c2.name,
    replace_parent_path (c1.path, c2.path, COALESCE(cu.path, c1.path)) AS path,
    COALESCE(cs."order", (((EXTRACT(epoch FROM CURRENT_TIMESTAMP) * (1000)::numeric))::double precision * (10)::double precision)) AS "order",
    COALESCE(cs.pomodoro, 25) AS pomodoro
FROM (((activity_user cu
            JOIN activity c1 ON (cu.activity_id = c1.id))
        JOIN activity c2 ON (c1.path @> c2.path))
    LEFT JOIN activity_settings cs ON (((cs.user_id = cu.user_id)
                AND (c2.id = cs.activity_id))));

CREATE OR REPLACE FUNCTION public.can_access_activity (_activity_id uuid)
    RETURNS boolean
    LANGUAGE sql
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.activity_user cu
                JOIN public.activity c ON c.id = cu.activity_id
            WHERE
                cu.user_id = auth.uid ()
                AND c.path @> (
                    SELECT
                        path
                    FROM
                        public.activity c2
                    WHERE
                        c2.id = _activity_id))
            OR NOT EXISTS (
                SELECT
                    1
                FROM
                    public.activity_user cu
                WHERE
                    cu.activity_id = _activity_id);
$function$;

CREATE OR REPLACE FUNCTION public.can_access_activity (_activity_path ltree)
    RETURNS boolean
    LANGUAGE sql
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.activity_user cu
                JOIN public.activity c ON c.id = cu.activity_id
            WHERE
                cu.user_id = auth.uid ()
                AND c.path @> (
                    SELECT
                        path
                    FROM
                        public.activity c2
                    WHERE
                        c2.path = _activity_path));
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
        INSERT INTO activity (id, name, path, created_by)
            VALUES (NEW.id, NEW.name, NEW.path, auth.uid ())
        ON CONFLICT (id)
            DO UPDATE SET
                name = NEW.name, path = NEW.path
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

CREATE OR REPLACE FUNCTION public.insert_activity_user ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
BEGIN
    IF nlevel (NEW.path) = 1 THEN
        INSERT INTO public.activity_user (created_at, updated_at, user_id, activity_id)
            VALUES (now(), now(), NEW.created_by, NEW.id);
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.budget (activity)
    RETURNS SETOF budget
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        *
    FROM
        budget
    WHERE
        activity_id = $1.id;
$function$;

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
    note.updated_at,
    note.user_id,
    note.activity_id,
    note.topic_id,
    note.body,
    note."order",
    note.root,
    note.private,
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

CREATE OR REPLACE FUNCTION public.update_topic_root (note_id uuid)
    RETURNS void
    LANGUAGE plpgsql
    AS $function$
DECLARE
    _root_order text;
    _activity_id uuid;
    _topic_id uuid;
BEGIN
    -- Start a transaction block
    BEGIN
        -- Find the activity_id and topic_id for the given ID
        SELECT
            activity_id,
            topic_id INTO _activity_id,
            _topic_id
        FROM
            "public"."note"
        WHERE
            id = note_id;
        -- Find the previous root and capture the order value
        SELECT
            "order" INTO _root_order
        FROM
            "public"."note"
        WHERE (activity_id IS NOT DISTINCT FROM _activity_id)
            AND topic_id = _topic_id
            AND root = TRUE
        FOR UPDATE;
        -- Update previous root record to set root = false and order = '!'
        UPDATE
            "public"."note"
        SET
            root = FALSE,
            "order" = '!'
        WHERE (activity_id IS NOT DISTINCT FROM _activity_id)
            AND topic_id = _topic_id
            AND root = TRUE;
        -- Update the row for the given id to set root = true and order previous order
        UPDATE
            "public"."note"
        SET
            root = TRUE,
            "order" = _root_order
        WHERE
            id = note_id;
    EXCEPTION
        WHEN OTHERS THEN
            -- Rollback the transaction if any exception occurs
            RAISE;
    END;
END;

$function$;

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

CREATE POLICY "Users can access their activities" ON "public"."activity" AS permissive
    FOR SELECT TO authenticated
        USING (can_access_activity (id));

CREATE POLICY "Users can create new activities in their activities" ON "public"."activity" AS permissive
    FOR INSERT TO authenticated
        WITH CHECK (can_access_activity (parent_path (path)));

CREATE POLICY "Users can create new root activities" ON "public"."activity" AS permissive
    FOR INSERT TO authenticated
        WITH CHECK ((nlevel (path) = 1));

CREATE POLICY "Users can update their activities" ON "public"."activity" AS permissive
    FOR UPDATE TO authenticated
        USING (can_access_activity (id))
        WITH CHECK (((nlevel (path) = 1) OR can_access_activity (parent_path (path))));

CREATE POLICY "Users can read/write their activity settings" ON "public"."activity_settings" AS permissive
    FOR ALL TO authenticated
        USING ((user_id = auth.uid ()));

CREATE POLICY "Users can see who shares their activities" ON "public"."activity_user" AS permissive
    FOR SELECT TO authenticated
        USING (((user_id = auth.uid ()) OR can_access_activity (activity_id)));

CREATE TRIGGER activity_insert_trigger
    AFTER INSERT ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION insert_activity_user ();

CREATE TRIGGER set_activity_created_by
    BEFORE INSERT ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION update_created_by ();

CREATE TRIGGER set_activity_updated_at
    BEFORE UPDATE ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_activity_settings_updated_at
    BEFORE UPDATE ON public.activity_settings
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_activity_user_updated_at
    BEFORE UPDATE ON public.activity_user
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER upsert_activity_x
    INSTEAD OF INSERT OR UPDATE ON public.activity_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_activity_x_upsert ();

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

