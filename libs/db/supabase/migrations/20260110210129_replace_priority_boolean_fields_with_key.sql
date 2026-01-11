DROP TRIGGER IF EXISTS "prevent_priority_root_change_trigger" ON "public"."priority";

DROP TRIGGER IF EXISTS "upsert_user_priority" ON "public"."user_priority";

DROP POLICY "Users can update their priorities" ON "public"."priority";

ALTER TABLE "public"."contact"
    DROP CONSTRAINT "contact_user_email_unique";

ALTER TABLE "public"."contact"
    DROP CONSTRAINT "contact_user_id_unique";

DROP FUNCTION IF EXISTS "public"."prevent_priority_root_change" ();

DROP VIEW IF EXISTS "public"."priority_child_twist";

DROP VIEW IF EXISTS "public"."user_activity_exception";

DROP VIEW IF EXISTS "public"."user_activity_tags";

DROP VIEW IF EXISTS "public"."user_actor";

DROP VIEW IF EXISTS "public"."user_note";

DROP VIEW IF EXISTS "public"."user_note_tags";

DROP VIEW IF EXISTS "public"."user_priority";

DROP VIEW IF EXISTS "public"."user_priority_actor";

DROP VIEW IF EXISTS "public"."user_priority_unread";

DROP VIEW IF EXISTS "public"."user_twist";

DROP VIEW IF EXISTS "public"."priority_settings_inherited";

DROP VIEW IF EXISTS "public"."user_activity";

DROP VIEW IF EXISTS "public"."user_activity_unread";

DROP VIEW IF EXISTS "public"."user_priority_expanded";

DROP VIEW IF EXISTS "public"."activity_x";

DROP VIEW IF EXISTS "public"."priority_child";

DROP INDEX IF EXISTS "public"."contact_user_email_unique";

DROP INDEX IF EXISTS "public"."contact_user_id_unique";

DROP INDEX IF EXISTS "public"."idx_priority_created_by_root_true";

-- Add key column BEFORE dropping old columns so we can migrate data
ALTER TABLE "public"."priority_user"
    ADD COLUMN "key" text;

-- Migrate data: Set key='root' for priorities with root=true
UPDATE
    priority_user pu
SET
    key = 'root'
FROM
    priority p
WHERE
    pu.priority_id = p.id
    AND p.root = TRUE;

-- Migrate data: Set key='twist_development' for priorities with twist_development=true
UPDATE
    priority_user pu
SET
    key = 'twist_development'
FROM
    priority p
WHERE
    pu.priority_id = p.id
    AND p.twist_development = TRUE;

-- Now safe to drop the old columns
ALTER TABLE "public"."priority"
    DROP COLUMN "root";

ALTER TABLE "public"."priority"
    DROP COLUMN "twist_development";

CREATE UNIQUE INDEX contact_email_unique ON public.contact USING btree (email);

CREATE UNIQUE INDEX idx_priority_user_key ON public.priority_user USING btree (user_id, key)
WHERE (key IS NOT NULL);

ALTER TABLE "public"."contact"
    ADD CONSTRAINT "contact_email_unique" UNIQUE USING INDEX "contact_email_unique";

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.get_primary_contact_id (p_user_id uuid)
    RETURNS uuid
    LANGUAGE plpgsql
    STABLE
    AS $function$
DECLARE
    v_preferred_contact_id uuid;
    v_contact_id uuid;
    v_user_email text;
BEGIN
    -- Get user's email and preferred contact_id from app_metadata
    SELECT
        LOWER(email),
        (raw_app_meta_data ->> 'contact_id')::uuid INTO v_user_email,
        v_preferred_contact_id
    FROM
        auth.users
    WHERE
        id = p_user_id;
    -- If user has a preferred contact_id in app_metadata, validate and return it
    IF v_preferred_contact_id IS NOT NULL THEN
        SELECT
            id INTO v_contact_id
        FROM
            contact
        WHERE
            id = v_preferred_contact_id
            AND user_id = p_user_id;
        IF v_contact_id IS NOT NULL THEN
            RETURN v_contact_id;
        END IF;
    END IF;
    -- Fall back to finding contact by matching email
    IF v_user_email IS NOT NULL THEN
        SELECT
            id INTO v_contact_id
        FROM
            contact
        WHERE
            email = v_user_email
            AND user_id = p_user_id;
        RETURN v_contact_id;
    END IF;
    -- No match found
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE VIEW "public"."activity_x" AS
SELECT
    a.id,
    a.created_at,
    a.updated_at,
    a.source_created_at,
    a.author_id,
    a.created_by,
    a.assignee_id,
    a.updated_by,
    a.sync_depth,
    a.archived_at,
    a.priority_id,
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
    a.source,
    a.created_by_twist_id,
    a.embedding,
    a.pick_priority,
    a.last_note_created_at,
    a.last_note_source_created_at,
    a.source_priority_root,
    p.path AS priority_path,
    m.mentions
FROM ((activity a
        JOIN priority p ON (p.id = a.priority_id))
    LEFT JOIN (
        SELECT
            n.activity_id,
            array_agg(DISTINCT mention.mention) AS mentions
        FROM
            note n,
            LATERAL unnest(n.mentions) mention (mention)
        WHERE ((n.archived_at IS NULL)
            AND (n.mentions IS NOT NULL))
    GROUP BY
        n.activity_id) m ON (m.activity_id = a.id));

CREATE OR REPLACE FUNCTION public.get_priority_twist_owner_contact (p_priority_twist_id uuid)
    RETURNS uuid
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        public.get_primary_contact_id (pt.owner_id)
    FROM
        priority_twist pt
    WHERE
        pt.id = p_priority_twist_id;
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
    is_root boolean;
BEGIN
    IF TG_OP = 'INSERT' THEN
        event_type := 'created';
        current_item := NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        event_type := 'updated';
        current_item := NEW;
    END IF;
    -- Get users who have access to this priority (just the creator for now)
    SELECT
        jsonb_agg(jsonb_build_object('user_id', current_item.created_by)) INTO users_data;
    -- Exit early if no users found
    IF users_data IS NULL OR jsonb_array_length(users_data) = 0 THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    -- Compute root field from priority_user.key
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                priority_user
            WHERE
                priority_user.priority_id = current_item.id
                AND priority_user.key = 'root') INTO is_root;
    -- Build enriched item
    enriched_item := jsonb_build_object('id', current_item.id, 'created_at', current_item.created_at, 'updated_at', current_item.updated_at, 'created_by', current_item.created_by, 'root', is_root, 'archived_at', current_item.archived_at, 'title', current_item.title, 'path', current_item.path, 'updated_by', current_item.updated_by, 'sync_depth', current_item.sync_depth);
    -- Build the payload (no twists for priority)
    payload := jsonb_build_object('type', 'priority', 'event', event_type, 'item', enriched_item, 'twists', '[]'::jsonb, 'users', users_data, 'timestamp', extract(epoch FROM now()), 'table', 'priority');
    api_url := public.get_api_root () || '/update';
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
    c.id AS child_id,
    c.archived_at
FROM (priority p
    JOIN priority c ON (c.path <@ p.path));

CREATE OR REPLACE VIEW "public"."priority_child_twist" AS
SELECT
    pt.id,
    pt.priority_id,
    pt.twist_id,
    pt.owner_id,
    pt.name,
    pt.config,
    pt.created_at,
    pt.updated_at,
    pt.archived_at,
    t.version,
    t.environment AS twist_environment,
    p.name AS author_name,
    p.email AS author_email,
    p.url AS author_url,
    pc.child_id AS priority_child_id
FROM ((((priority_twist pt
                JOIN priority_child pc ON (pt.priority_id = pc.priority_id))
            JOIN twist t ON (pt.twist_id = t.id))
        JOIN twist_admin ta ON (t.twist_admin_id = ta.id))
    LEFT JOIN publisher p ON (ta.publisher_id = p.id))
WHERE (pt.archived_at IS NULL);

CREATE OR REPLACE VIEW "public"."priority_settings_inherited" AS
WITH inherited_sources AS (
    SELECT
        ps.user_id,
        p.id AS priority_id,
        (nlevel (p.path) - nlevel (parent.path)) AS distance,
        0 AS source_type,
        CASE WHEN ((nlevel (p.path) > nlevel (parent.path))
            AND (subpath (p.path, nlevel (parent.path)) <> ''::ltree)) THEN
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
UNION ALL
SELECT
    pu.user_id,
    p.id AS priority_id,
    (nlevel (p.path) - nlevel (parent.path)) AS distance,
    1 AS source_type,
    NULL::ltree AS path,
    NULL::integer AS pomodoro,
    parent.color
FROM (((priority_user pu
            JOIN priority root ON (pu.priority_id = root.id))
        JOIN priority p ON (p.path <@ root.path))
    JOIN priority parent ON (p.path <@ parent.path))
WHERE (parent.color IS NOT NULL))
SELECT DISTINCT ON (user_id, priority_id)
    user_id,
    priority_id,
    path,
    pomodoro,
    color
FROM
    inherited_sources
ORDER BY
    user_id,
    priority_id,
    distance,
    source_type;

CREATE OR REPLACE FUNCTION public.sync_priority_contact_on_delete ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_contact_id uuid;
BEGIN
    -- Get the primary contact_id for this user
    v_contact_id := public.get_primary_contact_id (OLD.user_id);
    -- Delete the corresponding priority_contact if it exists
    IF v_contact_id IS NOT NULL THEN
        DELETE FROM public.priority_contact
        WHERE priority_id = OLD.priority_id
            AND contact_id = v_contact_id;
    END IF;
    RETURN OLD;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_priority_contact_on_insert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_contact_id uuid;
BEGIN
    -- Get the primary contact_id for this user
    v_contact_id := public.get_primary_contact_id (NEW.user_id);
    -- Only create priority_contact if the user has a contact record
    IF v_contact_id IS NOT NULL THEN
        INSERT INTO public.priority_contact (priority_id, contact_id, created_at, archived_at)
            VALUES (NEW.priority_id, v_contact_id, NEW.created_at, NEW.archived_at)
        ON CONFLICT (priority_id, contact_id)
            DO NOTHING;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_priority_contact_on_update ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_contact_id uuid;
BEGIN
    -- Only proceed if archived_at changed
    IF OLD.archived_at IS DISTINCT FROM NEW.archived_at THEN
        -- Get the primary contact_id for this user
        v_contact_id := public.get_primary_contact_id (NEW.user_id);
        -- Update the corresponding priority_contact if it exists
        IF v_contact_id IS NOT NULL THEN
            UPDATE
                public.priority_contact
            SET
                archived_at = NEW.archived_at
            WHERE
                priority_id = NEW.priority_id
                AND contact_id = v_contact_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE VIEW "public"."user_priority_expanded" AS
SELECT
    pu.user_id,
    c.child_id AS priority_id,
    min(pu.created_at) AS joined_at,
    CASE WHEN bool_or(pu.archived_at IS NULL) THEN
        NULL::timestamp with time zone
    ELSE
        LEAST (min(pu.archived_at), min(c.archived_at))
    END AS archived_at
FROM (priority_user pu
    JOIN priority_child c ON (pu.priority_id = c.priority_id))
GROUP BY
    pu.user_id,
    c.child_id;

CREATE OR REPLACE VIEW "public"."user_priority_unread" AS
SELECT
    upe.user_id,
    upe.priority_id,
    TRUE AS unread,
    max(GREATEST (COALESCE(ar.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone), CASE WHEN (a.created_by = upe.user_id) THEN
                COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)
            ELSE
                COALESCE(a.last_note_created_at, a.created_at)
            END)) AS updated_at
FROM ((user_priority_expanded upe
        JOIN activity a ON (((a.priority_id = upe.priority_id)
                    AND (a.archived_at IS NULL)
                    AND (((a.created_by = upe.user_id)
                            AND (a.last_note_created_at IS NOT NULL)
                            AND (a.last_note_created_at > upe.joined_at))
                        OR (((a.created_by IS NULL)
                                OR (a.created_by <> upe.user_id))
                            AND (COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at))))))
    LEFT JOIN activity_read ar ON (((ar.user_id = upe.user_id)
                AND (ar.activity_id = a.id))))
GROUP BY
    upe.user_id,
    upe.priority_id;

CREATE OR REPLACE VIEW "public"."user_twist" AS
SELECT
    upe.user_id,
    pt.id,
    pt.created_at,
    pt.updated_at,
    pt.archived_at,
    pt.priority_id,
    pt.twist_id,
    t.environment AS twist_environment,
    pt.owner_id,
    pt.name,
    pt.config
FROM ((priority_twist pt
        JOIN user_priority_expanded upe ON (upe.priority_id = pt.priority_id))
    JOIN twist t ON (pt.twist_id = t.id));

CREATE OR REPLACE VIEW "public"."user_activity_unread" AS
SELECT
    upe.user_id,
    a.id AS activity_id,
    (ar.read_at IS NULL) AS unread,
    GREATEST (COALESCE(ar.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone), CASE WHEN (a.created_by = upe.user_id) THEN
            COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)
        ELSE
            COALESCE(a.last_note_created_at, a.created_at)
        END) AS updated_at
FROM ((user_priority_expanded upe
        JOIN activity a ON (((a.priority_id = upe.priority_id)
                    AND (a.archived_at IS NULL)
                    AND (((a.created_by = upe.user_id)
                            AND (a.last_note_created_at IS NOT NULL)
                            AND (a.last_note_created_at > upe.joined_at))
                        OR (((a.created_by IS NULL)
                                OR (a.created_by <> upe.user_id))
                            AND (COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at))))))
    LEFT JOIN activity_read ar ON (((ar.user_id = upe.user_id)
                AND (ar.activity_id = a.id)
                AND (ar.read_at >= CASE WHEN (a.created_by = upe.user_id) THEN
                        a.last_note_created_at
                    ELSE
                        COALESCE(a.last_note_created_at, a.created_at)
                    END))));

CREATE OR REPLACE VIEW "public"."user_note" AS
SELECT
    upe.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
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
    JOIN user_priority_expanded upe ON (upe.priority_id = a.priority_id));

CREATE OR REPLACE VIEW "public"."user_priority" AS
SELECT
    pu.user_id,
    p.id,
    p.created_at,
    GREATEST (settings.updated_at, pu.updated_at, p.updated_at, COALESCE(upu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    GREATEST (pu.archived_at, p.archived_at) AS archived_at,
    p.created_by,
    p.updated_by,
    ((pu.key = 'root'::text)
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
    inherited_settings.color,
    COALESCE(upu.unread, FALSE) AS unread
FROM (((((((priority_user pu
                            JOIN priority root ON (pu.priority_id = root.id))
                        JOIN priority_user pu_root ON (((pu.user_id = pu_root.user_id)
                                    AND (pu_root.key = 'root'::text))))
                    JOIN priority user_root ON (pu_root.priority_id = user_root.id))
                JOIN priority p ON (root.path @> p.path))
            LEFT JOIN priority_settings settings ON (((settings.user_id = pu.user_id)
                        AND (p.id = settings.priority_id))))
        LEFT JOIN priority_settings_inherited inherited_settings ON (((inherited_settings.user_id = pu.user_id)
                    AND (p.id = inherited_settings.priority_id))))
    LEFT JOIN user_priority_unread upu ON (((upu.user_id = pu.user_id)
                AND (upu.priority_id = p.id))))
WHERE (pu.archived_at IS NULL);

CREATE OR REPLACE VIEW "public"."user_priority_actor" AS
SELECT
    user_id,
    priority_path,
    actor_id,
    created_at,
    updated_at,
    archived_at
FROM (
    SELECT
        upe.user_id,
        p.path AS priority_path,
        pc.contact_id AS actor_id,
        LEAST (COALESCE(pc.created_at, c.created_at), COALESCE(c.created_at, pc.created_at)) AS created_at,
        GREATEST (COALESCE(pc.created_at, c.updated_at), COALESCE(c.updated_at, pc.created_at)) AS updated_at,
        GREATEST (COALESCE(pc.archived_at, c.archived_at), COALESCE(c.archived_at, pc.archived_at)) AS archived_at
    FROM (((user_priority_expanded upe
                JOIN priority_contact pc ON (pc.priority_id = upe.priority_id))
            JOIN contact c ON (c.id = pc.contact_id))
        JOIN priority p ON (p.id = pc.priority_id))
UNION ALL
SELECT
    upe.user_id,
    p.path AS priority_path,
    pt.id AS actor_id,
    pt.created_at,
    pt.updated_at,
    pt.archived_at
FROM ((user_priority_expanded upe
        JOIN priority_twist pt ON (pt.priority_id = upe.priority_id))
    JOIN priority p ON (p.id = pt.priority_id))) actors;

CREATE OR REPLACE VIEW "public"."user_activity" AS
SELECT
    upe.user_id,
    a.id,
    a.created_at,
    COALESCE(GREATEST (a.updated_at, a.last_note_source_created_at), a.updated_at) AS updated_at,
    a.source_created_at,
    a.author_id,
    a.assignee_id,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at) AS archived_at,
    a.priority_id,
    a.priority_path,
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
    a.source,
    a.created_by_twist_id,
    a.last_note_created_at,
    a.last_note_source_created_at,
    a.mentions,
    CASE WHEN (a.done_at IS NOT NULL) THEN
        tstzrange(a.done_at, a.done_at, '[]'::text)
    WHEN ((a.assignee_id IS NOT NULL)
        AND (ac.user_id <> upe.user_id)) THEN
        tstzrange(GREATEST (a.source_created_at, COALESCE(a.last_note_source_created_at, a.source_created_at)), GREATEST (a.source_created_at, COALESCE(a.last_note_source_created_at, a.source_created_at)), '[]'::text)
    WHEN (a.at IS NOT NULL) THEN
        a.at
    WHEN (a."on" IS NOT NULL) THEN
        NULL::tstzrange
    ELSE
        tstzrange(GREATEST (a.source_created_at, COALESCE(a.last_note_source_created_at, a.source_created_at)), GREATEST (a.source_created_at, COALESCE(a.last_note_source_created_at, a.source_created_at)), '[]'::text)
    END AS range_at,
    CASE WHEN (a.done_at IS NOT NULL) THEN
        NULL::daterange
    WHEN ((a.assignee_id IS NOT NULL)
        AND (ac.user_id <> upe.user_id)) THEN
        NULL::daterange
    WHEN (a.at IS NOT NULL) THEN
        NULL::daterange
    WHEN (a."on" IS NOT NULL) THEN
        a."on"
    ELSE
        NULL::daterange
    END AS range_on,
    COALESCE(uau.unread, FALSE) AS unread
FROM (((activity_x a
            JOIN user_priority_expanded upe ON (a.priority_id = upe.priority_id))
        LEFT JOIN contact ac ON (ac.id = a.assignee_id))
    LEFT JOIN user_activity_unread uau ON (((uau.user_id = upe.user_id)
                AND (uau.activity_id = a.id))));

CREATE OR REPLACE VIEW "public"."user_activity_exception" AS
SELECT
    ua.user_id,
    ua.id,
    COALESCE(ae.archived_at, ua.archived_at) AS archived_at,
    ae.occurrence,
    ae.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    ae.at,
    ae."on",
    ae.title,
    ae.note
FROM (activity_exception ae
    JOIN user_activity ua ON (ua.id = ae.activity_id));

CREATE OR REPLACE VIEW "public"."user_activity_tags" AS
SELECT
    ua.user_id,
    ua.id,
    ua.archived_at,
    at.occurrence,
    at.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    at.tags
FROM (activity_tags at
    JOIN user_activity ua ON (ua.id = at.activity_id));

CREATE OR REPLACE VIEW "public"."user_actor" AS
WITH upa_agg AS (
    SELECT
        upa.user_id,
        upa.actor_id,
        COALESCE(min(upa.updated_at) FILTER (WHERE (upa.archived_at IS NULL)), max(upa.archived_at)) AS updated_at,
        CASE WHEN (count(*) FILTER (WHERE (upa.archived_at IS NULL)) = 0) THEN
            max(upa.archived_at)
        ELSE
            NULL::timestamp with time zone
        END AS archived_at
    FROM
        user_priority_actor upa
    GROUP BY
        upa.user_id,
        upa.actor_id
)
SELECT
    ua.user_id,
    a.id,
    a.created_at,
    GREATEST (ua.updated_at, a.updated_at) AS updated_at,
    COALESCE(a.archived_at, ua.archived_at) AS archived_at,
    a.type,
    a.name,
    a.email,
    a.avatar_url
FROM (upa_agg ua
    JOIN actor a ON (a.id = ua.actor_id));

CREATE OR REPLACE VIEW "public"."user_note_tags" AS
SELECT
    ua.user_id,
    n.id,
    nt.updated_at,
    ua.archived_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    nt.tags
FROM ((note_tags nt
        JOIN note n ON (n.id = nt.note_id))
    JOIN user_activity ua ON (ua.id = n.activity_id));

CREATE POLICY "Users can update their priorities" ON "public"."priority" AS permissive
    FOR UPDATE TO authenticated
        USING ((can_access_priority (id) AND ((archived_at IS NULL) OR (NOT (EXISTS (
            SELECT
                1
            FROM
                priority_user
            WHERE ((priority_user.priority_id = priority.id) AND (priority_user.key = 'root'::text))))))))
        WITH CHECK (((nlevel (path) = 1) OR can_access_priority (parent_path (path))));

CREATE TRIGGER upsert_user_priority
    INSTEAD OF INSERT OR UPDATE ON public.user_priority
    FOR EACH ROW
    EXECUTE FUNCTION handle_user_priority_upsert ();

ALTER VIEW "public"."user_note" SET ( security_invoker = TRUE);
ALTER VIEW "public"."note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_twist" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_exception" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_expanded" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);
