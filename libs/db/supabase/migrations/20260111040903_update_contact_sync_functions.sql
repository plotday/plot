SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_priority ()
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
    is_root boolean;
BEGIN
    IF TG_OP = 'INSERT' THEN
        event_type := 'created';
        current_item := NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        event_type := 'updated';
        current_item := NEW;
    END IF;
    -- Get users who have access to this priority (just the creator for now)
    SELECT
        jsonb_agg(jsonb_build_object('user_id', current_item.created_by)) INTO users_data;
    -- Exit early if no users found
    IF users_data IS NULL OR jsonb_array_length(users_data) = 0 THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    -- Compute root field from priority_user.key
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                priority_user
            WHERE
                priority_user.priority_id = current_item.id
                AND priority_user.key = 'root') INTO is_root;
    -- Build enriched item
    enriched_item := jsonb_build_object('id', current_item.id, 'created_at', current_item.created_at, 'updated_at', current_item.updated_at, 'created_by', current_item.created_by, 'root', is_root, 'archived_at', current_item.archived_at, 'title', current_item.title, 'path', current_item.path, 'updated_by', current_item.updated_by, 'sync_depth', current_item.sync_depth);
    -- Build the payload (no twists for priority)
    payload := jsonb_build_object('type', 'priority', 'event', event_type, 'item', enriched_item, 'twists', '[]'::jsonb, 'users', users_data, 'timestamp', extract(epoch FROM now()), 'table', 'priority');
    api_url := public.get_api_root () || '/update';
    hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
    signature := encode(extensions.hmac(convert_to(payload::text, 'UTF8'), hmac_secret::bytea, 'sha256'), 'hex');
    PERFORM
        net.http_post (url := api_url, body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_priority_contact_on_delete ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_contact_id uuid;
BEGIN
    -- Get the primary contact_id for this user
    v_contact_id := public.get_primary_contact_id (OLD.user_id);
    -- Delete the corresponding priority_contact if it exists
    IF v_contact_id IS NOT NULL THEN
        DELETE FROM public.priority_contact
        WHERE priority_id = OLD.priority_id
            AND contact_id = v_contact_id;
    END IF;
    RETURN OLD;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_priority_contact_on_insert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_contact_id uuid;
BEGIN
    -- Get the primary contact_id for this user
    v_contact_id := public.get_primary_contact_id (NEW.user_id);
    -- Only create priority_contact if the user has a contact record
    IF v_contact_id IS NOT NULL THEN
        INSERT INTO public.priority_contact (priority_id, contact_id, created_at, archived_at)
            VALUES (NEW.priority_id, v_contact_id, NEW.created_at, NEW.archived_at)
        ON CONFLICT (priority_id, contact_id)
            DO NOTHING;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_priority_contact_on_update ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_contact_id uuid;
BEGIN
    -- Only proceed if archived_at changed
    IF OLD.archived_at IS DISTINCT FROM NEW.archived_at THEN
        -- Get the primary contact_id for this user
        v_contact_id := public.get_primary_contact_id (NEW.user_id);
        -- Update the corresponding priority_contact if it exists
        IF v_contact_id IS NOT NULL THEN
            UPDATE
                public.priority_contact
            SET
                archived_at = NEW.archived_at
            WHERE
                priority_id = NEW.priority_id
                AND contact_id = v_contact_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.upsert_contacts (contacts jsonb)
    RETURNS TABLE (
        id uuid,
        email text,
        name text,
        user_id uuid)
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN QUERY INSERT INTO contact (email, name, avatar_url)
    SELECT
        (c ->> 'email')::text,
        (c ->> 'name')::text,
        (c ->> 'avatar_url')::text
    FROM
        jsonb_array_elements(contacts) AS c
ON CONFLICT (email)
    DO UPDATE SET
        name = COALESCE(EXCLUDED.name, contact.name),
        avatar_url = COALESCE(EXCLUDED.avatar_url, contact.avatar_url)
    RETURNING
        contact.id,
        contact.email,
        contact.name,
        contact.user_id;
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
