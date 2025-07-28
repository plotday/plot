CREATE OR REPLACE FUNCTION public.add_default_priority (user_id uuid)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $function$
DECLARE
    _priority_id uuid;
    payload jsonb;
    _plot_agent_tools jsonb;
    _priority_agent_id uuid;
    hmac_secret text;
    signature text;
BEGIN
    INSERT INTO public.priority (created_by, title, path, root)
        VALUES (user_id, 'Everything', public.generate_path (NULL), TRUE)
    RETURNING
        id INTO _priority_id;
    INSERT INTO public.priority_settings (user_id, priority_id)
        VALUES (user_id, _priority_id);
    -- Install Plot agent
    SELECT
        tools INTO _plot_agent_tools
    FROM
        public.agent
    WHERE
        id = 'plot'
    LIMIT 1;
    IF _plot_agent_tools IS NOT NULL THEN
        INSERT INTO public.priority_agent (priority_id, agent_id, name)
            VALUES (_priority_id, 'plot', 'Plot')
        RETURNING
            id INTO _priority_agent_id;
        payload := jsonb_build_object('agent_id', 'plot', 'priority_agent_id', _priority_agent_id, 'priority_id', _priority_id, 'tools', _plot_agent_tools);
        hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
        signature := encode(extensions.hmac(payload::text::bytea, hmac_secret::bytea, 'sha256'::text), 'hex');
        PERFORM
            net.http_post (url := public.get_api_root () || '/activate', body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
    END IF;
END;
$function$;

