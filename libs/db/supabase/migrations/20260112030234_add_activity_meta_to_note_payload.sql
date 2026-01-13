SET check_function_bodies = OFF;

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
