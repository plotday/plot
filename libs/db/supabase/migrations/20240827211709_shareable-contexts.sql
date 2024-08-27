DROP POLICY "Users can read/write their contexts" ON "public"."context";

ALTER TABLE "public"."context"
    DROP CONSTRAINT "context_user_id_fkey";

ALTER TABLE "public"."context"
    DROP CONSTRAINT "user_parent_path_order_unique";

ALTER TABLE "public"."context"
    DROP CONSTRAINT "user_path_unique";

DROP VIEW IF EXISTS "public"."insight_weekly";

DROP FUNCTION IF EXISTS "public"."balance" (user_id uuid, week daterange);

DROP VIEW IF EXISTS "public"."expenditure_weekly";

DROP VIEW IF EXISTS "public"."gap_daily";

DROP VIEW IF EXISTS "public"."gap_monthly";

DROP VIEW IF EXISTS "public"."insight";

DROP VIEW IF EXISTS "public"."note_x";

DROP VIEW IF EXISTS "public"."expenditure";

DROP VIEW IF EXISTS "public"."gap";

DROP VIEW IF EXISTS "public"."event_x" CASCADE;

DROP INDEX IF EXISTS "public"."context_path_idx";

DROP INDEX IF EXISTS "public"."context_user_id";

-- drop index if exists "public"."user_parent_path_order_unique";
DROP INDEX IF EXISTS "public"."user_path_unique";

CREATE TABLE "public"."context_settings" (
    "modified_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "context_id" uuid NOT NULL,
    "order" double precision NOT NULL,
    "pomodoro" integer NOT NULL DEFAULT 25
);

ALTER TABLE "public"."context_settings" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."context_user" (
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "modified_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "context_id" uuid NOT NULL,
    "path" ltree
);

ALTER TABLE "public"."context_user" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."context"
    DROP COLUMN "order";

ALTER TABLE "public"."context"
    DROP COLUMN "pomodoro";

ALTER TABLE "public"."context"
    DROP COLUMN "user_id";

ALTER TABLE "public"."context"
    ADD COLUMN "created_by" uuid NOT NULL;

CREATE UNIQUE INDEX context_path_key ON public.context USING btree (path);

CREATE UNIQUE INDEX context_user_user_path_unique ON public.context_user USING btree (user_id, path);

CREATE UNIQUE INDEX user_context_unique ON public.context_settings USING btree (user_id, context_id);

ALTER TABLE "public"."context"
    ADD CONSTRAINT "context_created_by_fkey" FOREIGN KEY (created_by) REFERENCES auth.users (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."context" validate CONSTRAINT "context_created_by_fkey";

ALTER TABLE "public"."context"
    ADD CONSTRAINT "context_path_key" UNIQUE USING INDEX "context_path_key";

ALTER TABLE "public"."context_settings"
    ADD CONSTRAINT "context_settings_context_id_fkey" FOREIGN KEY (context_id) REFERENCES context (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."context_settings" validate CONSTRAINT "context_settings_context_id_fkey";

ALTER TABLE "public"."context_settings"
    ADD CONSTRAINT "context_settings_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."context_settings" validate CONSTRAINT "context_settings_user_id_fkey";

ALTER TABLE "public"."context_settings"
    ADD CONSTRAINT "user_context_unique" UNIQUE USING INDEX "user_context_unique";

ALTER TABLE "public"."context_user"
    ADD CONSTRAINT "context_user_context_id_fkey" FOREIGN KEY (context_id) REFERENCES context (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."context_user" validate CONSTRAINT "context_user_context_id_fkey";

ALTER TABLE "public"."context_user"
    ADD CONSTRAINT "context_user_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."context_user" validate CONSTRAINT "context_user_user_id_fkey";

ALTER TABLE "public"."context_user"
    ADD CONSTRAINT "context_user_user_path_unique" UNIQUE USING INDEX "context_user_user_path_unique";

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.can_access_context (_context_id uuid)
    RETURNS boolean
    LANGUAGE sql
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.context_user cu
                JOIN public.context c ON c.id = cu.context_id
            WHERE
                cu.user_id = auth.uid ()
                AND c.path @> (
                    SELECT
                        path
                    FROM
                        public.context c2
                    WHERE
                        c2.id = _context_id))
            OR NOT EXISTS (
                SELECT
                    1
                FROM
                    public.context_user cu
                WHERE
                    cu.context_id = _context_id);
$function$;

CREATE OR REPLACE FUNCTION public.can_access_context (_context_path ltree)
    RETURNS boolean
    LANGUAGE sql
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.context_user cu
                JOIN public.context c ON c.id = cu.context_id
            WHERE
                cu.user_id = auth.uid ()
                AND c.path @> (
                    SELECT
                        path
                    FROM
                        public.context c2
                    WHERE
                        c2.path = _context_path));
$function$;

CREATE OR REPLACE FUNCTION public.insert_context_user ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
BEGIN
    IF nlevel (NEW.path) = 1 THEN
        INSERT INTO public.context_user (created_at, modified_at, user_id, context_id)
            VALUES (now(), now(), NEW.created_by, NEW.id);
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.replace_parent_path (parent_path ltree, child_path ltree, new_parent_path ltree)
    RETURNS ltree
    LANGUAGE plpgsql
    AS $function$
BEGIN
    IF child_path = parent_path THEN
        RETURN new_parent_path;
    ELSIF child_path <@ parent_path THEN
        RETURN new_parent_path || subpath (child_path, nlevel (parent_path));
    ELSE
        RETURN child_path;
    END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_created_by ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    NEW.created_by = auth.uid ();
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.balance (user_id uuid, week daterange)
    RETURNS TABLE (
        id uuid,
        budget integer,
        budget_type budget_type,
        count integer,
        minutes integer,
        tentative_count integer,
        tentative_minutes integer,
        declined_count integer,
        declined_minutes integer)
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN QUERY
    SELECT
        c.id,
        b.minutes AS budget,
        b.budget_type,
        COALESCE(e.count, 0)::int AS count,
        COALESCE(e.minutes, 0)::int AS minutes,
        COALESCE(e.tentative_count, 0)::int AS tentative_count,
        COALESCE(e.tentative_minutes, 0)::int AS tentative_minutes,
        COALESCE(e.declined_count, 0)::int AS declined_count,
        COALESCE(e.declined_minutes, 0)::int AS declined_minutes
    FROM (
        SELECT
            c.id
        FROM
            context_x c
        WHERE
            c.user_id = balance.user_id
            -- Include uncategorized events
        UNION ALL
        SELECT
            NULL AS id) AS c
    LEFT JOIN ( SELECT DISTINCT ON (b.context_id)
            b.context_id,
            b.minutes,
            b.type AS budget_type
        FROM
            budget b
        WHERE
            b.user_id = balance.user_id
            AND b.minutes IS NOT NULL
            AND b.week <= balance.week
            AND (b.type = 'default'
                OR b.week && balance.week)
        ORDER BY
            b.context_id,
            b.week DESC) AS b ON (b.context_id = c.id
            OR (b.context_id IS NULL
                AND c.id IS NULL))
        LEFT JOIN (
            SELECT
                *
            FROM
                expenditure_weekly e
            WHERE
                e.user_id = balance.user_id
                AND e.week && balance.week) AS e ON (e.context_id = c.id
                OR (b.context_id IS NULL
                    AND c.id IS NULL));
END;
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
        calc_minutes (e_1.at) AS minutes,
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
    e.minutes,
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
    ctx.id AS context_id,
    ctx.path AS context_path
FROM ((event_x1 e
    LEFT JOIN LATERAL (
        SELECT
            series.context_id
        FROM
            series
        WHERE ((series.user_id = e.user_id)
            AND (series.context_id IS NOT NULL))
    ORDER BY
        (series.series = e.series) DESC,
        (series.invitees = e.invitees) DESC,
        (series.embedding <-> e.embedding) DESC
    LIMIT 1) s ON (TRUE))
    LEFT JOIN context ctx ON (ctx.id = s.context_id));

CREATE OR REPLACE VIEW "public"."expenditure" AS
SELECT
    COALESCE(e.user_id, s.user_id) AS user_id,
    COALESCE(e.day, s.day) AS day,
    COALESCE(e.context_id, s.context_id) AS context_id,
    COALESCE((COALESCE(e.count, (0)::bigint) + COALESCE(s.count, (0)::bigint))) AS count,
    COALESCE((COALESCE(e.minutes, (0)::bigint) + COALESCE(s.minutes, 0))) AS minutes,
    COALESCE(e.tentative_count, (0)::bigint) AS tentative_count,
    COALESCE(e.tentative_minutes, (0)::bigint) AS tentative_minutes,
    COALESCE(e.declined_count, (0)::bigint) AS declined_count,
    COALESCE(e.declined_minutes, (0)::bigint) AS declined_minutes
FROM ((
        SELECT
            event_x.user_id,
            event_x.day,
            event_x.context_id,
            COALESCE(count(*) FILTER (WHERE (event_x.response <> 'declined'::event_response)), (0)::bigint) AS count,
            COALESCE(sum(event_x.minutes) FILTER (WHERE (event_x.response <> 'declined'::event_response)), (0)::bigint) AS minutes,
            COALESCE(count(*) FILTER (WHERE ((event_x.response = 'tentative'::event_response)
                OR (event_x.response IS NULL))), (0)::bigint) AS tentative_count,
            COALESCE(sum(event_x.minutes) FILTER (WHERE ((event_x.response = 'tentative'::event_response)
                OR (event_x.response IS NULL))), (0)::bigint) AS tentative_minutes,
            COALESCE(count(*) FILTER (WHERE (event_x.response = 'declined'::event_response)), (0)::bigint) AS declined_count,
            COALESCE(sum(event_x.minutes) FILTER (WHERE (event_x.response = 'declined'::event_response)), (0)::bigint) AS declined_minutes
        FROM
            event_x
        WHERE ((event_x.status <> 'cancelled'::event_status)
            AND (event_x.response <> 'declined'::event_response)
            AND (event_x.all_day = FALSE))
    GROUP BY
        event_x.user_id,
        event_x.day,
        event_x.context_id) e
    FULL JOIN (
        SELECT
            session.user_id,
            ((lower(session.at) AT TIME ZONE user_timezone ()))::date AS day,
            session.context_id,
            count(*) AS count,
            (sum((EXTRACT(epoch FROM ((upper(session.at) - lower(session.at)) - session.paused)) / (60)::numeric)))::integer AS minutes
        FROM
            session
        GROUP BY
            session.user_id,
            (((lower(session.at) AT TIME ZONE user_timezone ()))::date),
            session.context_id) s ON (((e.user_id = s.user_id)
                AND (e.day = s.day)
                AND (e.context_id = s.context_id))));

CREATE OR REPLACE VIEW "public"."expenditure_weekly" AS
SELECT
    expenditure.user_id,
    week_from_date (expenditure.day) AS week,
    expenditure.context_id,
    sum(COALESCE(expenditure.count, (0)::bigint)) AS count,
    sum(expenditure.minutes) AS minutes,
    sum(expenditure.tentative_count) AS tentative_count,
    sum(expenditure.tentative_minutes) AS tentative_minutes,
    sum(expenditure.declined_count) AS declined_count,
    sum(expenditure.declined_minutes) AS declined_minutes
FROM
    expenditure
GROUP BY
    expenditure.user_id,
    (week_from_date (expenditure.day)),
    expenditure.context_id;

CREATE OR REPLACE VIEW "public"."gap" AS
SELECT
    gap.user_id,
    gap.day,
    (gap.at * tstzrange(((gap.day + work_day_start ()) AT TIME ZONE user_timezone ()), ((gap.day + work_day_end ()) AT TIME ZONE user_timezone ()), '[]'::text)) AS at,
    extract_minutes ((gap.at * tstzrange(((gap.day + work_day_start ()) AT TIME ZONE user_timezone ()), ((gap.day + work_day_end ()) AT TIME ZONE user_timezone ()), '[]'::text))) AS minutes
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
    sum(gap.minutes) AS total,
    sum(gap.minutes) FILTER (WHERE (gap.minutes >= 60)) AS focus
FROM
    gap
GROUP BY
    gap.user_id,
    gap.day;

CREATE OR REPLACE VIEW "public"."gap_monthly" AS
SELECT
    gap.user_id,
    (date_trunc('month'::text, (gap.day)::timestamp with time zone))::date AS month,
    sum(gap.minutes) AS total,
    sum(gap.minutes) FILTER (WHERE (gap.minutes >= 60)) AS focus
FROM
    gap
GROUP BY
    gap.user_id,
    ((date_trunc('month'::text, (gap.day)::timestamp with time zone))::date);

CREATE OR REPLACE VIEW "public"."insight" AS
SELECT
    e.user_id,
    e.day,
    text2ltree (min(ltree2text (e.context_path))) AS context_path,
    e.type,
    e.response,
    nv.name,
    nv.value,
    (count(*))::integer AS count,
    (sum(e.minutes))::integer AS minutes
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
    e.context_path,
    e.type,
    e.response,
    nv.name,
    nv.value;

CREATE OR REPLACE VIEW "public"."note_x" AS
SELECT
    note.id,
    note.created_at,
    note.modified_at,
    note.user_id,
    note.context_id,
    note.topic_id,
    note.body,
    note."order",
    note.root,
    note.private,
    context.path AS context_path,
    COALESCE(jsonb_object_agg(tag_users.emoji, tag_users.user_ids) FILTER (WHERE (tag_users.emoji IS NOT NULL)), '{}'::jsonb) AS tags
FROM ((note
    LEFT JOIN context ON (note.context_id = context.id))
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
    context.path;

CREATE OR REPLACE FUNCTION public.parent_path (p ltree)
    RETURNS ltree
    LANGUAGE plpgsql
    IMMUTABLE
    AS $function$
BEGIN
    IF nlevel (p) = 1 THEN
        RETURN p;
    END IF;
    RETURN subpath (p, 0, nlevel (p) - 1);
END;
$function$;

CREATE OR REPLACE VIEW "public"."context_x" AS
SELECT
    c2.id,
    cu.user_id,
    GREATEST (cs.modified_at, cu.modified_at, c2.modified_at) AS modified_at,
    c2.name,
    replace_parent_path (c1.path, c2.path, COALESCE(cu.path, c1.path)) AS path,
    COALESCE(cs."order", (((EXTRACT(epoch FROM CURRENT_TIMESTAMP) * (1000)::numeric))::double precision * (10)::double precision)) AS "order",
    COALESCE(cs.pomodoro, 25) AS pomodoro
FROM (((context_user cu
            JOIN context c1 ON (cu.context_id = c1.id))
        JOIN context c2 ON (c1.path @> c2.path))
    LEFT JOIN context_settings cs ON (((cs.user_id = cu.user_id)
                AND (c2.id = cs.context_id))));

CREATE POLICY "Users can access their contexts" ON "public"."context" AS permissive
    FOR SELECT TO authenticated
        USING (can_access_context (id));

CREATE POLICY "Users can create new contexts in their contexts" ON "public"."context" AS permissive
    FOR INSERT TO authenticated
        WITH CHECK (can_access_context (parent_path (path)));

CREATE POLICY "Users can create new root contexts" ON "public"."context" AS permissive
    FOR INSERT TO authenticated
        WITH CHECK ((nlevel (path) = 1));

CREATE POLICY "Users can update their contexts" ON "public"."context" AS permissive
    FOR UPDATE TO authenticated
        USING (can_access_context (id))
        WITH CHECK (((nlevel (path) = 1) OR can_access_context (parent_path (path))));

CREATE POLICY "Users can read/write their context settings" ON "public"."context_settings" AS permissive
    FOR ALL TO authenticated
        USING ((user_id = auth.uid ()));

CREATE POLICY "Users can see who shares their contexts" ON "public"."context_user" AS permissive
    FOR SELECT TO authenticated
        USING (((user_id = auth.uid ()) OR can_access_context (context_id)));

CREATE TRIGGER context_insert_trigger
    AFTER INSERT ON public.context
    FOR EACH ROW
    EXECUTE FUNCTION insert_context_user ();

CREATE TRIGGER set_context_created_by
    BEFORE INSERT ON public.context
    FOR EACH ROW
    EXECUTE FUNCTION update_created_by ();

CREATE TRIGGER set_context_settings_modified_at
    BEFORE UPDATE ON public.context_settings
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

CREATE TRIGGER set_context_user_modified_at
    BEFORE UPDATE ON public.context_user
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

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

ALTER VIEW "public"."context_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."waitlist_admin" SET (security_invoker = FALSE);

ALTER VIEW expenditure SET (security_invoker = TRUE);

ALTER VIEW expenditure_weekly SET (security_invoker = TRUE);

ALTER VIEW "public"."sync_admin" SET (security_invoker = FALSE);

