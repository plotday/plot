-- Function to broadcast actor sync when priority_contact entries are added
CREATE OR REPLACE FUNCTION public.broadcast_priority_contact_sync ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    users_for_priority jsonb;
    api_url text;
    hmac_secret text;
    signature text;
    payload jsonb;
    payloads jsonb;
    priority_record record;
BEGIN
    -- For each affected priority, get users and broadcast
    FOR priority_record IN ( SELECT DISTINCT
            pc.priority_id
        FROM
            new_priority_contacts pc)
        LOOP
            -- Get users who have access to this priority
            SELECT
                jsonb_agg(jsonb_build_object('user_id', user_id)) INTO users_for_priority
FROM
    public.get_users_with_priority_access (priority_record.priority_id);
            -- Skip if no users found
            IF users_for_priority IS NULL OR jsonb_array_length(users_for_priority) = 0 THEN
                CONTINUE;
            END IF;
            -- Build payload for actor sync broadcast
            -- We don't need to include the full item data, just signal to sync the actor view
            payload := jsonb_build_object('type', 'priority_contact', 'event', 'created', 'item', jsonb_build_object('priority_id', priority_record.priority_id), 'twists', '[]'::jsonb, 'users', users_for_priority, 'timestamp', extract(epoch FROM now()), 'table', 'actor');
            -- Wrap payload in array to match API expectation
            payloads := jsonb_build_array(payload);
            -- Get API configuration
            api_url := public.get_api_root () || '/update';
            hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
            signature := encode(extensions.hmac(convert_to(payloads::text, 'UTF8'), hmac_secret::bytea, 'sha256'), 'hex');
            -- Send HTTP request to API
            PERFORM
                net.http_post (url := api_url, body := payloads, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
        END LOOP;
    RETURN NULL;
END;
$function$;

