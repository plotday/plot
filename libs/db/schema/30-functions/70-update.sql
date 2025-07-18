CREATE OR REPLACE FUNCTION get_api_root()
RETURNS text 
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN COALESCE(
        current_setting('plot.api_root', true), 
        'http://host.docker.internal:8787/_'
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_activity()
RETURNS TRIGGER
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
DECLARE
    event_type text;
    payload jsonb;
    api_url text;
BEGIN
    IF TG_OP = 'INSERT' THEN
        event_type := 'created';
    ELSIF TG_OP = 'UPDATE' THEN
        event_type := 'updated';
    ELSIF TG_OP = 'DELETE' THEN
        event_type := 'deleted';
    END IF;

    -- Build the payload
    payload := jsonb_build_object(
        'type', 'activity',
        'event', event_type,
        'item', CASE 
            WHEN TG_OP = 'DELETE' THEN to_jsonb(OLD)
            ELSE to_jsonb(NEW)
        END,
        'agents', (
            SELECT jsonb_agg(
                jsonb_build_object('public_id', public_id, 'id', id, 'config', config)
                ) AS agents_jsonb
            FROM agent_x
            WHERE priority_child_id = COALESCE(NEW.priority_id, OLD.priority_id)
            AND id != COALESCE(NEW.created_by, OLD.created_by)
        ),
        'timestamp', extract(epoch from now()),
        'table', 'activity'
    );
    
    api_url := get_api_root() || '/update';

    PERFORM net.http_post(
        url := api_url,
        body := payload,
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'User-Agent', 'PostgreSQL/pg_net'
        )
    );
    RETURN COALESCE(NEW, OLD);
END;
$$;