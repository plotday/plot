DROP POLICY "Users can delete their own activities" ON "public"."activity";

DROP POLICY "Users can insert activities in their accessible priorities" ON "public"."activity";

DROP POLICY "Users can update their own activities" ON "public"."activity";

DROP POLICY "Users can view activities in their accessible priorities" ON "public"."activity";

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.get_users_with_priority_access (target_priority_id uuid)
    RETURNS TABLE (
        user_id uuid)
    LANGUAGE plpgsql
    STABLE
    SECURITY DEFINER
    AS $function$
BEGIN
    RETURN QUERY SELECT DISTINCT
        pu.user_id
    FROM
        priority_user pu
        JOIN priority p ON pu.priority_id = p.id
            OR (p.path <@ (
                    SELECT
                        path
                    FROM
                        priority
                WHERE
                    id = pu.priority_id))
    WHERE
        pu.deleted_at IS NULL
        AND p.id = get_users_with_priority_access.target_priority_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.user_has_priority_access (user_id uuid, target_priority_id uuid)
    RETURNS boolean
    LANGUAGE plpgsql
    STABLE
    SECURITY DEFINER
    AS $function$
BEGIN
    RETURN EXISTS (
        SELECT
            1
        FROM
            priority_user pu
            JOIN priority p ON pu.priority_id = p.id
                OR (p.path <@ (
                        SELECT
                            path
                        FROM
                            priority
                    WHERE
                        id = pu.priority_id))
            WHERE
                pu.user_id = user_has_priority_access.user_id
                AND pu.deleted_at IS NULL
                AND p.id = user_has_priority_access.target_priority_id);
END;
$function$;

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

CREATE OR REPLACE FUNCTION public.notify_user_for_activity ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    target_priority_id uuid;
    user_to_notify uuid;
BEGIN
    -- Get the priority_id from the activity
    target_priority_id := COALESCE(NEW.priority_id, OLD.priority_id);
    -- Notify all users who have access to this priority
    FOR user_to_notify IN
    SELECT
        user_id
    FROM
        public.get_users_with_priority_access (target_priority_id)
        LOOP
            PERFORM
                realtime.send (jsonb_build_object('table', 'activity', 'updated_by', COALESCE(NEW.updated_by, OLD.updated_by)), -- JSONB Payload
                    'sync', -- Event name
                    'user:' || user_to_notify::text, -- Topic
                    FALSE -- Public / Private flag
);
        END LOOP;
    RETURN NULL;
END;
$function$;

CREATE POLICY "Users can delete their own activities" ON "public"."activity" AS permissive
    FOR DELETE TO public
        USING (((created_by = auth.uid ()) AND user_has_priority_access (auth.uid (), priority_id)));

CREATE POLICY "Users can insert activities in their accessible priorities" ON "public"."activity" AS permissive
    FOR INSERT TO public
        WITH CHECK (((created_by = auth.uid ()) AND user_has_priority_access (auth.uid (), priority_id)));

CREATE POLICY "Users can update their own activities" ON "public"."activity" AS permissive
    FOR UPDATE TO public
        USING (((created_by = auth.uid ()) AND user_has_priority_access (auth.uid (), priority_id)));

CREATE POLICY "Users can view activities in their accessible priorities" ON "public"."activity" AS permissive
    FOR SELECT TO public
        USING (user_has_priority_access (auth.uid (), priority_id));

ALTER VIEW "public"."activity_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_children" SET ( security_invoker = TRUE);
ALTER VIEW gap SET ( security_invoker = TRUE);
ALTER VIEW gap_monthly SET ( security_invoker = TRUE);
ALTER VIEW gap_daily SET ( security_invoker = TRUE);
ALTER VIEW insight SET ( security_invoker = TRUE);
ALTER VIEW "admin"."sync" SET ( security_invoker = FALSE);
ALTER VIEW "admin"."invitation" SET ( security_invoker = FALSE);
ALTER VIEW "public"."event_invitees" SET ( security_invoker = TRUE);
ALTER VIEW "public"."event_x" SET ( security_invoker = TRUE);
ALTER VIEW public.calendar_x SET ( security_invoker = TRUE);
ALTER VIEW "admin"."user" SET ( security_invoker = FALSE);
ALTER VIEW balance_without_children SET ( security_invoker = TRUE);
ALTER VIEW balance SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_children" SET ( security_invoker = TRUE);
ALTER VIEW "public"."agent_x" SET ( security_invoker = TRUE);
