DROP TRIGGER IF EXISTS "set_activity_updated_at" ON "public"."activity";

DROP TRIGGER IF EXISTS "set_note_updated_at" ON "public"."note";

DROP TRIGGER IF EXISTS "set_priority_settings_updated_at" ON "public"."priority_settings";

DROP TRIGGER IF EXISTS "upsert_event_x" ON "public"."event_x";

DROP TRIGGER IF EXISTS "upsert_priority_x" ON "public"."priority_x";

DROP POLICY "Users can edit their activites" ON "public"."activity";

DROP POLICY "Users can edit their notes" ON "public"."note";

DROP POLICY "Users can access their activities" ON "public"."priority";

DROP POLICY "Users can create new activities in their activities" ON "public"."priority";

DROP POLICY "Users can create new root activities" ON "public"."priority";

DROP POLICY "Users can update their activities" ON "public"."priority";

DROP POLICY "Users can read/write their priority settings" ON "public"."priority_settings";

DROP POLICY "Users can see who shares their activities" ON "public"."priority_user";

ALTER TABLE "public"."activity"
    DROP CONSTRAINT "activity_priority_id_fkey";

ALTER TABLE "public"."activity"
    DROP CONSTRAINT "activity_user_id_fkey";

ALTER TABLE "public"."note"
    DROP CONSTRAINT "note_activity_id_fkey";

ALTER TABLE "public"."note"
    DROP CONSTRAINT "note_user_id_fkey";

ALTER TABLE "public"."priority_settings"
    DROP CONSTRAINT "priority_settings_priority_id_fkey";

ALTER TABLE "public"."priority_settings"
    DROP CONSTRAINT "priority_settings_user_id_fkey";

ALTER TABLE "public"."priority_settings"
    DROP CONSTRAINT "user_priority_unique";

ALTER TABLE "public"."tag"
    DROP CONSTRAINT "tag_user_id_item_type_item_id_emoji_key";

DROP VIEW IF EXISTS "public"."activity_x";

DROP VIEW IF EXISTS "public"."note_x";

DROP VIEW IF EXISTS "public"."balance";

DROP VIEW IF EXISTS "public"."balance_without_children";

DROP VIEW IF EXISTS "public"."gap_daily";

DROP VIEW IF EXISTS "public"."gap_monthly";

DROP VIEW IF EXISTS "public"."insight";

DROP VIEW IF EXISTS "public"."priority_children";

DROP VIEW IF EXISTS "public"."priority_x";

DROP VIEW IF EXISTS "public"."gap";

DROP VIEW IF EXISTS "public"."event_x";

ALTER TABLE "public"."activity"
    DROP CONSTRAINT "activity_pkey";

ALTER TABLE "public"."note"
    DROP CONSTRAINT "note_pkey";

DROP INDEX IF EXISTS "public"."activity_order_root";

DROP INDEX IF EXISTS "public"."activity_pkey";

DROP INDEX IF EXISTS "public"."note_activity_order";

DROP INDEX IF EXISTS "public"."note_pkey";

DROP INDEX IF EXISTS "public"."priority_settings_user_id_idx";

DROP INDEX IF EXISTS "public"."tag_user_id_item_type_item_id_emoji_key";

DROP INDEX IF EXISTS "public"."user_priority_unique";

DROP TABLE "public"."activity";

DROP TABLE "public"."note";

DROP TABLE "public"."priority_settings";

ALTER TABLE "public"."priority"
    ADD COLUMN "do_at" timestamp with time zone;

ALTER TABLE "public"."priority"
    ADD COLUMN "done_at" timestamp with time zone;

ALTER TABLE "public"."priority"
    ADD COLUMN "note" text;

ALTER TABLE "public"."priority"
    ADD COLUMN "order" double precision NOT NULL DEFAULT order_first ();

ALTER TABLE "public"."priority"
    ADD COLUMN "ordered_at" timestamp with time zone NOT NULL DEFAULT now();

ALTER TABLE "public"."priority"
    ADD COLUMN "pinned" boolean NOT NULL DEFAULT FALSE;

ALTER TABLE "public"."priority"
    ADD COLUMN "private" boolean NOT NULL DEFAULT FALSE;

ALTER TABLE "public"."priority_user"
    ADD COLUMN "color" integer;

ALTER TABLE "public"."priority_user"
    ADD COLUMN "is_default" boolean;

ALTER TABLE "public"."priority_user"
    ADD COLUMN "order" double precision NOT NULL DEFAULT order_first ();

ALTER TABLE "public"."priority_user"
    ADD COLUMN "path" ltree;

ALTER TABLE "public"."priority_user"
    ADD COLUMN "pomodoro" integer;

ALTER TABLE "public"."tag"
    DROP COLUMN "item_id";

ALTER TABLE "public"."tag"
    DROP COLUMN "item_type";

ALTER TABLE "public"."tag"
    ADD COLUMN "priority_id" uuid;

DROP TYPE "public"."item_type";

CREATE UNIQUE INDEX priority_user_user_id_idx ON public.priority_user USING btree (user_id)
WHERE (is_default = TRUE);

CREATE UNIQUE INDEX tag_user_id_priority_id_emoji_key ON public.tag USING btree (user_id, priority_id, emoji);

ALTER TABLE "public"."tag"
    ADD CONSTRAINT "tag_priority_id_fkey" FOREIGN KEY (priority_id) REFERENCES priority (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."tag" validate CONSTRAINT "tag_priority_id_fkey";

ALTER TABLE "public"."tag"
    ADD CONSTRAINT "tag_user_id_priority_id_emoji_key" UNIQUE USING INDEX "tag_user_id_priority_id_emoji_key";

SET check_function_bodies = OFF;

CREATE OR REPLACE VIEW "public"."priority_tags" AS
SELECT
    subquery.priority_id,
    jsonb_object_agg(subquery.emoji, subquery.user_ids) AS tags
FROM (
    SELECT
        tag.priority_id,
        tag.emoji,
        jsonb_agg(tag.user_id) AS user_ids
    FROM
        tag
    GROUP BY
        tag.priority_id,
        tag.emoji) subquery
GROUP BY
    subquery.priority_id;

CREATE OR REPLACE FUNCTION public.add_default_priority ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $function$
DECLARE
    _priority_id uuid;
BEGIN
    INSERT INTO public.priority (created_by, name, path)
        VALUES (NEW.id, 'Personal', public.generate_path (NULL))
    RETURNING
        id INTO _priority_id;
    UPDATE
        public.priority_user
    SET
        is_default = TRUE
    WHERE
        user_id = NEW.id
        AND priority_id = _priority_id;
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
    IF (OLD IS NULL OR (NEW.name IS DISTINCT FROM OLD.name OR NEW.path IS DISTINCT FROM OLD.path OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at)) THEN
        INSERT INTO priority (id, name, path, draft, created_by, deleted_at)
            VALUES (NEW.id, NEW.name, NEW.path, NEW.draft, auth.uid (), NEW.deleted_at)
        ON CONFLICT (id)
            DO UPDATE SET
                name = NEW.name,
                path = NEW.path,
                draft = NEW.draft,
                deleted_at = NEW.deleted_at
            RETURNING
                id INTO _priority_id;
    END IF;
    IF (OLD IS NULL AND (NEW.order IS NOT NULL OR NEW.pomodoro IS NOT NULL OR NEW.color IS NOT NULL OR NEW.is_default IS NOT NULL)) OR (OLD IS NOT NULL AND (NEW."order" IS DISTINCT FROM OLD."order" OR NEW.pomodoro IS DISTINCT FROM OLD.pomodoro OR NEW.color IS DISTINCT FROM OLD.color OR NEW.is_default IS DISTINCT FROM OLD.is_default)) THEN
        INSERT INTO priority_user (user_id, priority_id, "order", pomodoro, color, is_default)
            VALUES (auth.uid (), _priority_id, NEW.order, COALESCE(NEW.pomodoro, 25 * 60), COALESCE(NEW.color, 0), COALESCE(NEW.is_default, FALSE))
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET
                "order" = COALESCE(NEW.order, priority_user."order"),
                pomodoro = COALESCE(NEW.pomodoro, priority_user.pomodoro),
                color = COALESCE(NEW.color, priority_user.color),
                is_default = COALESCE(NEW.is_default, priority_user.is_default);
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.insert_priority_user ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
BEGIN
    -- Only create entry for new, top-level priorities.
    IF extensions.nlevel (NEW.path) = 1 THEN
        INSERT INTO public.priority_user (user_id, priority_id)
            VALUES (NEW.created_by, NEW.id);
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
    c2.id,
    cu.user_id,
    c2.created_at,
    GREATEST (cs.updated_at, cu.updated_at, c2.updated_at) AS updated_at,
    GREATEST (cu.deleted_at, c2.deleted_at) AS deleted_at,
    c2.draft,
    c2.name,
    replace_parent_path (c1.path, c2.path, COALESCE(cs.path, c1.path)) AS path,
    COALESCE(cs."order", c2."order") AS "order",
    cs.pomodoro,
    cs.color,
    COALESCE(cs.is_default, FALSE) AS is_default,
    pt.tags
FROM ((((priority_user cu
                JOIN priority c1 ON (cu.priority_id = c1.id))
            JOIN priority c2 ON (c1.path @> c2.path))
        LEFT JOIN priority_user cs ON (((cs.user_id = cu.user_id)
                    AND (c2.id = cs.priority_id))))
    LEFT JOIN priority_tags pt ON (pt.priority_id = cu.priority_id));

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
    ((COALESCE(priority.done_at, priority.do_at) AT TIME ZONE user_timezone ()))::date AS day,
    priority_user.priority_id,
    CASE WHEN (priority.done_at IS NULL) THEN
        'todo'::text
    ELSE
        'done'::text
    END AS type,
    count(*) AS count,
    0 AS seconds,
    max(priority.updated_at) AS updated_at
FROM (priority
    JOIN priority_user ON (priority_user.priority_id = priority.id))
WHERE ((priority.draft = FALSE)
    AND (priority.do_at IS NOT NULL)
    AND (priority.done_at IS NULL))
GROUP BY
    priority_user.user_id,
    (((COALESCE(priority.done_at, priority.do_at) AT TIME ZONE user_timezone ()))::date),
    priority_user.priority_id,
    CASE WHEN (priority.done_at IS NULL) THEN
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

CREATE POLICY "Users can access their priorities" ON "public"."priority" AS permissive
    FOR SELECT TO authenticated
        USING (can_access_priority (id));

CREATE POLICY "Users can create new priorities in their priorities" ON "public"."priority" AS permissive
    FOR INSERT TO authenticated
        WITH CHECK (can_access_priority (parent_path (path)));

CREATE POLICY "Users can create new root priorities" ON "public"."priority" AS permissive
    FOR INSERT TO authenticated
        WITH CHECK ((nlevel (path) = 1));

CREATE POLICY "Users can update their priorities" ON "public"."priority" AS permissive
    FOR UPDATE TO authenticated
        USING (can_access_priority (id))
        WITH CHECK (((nlevel (path) = 1) OR can_access_priority (parent_path (path))));

CREATE POLICY "Users can read/write their priority settings" ON "public"."priority_user" AS permissive
    FOR ALL TO authenticated
        USING ((user_id = auth.uid ()));

CREATE POLICY "Users can see who shares their priorities" ON "public"."priority_user" AS permissive
    FOR SELECT TO authenticated
        USING (((user_id = auth.uid ()) OR can_access_priority (priority_id)));

CREATE TRIGGER upsert_event_x
    INSTEAD OF INSERT OR UPDATE ON public.event_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_event_x_upsert ();

CREATE TRIGGER upsert_priority_x
    INSTEAD OF INSERT OR UPDATE ON public.priority_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_priority_x_upsert ();

ALTER VIEW gap SET ( security_invoker = TRUE);
ALTER VIEW gap_monthly SET ( security_invoker = TRUE);
ALTER VIEW gap_daily SET ( security_invoker = TRUE);
ALTER VIEW insight SET ( security_invoker = TRUE);
ALTER VIEW "admin"."sync" SET ( security_invoker = FALSE);
ALTER VIEW "admin"."invitation" SET ( security_invoker = FALSE);
ALTER VIEW "public"."event_invitees" SET ( security_invoker = TRUE);
ALTER VIEW "public"."event_x" SET ( security_invoker = TRUE);
ALTER VIEW "admin"."user" SET ( security_invoker = FALSE);
ALTER VIEW balance_without_children SET ( security_invoker = TRUE);
ALTER VIEW balance SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_children" SET ( security_invoker = TRUE);
