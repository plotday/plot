DROP VIEW IF EXISTS "public"."agent_x";

ALTER TABLE "public"."agent"
    ADD COLUMN "public_id" text NOT NULL;

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.get_api_root ()
    RETURNS text
    LANGUAGE plpgsql
    STABLE
    AS $function$
BEGIN
    RETURN COALESCE(current_setting('plot.api_root', TRUE), 'http://host.docker.internal:8787/_');
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_activity ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
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
    payload := jsonb_build_object('type', 'activity', 'event', event_type, 'item', CASE WHEN TG_OP = 'DELETE' THEN
            to_jsonb (OLD)
        ELSE
            to_jsonb (NEW)
        END, 'agents', (
            SELECT
                jsonb_agg(jsonb_build_object('public_id', public_id, 'id', id, 'config', config)) AS agents_jsonb FROM agent_x
            WHERE
                priority_child_id = COALESCE(NEW.priority_id, OLD.priority_id)
                AND id != COALESCE(NEW.created_by, OLD.created_by)), 'timestamp', extract(epoch FROM now()), 'table', 'activity');
    api_url := get_api_root () || '/update';
    PERFORM
        net.http_post (url := api_url, body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net'));
    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE OR REPLACE FUNCTION public.agent_uuid ()
    RETURNS uuid
    LANGUAGE plpgsql
    AS $function$
DECLARE
    random_bytes bytea;
    uuid_text text;
BEGIN
    SELECT
        encode(gen_random_bytes(12), 'hex') INTO uuid_text;
    RETURN (uuid ('ab07ab07' || '-' || substring(uuid_text FROM 1 FOR 4) || '-' || substring(uuid_text FROM 3 FOR 4) || '-' || substring(uuid_text FROM 5 FOR 4) || '-' || substring(uuid_text FROM 7 FOR 12)));
END;
$function$;

CREATE OR REPLACE VIEW "public"."agent_x" AS
SELECT
    pa.id,
    pa.priority_id,
    pa.agent_id,
    pa.name,
    pa.config,
    pa.created_at,
    pa.updated_at,
    pa.deleted_at,
    pc.child_id AS priority_child_id,
    a.public_id
FROM ((priority_agent pa
        JOIN priority_children pc ON (pa.priority_id = pc.id))
    JOIN agent a ON (pa.agent_id = a.id));

CREATE OR REPLACE FUNCTION public.handle_activity_x_upsert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
DECLARE
    _activity_id uuid;
BEGIN
    _activity_id := NEW.id;
    -- Insert or update the activity
    INSERT INTO activity (id, deleted_at, priority_id, path, draft, private, pinned, do_at, done_at, "order", title, note, event_series)
        VALUES (NEW.id, NEW.deleted_at, NEW.priority_id, NEW.path, NEW.draft, NEW.private, NEW.pinned, NEW.do_at, NEW.done_at, NEW.order, NEW.title, NEW.note, NEW.event_series)
    ON CONFLICT (id)
        DO UPDATE SET
            deleted_at = NEW.deleted_at, priority_id = NEW.priority_id, path = NEW.path, draft = NEW.draft, private = NEW.private, pinned = NEW.pinned, do_at = NEW.do_at, done_at = NEW.done_at, "order" = NEW.order, title = NEW.title, note = NEW.note, event_series = NEW.event_series
        RETURNING
            id INTO _activity_id;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER activity_change_api_call
    AFTER INSERT ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION notify_internal_api_for_activity ();

ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_children" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_children" SET ( security_invoker = TRUE);
ALTER VIEW public.calendar_x SET ( security_invoker = TRUE);
ALTER VIEW "public"."event_invitees" SET ( security_invoker = TRUE);
ALTER VIEW "public"."event_x" SET ( security_invoker = TRUE);
ALTER VIEW gap SET ( security_invoker = TRUE);
ALTER VIEW gap_monthly SET ( security_invoker = TRUE);
ALTER VIEW gap_daily SET ( security_invoker = TRUE);
ALTER VIEW balance_without_children SET ( security_invoker = TRUE);
ALTER VIEW balance SET ( security_invoker = TRUE);
ALTER VIEW insight SET ( security_invoker = TRUE);
ALTER VIEW "public"."agent_x" SET ( security_invoker = TRUE);
ALTER VIEW "admin"."invitation" SET ( security_invoker = FALSE);
ALTER VIEW "admin"."sync" SET ( security_invoker = FALSE);
ALTER VIEW "admin"."user" SET ( security_invoker = FALSE);
