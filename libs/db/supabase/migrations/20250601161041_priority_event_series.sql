DROP TRIGGER IF EXISTS "upsert_priority_x" ON "public"."priority_x";

DROP VIEW IF EXISTS "public"."balance";

DROP VIEW IF EXISTS "public"."priority_children";

DROP VIEW IF EXISTS "public"."priority_x";

SET check_function_bodies = OFF;

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
    p.draft,
    p.title,
    CASE WHEN root.root THEN
        p.path
    ELSE
        (COALESCE(pu.path, user_root.path) || subpath (p.path, nlevel (root.path)))
    END AS path,
    p.private,
    p.pinned,
    p.do_at,
    p.done_at,
    p.note,
    p.event_series,
    CASE WHEN ((pu.priority_id = p.id)
        AND (pu."order" IS NOT NULL)) THEN
        pu."order"
    ELSE
        p."order"
    END AS "order",
    CASE WHEN (p.pinned = TRUE) THEN
        (('400000000000000'::numeric)::double precision - COALESCE(pu."order", p."order"))
    WHEN (p.do_at <= now()) THEN
        ((('200000000000000'::numeric - (EXTRACT(epoch FROM p.do_at) * '1000'::numeric)))::double precision - (COALESCE(pu."order", p."order") / ('10000000'::numeric)::double precision))
    ELSE
        COALESCE(pu."order", p."order")
    END AS order_x,
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

CREATE TRIGGER upsert_priority_x
    INSTEAD OF INSERT OR UPDATE ON public.priority_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_priority_x_upsert ();

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

