DROP TRIGGER IF EXISTS "activity_change_api_call" ON "public"."activity";

DROP TRIGGER IF EXISTS "notify_activity_read_change" ON "public"."activity_read";

DROP TRIGGER IF EXISTS "note_change_api_call" ON "public"."note";

DROP TRIGGER IF EXISTS "handle_priority_changes" ON "public"."priority";

DROP TRIGGER IF EXISTS "notify_priority_twist_update" ON "public"."priority_twist";

DROP TRIGGER IF EXISTS "handle_session_changes" ON "public"."session";

SET check_function_bodies = OFF;

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
                jsonb_agg(jsonb_build_object('id', twist_id, 'environment', twist_environment, 'version', version, 'priority_twist_id', id, 'config', config)) INTO twists_data
            FROM
                public.priority_child_twist
            WHERE
                priority_child_id = current_item.priority_id
                AND id != current_item.author_id
                AND archived_at IS NULL;
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

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_activity_read ()
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
            -- Get user for this activity_read record
            SELECT
                jsonb_agg(jsonb_build_object('user_id', current_item.user_id)) INTO users_data;
            -- Skip this row if no users found
            IF users_data IS NULL OR jsonb_array_length(users_data) = 0 THEN
                CONTINUE;
            END IF;
            -- Build minimal enriched item (only what's needed for sync)
            enriched_item := jsonb_build_object('user_id', current_item.user_id, 'activity_id', current_item.activity_id, 'read_at', current_item.read_at, 'updated_at', current_item.updated_at);
            -- Build the payload (no twists for activity_read)
            payload := jsonb_build_object('type', 'activity_read', 'event', event_type, 'item', enriched_item, 'twists', '[]'::jsonb, 'users', users_data, 'timestamp', extract(epoch FROM now()), 'table', 'activity_read');
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
                jsonb_agg(jsonb_build_object('id', twist_id, 'environment', twist_environment, 'version', version, 'priority_twist_id', id, 'config', config)) INTO twists_data
            FROM
                public.priority_child_twist
            WHERE
                priority_child_id = parent_priority_id
                AND id != current_item.author_id
                AND archived_at IS NULL;
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

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_priority_twist ()
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
    api_url text;
    hmac_secret text;
    signature text;
    current_item record;
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
            -- Get twists that have access to this priority (excluding the current twist)
            SELECT
                jsonb_agg(jsonb_build_object('id', twist_id, 'environment', twist_environment, 'version', version, 'priority_twist_id', id, 'config', config)) INTO twists_data
FROM
    public.priority_child_twist
WHERE
    priority_child_id = current_item.priority_id
    AND id != current_item.id
    AND archived_at IS NULL;
            -- Get users who have access to this priority
            SELECT
                jsonb_agg(jsonb_build_object('user_id', user_id)) INTO users_data
            FROM
                public.get_users_with_priority_access (current_item.priority_id);
            -- Skip this row if no twists or users found
            IF (twists_data IS NULL OR jsonb_array_length(twists_data) = 0) AND (users_data IS NULL OR jsonb_array_length(users_data) = 0) THEN
                CONTINUE;
            END IF;
            -- Build enriched item
            enriched_item := jsonb_build_object('id', current_item.id, 'created_at', current_item.created_at, 'updated_at', current_item.updated_at, 'archived_at', current_item.archived_at, 'priority_id', current_item.priority_id, 'twist_id', current_item.twist_id, 'owner_id', current_item.owner_id, 'name', current_item.name, 'config', current_item.config);
            -- Build the payload
            payload := jsonb_build_object('type', 'priority_twist', 'event', event_type, 'item', enriched_item, 'twists', COALESCE(twists_data, '[]'::jsonb), 'users', COALESCE(users_data, '[]'::jsonb), 'timestamp', extract(epoch FROM now()), 'table', 'priority_twist');
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

DROP TRIGGER IF EXISTS "activity_insert_api_call" ON "public"."activity";

DROP TRIGGER IF EXISTS "activity_update_api_call" ON "public"."activity";

DROP TRIGGER IF EXISTS "activity_read_insert_api_call" ON "public"."activity_read";

DROP TRIGGER IF EXISTS "activity_read_update_api_call" ON "public"."activity_read";

DROP TRIGGER IF EXISTS "note_insert_api_call" ON "public"."note";

DROP TRIGGER IF EXISTS "note_update_api_call" ON "public"."note";

DROP TRIGGER IF EXISTS "priority_insert_api_call" ON "public"."priority";

DROP TRIGGER IF EXISTS "priority_update_api_call" ON "public"."priority";

DROP TRIGGER IF EXISTS "priority_twist_insert_api_call" ON "public"."priority_twist";

DROP TRIGGER IF EXISTS "priority_twist_update_api_call" ON "public"."priority_twist";

DROP TRIGGER IF EXISTS "session_insert_api_call" ON "public"."session";

DROP TRIGGER IF EXISTS "session_update_api_call" ON "public"."session";

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_session ()
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
            -- Get user for this session
            SELECT
                jsonb_agg(jsonb_build_object('user_id', current_item.user_id)) INTO users_data;
            -- Skip this row if no users found
            IF users_data IS NULL OR jsonb_array_length(users_data) = 0 THEN
                CONTINUE;
            END IF;
            -- Build enriched item
            enriched_item := jsonb_build_object('id', current_item.id, 'created_at', current_item.created_at, 'updated_at', current_item.updated_at, 'archived_at', current_item.archived_at, 'user_id', current_item.user_id, 'priority_id', current_item.priority_id, 'at', current_item.at, 'precedence', current_item.precedence, 'pomodoro', current_item.pomodoro, 'pomodoro_at', current_item.pomodoro_at, 'updated_by', current_item.updated_by);
            -- Build the payload (no twists for session)
            payload := jsonb_build_object('type', 'session', 'event', event_type, 'item', enriched_item, 'twists', '[]'::jsonb, 'users', users_data, 'timestamp', extract(epoch FROM now()), 'table', 'session');
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

CREATE TRIGGER activity_insert_api_call
    AFTER INSERT ON public.activity REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION notify_internal_api_for_activity ();

CREATE TRIGGER activity_update_api_call
    AFTER UPDATE ON public.activity REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION notify_internal_api_for_activity ();

CREATE TRIGGER activity_read_insert_api_call
    AFTER INSERT ON public.activity_read REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION notify_internal_api_for_activity_read ();

CREATE TRIGGER activity_read_update_api_call
    AFTER UPDATE ON public.activity_read REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION notify_internal_api_for_activity_read ();

CREATE TRIGGER note_insert_api_call
    AFTER INSERT ON public.note REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION notify_internal_api_for_note ();

CREATE TRIGGER note_update_api_call
    AFTER UPDATE ON public.note REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION notify_internal_api_for_note ();

CREATE TRIGGER priority_insert_api_call
    AFTER INSERT ON public.priority REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION notify_internal_api_for_priority ();

CREATE TRIGGER priority_update_api_call
    AFTER UPDATE ON public.priority REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION notify_internal_api_for_priority ();

CREATE TRIGGER priority_twist_insert_api_call
    AFTER INSERT ON public.priority_twist REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION notify_internal_api_for_priority_twist ();

CREATE TRIGGER priority_twist_update_api_call
    AFTER UPDATE ON public.priority_twist REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION notify_internal_api_for_priority_twist ();

CREATE TRIGGER session_insert_api_call
    AFTER INSERT ON public.session REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION notify_internal_api_for_session ();

CREATE TRIGGER session_update_api_call
    AFTER UPDATE ON public.session REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION notify_internal_api_for_session ();

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

