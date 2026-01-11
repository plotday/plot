SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.actor (user_activity)
    RETURNS SETOF actor
    LANGUAGE sql
    STABLE ROWS 1
    AS $function$
    SELECT
        actor.*
    FROM
        actor
    WHERE
        actor.id = $1.author_id
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

CREATE OR REPLACE FUNCTION public.migrate_existing_users_to_contacts ()
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $function$
DECLARE
    _user_record record;
    _user_name text;
    _contact_id uuid;
    _updated_app_metadata jsonb;
BEGIN
    -- Loop through all existing auth users and create/update corresponding contacts
    FOR _user_record IN
    SELECT
        id,
        email,
        raw_app_meta_data,
        raw_user_meta_data
    FROM
        auth.users
    WHERE
        email IS NOT NULL LOOP
            -- Extract name from user metadata (check both raw_user_meta_data and raw_app_meta_data)
            -- If no name in metadata, will be NULL (displayName generated from email in app)
            _user_name := COALESCE(_user_record.raw_user_meta_data ->> 'full_name', _user_record.raw_app_meta_data ->> 'full_name', _user_record.raw_app_meta_data ->> 'name');
            -- Upsert contact for this user and get contact ID
            _contact_id := public.upsert_user_contact (_user_record.id, _user_record.email, _user_name, _user_record.raw_app_meta_data ->> 'avatar_url');
            -- Update the user's app_metadata with contact_id
            _updated_app_metadata := COALESCE(_user_record.raw_app_meta_data, '{}'::jsonb) || jsonb_build_object('contact_id', _contact_id);
            -- Update the user record with the new app_metadata
            UPDATE
                auth.users
            SET
                raw_app_meta_data = _updated_app_metadata
            WHERE
                id = _user_record.id;
        END LOOP;
    RAISE NOTICE 'Migration completed: synchronized % users with contacts', (
        SELECT
            COUNT(*)
        FROM
            auth.users
        WHERE
            email IS NOT NULL);
END;
$function$;

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

CREATE OR REPLACE FUNCTION public.sync_user_contact_trigger ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $function$
DECLARE
    _user_name text;
    _contact_id uuid;
BEGIN
    -- Extract name from user metadata (check both raw_user_meta_data and raw_app_meta_data)
    -- If no name in metadata, will be NULL (displayName generated from email in app)
    _user_name := COALESCE(NEW.raw_user_meta_data ->> 'full_name', NEW.raw_app_meta_data ->> 'full_name', NEW.raw_app_meta_data ->> 'name');
    -- Upsert contact and get the contact ID
    _contact_id := public.upsert_user_contact (NEW.id, NEW.email, _user_name, NEW.raw_app_meta_data ->> 'avatar_url');
    -- Update NEW.raw_app_meta_data directly (no UPDATE needed, prevents recursion)
    NEW.raw_app_meta_data := COALESCE(NEW.raw_app_meta_data, '{}'::jsonb) || jsonb_build_object('contact_id', _contact_id);
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE VIEW "public"."user_activity" AS
SELECT
    upe.user_id,
    a.id,
    a.created_at,
    GREATEST (a.updated_at, COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone), COALESCE(uau.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    a.source_created_at,
    a.author_id,
    a.assignee_id,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at) AS archived_at,
    a.priority_id,
    a.priority_path,
    a.type,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.at,
    a."on",
    a.duration,
    a.done_at,
    a.recurrence_rule,
    a.recurrence_exdates,
    a.recurrence_dates,
    a.meta,
    a.source,
    a.created_by_twist_id,
    a.last_note_created_at,
    a.last_note_source_created_at,
    a.mentions,
    CASE WHEN (a.done_at IS NOT NULL) THEN
        tstzrange(a.done_at, a.done_at, '[]'::text)
    WHEN ((a.assignee_id IS NOT NULL)
        AND (ac.user_id <> upe.user_id)) THEN
        tstzrange(GREATEST (a.source_created_at, COALESCE(a.last_note_source_created_at, a.source_created_at)), GREATEST (a.source_created_at, COALESCE(a.last_note_source_created_at, a.source_created_at)), '[]'::text)
    WHEN (a.at IS NOT NULL) THEN
        a.at
    WHEN (a."on" IS NOT NULL) THEN
        NULL::tstzrange
    ELSE
        tstzrange(GREATEST (a.source_created_at, COALESCE(a.last_note_source_created_at, a.source_created_at)), GREATEST (a.source_created_at, COALESCE(a.last_note_source_created_at, a.source_created_at)), '[]'::text)
    END AS range_at,
    CASE WHEN (a.done_at IS NOT NULL) THEN
        NULL::daterange
    WHEN ((a.assignee_id IS NOT NULL)
        AND (ac.user_id <> upe.user_id)) THEN
        NULL::daterange
    WHEN (a.at IS NOT NULL) THEN
        NULL::daterange
    WHEN (a."on" IS NOT NULL) THEN
        a."on"
    ELSE
        NULL::daterange
    END AS range_on,
    COALESCE(uau.unread, FALSE) AS unread
FROM (((activity_x a
            JOIN user_priority_expanded upe ON (a.priority_id = upe.priority_id))
        LEFT JOIN contact ac ON (ac.id = a.assignee_id))
    LEFT JOIN user_activity_unread uau ON (((uau.user_id = upe.user_id)
                AND (uau.activity_id = a.id))));

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
