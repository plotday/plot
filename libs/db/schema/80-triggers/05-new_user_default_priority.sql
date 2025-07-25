CREATE OR REPLACE FUNCTION public.add_default_priority (user_id uuid)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $function$
DECLARE
    _priority_id uuid;
    payload jsonb;
    _plot_agent_id uuid;
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
    SELECT
        id INTO _plot_agent_id
    FROM
        public.agent
    WHERE
        public_id = 'plot'
    LIMIT 1;
    IF _plot_agent_id IS NOT NULL THEN
        INSERT INTO public.priority_agent (priority_id, agent_id, name)
            VALUES (_priority_id, _plot_agent_id, 'Plot')
        RETURNING
            id INTO _priority_agent_id;
    END IF;
    payload := jsonb_build_object('public_id', 'onboarding', 'priority_agent_id', _priority_agent_id, 'priority_id', _priority_id);
    hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
    signature := encode(extensions.hmac(payload::text::bytea, hmac_secret::bytea, 'sha256'::text), 'hex');
    PERFORM
        net.http_post (url := public.get_api_root () || '/activate', body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
END;
$function$;

CREATE OR REPLACE FUNCTION public.add_default_priority_trigger ()
    RETURNS TRIGGER
    SECURITY DEFINER
    SET search_path = public, auth
    LANGUAGE plpgsql
    AS $function$
BEGIN
    PERFORM
        public.add_default_priority (NEW.id);
    RETURN NEW;
END;
$function$;

CREATE TRIGGER on_user_created_add_default_priority
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.add_default_priority_trigger ();

