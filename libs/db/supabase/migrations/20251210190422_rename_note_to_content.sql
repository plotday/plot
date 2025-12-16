DROP TRIGGER IF EXISTS "upsert_user_priority" ON "public"."user_priority";

DROP VIEW IF EXISTS "public"."user_activity_exception";

DROP VIEW IF EXISTS "public"."user_activity_tags";

DROP VIEW IF EXISTS "public"."user_note";

DROP VIEW IF EXISTS "public"."user_note_tags";

DROP VIEW IF EXISTS "public"."user_twist";

DROP FUNCTION public.actor (user_activity);

DROP VIEW IF EXISTS "public"."user_activity";

DROP VIEW IF EXISTS "public"."user_activity_unread";

DROP VIEW IF EXISTS "public"."user_priority";

DROP VIEW IF EXISTS "public"."priority_unread";

ALTER TABLE "public"."note"
    DROP COLUMN "note";

ALTER TABLE "public"."note"
    ADD COLUMN "content" text;

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_note ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    event_type text;
    twists_data jsonb;
    users_data jsonb;
    enriched_item jsonb;
    previous_enriched_item jsonb;
    current_tags jsonb;
    previous_tags jsonb;
    payload jsonb;
    api_url text;
    hmac_secret text;
    signature text;
    current_item record;
    previous_item record;
    parent_priority_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        event_type := 'created';
        current_item := NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        event_type := 'updated';
        current_item := NEW;
        previous_item := OLD;
    ELSIF TG_OP = 'DELETE' THEN
        event_type := 'deleted';
        current_item := OLD;
    END IF;
    -- Get the parent activity's priority_id
    SELECT
        priority_id INTO parent_priority_id
    FROM
        activity
    WHERE
        id = current_item.activity_id;
    -- Exit early if parent activity not found
    IF parent_priority_id IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    -- Extract twists query into a variable
    SELECT
        jsonb_agg(jsonb_build_object('id', twist_id, 'environment', twist_environment, 'version', version, 'priority_twist_id', id, 'config', config)) INTO twists_data
    FROM
        priority_child_twist
    WHERE
        priority_child_id = parent_priority_id
        AND id != current_item.author_id
        AND archived_at IS NULL;
    -- Get users who have access to this priority
    SELECT
        jsonb_agg(jsonb_build_object('user_id', user_id)) INTO users_data
    FROM
        public.get_users_with_priority_access (parent_priority_id);
    -- Exit early if no twists or users found
    IF (twists_data IS NULL OR jsonb_array_length(twists_data) = 0) AND (users_data IS NULL OR jsonb_array_length(users_data) = 0) THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    -- Build enriched item with author and activity information
    SELECT
        jsonb_build_object('id', current_item.id, 'created_at', current_item.created_at, 'updated_at', current_item.updated_at, 'author_id', current_item.author_id, 'created_by', current_item.created_by, 'updated_by', current_item.updated_by, 'archived_at', current_item.archived_at, 'activity_id', current_item.activity_id, 'draft', current_item.draft, 'private', current_item.private, 'content', current_item.content, 'links', current_item.links, 'mentions', current_item.mentions,
            -- Enriched data from JOINs
            'author_name', a.name, 'author_type', a.type, 'activity_title', act.title, 'priority_id', act.priority_id) INTO enriched_item
    FROM
        actor a,
        activity act
    WHERE
        a.id = current_item.author_id
        AND act.id = current_item.activity_id;
    -- Get tags for current note
    SELECT
        tags INTO current_tags
    FROM
        note_tags
    WHERE
        note_id = current_item.id;
    -- Add tags to enriched item
    enriched_item := enriched_item || jsonb_build_object('tags', current_tags);
    -- Build previous enriched item for updates
    IF TG_OP = 'UPDATE' THEN
        SELECT
            jsonb_build_object('id', previous_item.id, 'created_at', previous_item.created_at, 'updated_at', previous_item.updated_at, 'author_id', previous_item.author_id, 'created_by', previous_item.created_by, 'updated_by', previous_item.updated_by, 'archived_at', previous_item.archived_at, 'activity_id', previous_item.activity_id, 'draft', previous_item.draft, 'private', previous_item.private, 'content', previous_item.content, 'links', previous_item.links, 'mentions', previous_item.mentions,
                -- Enriched data from JOINs
                'author_name', a.name, 'author_type', a.type, 'activity_title', act.title, 'priority_id', act.priority_id) INTO previous_enriched_item
        FROM
            actor a,
            activity act
        WHERE
            a.id = previous_item.author_id
            AND act.id = previous_item.activity_id;
        -- Get tags for previous note state
        SELECT
            tags INTO previous_tags
        FROM
            note_tags
        WHERE
            note_id = previous_item.id;
        -- Add tags to previous enriched item
        previous_enriched_item := previous_enriched_item || jsonb_build_object('tags', previous_tags);
    END IF;
    -- Build the payload
    IF TG_OP = 'UPDATE' THEN
        payload := jsonb_build_object('type', 'note', 'event', event_type, 'item', enriched_item, 'previous', previous_enriched_item, 'twists', COALESCE(twists_data, '[]'::jsonb), 'users', COALESCE(users_data, '[]'::jsonb), 'timestamp', extract(epoch FROM now()), 'table', 'note');
    ELSE
        payload := jsonb_build_object('type', 'note', 'event', event_type, 'item', enriched_item, 'twists', COALESCE(twists_data, '[]'::jsonb), 'users', COALESCE(users_data, '[]'::jsonb), 'timestamp', extract(epoch FROM now()), 'table', 'note');
    END IF;
    api_url := get_api_root () || '/update';
    hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
    signature := encode(extensions.hmac(convert_to(payload::text, 'UTF8'), hmac_secret::bytea, 'sha256'), 'hex');
    PERFORM
        net.http_post (url := api_url, body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE OR REPLACE VIEW "public"."priority_unread" AS
SELECT
    upb.user_id,
    upb.id AS priority_id,
    COALESCE(unread_check.unread, FALSE) AS unread
FROM (((user_priority_base upb
        LEFT JOIN contact c ON (c.user_id = upb.user_id))
    LEFT JOIN LATERAL (
        SELECT
            pu.created_at
        FROM (priority_user pu
            JOIN priority p ON (p.id = pu.priority_id))
    WHERE ((pu.user_id = upb.user_id)
        AND (p.path @> upb.path))
ORDER BY
    (nlevel (p.path))
LIMIT 1) member ON (TRUE))
    LEFT JOIN LATERAL (
        SELECT
            TRUE AS unread
        FROM (activity a
            LEFT JOIN activity_read ar ON (((ar.user_id = upb.user_id)
                        AND (ar.activity_id = a.id))))
    WHERE ((a.priority_id = upb.id)
        AND (a.archived_at IS NULL)
        AND (a.draft = FALSE)
        AND (((a.author_id <> c.id)
                AND ((member.created_at IS NULL)
                    OR (a.created_at >= member.created_at))
                AND (ar.read_at IS NULL))
            OR (EXISTS (
                    SELECT
                        1
                    FROM
                        note n
                    WHERE ((n.activity_id = a.id)
                        AND (n.archived_at IS NULL)
                        AND (n.author_id <> c.id)
                        AND ((member.created_at IS NULL)
                            OR (n.created_at >= member.created_at))
                        AND ((ar.read_at IS NULL)
                            OR (n.created_at > ar.read_at)))))))
LIMIT 1) unread_check ON (TRUE));

CREATE OR REPLACE VIEW "public"."user_priority" AS
SELECT
    upb.user_id,
    upb.id,
    upb.created_at,
    upb.updated_at,
    upb.archived_at,
    upb.created_by,
    upb.updated_by,
    upb.root,
    upb.title,
    upb.path,
    upb.top_order,
    upb.pomodoro,
    upb.color,
    COALESCE(pu.unread, FALSE) AS unread
FROM (user_priority_base upb
    LEFT JOIN priority_unread pu ON (((pu.user_id = upb.user_id)
                AND (pu.priority_id = upb.id))));

CREATE OR REPLACE VIEW "public"."user_twist" AS
SELECT
    up.user_id,
    pt.id,
    pt.created_at,
    pt.updated_at,
    pt.archived_at,
    pt.priority_id,
    pt.twist_id,
    pt.twist_environment,
    pt.owner_id,
    pt.name,
    pt.config
FROM (priority_twist pt
    JOIN user_priority up ON (up.id = pt.priority_id));

CREATE OR REPLACE VIEW "public"."user_activity_unread" AS
SELECT
    up.user_id,
    a.id AS activity_id,
    (unread.updated_at IS NOT NULL) AS unread,
    COALESCE(ar.updated_at, unread.updated_at) AS updated_at
FROM (((((user_priority up
                    JOIN contact c ON (c.user_id = up.user_id))
                JOIN activity a ON (a.priority_id = up.id))
            LEFT JOIN activity_read ar ON (((ar.user_id = up.user_id)
                        AND (ar.activity_id = a.id))))
        LEFT JOIN LATERAL (
            SELECT
                pu.created_at
            FROM ((priority_user pu
                    JOIN priority p ON (p.id = pu.priority_id))
                JOIN priority ap ON (ap.id = a.priority_id))
        WHERE ((pu.user_id = up.user_id)
            AND (p.path @> ap.path))
    ORDER BY
        (nlevel (p.path))
    LIMIT 1) member ON (TRUE))
    LEFT JOIN LATERAL (
        SELECT
            max(GREATEST (a.updated_at, n.updated_at)) AS updated_at
        FROM
            note n
        WHERE ((n.activity_id = a.id)
            AND (n.archived_at IS NULL)
            AND (n.author_id <> c.id)
            AND ((member.created_at IS NULL)
                OR (n.created_at >= member.created_at))
            AND ((ar.read_at IS NULL)
                OR (n.created_at > ar.read_at)))
    UNION ALL
    SELECT
        a.updated_at
    WHERE ((a.author_id <> c.id)
        AND ((member.created_at IS NULL)
            OR (a.created_at >= member.created_at))
        AND (ar.read_at IS NULL))) unread ON (TRUE))
WHERE (up.archived_at IS NULL);

CREATE OR REPLACE VIEW "public"."user_note" AS
SELECT
    up.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.archived_at,
    n.activity_id,
    n.draft,
    n.private,
    n.content,
    n.links,
    n.mentions
FROM ((note n
        JOIN activity a ON (a.id = n.activity_id))
    JOIN user_priority up ON (up.id = a.priority_id));

CREATE OR REPLACE VIEW "public"."user_activity" AS
SELECT
    up.user_id,
    a.id,
    a.created_at,
    COALESCE(uau.updated_at, a.updated_at) AS updated_at,
    a.author_id,
    a.updated_by,
    a.archived_at,
    a.priority_id,
    p.path AS priority_path,
    a.type,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.at,
    a."on",
    a.duration,
    a.done_at,
    a.recurrence_rule,
    a.recurrence_exdates,
    a.recurrence_dates,
    a.meta,
    a.mentions,
    CASE WHEN (a.done_at IS NOT NULL) THEN
        tstzrange(a.done_at, a.done_at, '[]'::text)
    WHEN (a.at IS NOT NULL) THEN
        a.at
    WHEN (a."on" IS NOT NULL) THEN
        NULL::tstzrange
    ELSE
        tstzrange(a.created_at, a.created_at, '[]'::text)
    END AS range_at,
    CASE WHEN (a.done_at IS NOT NULL) THEN
        NULL::daterange
    WHEN (a.at IS NOT NULL) THEN
        NULL::daterange
    WHEN (a."on" IS NOT NULL) THEN
        a."on"
    ELSE
        NULL::daterange
    END AS range_on,
    COALESCE(uau.unread, FALSE) AS unread
FROM (((activity a
            JOIN priority p ON (p.id = a.priority_id))
        JOIN user_priority up ON (a.priority_id = up.id))
    LEFT JOIN user_activity_unread uau ON (((uau.user_id = up.user_id)
                AND (uau.activity_id = a.id))))
WHERE (up.archived_at IS NULL);

CREATE OR REPLACE VIEW "public"."user_activity_exception" AS
SELECT
    ua.user_id,
    ua.id,
    ae.occurrence,
    ae.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    CASE WHEN (ae.archived_at IS NULL) THEN
        ae.at
    ELSE
        NULL::tstzrange
    END AS at,
    CASE WHEN (ae.archived_at IS NULL) THEN
        ae."on"
    ELSE
        NULL::daterange
    END AS "on",
    CASE WHEN (ae.archived_at IS NULL) THEN
        ae.title
    ELSE
        NULL::text
    END AS title,
    CASE WHEN (ae.archived_at IS NULL) THEN
        ae.note
    ELSE
        NULL::text
    END AS note
FROM (activity_exception ae
    JOIN user_activity ua ON (ua.id = ae.activity_id));

CREATE OR REPLACE VIEW "public"."user_activity_tags" AS
SELECT
    ua.user_id,
    ua.id,
    at.occurrence,
    at.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    at.tags
FROM (activity_tags at
    JOIN user_activity ua ON (ua.id = at.activity_id));

CREATE OR REPLACE VIEW "public"."user_note_tags" AS
SELECT
    ua.user_id,
    n.id,
    nt.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    nt.tags
FROM ((note_tags nt
        JOIN note n ON (n.id = nt.note_id))
    JOIN user_activity ua ON (ua.id = n.activity_id));

CREATE TRIGGER upsert_user_priority
    INSTEAD OF INSERT OR UPDATE ON public.user_priority
    FOR EACH ROW
    EXECUTE FUNCTION handle_user_priority_upsert ();

CREATE OR REPLACE FUNCTION public.actor (user_activity)
    RETURNS SETOF actor
    LANGUAGE sql
    STABLE ROWS 1
    AS $function$
    SELECT
        actor.*
    FROM
        actor
    WHERE
        actor.id = $1.author_id
$function$;

ALTER VIEW "public"."user_note" SET (security_invoker = TRUE);

ALTER VIEW "public"."note_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_note_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_twist" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_exception" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_settings_inherited" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_base" SET (security_invoker = TRUE);

ALTER VIEW "public"."actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child_twist" SET (security_invoker = TRUE);

