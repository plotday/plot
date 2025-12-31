SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.notify_for_activity_tag_change ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    activity_record record;
    result record;
BEGIN
    -- Get the activity_id from either NEW or OLD depending on operation
    -- For INSERT and UPDATE, use NEW.activity_id
    -- For DELETE, use OLD.activity_id
    IF TG_OP = 'DELETE' THEN
        -- Fetch the parent activity record
        SELECT
            * INTO activity_record
        FROM
            activity
        WHERE
            id = OLD.activity_id;
    ELSE
        -- Fetch the parent activity record
        SELECT
            * INTO activity_record
        FROM
            activity
        WHERE
            id = NEW.activity_id;
    END IF;
    -- Exit early if parent activity not found
    IF activity_record IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    -- Create a synthetic trigger context for the parent activity
    -- We treat tag changes as updates to the activity
    -- Set both NEW and OLD to the same activity record since the activity itself didn't change
    -- The notification function will detect tag changes by querying activity_tags view
    BEGIN
        -- Temporarily set TG_OP to UPDATE and call the notification function
        -- We use a dynamic SQL approach to simulate the trigger
        PERFORM
            public.notify_internal_api_for_activity_from_record (activity_record, activity_record);
    EXCEPTION
        WHEN undefined_function THEN
            -- If the helper function doesn't exist, we'll inline the logic
            -- This is a fallback but we should create the helper function instead
            RAISE NOTICE 'Helper function notify_internal_api_for_activity_from_record not found';
    END;
    RETURN COALESCE(NEW, OLD);
END;

$function$;

CREATE OR REPLACE FUNCTION public.notify_for_note_tag_change ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    note_record record;
    result record;
BEGIN
    -- Get the note_id from either NEW or OLD depending on operation
    -- For INSERT and UPDATE, use NEW.note_id
    -- For DELETE, use OLD.note_id
    IF TG_OP = 'DELETE' THEN
        -- Fetch the parent note record
        SELECT
            * INTO note_record
        FROM
            note
        WHERE
            id = OLD.note_id;
    ELSE
        -- Fetch the parent note record
        SELECT
            * INTO note_record
        FROM
            note
        WHERE
            id = NEW.note_id;
    END IF;
    -- Exit early if parent note not found
    IF note_record IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    -- Create a synthetic trigger context for the parent note
    -- We treat tag changes as updates to the note
    -- Set both NEW and OLD to the same note record since the note itself didn't change
    -- The notification function will detect tag changes by querying note_tags view
    BEGIN
        -- Temporarily set TG_OP to UPDATE and call the notification function
        -- We use a dynamic SQL approach to simulate the trigger
        PERFORM
            public.notify_internal_api_for_note_from_record (note_record, note_record);
    EXCEPTION
        WHEN undefined_function THEN
            -- If the helper function doesn't exist, we'll inline the logic
            -- This is a fallback but we should create the helper function instead
            RAISE NOTICE 'Helper function notify_internal_api_for_note_from_record not found';
    END;
    RETURN COALESCE(NEW, OLD);
END;

$function$;

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_activity_from_record (current_record record, previous_record record)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    event_type text := 'updated';
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
BEGIN
    -- Extract twists query into a variable
    SELECT
        jsonb_agg(jsonb_build_object('id', twist_id, 'environment', twist_environment, 'version', version, 'priority_twist_id', id, 'config', config)) INTO twists_data
    FROM
        public.priority_child_twist
    WHERE
        priority_child_id = current_record.priority_id
        AND id != current_record.author_id
        AND archived_at IS NULL;
    -- Get users who have access to this priority
    SELECT
        jsonb_agg(jsonb_build_object('user_id', user_id)) INTO users_data
    FROM
        public.get_users_with_priority_access (current_record.priority_id);
    -- Exit early if no twists or users found
    IF (twists_data IS NULL OR jsonb_array_length(twists_data) = 0) AND (users_data IS NULL OR jsonb_array_length(users_data) = 0) THEN
        RETURN;
    END IF;
    -- Build enriched item with author and priority information
    SELECT
        jsonb_build_object('id', current_record.id, 'created_at', current_record.created_at, 'updated_at', current_record.updated_at, 'author_id', current_record.author_id, 'created_by', current_record.created_by, 'assignee_id', current_record.assignee_id, 'updated_by', current_record.updated_by, 'archived_at', current_record.archived_at, 'priority_id', current_record.priority_id, 'type', current_record.type, 'order', current_record.order, 'draft', current_record.draft, 'private', current_record.private, 'title', current_record.title, 'preview', current_record.preview, 'at', current_record.at, 'on', current_record.on, 'duration', current_record.duration, 'done_at', current_record.done_at, 'recurrence_rule', current_record.recurrence_rule, 'recurrence_exdates', current_record.recurrence_exdates, 'recurrence_dates', current_record.recurrence_dates, 'source', current_record.source, 'meta', current_record.meta, 'mentions', (
                SELECT
                    ARRAY ( SELECT DISTINCT
                            unnest(n.mentions)
                    FROM note n
                    WHERE
                        n.activity_id = current_record.id
                        AND n.archived_at IS NULL
                        AND n.mentions IS NOT NULL)),
            -- Enriched data from JOINs
            'author_name', a.name, 'author_type', a.type, 'priority_title', p.title) INTO enriched_item
    FROM
        actor a,
        priority p
    WHERE
        a.id = current_record.author_id
        AND p.id = current_record.priority_id;
    -- Exit early if enriched item couldn't be built (e.g., during cascade deletes)
    IF enriched_item IS NULL THEN
        RETURN;
    END IF;
    -- Get tags for current activity
    SELECT
        tags INTO current_tags
    FROM
        activity_tags
    WHERE
        activity_id = current_record.id;
    -- Add tags to enriched item
    enriched_item := enriched_item || jsonb_build_object('tags', current_tags);
    -- Build previous enriched item
    SELECT
        jsonb_build_object('id', previous_record.id, 'created_at', previous_record.created_at, 'updated_at', previous_record.updated_at, 'author_id', previous_record.author_id, 'created_by', previous_record.created_by, 'assignee_id', previous_record.assignee_id, 'updated_by', previous_record.updated_by, 'archived_at', previous_record.archived_at, 'priority_id', previous_record.priority_id, 'type', previous_record.type, 'order', previous_record.order, 'draft', previous_record.draft, 'private', previous_record.private, 'title', previous_record.title, 'preview', previous_record.preview, 'at', previous_record.at, 'on', previous_record.on, 'duration', previous_record.duration, 'done_at', previous_record.done_at, 'recurrence_rule', previous_record.recurrence_rule, 'recurrence_exdates', previous_record.recurrence_exdates, 'recurrence_dates', previous_record.recurrence_dates, 'source', previous_record.source, 'meta', previous_record.meta, 'mentions', (
                SELECT
                    ARRAY ( SELECT DISTINCT
                            unnest(n.mentions)
                    FROM note n
                    WHERE
                        n.activity_id = previous_record.id
                        AND n.archived_at IS NULL
                        AND n.mentions IS NOT NULL)),
            -- Enriched data from JOINs
            'author_name', a.name, 'author_type', a.type, 'priority_title', p.title) INTO previous_enriched_item
    FROM
        actor a,
        priority p
    WHERE
        a.id = previous_record.author_id
        AND p.id = previous_record.priority_id;
    -- Exit early if previous enriched item couldn't be built (e.g., during cascade deletes)
    IF previous_enriched_item IS NULL THEN
        RETURN;
    END IF;
    -- Get tags for previous activity state (same as current since we're simulating)
    SELECT
        tags INTO previous_tags
    FROM
        activity_tags
    WHERE
        activity_id = previous_record.id;
    -- Add tags to previous enriched item
    previous_enriched_item := previous_enriched_item || jsonb_build_object('tags', previous_tags);
    -- Build the payload
    payload := jsonb_build_object('type', 'activity', 'event', event_type, 'item', enriched_item, 'previous', previous_enriched_item, 'twists', COALESCE(twists_data, '[]'::jsonb), 'users', COALESCE(users_data, '[]'::jsonb), 'timestamp', extract(epoch FROM now()), 'table', 'activity');
    api_url := public.get_api_root () || '/update';
    hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
    signature := encode(extensions.hmac(convert_to(payload::text, 'UTF8'), hmac_secret::bytea, 'sha256'), 'hex');
    PERFORM
        net.http_post (url := api_url, body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_note_from_record (current_record record, previous_record record)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    event_type text := 'updated';
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
    parent_priority_id uuid;
BEGIN
    -- Get the parent activity's priority_id
    SELECT
        priority_id INTO parent_priority_id
    FROM
        activity
    WHERE
        id = current_record.activity_id;
    -- Exit early if parent activity not found
    IF parent_priority_id IS NULL THEN
        RETURN;
    END IF;
    -- Extract twists query into a variable
    SELECT
        jsonb_agg(jsonb_build_object('id', twist_id, 'environment', twist_environment, 'version', version, 'priority_twist_id', id, 'config', config)) INTO twists_data
    FROM
        public.priority_child_twist
    WHERE
        priority_child_id = parent_priority_id
        AND id != current_record.author_id
        AND archived_at IS NULL;
    -- Get users who have access to this priority
    SELECT
        jsonb_agg(jsonb_build_object('user_id', user_id)) INTO users_data
    FROM
        public.get_users_with_priority_access (parent_priority_id);
    -- Exit early if no twists or users found
    IF (twists_data IS NULL OR jsonb_array_length(twists_data) = 0) AND (users_data IS NULL OR jsonb_array_length(users_data) = 0) THEN
        RETURN;
    END IF;
    -- Build enriched item with author and activity information
    SELECT
        jsonb_build_object('id', current_record.id, 'created_at', current_record.created_at, 'updated_at', current_record.updated_at, 'author_id', current_record.author_id, 'created_by', current_record.created_by, 'updated_by', current_record.updated_by, 'archived_at', current_record.archived_at, 'activity_id', current_record.activity_id, 'draft', current_record.draft, 'private', current_record.private, 'content', current_record.content, 'links', current_record.links, 'mentions', current_record.mentions,
            -- Enriched data from JOINs
            'author_name', a.name, 'author_type', a.type, 'activity_title', act.title, 'priority_id', act.priority_id) INTO enriched_item
    FROM
        actor a,
        activity act
    WHERE
        a.id = current_record.author_id
        AND act.id = current_record.activity_id;
    -- Exit early if enriched item couldn't be built (e.g., during cascade deletes)
    IF enriched_item IS NULL THEN
        RETURN;
    END IF;
    -- Get tags for current note
    SELECT
        tags INTO current_tags
    FROM
        note_tags
    WHERE
        note_id = current_record.id;
    -- Add tags to enriched item
    enriched_item := enriched_item || jsonb_build_object('tags', current_tags);
    -- Build previous enriched item
    SELECT
        jsonb_build_object('id', previous_record.id, 'created_at', previous_record.created_at, 'updated_at', previous_record.updated_at, 'author_id', previous_record.author_id, 'created_by', previous_record.created_by, 'updated_by', previous_record.updated_by, 'archived_at', previous_record.archived_at, 'activity_id', previous_record.activity_id, 'draft', previous_record.draft, 'private', previous_record.private, 'content', previous_record.content, 'links', previous_record.links, 'mentions', previous_record.mentions,
            -- Enriched data from JOINs
            'author_name', a.name, 'author_type', a.type, 'activity_title', act.title, 'priority_id', act.priority_id) INTO previous_enriched_item
    FROM
        actor a,
        activity act
    WHERE
        a.id = previous_record.author_id
        AND act.id = previous_record.activity_id;
    -- Exit early if previous enriched item couldn't be built (e.g., during cascade deletes)
    IF previous_enriched_item IS NULL THEN
        RETURN;
    END IF;
    -- Get tags for previous note state (same as current since we're simulating)
    SELECT
        tags INTO previous_tags
    FROM
        note_tags
    WHERE
        note_id = previous_record.id;
    -- Add tags to previous enriched item
    previous_enriched_item := previous_enriched_item || jsonb_build_object('tags', previous_tags);
    -- Build the payload
    payload := jsonb_build_object('type', 'note', 'event', event_type, 'item', enriched_item, 'previous', previous_enriched_item, 'twists', COALESCE(twists_data, '[]'::jsonb), 'users', COALESCE(users_data, '[]'::jsonb), 'timestamp', extract(epoch FROM now()), 'table', 'note');
    api_url := public.get_api_root () || '/update';
    hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
    signature := encode(extensions.hmac(convert_to(payload::text, 'UTF8'), hmac_secret::bytea, 'sha256'), 'hex');
    PERFORM
        net.http_post (url := api_url, body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
END;
$function$;

CREATE TRIGGER notify_api_for_activity_tag_change
    AFTER INSERT OR DELETE OR UPDATE ON public.activity_tag
    FOR EACH ROW
    EXECUTE FUNCTION notify_for_activity_tag_change ();

CREATE TRIGGER notify_api_for_note_tag_change
    AFTER INSERT OR DELETE OR UPDATE ON public.note_tag
    FOR EACH ROW
    EXECUTE FUNCTION notify_for_note_tag_change ();

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
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);
