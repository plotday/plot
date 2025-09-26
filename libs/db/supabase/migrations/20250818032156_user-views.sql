DROP TRIGGER IF EXISTS "upsert_activity_x" ON "public"."activity_x";

DROP TRIGGER IF EXISTS "upsert_priority_x" ON "public"."priority_x";

ALTER TABLE "public"."raw_event"
    DROP CONSTRAINT "calendar_provider_id_unique";

ALTER TABLE "public"."raw_event"
    DROP CONSTRAINT "raw_event_calendar_id_fkey";

DROP FUNCTION IF EXISTS "public"."handle_activity_x_upsert" ();

DROP FUNCTION IF EXISTS "public"."handle_priority_x_upsert" ();

DROP VIEW IF EXISTS "public"."activity_children";

DROP VIEW IF EXISTS "public"."activity_x";

DROP VIEW IF EXISTS "public"."activity_tags";

DROP VIEW IF EXISTS "public"."agent_x";

DROP VIEW IF EXISTS "public"."balance";

DROP VIEW IF EXISTS "public"."balance_without_children";

DROP VIEW IF EXISTS "public"."priority_tags";

DROP VIEW IF EXISTS "public"."priority_children";

DROP VIEW IF EXISTS "public"."priority_x";

ALTER TABLE "public"."raw_event"
    DROP CONSTRAINT "raw_event_pkey";

DROP INDEX IF EXISTS "public"."calendar_provider_id_unique";

DROP INDEX IF EXISTS "public"."idx_activity_do_on";

DROP INDEX IF EXISTS "public"."raw_event_pkey";

DROP TABLE "public"."raw_event";

CREATE TABLE "public"."activity_exception" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid_v7 (),
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL,
    "updated_by" integer NOT NULL DEFAULT 0,
    "deleted_at" timestamp with time zone,
    "activity_id" uuid NOT NULL,
    "occurrence" timestamp with time zone NOT NULL,
    "at" tstzrange,
    "on" daterange,
    "title" text,
    "note" text
);

ALTER TABLE "public"."activity"
    DROP COLUMN "event_series";

ALTER TABLE "public"."activity"
    ADD COLUMN "at" tstzrange;

ALTER TABLE "public"."activity"
    ADD COLUMN "duration" interval;

ALTER TABLE "public"."activity"
    ADD COLUMN "on" daterange;

ALTER TABLE "public"."activity"
    ADD COLUMN "recurrence_dates" timestamp with time zone[];

ALTER TABLE "public"."activity"
    ADD COLUMN "recurrence_exdates" timestamp with time zone[];

ALTER TABLE "public"."activity"
    ADD COLUMN "recurrence_rule" text;

ALTER TABLE "public"."activity_tag"
    ADD COLUMN "occurrence" timestamp with time zone;

CREATE UNIQUE INDEX activity_exception_pkey ON public.activity_exception USING btree (id);

CREATE INDEX idx_activity_at ON public.activity USING gist (at);

CREATE INDEX idx_activity_do_on_range ON public.activity USING gist (do_on);

CREATE INDEX idx_activity_occurrence ON public.activity_exception USING btree (activity_id, occurrence)
WHERE (activity_id IS NOT NULL);

CREATE INDEX idx_activity_on ON public.activity USING gist ("on");

ALTER TABLE "public"."activity_exception"
    ADD CONSTRAINT "activity_exception_pkey" PRIMARY KEY USING INDEX "activity_exception_pkey";

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_recurrence_on_or_at" CHECK (((recurrence_rule IS NULL) OR ((at IS NOT NULL) OR ("on" IS NOT NULL)))) NOT valid;

ALTER TABLE "public"."activity" validate CONSTRAINT "activity_recurrence_on_or_at";

CREATE OR REPLACE FUNCTION public.count_not_null (val anyelement)
    RETURNS integer
    LANGUAGE sql
    IMMUTABLE
    AS $function$
    SELECT
        CASE WHEN val IS NULL THEN
            0
        ELSE
            1
        END;
$function$;

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_single_schedule" CHECK ((((count_not_null (do_on) + count_not_null (at)) + count_not_null ("on")) <= 1)) NOT valid;

ALTER TABLE "public"."activity" validate CONSTRAINT "activity_single_schedule";

ALTER TABLE "public"."activity_exception"
    ADD CONSTRAINT "activity_exception_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES activity (id) NOT valid;

ALTER TABLE "public"."activity_exception" validate CONSTRAINT "activity_exception_activity_id_fkey";

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.handle_user_priority_upsert ()
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
                deleted_at = NEW.deleted_at,
                title = NEW.title,
                path = NEW.path,
                "order" = NEW.order,
                updated_by = NEW.updated_by
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

CREATE OR REPLACE VIEW "public"."priority_child" AS
SELECT
    p.id AS priority_id,
    c.id AS child_id
FROM (priority p
    JOIN priority c ON (c.path <@ p.path));

CREATE OR REPLACE FUNCTION public.upsert_activity (p_id uuid, p_user_id uuid, p_updated_by integer, p_deleted_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_priority_id uuid DEFAULT NULL::uuid, p_path ltree DEFAULT NULL::LTREE, p_draft boolean DEFAULT NULL::boolean, p_private boolean DEFAULT NULL::boolean, p_do_on date DEFAULT NULL::date, p_at tstzrange DEFAULT NULL::tstzrange, p_on daterange DEFAULT NULL::dateRANGE, p_duration interval DEFAULT NULL::interval, p_done_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_title text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_order double precision DEFAULT NULL::double precision, p_recurrence_rule text DEFAULT NULL::text, p_recurrence_exdates timestamp with time zone[] DEFAULT NULL::timestamp with time zone[], p_recurrence_dates timestamp with time zone[] DEFAULT NULL::timestamp with time zone[], p_series uuid DEFAULT NULL::uuid, p_occurrence_start timestamp with time zone DEFAULT NULL::timestamp with time zone)
    RETURNS uuid
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    _activity_id uuid;
    _occurrence_root_id uuid;
    _occurrence_original_start timestamptz;
    _existing_path ltree;
BEGIN
    -- Convert series field to occurrence_root_id
    _occurrence_root_id := p_series;
    _occurrence_original_start := p_occurrence_start;
    -- Check if this is an update to an existing activity
    IF p_id IS NOT NULL THEN
        SELECT
            id INTO _activity_id
        FROM
            activity
        WHERE
            id = p_id;
    END IF;
    -- If updating a synthetic recurrence instance (generated ID), create a new exception record
    IF _activity_id IS NULL AND _occurrence_root_id IS NOT NULL AND _occurrence_original_start IS NOT NULL THEN
        -- This is a new exception for a recurring activity
        _activity_id := gen_random_uuid_v7 ();
        -- Get path from the root recurring activity if not provided
        IF p_path IS NULL THEN
            SELECT
                path INTO _existing_path
            FROM
                activity
            WHERE
                id = _occurrence_root_id;
            p_path := _existing_path;
        END IF;
        -- Insert new exception activity
        INSERT INTO activity (id, updated_by, deleted_at, priority_id, path, draft, private, do_on, at, "on", duration, done_at, title, note, "order", recurrence_rule, recurrence_exdates, recurrence_dates, occurrence_root_id, occurrence_original_start)
            VALUES (_activity_id, p_updated_by, p_deleted_at, COALESCE(p_priority_id, (
                        SELECT
                            priority_id
                        FROM activity
                        WHERE
                            id = _occurrence_root_id)),
                p_path,
                COALESCE(p_draft, FALSE),
                COALESCE(p_private, FALSE),
                p_do_on,
                p_at,
                p_on,
                p_duration,
                p_done_at,
                p_title,
                p_note,
                p_order,
                NULL, -- Exceptions don't have their own recurrence rules
                NULL,
                NULL,
                _occurrence_root_id,
                _occurrence_original_start);
        RETURN _activity_id;
    END IF;
    -- Handle path updates for recurring activity instances
    IF _occurrence_root_id IS NOT NULL AND p_path IS NOT NULL THEN
        -- Update path on the root recurring activity, not the instance
        UPDATE
            activity
        SET
            path = p_path,
            updated_at = now(),
            updated_by = p_updated_by
        WHERE
            id = _occurrence_root_id;
        -- Don't update the path on the exception instance
        p_path := NULL;
    END IF;
    -- Standard upsert for regular activities or existing exception records
    INSERT INTO activity (id, updated_by, deleted_at, priority_id, path, draft, private, do_on, at, "on", duration, done_at, title, note, "order", recurrence_rule, recurrence_exdates, recurrence_dates, occurrence_root_id, occurrence_original_start)
        VALUES (COALESCE(p_id, gen_random_uuid_v7 ()), p_updated_by, p_deleted_at, p_priority_id, p_path, COALESCE(p_draft, FALSE), COALESCE(p_private, FALSE), p_do_on, p_at, p_on, p_duration, p_done_at, p_title, p_note, COALESCE(p_order, public.order_first ()), p_recurrence_rule, p_recurrence_exdates, p_recurrence_dates, _occurrence_root_id, _occurrence_original_start)
    ON CONFLICT (id)
        DO UPDATE SET
            updated_by = EXCLUDED.updated_by,
            updated_at = now(),
            deleted_at = COALESCE(EXCLUDED.deleted_at, activity.deleted_at),
            priority_id = COALESCE(EXCLUDED.priority_id, activity.priority_id),
            path = COALESCE(EXCLUDED.path, activity.path),
            draft = COALESCE(EXCLUDED.draft, activity.draft),
            private = COALESCE(EXCLUDED.private, activity.private),
            do_on = COALESCE(EXCLUDED.do_on, activity.do_on),
            at = COALESCE(EXCLUDED.at, activity.at),
            "on" = COALESCE(EXCLUDED.on, activity.on),
            duration = COALESCE(EXCLUDED.duration, activity.duration),
            done_at = COALESCE(EXCLUDED.done_at, activity.done_at),
            title = COALESCE(EXCLUDED.title, activity.title),
            note = COALESCE(EXCLUDED.note, activity.note),
            "order" = COALESCE(EXCLUDED."order", activity."order"),
            recurrence_rule = COALESCE(EXCLUDED.recurrence_rule, activity.recurrence_rule),
            recurrence_exdates = COALESCE(EXCLUDED.recurrence_exdates, activity.recurrence_exdates),
            recurrence_dates = COALESCE(EXCLUDED.recurrence_dates, activity.recurrence_dates)
        RETURNING
            id INTO _activity_id;
    RETURN _activity_id;
END;
$function$;

CREATE OR REPLACE VIEW "public"."user_priority" AS
SELECT
    pu.user_id,
    p.id,
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
    settings.color
FROM ((((priority_user pu
                JOIN priority root ON (pu.priority_id = root.id))
            JOIN priority user_root ON (((pu.user_id = user_root.created_by)
                        AND user_root.root)))
        JOIN priority p ON (root.path @> p.path))
    LEFT JOIN priority_settings settings ON (((settings.user_id = pu.user_id)
                AND (p.id = settings.priority_id))))
WHERE (pu.deleted_at IS NULL);

CREATE OR REPLACE VIEW "public"."activity_children" AS
SELECT
    a.id,
    c.id AS child_id
FROM (activity a
    JOIN activity c ON (c.path <@ a.path));

CREATE OR REPLACE VIEW "public"."activity_tags" AS
SELECT
    sq.activity_id,
    sq.occurrence,
    jsonb_object_agg(sq.tag_id, sq.user_ids) FILTER (WHERE ((sq.user_ids IS NOT NULL)
    AND (jsonb_array_length(sq.user_ids) > 0))) AS tags,
max(sq.updated_at) AS updated_at,
(array_agg(sq.updated_by ORDER BY sq.updated_at DESC))[1] AS updated_by
FROM (
    SELECT
        at.activity_id,
        at.occurrence,
        at.tag_id,
        jsonb_agg(at.user_id) FILTER (WHERE (at.deleted_at IS NULL)) AS user_ids,
    max(COALESCE(at.deleted_at, at.updated_at)) AS updated_at,
    (array_agg(at.updated_by ORDER BY at.updated_at DESC))[1] AS updated_by
FROM
    activity_tag at
GROUP BY
    at.activity_id,
    at.occurrence,
    at.tag_id) sq
GROUP BY
    sq.activity_id,
    sq.occurrence;

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
    a.tools,
    pc.child_id AS priority_child_id
FROM ((priority_agent pa
        JOIN priority_child pc ON (pa.priority_id = pc.priority_id))
    JOIN agent a ON (pa.agent_id = a.id));

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
    ((COALESCE(activity.done_at, (activity.do_on)::timestamp with time zone) AT TIME ZONE user_timezone ()))::date AS day,
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
    AND ((activity.do_on IS NOT NULL)
        OR (activity.done_at IS NOT NULL)))
GROUP BY
    priority_user.user_id,
    (((COALESCE(activity.done_at, (activity.do_on)::timestamp with time zone) AT TIME ZONE user_timezone ()))::date),
    activity.priority_id,
    CASE WHEN (activity.done_at IS NULL) THEN
        'todo'::text
    ELSE
        'done'::text
    END;

CREATE OR REPLACE VIEW "public"."priority_tags" AS
SELECT
    a.priority_id,
    at.tag_id,
    count(*) AS count,
    max(COALESCE(at.deleted_at, at.updated_at)) AS updated_at
FROM (activity_tag at
    JOIN activity a ON (at.activity_id = a.id))
WHERE ((at.deleted_at IS NULL)
    AND (a.deleted_at IS NULL)
    AND (nlevel (a.path) = 1))
GROUP BY
    a.priority_id,
    at.tag_id;

CREATE OR REPLACE VIEW "public"."user_activity" AS
SELECT
    up.user_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.created_by,
    a.updated_by,
    a.deleted_at,
    a.priority_id,
    a.path,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.note,
    a.do_on,
    a.done_at,
    a.at,
    a."on",
    a.duration,
    a.recurrence_rule,
    a.recurrence_exdates,
    a.recurrence_dates,
    CASE WHEN (a.at IS NOT NULL) THEN
        a.at
    WHEN (a."on" IS NOT NULL) THEN
        NULL::tstzrange
    WHEN (a.done_at IS NOT NULL) THEN
        tstzrange(a.done_at, a.done_at, '[]'::text)
    WHEN (a.do_on IS NOT NULL) THEN
        NULL::tstzrange
    ELSE
        tstzrange(a.created_at, a.created_at, '[]'::text)
    END AS range_at,
    CASE WHEN (a.at IS NOT NULL) THEN
        NULL::daterange
    WHEN (a."on" IS NOT NULL) THEN
        a."on"
    WHEN ((a.do_on IS NOT NULL)
        AND (a.done_at IS NULL)) THEN
        daterange(a.do_on, a.do_on, '[]'::text)
    ELSE
        NULL::daterange
    END AS range_on
FROM (activity a
    JOIN user_priority up ON (a.priority_id = up.id))
WHERE (up.deleted_at IS NULL);

CREATE OR REPLACE VIEW "public"."user_activity_occurrence" AS
SELECT
    ua.user_id,
    ua.id,
    COALESCE(ae.occurrence, at.occurrence) AS occurrence,
    GREATEST (ae.updated_at, at.updated_at) AS updated_at,
    ua.range_at,
    ua.range_on,
    CASE WHEN (ae.deleted_at IS NULL) THEN
        ae.at
    ELSE
        NULL::tstzrange
    END AS at,
    CASE WHEN (ae.deleted_at IS NULL) THEN
        ae."on"
    ELSE
        NULL::daterange
    END AS "on",
    CASE WHEN (ae.deleted_at IS NULL) THEN
        ae.title
    ELSE
        NULL::text
    END AS title,
    CASE WHEN (ae.deleted_at IS NULL) THEN
        ae.note
    ELSE
        NULL::text
    END AS note,
    at.tags
FROM ((activity_exception ae
    FULL JOIN activity_tags at ON (ae.activity_id = at.activity_id))
    LEFT JOIN user_activity ua ON ((ua.id = COALESCE(ae.activity_id, at.activity_id))));

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
    JOIN priority_child pc ON (b.priority_id = pc.child_id))
WHERE (b.priority_id IS NOT NULL)
GROUP BY
    b.user_id,
    b.day,
    b.priority_id,
    b.type;

CREATE TRIGGER upsert_user_priority
    INSTEAD OF INSERT OR UPDATE ON public.user_priority
    FOR EACH ROW
    EXECUTE FUNCTION handle_user_priority_upsert ();

ALTER VIEW "public"."activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_children" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_occurrence" SET (security_invoker = TRUE);

ALTER VIEW gap SET (security_invoker = TRUE);

ALTER VIEW gap_monthly SET (security_invoker = TRUE);

ALTER VIEW gap_daily SET (security_invoker = TRUE);

ALTER VIEW insight SET (security_invoker = TRUE);

ALTER VIEW "admin"."sync" SET (security_invoker = FALSE);

ALTER VIEW "admin"."invitation" SET (security_invoker = FALSE);

ALTER VIEW "public"."event_invitees" SET (security_invoker = TRUE);

ALTER VIEW "public"."event_x" SET (security_invoker = TRUE);

ALTER VIEW public.calendar_x SET (security_invoker = TRUE);

ALTER VIEW "admin"."user" SET (security_invoker = FALSE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority" SET (security_invoker = TRUE);

ALTER VIEW balance_without_children SET (security_invoker = TRUE);

ALTER VIEW balance SET (security_invoker = TRUE);

ALTER VIEW "public"."agent_x" SET (security_invoker = TRUE);

