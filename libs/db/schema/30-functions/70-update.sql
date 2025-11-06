CREATE OR REPLACE FUNCTION get_api_root ()
    RETURNS text
    LANGUAGE plpgsql
    STABLE
    AS $$
BEGIN
    RETURN COALESCE(current_setting('plot.api_root', TRUE), 'http://host.docker.internal:8787/sync');
END;
$$;

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_activity ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    event_type text;
    agents_data jsonb;
    users_data jsonb;
    enriched_item jsonb;
    previous_enriched_item jsonb;
    current_tags jsonb;
    previous_tags jsonb;
    thread_root_data jsonb;
    previous_thread_root_data jsonb;
    thread_root_tags jsonb;
    previous_thread_root_tags jsonb;
    payload jsonb;
    api_url text;
    hmac_secret text;
    signature text;
    current_item record;
    previous_item record;
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
    -- Extract agents query into a variable
    SELECT
        jsonb_agg(jsonb_build_object('id', agent_id, 'environment', agent_environment, 'version', version, 'priority_agent_id', id, 'config', config)) INTO agents_data
    FROM
        priority_child_agent
    WHERE
        priority_child_id = current_item.priority_id
        AND id != current_item.author_id
        AND archived_at IS NULL;
    -- Get users who have access to this priority
    SELECT
        jsonb_agg(jsonb_build_object('user_id', user_id)) INTO users_data
    FROM
        public.get_users_with_priority_access (current_item.priority_id);
    -- Exit early if no agents or users found
    IF (agents_data IS NULL OR jsonb_array_length(agents_data) = 0) AND (users_data IS NULL OR jsonb_array_length(users_data) = 0) THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    -- Build enriched item with author and priority information
    SELECT
        jsonb_build_object('id', current_item.id, 'created_at', current_item.created_at, 'updated_at', current_item.updated_at, 'author_id', current_item.author_id, 'created_by', current_item.created_by, 'assignee_id', current_item.assignee_id, 'updated_by', current_item.updated_by, 'archived_at', current_item.archived_at, 'priority_id', current_item.priority_id, 'type', current_item.type, 'path', current_item.path, 'order', current_item.order, 'draft', current_item.draft, 'private', current_item.private, 'title', current_item.title, 'note', current_item.note, 'links', current_item.links, 'at', current_item.at, 'on', current_item.on, 'duration', current_item.duration, 'done_at', current_item.done_at, 'recurrence_rule', current_item.recurrence_rule, 'recurrence_exdates', current_item.recurrence_exdates, 'recurrence_dates', current_item.recurrence_dates, 'meta', current_item.meta, 'mentions', current_item.mentions,
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
    -- Fetch thread root data if this activity is nested (path depth > 1)
    IF nlevel (current_item.path) > 1 THEN
        SELECT
            jsonb_build_object('id', tr.id, 'created_at', tr.created_at, 'updated_at', tr.updated_at, 'author_id', tr.author_id, 'created_by', tr.created_by, 'assignee_id', tr.assignee_id, 'updated_by', tr.updated_by, 'archived_at', tr.archived_at, 'priority_id', tr.priority_id, 'type', tr.type, 'path', tr.path, 'order', tr.order, 'draft', tr.draft, 'private', tr.private, 'title', tr.title, 'note', tr.note, 'links', tr.links, 'at', tr.at, 'on', tr.on, 'duration', tr.duration, 'done_at', tr.done_at, 'recurrence_rule', tr.recurrence_rule, 'recurrence_exdates', tr.recurrence_exdates, 'recurrence_dates', tr.recurrence_dates, 'meta', tr.meta, 'mentions', tr.mentions,
                -- Enriched data from JOINs
                'author_name', tra.name, 'author_type', tra.type, 'priority_title', trp.title) INTO thread_root_data
        FROM
            activity tr
            JOIN actor tra ON tra.id = tr.author_id
            JOIN priority trp ON trp.id = tr.priority_id
        WHERE
            tr.path = subpath (current_item.path, 0, 1)
            AND tr.priority_id = current_item.priority_id;
        -- Get tags for thread root
        IF thread_root_data IS NOT NULL THEN
            SELECT
                tags INTO thread_root_tags
            FROM
                activity_tags
            WHERE
                activity_id = (thread_root_data ->> 'id')::uuid;
            -- Add tags to thread root data
            thread_root_data := thread_root_data || jsonb_build_object('tags', thread_root_tags);
        END IF;
        -- Add thread root to enriched item
        enriched_item := enriched_item || jsonb_build_object('thread_root', thread_root_data);
    END IF;
    -- Build previous enriched item for updates
    IF TG_OP = 'UPDATE' THEN
        SELECT
            jsonb_build_object('id', previous_item.id, 'created_at', previous_item.created_at, 'updated_at', previous_item.updated_at, 'author_id', previous_item.author_id, 'created_by', previous_item.created_by, 'assignee_id', previous_item.assignee_id, 'updated_by', previous_item.updated_by, 'archived_at', previous_item.archived_at, 'priority_id', previous_item.priority_id, 'type', previous_item.type, 'path', previous_item.path, 'order', previous_item.order, 'draft', previous_item.draft, 'private', previous_item.private, 'title', previous_item.title, 'note', previous_item.note, 'links', previous_item.links, 'at', previous_item.at, 'on', previous_item.on, 'duration', previous_item.duration, 'done_at', previous_item.done_at, 'recurrence_rule', previous_item.recurrence_rule, 'recurrence_exdates', previous_item.recurrence_exdates, 'recurrence_dates', previous_item.recurrence_dates, 'meta', previous_item.meta, 'mentions', previous_item.mentions,
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
        -- Fetch thread root data for previous state if nested (path depth > 1)
        IF nlevel (previous_item.path) > 1 THEN
            SELECT
                jsonb_build_object('id', tr.id, 'created_at', tr.created_at, 'updated_at', tr.updated_at, 'author_id', tr.author_id, 'created_by', tr.created_by, 'assignee_id', tr.assignee_id, 'updated_by', tr.updated_by, 'archived_at', tr.archived_at, 'priority_id', tr.priority_id, 'type', tr.type, 'path', tr.path, 'order', tr.order, 'draft', tr.draft, 'private', tr.private, 'title', tr.title, 'note', tr.note, 'links', tr.links, 'at', tr.at, 'on', tr.on, 'duration', tr.duration, 'done_at', tr.done_at, 'recurrence_rule', tr.recurrence_rule, 'recurrence_exdates', tr.recurrence_exdates, 'recurrence_dates', tr.recurrence_dates, 'meta', tr.meta, 'mentions', tr.mentions,
                    -- Enriched data from JOINs
                    'author_name', tra.name, 'author_type', tra.type, 'priority_title', trp.title) INTO previous_thread_root_data
            FROM
                activity tr
                JOIN actor tra ON tra.id = tr.author_id
                JOIN priority trp ON trp.id = tr.priority_id
            WHERE
                tr.path = subpath (previous_item.path, 0, 1)
                AND tr.priority_id = previous_item.priority_id;
            -- Get tags for previous thread root
            IF previous_thread_root_data IS NOT NULL THEN
                SELECT
                    tags INTO previous_thread_root_tags
                FROM
                    activity_tags
                WHERE
                    activity_id = (previous_thread_root_data ->> 'id')::uuid;
                -- Add tags to previous thread root data
                previous_thread_root_data := previous_thread_root_data || jsonb_build_object('tags', previous_thread_root_tags);
            END IF;
            -- Add thread root to previous enriched item
            previous_enriched_item := previous_enriched_item || jsonb_build_object('thread_root', previous_thread_root_data);
        END IF;
    END IF;
    -- Build the payload
    IF TG_OP = 'UPDATE' THEN
        payload := jsonb_build_object('type', 'activity', 'event', event_type, 'item', enriched_item, 'previous', previous_enriched_item, 'agents', COALESCE(agents_data, '[]'::jsonb), 'users', COALESCE(users_data, '[]'::jsonb), 'timestamp', extract(epoch FROM now()), 'table', 'activity');
    ELSE
        payload := jsonb_build_object('type', 'activity', 'event', event_type, 'item', enriched_item, 'agents', COALESCE(agents_data, '[]'::jsonb), 'users', COALESCE(users_data, '[]'::jsonb), 'timestamp', extract(epoch FROM now()), 'table', 'activity');
    END IF;
    api_url := get_api_root () || '/update';
    hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
    signature := encode(extensions.hmac(convert_to(payload::text, 'UTF8'), hmac_secret::bytea, 'sha256'), 'hex');
    PERFORM
        net.http_post (url := api_url, body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
    RETURN COALESCE(NEW, OLD);
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
    enriched_item := jsonb_build_object('id', current_item.id, 'created_at', current_item.created_at, 'updated_at', current_item.updated_at, 'created_by', current_item.created_by, 'root', current_item.root, 'archived_at', current_item.archived_at, 'title', current_item.title, 'path', current_item.path, 'updated_by', current_item.updated_by);
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

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_session ()
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
    -- Get user for this session
    SELECT
        jsonb_agg(jsonb_build_object('user_id', current_item.user_id)) INTO users_data;
    -- Exit early if no users found
    IF users_data IS NULL OR jsonb_array_length(users_data) = 0 THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    -- Build enriched item
    enriched_item := jsonb_build_object('id', current_item.id, 'created_at', current_item.created_at, 'updated_at', current_item.updated_at, 'archived_at', current_item.archived_at, 'user_id', current_item.user_id, 'priority_id', current_item.priority_id, 'at', current_item.at, 'precedence', current_item.precedence, 'pomodoro', current_item.pomodoro, 'pomodoro_at', current_item.pomodoro_at, 'updated_by', current_item.updated_by);
    -- Build the payload (no agents for session)
    payload := jsonb_build_object('type', 'session', 'event', event_type, 'item', enriched_item, 'agents', '[]'::jsonb, 'users', users_data, 'timestamp', extract(epoch FROM now()), 'table', 'session');
    api_url := get_api_root () || '/update';
    hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
    signature := encode(extensions.hmac(convert_to(payload::text, 'UTF8'), hmac_secret::bytea, 'sha256'), 'hex');
    PERFORM
        net.http_post (url := api_url, body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
    RETURN COALESCE(NEW, OLD);
END;
$function$;

