CREATE OR REPLACE FUNCTION get_api_root ()
    RETURNS text
    LANGUAGE plpgsql
    STABLE
    AS $$
BEGIN
    RETURN COALESCE(current_setting('plot.api_root', TRUE), 'http://host.docker.internal:8787/_');
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
    payload jsonb;
    api_url text;
    hmac_secret text;
    signature text;
BEGIN
    IF TG_OP = 'INSERT' THEN
        event_type := 'created';
    ELSIF TG_OP = 'UPDATE' THEN
        event_type := 'updated';
    ELSIF TG_OP = 'DELETE' THEN
        event_type := 'deleted';
    END IF;
    -- Extract agents query into a variable
    SELECT
        jsonb_agg(jsonb_build_object('agent_id', agent_id, 'priority_agent_id', id, 'config', config, 'tools', tools)) INTO agents_data
    FROM
        agent_x
    WHERE
        priority_child_id = COALESCE(NEW.priority_id, OLD.priority_id)
        AND id != COALESCE(NEW.created_by, OLD.created_by);
    -- Exit early if no agents found
    IF agents_data IS NULL OR jsonb_array_length(agents_data) = 0 THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    -- Build the payload
    payload := jsonb_build_object('type', 'activity', 'event', event_type, 'item', CASE WHEN TG_OP = 'DELETE' THEN
            to_jsonb (OLD)
        ELSE
            to_jsonb (NEW)
        END, 'agents', agents_data, 'timestamp', extract(epoch FROM now()), 'table', 'activity');
    api_url := get_api_root () || '/update';
    hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
    signature := encode(extensions.hmac(convert_to(payload::text, 'UTF8'), hmac_secret::bytea, 'sha256'), 'hex');
    PERFORM
        net.http_post (url := api_url, body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
    RETURN COALESCE(NEW, OLD);
END;
$function$;

