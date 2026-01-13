DROP TRIGGER IF EXISTS "upsert_user_priority" ON "public"."user_priority";

DROP POLICY "Users can update their priorities" ON "public"."priority";

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

DROP VIEW IF EXISTS "public"."user_activity" CASCADE;

DROP VIEW IF EXISTS "public"."user_activity_unread";

DROP VIEW IF EXISTS "public"."user_priority_expanded";

DROP INDEX IF EXISTS "public"."idx_priority_user_key";

ALTER TABLE "public"."priority"
    ADD COLUMN "key" text;

ALTER TABLE "public"."priority_user"
    ADD COLUMN "personal" boolean NOT NULL DEFAULT FALSE;

-- Migrate existing 'root' keys to personal = true
UPDATE
    "public"."priority_user"
SET
    personal = TRUE
WHERE
    key = 'root';

ALTER TABLE "public"."priority_user"
    DROP COLUMN "key";

CREATE UNIQUE INDEX idx_priority_key_per_root ON public.priority USING btree (subltree (path, 0, 1), key)
WHERE (key IS NOT NULL);

CREATE UNIQUE INDEX idx_priority_user_personal_priority ON public.priority_user USING btree (priority_id, personal)
WHERE (personal = TRUE);

CREATE UNIQUE INDEX idx_priority_user_personal_user ON public.priority_user USING btree (user_id, personal)
WHERE (personal = TRUE);

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.insert_priority_user ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
BEGIN
    -- Only create entry for new, top-level priorities, and mark them as personal
    IF nlevel (NEW.path) = 1 THEN
        INSERT INTO public.priority_user (user_id, priority_id, personal)
            VALUES (NEW.created_by, NEW.id, TRUE);
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_activity ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    event_type text;
    payloads jsonb := '[]'::jsonb;
    payload jsonb;
    twists_data jsonb;
    users_data jsonb;
    enriched_item jsonb;
    previous_enriched_item jsonb;
    current_tags jsonb;
    previous_tags jsonb;
    api_url text;
    hmac_secret text;
    signature text;
    current_item record;
    previous_item record;
BEGIN
    -- Determine event type
    IF TG_OP = 'INSERT' THEN
        event_type := 'created';
    ELSIF TG_OP = 'UPDATE' THEN
        event_type := 'updated';
    END IF;
    -- Loop through new rows
    FOR current_item IN
    SELECT
        *
    FROM
        new_rows LOOP
            -- For updates, get the corresponding previous row
            IF TG_OP = 'UPDATE' THEN
                SELECT
                    * INTO previous_item
                FROM
                    old_rows
                WHERE
                    id = current_item.id;
            END IF;
            -- Extract twists query into a variable
            SELECT
                jsonb_agg(jsonb_build_object('id', pct.twist_id, 'environment', pct.twist_environment, 'version', pct.version, 'priority_twist_id', pct.id, 'config', pct.config, 'priority_path', p.path, 'priority_root', subltree (p.path, 0, 1)::text)) INTO twists_data
            FROM
                public.priority_child_twist pct
                JOIN public.priority p ON p.id = pct.priority_id
            WHERE
                pct.priority_child_id = current_item.priority_id
                AND pct.id != current_item.author_id
                AND pct.archived_at IS NULL;
            -- Get users who have access to this priority
            SELECT
                jsonb_agg(jsonb_build_object('user_id', user_id)) INTO users_data
            FROM
                public.get_users_with_priority_access (current_item.priority_id);
            -- Skip this row if no twists or users found
            IF (twists_data IS NULL OR jsonb_array_length(twists_data) = 0) AND (users_data IS NULL OR jsonb_array_length(users_data) = 0) THEN
                CONTINUE;
            END IF;
            -- Build enriched item with author and priority information
            SELECT
                jsonb_build_object('id', current_item.id, 'created_at', current_item.created_at, 'updated_at', current_item.updated_at, 'author_id', current_item.author_id, 'created_by', current_item.created_by, 'assignee_id', current_item.assignee_id, 'updated_by', current_item.updated_by, 'sync_depth', current_item.sync_depth, 'archived_at', current_item.archived_at, 'priority_id', current_item.priority_id, 'type', current_item.type, 'order', current_item.order, 'draft', current_item.draft, 'private', current_item.private, 'title', current_item.title, 'preview', current_item.preview, 'at', current_item.at, 'on', current_item.on, 'duration', current_item.duration, 'done_at', current_item.done_at, 'recurrence_rule', current_item.recurrence_rule, 'recurrence_exdates', current_item.recurrence_exdates, 'recurrence_dates', current_item.recurrence_dates, 'source', current_item.source, 'meta', current_item.meta, 'mentions', (
                        SELECT
                            ARRAY ( SELECT DISTINCT
                                    unnest(n.mentions)
                            FROM note n
                            WHERE
                                n.activity_id = current_item.id
                                AND n.archived_at IS NULL
                                AND n.mentions IS NOT NULL)),
                    -- Enriched data from JOINs
                    'author_name', a.name, 'author_type', a.type, 'priority_title', p.title) INTO enriched_item
            FROM
                actor a,
                priority p
            WHERE
                a.id = current_item.author_id
                AND p.id = current_item.priority_id;
            -- Get tags for current activity
            SELECT
                tags INTO current_tags
            FROM
                activity_tags
            WHERE
                activity_id = current_item.id;
            -- Add tags to enriched item
            enriched_item := enriched_item || jsonb_build_object('tags', current_tags);
            -- Build previous enriched item for updates
            IF TG_OP = 'UPDATE' THEN
                SELECT
                    jsonb_build_object('id', previous_item.id, 'created_at', previous_item.created_at, 'updated_at', previous_item.updated_at, 'author_id', previous_item.author_id, 'created_by', previous_item.created_by, 'assignee_id', previous_item.assignee_id, 'updated_by', previous_item.updated_by, 'sync_depth', previous_item.sync_depth, 'archived_at', previous_item.archived_at, 'priority_id', previous_item.priority_id, 'type', previous_item.type, 'order', previous_item.order, 'draft', previous_item.draft, 'private', previous_item.private, 'title', previous_item.title, 'preview', previous_item.preview, 'at', previous_item.at, 'on', previous_item.on, 'duration', previous_item.duration, 'done_at', previous_item.done_at, 'recurrence_rule', previous_item.recurrence_rule, 'recurrence_exdates', previous_item.recurrence_exdates, 'recurrence_dates', previous_item.recurrence_dates, 'source', previous_item.source, 'meta', previous_item.meta, 'mentions', (
                            SELECT
                                ARRAY ( SELECT DISTINCT
                                        unnest(n.mentions)
                                FROM note n
                                WHERE
                                    n.activity_id = previous_item.id
                                    AND n.archived_at IS NULL
                                    AND n.mentions IS NOT NULL)),
                        -- Enriched data from JOINs
                        'author_name', a.name, 'author_type', a.type, 'priority_title', p.title) INTO previous_enriched_item
                FROM
                    actor a,
                    priority p
                WHERE
                    a.id = previous_item.author_id
                    AND p.id = previous_item.priority_id;
                -- Get tags for previous activity state
                SELECT
                    tags INTO previous_tags
                FROM
                    activity_tags
                WHERE
                    activity_id = previous_item.id;
                -- Add tags to previous enriched item
                previous_enriched_item := previous_enriched_item || jsonb_build_object('tags', previous_tags);
            END IF;
            -- Build the individual payload
            IF TG_OP = 'UPDATE' THEN
                payload := jsonb_build_object('type', 'activity', 'event', event_type, 'item', enriched_item, 'previous', previous_enriched_item, 'twists', COALESCE(twists_data, '[]'::jsonb), 'users', COALESCE(users_data, '[]'::jsonb), 'timestamp', extract(epoch FROM now()), 'table', 'activity');
            ELSE
                payload := jsonb_build_object('type', 'activity', 'event', event_type, 'item', enriched_item, 'twists', COALESCE(twists_data, '[]'::jsonb), 'users', COALESCE(users_data, '[]'::jsonb), 'timestamp', extract(epoch FROM now()), 'table', 'activity');
            END IF;
            -- Add to payloads array
            payloads := payloads || jsonb_build_array(payload);
        END LOOP;
    -- Exit early if no payloads to send
    IF jsonb_array_length(payloads) = 0 THEN
        RETURN NULL;
    END IF;
    -- Send HTTP request with batched payloads
    api_url := public.get_api_root () || '/update';
    hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
    signature := encode(extensions.hmac(convert_to(payloads::text, 'UTF8'), hmac_secret::bytea, 'sha256'), 'hex');
    PERFORM
        net.http_post (url := api_url, body := payloads, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_note ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    event_type text;
    payloads jsonb := '[]'::jsonb;
    payload jsonb;
    twists_data jsonb;
    users_data jsonb;
    enriched_item jsonb;
    previous_enriched_item jsonb;
    current_tags jsonb;
    previous_tags jsonb;
    api_url text;
    hmac_secret text;
    signature text;
    current_item record;
    previous_item record;
    parent_priority_id uuid;
BEGIN
    -- Determine event type
    IF TG_OP = 'INSERT' THEN
        event_type := 'created';
    ELSIF TG_OP = 'UPDATE' THEN
        event_type := 'updated';
    END IF;
    -- Loop through new rows
    FOR current_item IN
    SELECT
        *
    FROM
        new_rows LOOP
            -- For updates, get the corresponding previous row
            IF TG_OP = 'UPDATE' THEN
                SELECT
                    * INTO previous_item
                FROM
                    old_rows
                WHERE
                    id = current_item.id;
            END IF;
            -- Get the parent activity's priority_id
            SELECT
                priority_id INTO parent_priority_id
            FROM
                activity
            WHERE
                id = current_item.activity_id;
            -- Skip this row if parent activity not found
            IF parent_priority_id IS NULL THEN
                CONTINUE;
            END IF;
            -- Extract twists query into a variable
            SELECT
                jsonb_agg(jsonb_build_object('id', pct.twist_id, 'environment', pct.twist_environment, 'version', pct.version, 'priority_twist_id', pct.id, 'config', pct.config, 'priority_path', p.path, 'priority_root', subltree (p.path, 0, 1)::text)) INTO twists_data
            FROM
                public.priority_child_twist pct
                JOIN public.priority p ON p.id = pct.priority_id
            WHERE
                pct.priority_child_id = parent_priority_id
                AND pct.id != current_item.author_id
                AND pct.archived_at IS NULL;
            -- Get users who have access to this priority
            SELECT
                jsonb_agg(jsonb_build_object('user_id', user_id)) INTO users_data
            FROM
                public.get_users_with_priority_access (parent_priority_id);
            -- Skip this row if no twists or users found
            IF (twists_data IS NULL OR jsonb_array_length(twists_data) = 0) AND (users_data IS NULL OR jsonb_array_length(users_data) = 0) THEN
                CONTINUE;
            END IF;
            -- Build enriched item with author and activity information
            SELECT
                jsonb_build_object('id', current_item.id, 'created_at', current_item.created_at, 'updated_at', current_item.updated_at, 'author_id', current_item.author_id, 'created_by', current_item.created_by, 'updated_by', current_item.updated_by, 'sync_depth', current_item.sync_depth, 'archived_at', current_item.archived_at, 'activity_id', current_item.activity_id, 'draft', current_item.draft, 'private', current_item.private, 'content', current_item.content, 'key', current_item.key, 'links', current_item.links, 'mentions', current_item.mentions,
                    -- Enriched data from JOINs
                    'author_name', a.name, 'author_type', a.type, 'activity_title', act.title, 'priority_id', act.priority_id,
                    -- Parent activity metadata for dispatch logic
                    'activity_created_by', act.created_by, 'activity_meta', act.meta, 'activity_mentions', (
                        SELECT
                            COALESCE(array_agg(DISTINCT mention), ARRAY[]::uuid[])
                        FROM note n, LATERAL unnest(n.mentions) AS mention
                        WHERE
                            n.activity_id = act.id
                            AND n.archived_at IS NULL
                            AND n.mentions IS NOT NULL)) INTO enriched_item
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
                    jsonb_build_object('id', previous_item.id, 'created_at', previous_item.created_at, 'updated_at', previous_item.updated_at, 'author_id', previous_item.author_id, 'created_by', previous_item.created_by, 'updated_by', previous_item.updated_by, 'sync_depth', previous_item.sync_depth, 'archived_at', previous_item.archived_at, 'activity_id', previous_item.activity_id, 'draft', previous_item.draft, 'private', previous_item.private, 'content', previous_item.content, 'key', previous_item.key, 'links', previous_item.links, 'mentions', previous_item.mentions,
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
            -- Build the individual payload
            IF TG_OP = 'UPDATE' THEN
                payload := jsonb_build_object('type', 'note', 'event', event_type, 'item', enriched_item, 'previous', previous_enriched_item, 'twists', COALESCE(twists_data, '[]'::jsonb), 'users', COALESCE(users_data, '[]'::jsonb), 'timestamp', extract(epoch FROM now()), 'table', 'note');
            ELSE
                payload := jsonb_build_object('type', 'note', 'event', event_type, 'item', enriched_item, 'twists', COALESCE(twists_data, '[]'::jsonb), 'users', COALESCE(users_data, '[]'::jsonb), 'timestamp', extract(epoch FROM now()), 'table', 'note');
            END IF;
            -- Add to payloads array
            payloads := payloads || jsonb_build_array(payload);
        END LOOP;
    -- Exit early if no payloads to send
    IF jsonb_array_length(payloads) = 0 THEN
        RETURN NULL;
    END IF;
    -- Send HTTP request with batched payloads
    api_url := public.get_api_root () || '/update';
    hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
    signature := encode(extensions.hmac(convert_to(payloads::text, 'UTF8'), hmac_secret::bytea, 'sha256'), 'hex');
    PERFORM
        net.http_post (url := api_url, body := payloads, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_priority ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    event_type text;
    payloads jsonb := '[]'::jsonb;
    payload jsonb;
    users_data jsonb;
    enriched_item jsonb;
    api_url text;
    hmac_secret text;
    signature text;
    current_item record;
    is_root boolean;
BEGIN
    -- Determine event type
    IF TG_OP = 'INSERT' THEN
        event_type := 'created';
    ELSIF TG_OP = 'UPDATE' THEN
        event_type := 'updated';
    END IF;
    -- Loop through new rows
    FOR current_item IN
    SELECT
        *
    FROM
        new_rows LOOP
            -- Get users who have access to this priority (just the creator for now)
            SELECT
                jsonb_agg(jsonb_build_object('user_id', current_item.created_by)) INTO users_data;
            -- Skip this row if no users found
            IF users_data IS NULL OR jsonb_array_length(users_data) = 0 THEN
                CONTINUE;
            END IF;
            -- Compute root field from priority_user.personal
            SELECT
                EXISTS (
                    SELECT
                        1
                    FROM
                        priority_user
                    WHERE
                        priority_user.priority_id = current_item.id
                        AND priority_user.personal = TRUE) INTO is_root;
            -- Build enriched item
            enriched_item := jsonb_build_object('id', current_item.id, 'created_at', current_item.created_at, 'updated_at', current_item.updated_at, 'created_by', current_item.created_by, 'root', is_root, 'archived_at', current_item.archived_at, 'title', current_item.title, 'path', current_item.path, 'updated_by', current_item.updated_by, 'sync_depth', current_item.sync_depth, 'key', current_item.key);
            -- Build the payload (no twists for priority)
            payload := jsonb_build_object('type', 'priority', 'event', event_type, 'item', enriched_item, 'twists', '[]'::jsonb, 'users', users_data, 'timestamp', extract(epoch FROM now()), 'table', 'priority');
            -- Add to payloads array
            payloads := payloads || jsonb_build_array(payload);
        END LOOP;
    -- Exit early if no payloads to send
    IF jsonb_array_length(payloads) = 0 THEN
        RETURN NULL;
    END IF;
    -- Send HTTP request with batched payloads
    api_url := public.get_api_root () || '/update';
    hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
    signature := encode(extensions.hmac(convert_to(payloads::text, 'UTF8'), hmac_secret::bytea, 'sha256'), 'hex');
    PERFORM
        net.http_post (url := api_url, body := payloads, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
    RETURN NULL;
END;
$function$;

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
    ((pu.personal = TRUE)
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
                                    AND (pu_root.personal = TRUE))))
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
    GREATEST (a.updated_at, COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone), COALESCE(uau.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
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
    a.avatar_url,
    (EXISTS (
            SELECT
                1
            FROM
                contact c
            WHERE ((c.id = a.id)
                AND (c.user_id = ua.user_id)))) AS self
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
            WHERE ((priority_user.priority_id = priority.id) AND (priority_user.personal = TRUE))))))))
        WITH CHECK (((nlevel (path) = 1) OR can_access_priority (parent_path (path))));

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

ALTER VIEW "public"."activity_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_exception" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_expanded" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_settings_inherited" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child_twist" SET (security_invoker = TRUE);

