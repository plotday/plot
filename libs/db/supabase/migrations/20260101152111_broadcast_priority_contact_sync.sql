SET check_function_bodies = OFF;

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
            -- Get API configuration
            api_url := public.get_api_root () || '/update';
            hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
            signature := encode(extensions.hmac(convert_to(payload::text, 'UTF8'), hmac_secret::bytea, 'sha256'), 'hex');
            -- Send HTTP request to API
            PERFORM
                net.http_post (url := api_url, body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
        END LOOP;
    RETURN NULL;
END;
$function$;

CREATE TRIGGER broadcast_priority_contact_insert
    AFTER INSERT ON public.priority_contact REFERENCING NEW TABLE AS new_priority_contacts
    FOR EACH STATEMENT
    EXECUTE FUNCTION broadcast_priority_contact_sync ();

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
