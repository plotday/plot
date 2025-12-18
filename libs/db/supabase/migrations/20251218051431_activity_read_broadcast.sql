SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_activity_read ()
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
    -- Get user for this activity_read record
    SELECT
        jsonb_agg(jsonb_build_object('user_id', current_item.user_id)) INTO users_data;
    -- Exit early if no users found
    IF users_data IS NULL OR jsonb_array_length(users_data) = 0 THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    -- Build minimal enriched item (only what's needed for sync)
    enriched_item := jsonb_build_object('user_id', current_item.user_id, 'activity_id', current_item.activity_id, 'read_at', current_item.read_at, 'updated_at', current_item.updated_at);
    -- Build the payload (no twists for activity_read)
    payload := jsonb_build_object('type', 'activity_read', 'event', event_type, 'item', enriched_item, 'twists', '[]'::jsonb, 'users', users_data, 'timestamp', extract(epoch FROM now()), 'table', 'activity_read');
    api_url := get_api_root () || '/update';
    hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
    signature := encode(extensions.hmac(convert_to(payload::text, 'UTF8'), hmac_secret::bytea, 'sha256'), 'hex');
    PERFORM
        net.http_post (url := api_url, body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE TRIGGER notify_activity_read_change
    AFTER INSERT OR DELETE OR UPDATE ON public.activity_read
    FOR EACH ROW
    EXECUTE FUNCTION notify_internal_api_for_activity_read ();

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
ALTER VIEW "public"."priority_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_base" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);
