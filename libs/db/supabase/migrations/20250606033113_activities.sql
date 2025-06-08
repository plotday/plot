DROP TRIGGER IF EXISTS "upsert_event_x" ON "public"."event_x";

DROP TRIGGER IF EXISTS "upsert_priority_x" ON "public"."priority_x";

ALTER TABLE "public"."priority"
    DROP CONSTRAINT "priority_check";

DROP VIEW IF EXISTS "public"."balance";

DROP VIEW IF EXISTS "public"."balance_without_children";

DROP VIEW IF EXISTS "public"."gap_daily";

DROP VIEW IF EXISTS "public"."gap_monthly";

DROP VIEW IF EXISTS "public"."insight";

DROP VIEW IF EXISTS "public"."priority_children";

DROP VIEW IF EXISTS "public"."priority_x";

DROP VIEW IF EXISTS "public"."gap";

DROP VIEW IF EXISTS "public"."event_x" CASCADE;

CREATE TABLE "public"."activity" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid_v7 (),
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL,
    "deleted_at" timestamp with time zone,
    "priority_id" uuid NOT NULL,
    "path" ltree NOT NULL,
    "order" double precision NOT NULL DEFAULT order_first (),
    "draft" boolean NOT NULL DEFAULT FALSE,
    "private" boolean NOT NULL DEFAULT FALSE,
    "pinned" boolean NOT NULL DEFAULT FALSE,
    "do_at" date,
    "done_at" timestamp with time zone,
    "note" text,
    "event_series" text
);

ALTER TABLE "public"."activity" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."priority"
    DROP COLUMN "do_at";

ALTER TABLE "public"."priority"
    DROP COLUMN "done_at";

ALTER TABLE "public"."priority"
    DROP COLUMN "draft";

ALTER TABLE "public"."priority"
    DROP COLUMN "event_series";

ALTER TABLE "public"."priority"
    DROP COLUMN "note";

ALTER TABLE "public"."priority"
    DROP COLUMN "pinned";

ALTER TABLE "public"."priority"
    DROP COLUMN "private";

ALTER TABLE "public"."priority"
    ALTER COLUMN "title" SET NOT NULL;

CREATE UNIQUE INDEX activity_pkey ON public.activity USING btree (id);

CREATE INDEX idx_activity_do_at ON public.activity USING btree (do_at);

CREATE INDEX idx_activity_done_at ON public.activity USING btree (done_at);

CREATE INDEX idx_activity_path ON public.activity USING gist (path);

CREATE INDEX idx_activity_priority_id ON public.activity USING btree (priority_id);

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_pkey" PRIMARY KEY USING INDEX "activity_pkey";

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_created_by_fkey" FOREIGN KEY (created_by) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."activity" validate CONSTRAINT "activity_created_by_fkey";

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_priority_id_fkey" FOREIGN KEY (priority_id) REFERENCES priority (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."activity" validate CONSTRAINT "activity_priority_id_fkey";

SET check_function_bodies = OFF;

CREATE OR REPLACE VIEW "public"."activity_x" AS
SELECT
    a.id,
    pu.user_id,
    a.created_at,
    a.updated_at,
    a.deleted_at,
    a.created_by,
    a.priority_id,
    a.path,
    a.draft,
    a.private,
    a.pinned,
    a.do_at,
    a.done_at,
    a.note,
    a.event_series,
    a."order",
    CASE WHEN (a.pinned = TRUE) THEN
        (('400000000000000'::numeric)::double precision - a."order")
    WHEN (a.do_at <= now()) THEN
        ((('200000000000000'::numeric - (EXTRACT(epoch FROM a.do_at) * '1000'::numeric)))::double precision - (a."order" / ('10000000'::numeric)::double precision))
    ELSE
        a."order"
    END AS order_x
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

CREATE OR REPLACE FUNCTION public.handle_activity_x_upsert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
DECLARE
    _activity_id uuid;
BEGIN
    _activity_id := NEW.id;
    -- Insert or update the activity
    INSERT INTO activity (id, deleted_at, priority_id, path, draft, private, pinned, do_at, done_at, "order", note, event_series)
        VALUES (NEW.id, NEW.deleted_at, NEW.priority_id, NEW.path, NEW.draft, NEW.private, NEW.pinned, NEW.do_at, NEW.done_at, NEW.order, NEW.note, NEW.event_series)
    ON CONFLICT (id)
        DO UPDATE SET
            deleted_at = NEW.deleted_at,
            priority_id = NEW.priority_id,
            path = NEW.path,
            draft = NEW.draft,
            private = NEW.private,
            pinned = NEW.pinned,
            do_at = NEW.do_at,
            done_at = NEW.done_at,
            "order" = NEW.order,
            note = NEW.note,
            event_series = NEW.event_series
        RETURNING
            id INTO _activity_id;
    RETURN NEW;
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
FROM ((event_x1 e
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
    LEFT JOIN priority ctx ON (ctx.id = s.priority_id));

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

CREATE OR REPLACE FUNCTION public.handle_event_x_upsert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
DECLARE
    invitee text;
BEGIN
    INSERT INTO event (id, user_id, name, at, calendar_id, status, provider_link, summary, description, visibility, availability, conferencing_url, organizer_email, response, series, invitees_hidden, draft, deleted_at)
        VALUES (NEW.id, NEW.user_id, NEW.name, NEW.at, NEW.calendar_id, NEW.status, NEW.provider_link, NEW.summary, NEW.description, NEW.visibility, NEW.availability, NEW.conferencing_url, NEW.organizer_email, NEW.response, NEW.series, NEW.invitees_hidden, NEW.draft, NEW.deleted_at)
    ON CONFLICT (id)
        DO UPDATE SET
            name = NEW.name,
            at = NEW.at,
            calendar_id = NEW.calendar_id,
            status = NEW.status,
            provider_link = NEW.provider_link,
            summary = NEW.summary,
            description = NEW.description,
            visibility = NEW.visibility,
            availability = NEW.availability,
            conferencing_url = NEW.conferencing_url,
            organizer_email = NEW.organizer_email,
            response = NEW.response,
            series = NEW.series,
            invitees_hidden = NEW.invitees_hidden,
            draft = NEW.draft,
            deleted_at = NEW.deleted_at;
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

CREATE OR REPLACE FUNCTION public.handle_priority_x_upsert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
DECLARE
    _priority_id uuid;
BEGIN
    _priority_id := NEW.id;
    IF (OLD IS NULL OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at OR NEW.title IS DISTINCT FROM OLD.title OR NEW.path IS DISTINCT FROM OLD.path OR NEW.order IS DISTINCT FROM OLD.order) THEN
        INSERT INTO priority (id, deleted_at, title, path, "order")
            VALUES (NEW.id, NEW.deleted_at, NEW.title, NEW.path, NEW.order)
        ON CONFLICT (id)
            DO UPDATE SET
                deleted_at = NEW.deleted_at,
                title = NEW.title,
                path = NEW.path,
                "order" = NEW.order
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
                pomodoro = COALESCE(NEW.pomodoro, priority_settings.pomodoro),
                color = COALESCE(NEW.color, priority_settings.color);
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

CREATE OR REPLACE VIEW "public"."priority_x" AS
SELECT
    p.id,
    pu.user_id,
    p.created_at,
    GREATEST (settings.updated_at, pu.updated_at, p.updated_at) AS updated_at,
    GREATEST (pu.deleted_at, p.deleted_at) AS deleted_at,
    p.created_by,
    (root.root
        AND (p.id = root.id)) AS root,
    p.title,
    CASE WHEN root.root THEN
        p.path
    ELSE
        (COALESCE(pu.path, user_root.path) || subpath (p.path, nlevel (root.path)))
    END AS path,
    CASE WHEN ((pu.priority_id = p.id)
        AND (pu."order" IS NOT NULL)) THEN
        pu."order"
    ELSE
        p."order"
    END AS "order",
    COALESCE(pu."order", p."order") AS order_x,
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

CREATE OR REPLACE FUNCTION public.redeem_invitation (_user_id bigint, _invitation text)
    RETURNS void
    LANGUAGE plpgsql
    AS $function$
BEGIN
    UPDATE
        "invitation"
    SET
        remaining = remaining - 1
    WHERE
        code = _invitation
        AND remaining > 0;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invitation code % not valid', _invitation;
    END IF;
    BEGIN
        UPDATE
            public.user
        SET
            invitation = _invitation,
            activated_at = now()
        WHERE
            id = _user_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'User % not found', _user_id;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            UPDATE
                "invitation"
            SET
                remaining = remaining + 1
            WHERE
                code = _invitation;
                RAISE;
    END;
END;

$function$;

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

CREATE POLICY "Users can delete their own activities" ON "public"."activity" AS permissive
    FOR DELETE TO public
        USING (((created_by = auth.uid ()) AND (EXISTS (
            SELECT
                1
            FROM (priority_user pu
            JOIN priority p ON (((pu.priority_id = p.id) OR (p.path <@ (
                    SELECT
                        priority.path
                    FROM
                        priority
                WHERE (priority.id = pu.priority_id))))))
            WHERE ((pu.user_id = auth.uid ()) AND (pu.deleted_at IS NULL) AND (p.deleted_at IS NULL) AND (activity.priority_id = p.id))))));

CREATE POLICY "Users can insert activities in their accessible priorities" ON "public"."activity" AS permissive
    FOR INSERT TO public
        WITH CHECK (((created_by = auth.uid ()) AND (EXISTS (
            SELECT
                1
            FROM (priority_user pu
            JOIN priority p ON (((pu.priority_id = p.id) OR (p.path <@ (
                    SELECT
                        priority.path
                    FROM
                        priority
                WHERE (priority.id = pu.priority_id))))))
            WHERE ((pu.user_id = auth.uid ()) AND (pu.deleted_at IS NULL) AND (p.deleted_at IS NULL) AND (activity.priority_id = p.id))))));

CREATE POLICY "Users can update their own activities" ON "public"."activity" AS permissive
    FOR UPDATE TO public
        USING (((created_by = auth.uid ()) AND (EXISTS (
            SELECT
                1
            FROM (priority_user pu
            JOIN priority p ON (((pu.priority_id = p.id) OR (p.path <@ (
                    SELECT
                        priority.path
                    FROM
                        priority
                WHERE (priority.id = pu.priority_id))))))
            WHERE ((pu.user_id = auth.uid ()) AND (pu.deleted_at IS NULL) AND (p.deleted_at IS NULL) AND (activity.priority_id = p.id))))));

CREATE POLICY "Users can view activities in their accessible priorities" ON "public"."activity" AS permissive
    FOR SELECT TO public
        USING ((EXISTS (
            SELECT
                1
            FROM (priority_user pu
            JOIN priority p ON (((pu.priority_id = p.id) OR (p.path <@ (
                    SELECT
                        priority.path
                    FROM
                        priority
                WHERE (priority.id = pu.priority_id))))))
            WHERE ((pu.user_id = auth.uid ()) AND (pu.deleted_at IS NULL) AND (p.deleted_at IS NULL) AND (activity.priority_id = p.id)))));

CREATE TRIGGER set_activity_created_by
    BEFORE INSERT ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION update_created_by ();

CREATE TRIGGER set_activity_updated_at
    BEFORE UPDATE ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

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

ALTER VIEW "public"."activity_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_children" SET (security_invoker = TRUE);

ALTER VIEW gap SET (security_invoker = TRUE);

ALTER VIEW gap_monthly SET (security_invoker = TRUE);

ALTER VIEW gap_daily SET (security_invoker = TRUE);

ALTER VIEW insight SET (security_invoker = TRUE);

ALTER VIEW "admin"."sync" SET (security_invoker = FALSE);

ALTER VIEW "admin"."invitation" SET (security_invoker = FALSE);

ALTER VIEW "public"."event_invitees" SET (security_invoker = TRUE);

ALTER VIEW "public"."event_x" SET (security_invoker = TRUE);

ALTER VIEW "admin"."user" SET (security_invoker = FALSE);

ALTER VIEW balance_without_children SET (security_invoker = TRUE);

ALTER VIEW balance SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_children" SET (security_invoker = TRUE);

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

