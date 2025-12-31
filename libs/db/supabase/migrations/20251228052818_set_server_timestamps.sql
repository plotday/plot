DROP TRIGGER IF EXISTS "set_priority_user_updated_at" ON "public"."priority_settings";

DROP TRIGGER IF EXISTS "set_twist_updated_at" ON "public"."priority_twist";

DROP TRIGGER IF EXISTS "set_activity_updated_at" ON "public"."activity";

DROP TRIGGER IF EXISTS "set_activity_read_updated_at" ON "public"."activity_read";

DROP TRIGGER IF EXISTS "set_activity_tag_updated_at" ON "public"."activity_tag";

DROP TRIGGER IF EXISTS "set_contact_updated_at" ON "public"."contact";

DROP TRIGGER IF EXISTS "set_cost_updated_at" ON "public"."cost";

DROP TRIGGER IF EXISTS "set_note_updated_at" ON "public"."note";

DROP TRIGGER IF EXISTS "set_note_tag_updated_at" ON "public"."note_tag";

DROP TRIGGER IF EXISTS "set_priority_updated_at" ON "public"."priority";

DROP TRIGGER IF EXISTS "set_priority_user_updated_at" ON "public"."priority_user";

DROP TRIGGER IF EXISTS "set_publisher_updated_at" ON "public"."publisher";

DROP TRIGGER IF EXISTS "set_series_updated_at" ON "public"."series";

DROP TRIGGER IF EXISTS "set_session_updated_at" ON "public"."session";

DROP TRIGGER IF EXISTS "set_token_updated_at" ON "public"."token";

DROP TRIGGER IF EXISTS "set_twist_updated_at" ON "public"."twist";

DROP TRIGGER IF EXISTS "set_twist_admin_updated_at" ON "public"."twist_admin";

DROP TRIGGER IF EXISTS "set_usage_updated_at" ON "public"."usage";

DROP TRIGGER IF EXISTS "set_user_settings_updated_at" ON "public"."user_settings";

DROP TRIGGER IF EXISTS "set_user_subscription_updated_at" ON "public"."user_subscription";

ALTER TABLE "public"."activity_tag"
    DROP CONSTRAINT "activity_tag_no_computed_tags";

ALTER TABLE "public"."note_tag"
    DROP CONSTRAINT "note_tag_no_computed_tags";

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.set_created_at ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    NEW.created_at = now();
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_activity_tags (p_activity_id uuid, p_actor_id uuid, p_client_id integer, p_tag_updates jsonb)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    tag_record record;
    tag_id_int integer;
    is_adding boolean;
    current_tag_type tag_type;
BEGIN
    -- Validate that activity_id is provided
    IF p_activity_id IS NULL THEN
        RAISE EXCEPTION 'p_activity_id must be provided';
    END IF;
    -- Iterate through the tag updates JSON object
    FOR tag_record IN
    SELECT
        key,
        value
    FROM
        jsonb_each(p_tag_updates)
        LOOP
            -- Convert key to integer and value to boolean
            tag_id_int := tag_record.key::integer;
            is_adding := tag_record.value::boolean;
            -- Get tag type using the get_tag_type function
            current_tag_type := get_tag_type (tag_id_int);
            -- Prevent insertion of computed tags (tag_id 1-99)
            -- Computed tags should only exist as calculated values
            IF current_tag_type = 'compute' THEN
                RAISE EXCEPTION 'Cannot add computed tag (tag_id: %) - these tags are calculated from activity state', tag_id_int;
            END IF;
            IF is_adding THEN
                -- Adding a tag - use upsert to create or reactivate
                INSERT INTO activity_tag (actor_id, activity_id, occurrence, tag_id, updated_at, archived_at, updated_by)
                    VALUES (p_actor_id, p_activity_id, NULL, tag_id_int, now(), NULL, p_client_id)
                ON CONFLICT (actor_id, activity_id, occurrence, tag_id)
                    DO UPDATE SET
                        archived_at = NULL,
                        updated_at = now(),
                        updated_by = p_client_id;
            ELSE
                -- Removing a tag - use update to soft delete existing records
                IF current_tag_type = 'toggle' THEN
                    -- For toggle tags, remove all users' tags
                    UPDATE
                        activity_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        activity_id = p_activity_id
                        AND tag_id = tag_id_int
                        AND archived_at IS NULL;
                ELSE
                    -- For count/compute tags, only remove current actor's tag
                    UPDATE
                        activity_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        activity_id = p_activity_id
                        AND tag_id = tag_id_int
                        AND actor_id = p_actor_id
                        AND archived_at IS NULL;
                END IF;
            END IF;
        END LOOP;
END;
$function$;

CREATE TRIGGER set_activity_created_at
    BEFORE INSERT ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

CREATE TRIGGER set_activity_exception_created_at
    BEFORE INSERT ON public.activity_exception
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

CREATE TRIGGER set_activity_exception_updated_at
    BEFORE INSERT OR UPDATE ON public.activity_exception
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_contact_created_at
    BEFORE INSERT ON public.contact
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

CREATE TRIGGER set_cost_created_at
    BEFORE INSERT ON public.cost
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

CREATE TRIGGER set_note_created_at
    BEFORE INSERT ON public.note
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

CREATE TRIGGER set_priority_created_at
    BEFORE INSERT ON public.priority
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

CREATE TRIGGER set_priority_settings_updated_at
    BEFORE INSERT OR UPDATE ON public.priority_settings
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_priority_twist_created_at
    BEFORE INSERT ON public.priority_twist
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

CREATE TRIGGER set_priority_twist_updated_at
    BEFORE INSERT OR UPDATE ON public.priority_twist
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_priority_user_created_at
    BEFORE INSERT ON public.priority_user
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

CREATE TRIGGER set_publisher_created_at
    BEFORE INSERT ON public.publisher
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

CREATE TRIGGER set_series_created_at
    BEFORE INSERT ON public.series
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

CREATE TRIGGER set_session_created_at
    BEFORE INSERT ON public.session
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

CREATE TRIGGER set_token_created_at
    BEFORE INSERT ON public.token
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

CREATE TRIGGER set_twist_created_at
    BEFORE INSERT ON public.twist
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

CREATE TRIGGER set_twist_admin_created_at
    BEFORE INSERT ON public.twist_admin
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

CREATE TRIGGER set_usage_created_at
    BEFORE INSERT ON public.usage
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

CREATE TRIGGER set_user_subscription_created_at
    BEFORE INSERT ON public.user_subscription
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

CREATE TRIGGER set_activity_updated_at
    BEFORE INSERT OR UPDATE ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_activity_read_updated_at
    BEFORE INSERT OR UPDATE ON public.activity_read
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_activity_tag_updated_at
    BEFORE INSERT OR UPDATE ON public.activity_tag
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_contact_updated_at
    BEFORE INSERT OR UPDATE ON public.contact
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_cost_updated_at
    BEFORE INSERT OR UPDATE ON public.cost
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_note_updated_at
    BEFORE INSERT OR UPDATE ON public.note
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_note_tag_updated_at
    BEFORE INSERT OR UPDATE ON public.note_tag
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_priority_updated_at
    BEFORE INSERT OR UPDATE ON public.priority
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_priority_user_updated_at
    BEFORE INSERT OR UPDATE ON public.priority_user
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_publisher_updated_at
    BEFORE INSERT OR UPDATE ON public.publisher
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_series_updated_at
    BEFORE INSERT OR UPDATE ON public.series
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_session_updated_at
    BEFORE INSERT OR UPDATE ON public.session
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_token_updated_at
    BEFORE INSERT OR UPDATE ON public.token
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_twist_updated_at
    BEFORE INSERT OR UPDATE ON public.twist
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_twist_admin_updated_at
    BEFORE INSERT OR UPDATE ON public.twist_admin
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_usage_updated_at
    BEFORE INSERT OR UPDATE ON public.usage
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_user_settings_updated_at
    BEFORE INSERT OR UPDATE ON public.user_settings
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_user_subscription_updated_at
    BEFORE INSERT OR UPDATE ON public.user_subscription
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

DROP FUNCTION IF EXISTS "public"."server_timestamp" ();

ALTER VIEW "public"."user_note" SET (security_invoker = TRUE);

ALTER VIEW "public"."note_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_note_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_twist" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_exception" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_expanded" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_settings_inherited" SET (security_invoker = TRUE);

ALTER VIEW "public"."actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child_twist" SET (security_invoker = TRUE);

