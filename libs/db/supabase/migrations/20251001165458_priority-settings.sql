DROP TRIGGER IF EXISTS "upsert_user_priority" ON "public"."user_priority";

DROP POLICY "Users can create new root priorities" ON "public"."priority";

DROP VIEW IF EXISTS "public"."priority_child_agent";

DROP VIEW IF EXISTS "public"."user_activity_exception";

DROP VIEW IF EXISTS "public"."user_activity_tags";

DROP VIEW IF EXISTS "public"."priority_child";

DROP VIEW IF EXISTS "public"."user_activity";

DROP VIEW IF EXISTS "public"."user_priority";

ALTER TABLE "public"."priority"
    DROP COLUMN "order";

ALTER TABLE "public"."priority_settings"
    DROP COLUMN "order";

ALTER TABLE "public"."priority_settings"
    DROP COLUMN "top";

ALTER TABLE "public"."priority_settings"
    ADD COLUMN "top_order" double precision;

SET check_function_bodies = OFF;

CREATE OR REPLACE VIEW "public"."priority_settings_inherited" AS SELECT DISTINCT ON (ps.user_id, p.id)
    ps.user_id,
    p.id AS priority_id,
    CASE WHEN (subpath (p.path, nlevel (parent.path)) <> ''::ltree) THEN
        (ps.path || subpath (p.path, nlevel (parent.path)))
    ELSE
        ps.path
    END AS path,
    ps.pomodoro,
    ps.color
FROM ((priority_settings ps
        JOIN priority parent ON (ps.priority_id = parent.id))
    JOIN priority p ON (p.path <@ parent.path))
WHERE ((ps.path IS NOT NULL)
    OR (ps.pomodoro IS NOT NULL)
    OR (ps.color IS NOT NULL))
ORDER BY
    ps.user_id,
    p.id,
    (nlevel (p.path) - nlevel (parent.path));

CREATE OR REPLACE FUNCTION public.handle_user_priority_upsert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
DECLARE
    _priority_id uuid;
BEGIN
    _priority_id := NEW.id;
    IF (OLD IS NULL OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at OR NEW.title IS DISTINCT FROM OLD.title OR NEW.path IS DISTINCT FROM OLD.path OR NEW.updated_by IS DISTINCT FROM OLD.updated_by) THEN
        INSERT INTO priority (id, deleted_at, title, path, created_by, updated_by)
            VALUES (NEW.id, NEW.deleted_at, NEW.title, NEW.path, NEW.created_by, NEW.updated_by)
        ON CONFLICT (id)
            DO UPDATE SET
                deleted_at = NEW.deleted_at,
                title = NEW.title,
                path = NEW.path,
                updated_by = NEW.updated_by
            RETURNING
                id INTO _priority_id;
    END IF;
    IF ((OLD IS NULL AND (NEW."path" IS NOT NULL OR NEW."top_order" IS NOT NULL OR NEW."pomodoro" IS NOT NULL OR NEW."color" IS NOT NULL)) OR (OLD IS NOT NULL AND (NEW."path" IS DISTINCT FROM OLD."path" OR NEW."top_order" IS DISTINCT FROM OLD."top_order" OR NEW."pomodoro" IS DISTINCT FROM OLD."pomodoro" OR NEW."color" IS DISTINCT FROM OLD."color"))) THEN
        INSERT INTO priority_settings (user_id, priority_id, path, top_order, pomodoro, color)
            VALUES (COALESCE(auth.uid (), NEW.user_id), _priority_id, NEW.path, NEW.top_order, NEW.pomodoro, NEW.color)
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET
                path = COALESCE(NEW.path, priority_settings.path),
                top_order = COALESCE(NEW.top_order, priority_settings.top_order),
                pomodoro = COALESCE(NEW.pomodoro, priority_settings.pomodoro),
                color = COALESCE(NEW.color, priority_settings.color);
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_priority ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    event_type text;
    users_data jsonb;
    enriched_item jsonb;
    payload jsonb;
    api_url text;
    hmac_secret text;
    signature text;
    current_item record;
BEGIN
    IF TG_OP = 'INSERT' THEN
        event_type := 'created';
        current_item := NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        event_type := 'updated';
        current_item := NEW;
    ELSIF TG_OP = 'DELETE' THEN
        event_type := 'deleted';
        current_item := OLD;
    END IF;
    -- Get users who have access to this priority (just the creator for now)
    SELECT
        jsonb_agg(jsonb_build_object('user_id', current_item.created_by)) INTO users_data;
    -- Exit early if no users found
    IF users_data IS NULL OR jsonb_array_length(users_data) = 0 THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    -- Build enriched item
    enriched_item := jsonb_build_object('id', current_item.id, 'created_at', current_item.created_at, 'updated_at', current_item.updated_at, 'created_by', current_item.created_by, 'root', current_item.root, 'deleted_at', current_item.deleted_at, 'title', current_item.title, 'path', current_item.path, 'updated_by', current_item.updated_by);
    -- Build the payload (no agents for priority)
    payload := jsonb_build_object('type', 'priority', 'event', event_type, 'item', enriched_item, 'agents', '[]'::jsonb, 'users', users_data, 'timestamp', extract(epoch FROM now()), 'table', 'priority');
    api_url := get_api_root () || '/update';
    hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
    signature := encode(extensions.hmac(convert_to(payload::text, 'UTF8'), hmac_secret::bytea, 'sha256'), 'hex');
    PERFORM
        net.http_post (url := api_url, body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE OR REPLACE VIEW "public"."priority_child" AS
SELECT
    p.id AS priority_id,
    c.id AS child_id
FROM (priority p
    JOIN priority c ON (c.path <@ p.path));

CREATE OR REPLACE VIEW "public"."priority_child_agent" AS
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
    CASE WHEN (inherited_settings.path IS NOT NULL) THEN
        inherited_settings.path
    WHEN (user_root.path @> p.path) THEN
        p.path
    ELSE
        (user_root.path || p.path)
    END AS path,
    settings.top_order,
    inherited_settings.pomodoro,
    inherited_settings.color
FROM (((((priority_user pu
                    JOIN priority root ON (pu.priority_id = root.id))
                JOIN priority user_root ON (((pu.user_id = user_root.created_by)
                            AND user_root.root)))
            JOIN priority p ON (root.path @> p.path))
        LEFT JOIN priority_settings settings ON (((settings.user_id = pu.user_id)
                    AND (p.id = settings.priority_id))))
    LEFT JOIN priority_settings_inherited inherited_settings ON (((inherited_settings.user_id = pu.user_id)
                AND (p.id = inherited_settings.priority_id))))
WHERE (pu.deleted_at IS NULL);

CREATE OR REPLACE VIEW "public"."user_activity" AS
SELECT
    up.user_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.author_id,
    a.assignee_id,
    a.updated_by,
    a.deleted_at,
    a.priority_id,
    a.type,
    a.path,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.note,
    a.links,
    a.at,
    a."on",
    a.duration,
    a.done_at,
    a.recurrence_rule,
    a.recurrence_exdates,
    a.recurrence_dates,
    a.source,
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
    END AS range_on
FROM (activity a
    JOIN user_priority up ON (a.priority_id = up.id))
WHERE (up.deleted_at IS NULL);

CREATE OR REPLACE VIEW "public"."user_activity_exception" AS
SELECT
    ua.user_id,
    ua.id,
    ae.occurrence,
    ae.updated_at,
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
    END AS note
FROM (activity_exception ae
    JOIN user_activity ua ON (ua.id = ae.activity_id));

CREATE OR REPLACE VIEW "public"."user_activity_tags" AS
SELECT
    ua.user_id,
    ua.id,
    at.occurrence,
    at.updated_at,
    ua.range_at,
    ua.range_on,
    at.tags
FROM (activity_tags at
    JOIN user_activity ua ON (ua.id = at.activity_id));

CREATE TRIGGER upsert_user_priority
    INSTEAD OF INSERT OR UPDATE ON public.user_priority
    FOR EACH ROW
    EXECUTE FUNCTION handle_user_priority_upsert ();

ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_children" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_exception" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "admin"."invitation" SET ( security_invoker = FALSE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_agent" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
