SET check_function_bodies = OFF;

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
        AND id != current_item.author_id;
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
        jsonb_build_object('id', current_item.id, 'created_at', current_item.created_at, 'updated_at', current_item.updated_at, 'author_id', current_item.author_id, 'assignee_id', current_item.assignee_id, 'updated_by', current_item.updated_by, 'deleted_at', current_item.deleted_at, 'priority_id', current_item.priority_id, 'type', current_item.type, 'path', current_item.path, 'order', current_item.order, 'draft', current_item.draft, 'private', current_item.private, 'title', current_item.title, 'note', current_item.note, 'links', current_item.links, 'at', current_item.at, 'on', current_item.on, 'duration', current_item.duration, 'done_at', current_item.done_at, 'recurrence_rule', current_item.recurrence_rule, 'recurrence_exdates', current_item.recurrence_exdates, 'recurrence_dates', current_item.recurrence_dates, 'source', current_item.source,
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
            jsonb_build_object('id', previous_item.id, 'created_at', previous_item.created_at, 'updated_at', previous_item.updated_at, 'author_id', previous_item.author_id, 'assignee_id', previous_item.assignee_id, 'updated_by', previous_item.updated_by, 'deleted_at', previous_item.deleted_at, 'priority_id', previous_item.priority_id, 'type', previous_item.type, 'path', previous_item.path, 'order', previous_item.order, 'draft', previous_item.draft, 'private', previous_item.private, 'title', previous_item.title, 'note', previous_item.note, 'links', previous_item.links, 'at', previous_item.at, 'on', previous_item.on, 'duration', previous_item.duration, 'done_at', previous_item.done_at, 'recurrence_rule', previous_item.recurrence_rule, 'recurrence_exdates', previous_item.recurrence_exdates, 'recurrence_dates', previous_item.recurrence_dates, 'source', previous_item.source,
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

CREATE OR REPLACE FUNCTION public.update_activity_tags (p_activity_id uuid, p_user_id uuid, p_client_id integer, p_tag_updates jsonb)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    tag_record record;
    tag_id_int integer;
    is_adding boolean;
    current_tag_type tag_type;
BEGIN
    -- Iterate through the tag updates JSON object
    FOR tag_record IN
    SELECT
        key,
        value
    FROM
        jsonb_each(p_tag_updates)
        LOOP
            -- Convert key to integer and value to boolean
            tag_id_int := tag_record.key::integer;
            is_adding := tag_record.value::boolean;
            -- Get tag type using the get_tag_type function
            current_tag_type := get_tag_type (tag_id_int);
            IF is_adding THEN
                -- Adding a tag - use upsert to create or reactivate
                INSERT INTO activity_tag (actor_id, activity_id, tag_id, updated_at, deleted_at, updated_by)
                    VALUES (p_user_id, p_activity_id, tag_id_int, now(), NULL, p_client_id)
                ON CONFLICT (actor_id, activity_id, tag_id)
                    DO UPDATE SET
                        deleted_at = NULL,
                        updated_at = now(),
                        updated_by = p_client_id;
            ELSE
                -- Removing a tag - use update to soft delete existing records
                IF current_tag_type = 'toggle' THEN
                    -- For toggle tags, remove all users' tags
                    UPDATE
                        activity_tag
                    SET
                        deleted_at = now(),
                        updated_by = p_client_id
                    WHERE
                        activity_id = p_activity_id
                        AND tag_id = tag_id_int
                        AND deleted_at IS NULL;
                ELSE
                    -- For count/compute tags, only remove current user's tag
                    UPDATE
                        activity_tag
                    SET
                        deleted_at = now(),
                        updated_by = p_client_id
                    WHERE
                        activity_id = p_activity_id
                        AND tag_id = tag_id_int
                        AND actor_id = p_user_id
                        AND deleted_at IS NULL;
                END IF;
            END IF;
        END LOOP;
END;
$function$;

ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_children" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_unread" SET ( security_invoker = TRUE);
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
