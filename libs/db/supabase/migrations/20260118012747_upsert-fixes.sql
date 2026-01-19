DROP FUNCTION IF EXISTS "public"."get_accessible_twists" (p_priority_id uuid);

DROP FUNCTION IF EXISTS "public"."is_accessible_twist" (p_twist_id bigint, p_priority_id uuid);

DROP FUNCTION IF EXISTS "public"."upsert_activity" (p_activity jsonb, p_occurrences jsonb);

DROP FUNCTION IF EXISTS "public"."upsert_activity" (p_id uuid, p_user_id uuid, p_updated_by integer, p_archived_at timestamp with time zone, p_priority_id uuid, p_draft boolean, p_private boolean, p_at tstzrange, p_on daterange, p_duration interval, p_done_at timestamp with time zone, p_title text, p_preview text, p_assignee_id uuid, p_order double precision, p_recurrence_rule text, p_recurrence_exdates timestamp with time zone[], p_series uuid, p_occurrence_start timestamp with time zone);

DROP VIEW IF EXISTS "public"."user_activity_exception";

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.get_accessible_twists (p_priority_id uuid, p_user_id uuid)
    RETURNS SETOF twist
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    AS $function$
    SELECT DISTINCT
        twist.*
    FROM
        twist
        JOIN twist_admin ON twist.twist_admin_id = twist_admin.id
    WHERE
        twist.environment = 'public'
        OR (twist.environment = 'personal'
            AND twist_admin.user_id = p_user_id)
        OR user_has_priority_access (p_user_id, twist_admin.priority_id)
$function$;

CREATE OR REPLACE FUNCTION public.is_accessible_twist (p_twist_id bigint, p_priority_id uuid, p_user_id uuid)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                twist
                JOIN twist_admin ON twist.twist_admin_id = twist_admin.id
            WHERE
                twist.id = p_twist_id
                AND (twist.environment = 'public'
                    OR (twist.environment = 'personal'
                        AND twist_admin.user_id = p_user_id)
                    OR user_has_priority_access (p_user_id, twist_admin.priority_id)))
$function$;

CREATE OR REPLACE FUNCTION public.upsert_activity (p_activity jsonb, p_defaults jsonb DEFAULT '{}' ::jsonb)
    RETURNS activity
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    v_result activity;
    v_source text;
    v_source_priority_root ltree;
    v_type activity_type;
    -- Variables for derived values
    v_priority_id uuid;
    v_created_by uuid;
    v_created_by_twist_id bigint;
    v_assignee_id uuid;
    -- Array handling
    v_recurrence_exdates timestamptz[];
BEGIN
    -- Extract required fields from JSONB
    v_source := p_activity ->> 'source';
    v_type := COALESCE((p_activity ->> 'type')::activity_type, 'note'::activity_type);
    v_priority_id := (p_activity ->> 'priority_id')::uuid;
    v_created_by := (p_activity ->> 'created_by')::uuid;
    -- DERIVE source_priority_root from priority_id when source exists but root not provided
    IF p_activity ? 'source_priority_root' AND (p_activity ->> 'source_priority_root') IS NOT NULL THEN
        v_source_priority_root := (p_activity ->> 'source_priority_root')::ltree;
    ELSIF v_source IS NOT NULL
            AND v_priority_id IS NOT NULL THEN
            SELECT
                subpath (p.path, 0, 1) INTO v_source_priority_root
            FROM
                priority p
            WHERE
                p.id = v_priority_id;
    END IF;
    -- DERIVE created_by_twist_id from created_by (priority_twist_id)
    IF p_activity ? 'created_by_twist_id' AND (p_activity ->> 'created_by_twist_id') IS NOT NULL THEN
        v_created_by_twist_id := (p_activity ->> 'created_by_twist_id')::bigint;
    ELSIF v_created_by IS NOT NULL THEN
        SELECT
            pt.twist_id INTO v_created_by_twist_id
        FROM
            priority_twist pt
        WHERE
            pt.id = v_created_by;
    END IF;
    -- DERIVE default assignee for actions when assignee_id key is absent
    -- If key exists (even with null value), use the provided value
    -- If key is absent and type is action, derive from priority_twist owner
    IF p_activity ? 'assignee_id' THEN
        v_assignee_id := (p_activity ->> 'assignee_id')::uuid;
    ELSIF v_type = 'action'
            AND v_created_by IS NOT NULL THEN
            v_assignee_id := get_priority_twist_owner_contact (v_created_by);
    ELSE
        v_assignee_id := NULL;
    END IF;
    -- Handle recurrence_exdates array conversion from JSONB
    IF p_activity ? 'recurrence_exdates' AND p_activity -> 'recurrence_exdates' IS NOT NULL THEN
        SELECT
            ARRAY (
                SELECT
                    (jsonb_array_elements_text(p_activity -> 'recurrence_exdates'))::timestamptz) INTO v_recurrence_exdates;
    END IF;
    -- Perform the upsert and return the full row
    INSERT INTO activity (id, author_id, created_by, created_by_twist_id, assignee_id, priority_id, source_created_at, type, title, preview, at, "on", duration, done_at, recurrence_rule, recurrence_exdates, meta, source, updated_by, sync_depth, embedding, pick_priority, private, draft)
        VALUES (COALESCE((p_activity ->> 'id')::uuid, gen_random_uuid_v7 ()),
            (p_activity ->> 'author_id')::uuid, v_created_by, v_created_by_twist_id, v_assignee_id, v_priority_id, COALESCE((p_activity ->> 'source_created_at')::timestamptz, now()), v_type, COALESCE(p_activity ->> 'title', p_defaults ->> 'title'), COALESCE(p_activity ->> 'preview', p_defaults ->> 'preview'), COALESCE((p_activity ->> 'at')::tstzrange, (p_defaults ->> 'at')::tstzrange), COALESCE((p_activity ->> 'on')::daterange, (p_defaults ->> 'on')::daterange),
            (p_activity ->> 'duration')::interval, (p_activity ->> 'done_at')::timestamptz, p_activity ->> 'recurrence_rule', v_recurrence_exdates, p_activity -> 'meta', v_source, COALESCE((p_activity ->> 'updated_by')::integer, 0),
            (p_activity ->> 'sync_depth')::smallint, (p_activity ->> 'embedding')::halfvec, p_activity -> 'pick_priority', COALESCE((p_activity ->> 'private')::boolean, FALSE), COALESCE((p_activity ->> 'draft')::boolean, FALSE))
    ON CONFLICT (source, source_priority_root)
        DO UPDATE SET
            -- Update fields only if key is present in p_activity
            -- Key absent: keep existing value
            -- Key present (even with null): use provided value (allows clearing)
            title = CASE WHEN p_activity ? 'title' THEN
                p_activity ->> 'title'
            ELSE
                activity.title
            END,
            preview = CASE WHEN p_activity ? 'preview' THEN
                p_activity ->> 'preview'
            ELSE
                activity.preview
            END,
            at = CASE WHEN p_activity ? 'at' THEN
                (p_activity ->> 'at')::tstzrange
            ELSE
                activity.at
            END,
            "on" = CASE WHEN p_activity ? 'on' THEN
                (p_activity ->> 'on')::daterange
            ELSE
                activity."on"
            END,
            duration = CASE WHEN p_activity ? 'duration' THEN
                (p_activity ->> 'duration')::interval
            ELSE
                activity.duration
            END,
            done_at = CASE WHEN p_activity ? 'done_at' THEN
                (p_activity ->> 'done_at')::timestamptz
            ELSE
                activity.done_at
            END,
            recurrence_rule = CASE WHEN p_activity ? 'recurrence_rule' THEN
                p_activity ->> 'recurrence_rule'
            ELSE
                activity.recurrence_rule
            END,
            recurrence_exdates = CASE WHEN p_activity ? 'recurrence_exdates' THEN
                v_recurrence_exdates
            ELSE
                activity.recurrence_exdates
            END,
            meta = CASE WHEN p_activity ? 'meta' THEN
                p_activity -> 'meta'
            ELSE
                activity.meta
            END,
            updated_by = CASE WHEN p_activity ? 'updated_by' THEN
                (p_activity ->> 'updated_by')::integer
            ELSE
                activity.updated_by
            END,
            sync_depth = CASE WHEN p_activity ? 'sync_depth' THEN
                (p_activity ->> 'sync_depth')::smallint
            ELSE
                activity.sync_depth
            END,
            type = CASE WHEN p_activity ? 'type' THEN
                (p_activity ->> 'type')::activity_type
            ELSE
                activity.type
            END,
            assignee_id = CASE WHEN p_activity ? 'assignee_id' THEN
                (p_activity ->> 'assignee_id')::uuid
            ELSE
                activity.assignee_id
            END,
            private = CASE WHEN p_activity ? 'private' THEN
                (p_activity ->> 'private')::boolean
            ELSE
                activity.private
            END,
            archived_at = CASE WHEN p_activity ? 'archived_at' THEN
                (p_activity ->> 'archived_at')::timestamptz
            ELSE
                activity.archived_at
            END
        RETURNING
            * INTO v_result;
    RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.redeem_invitation_code (invitation_code text, user_id uuid)
    RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $function$
DECLARE
    _remaining numeric;
BEGIN
    -- Atomically decrement the invitation code's remaining count
    -- Returns NULL if code doesn't exist or has no remaining uses
    UPDATE
        public.invitation
    SET
        remaining = remaining - 1
    WHERE
        code = invitation_code
        AND remaining > 0
    RETURNING
        remaining INTO _remaining;
    -- Check if update was successful
    IF _remaining IS NULL THEN
        -- Either code doesn't exist or has no remaining uses
        RETURN jsonb_build_object('success', FALSE, 'error', 'invalid_or_exhausted');
    END IF;
    RETURN jsonb_build_object('success', TRUE, 'remaining', _remaining);
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_user_status (user_id uuid, status text)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $function$
BEGIN
    -- Atomically update the user's app_metadata with status
    -- This avoids race conditions by doing the read and write in one operation
    UPDATE
        auth.users
    SET
        raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb) || jsonb_build_object('status', status)
    WHERE
        id = user_id;
END;
$function$;

CREATE OR REPLACE VIEW "public"."user_activity_exception" AS
SELECT
    ua.user_id,
    ae.id,
    ae.activity_id,
    COALESCE(ae.archived_at, ua.archived_at) AS archived_at,
    ae.occurrence,
    ae.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    ae.at,
    ae."on",
    ae.title,
    ae.preview
FROM (activity_exception ae
    JOIN user_activity ua ON (ua.id = ae.activity_id));

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

ALTER VIEW "public"."priority_twist_activity_update" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_twist_note_create" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_twist_note_update" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_expanded" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_settings_inherited" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_twist_activity_tag_change" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child_twist" SET (security_invoker = TRUE);

-- Trigger function cannot be called via RPC, but REVOKE for defense-in-depth
REVOKE EXECUTE ON FUNCTION insert_priority_user () FROM PUBLIC;

-- Trigger function cannot be called via RPC, but REVOKE for defense-in-depth
REVOKE EXECUTE ON FUNCTION public.update_activity_on_note_change () FROM PUBLIC;

-- Trigger functions cannot be called via RPC, but REVOKE for defense-in-depth
REVOKE EXECUTE ON FUNCTION public.set_priority_twist_owner_id () FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.prevent_priority_twist_immutable_changes () FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.call_user_sync_api (uuid[]) FROM PUBLIC;

-- Trigger functions cannot be called via RPC, but REVOKE for defense-in-depth
REVOKE EXECUTE ON FUNCTION public.sync_user_for_activity () FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.sync_user_for_note () FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.sync_user_for_priority () FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.sync_user_for_session () FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.sync_user_for_priority_twist () FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.sync_user_for_activity_read () FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.sync_user_for_priority_contact () FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.sync_user_for_activity_tag () FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.sync_user_for_note_tag () FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.sync_user_for_contact () FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION set_user_status (uuid, text) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION redeem_invitation_code (text, uuid) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.call_twist_sync_api (uuid[]) FROM PUBLIC;

-- Trigger functions cannot be called via RPC, but REVOKE for defense-in-depth
REVOKE EXECUTE ON FUNCTION public.sync_twist_for_activity () FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.sync_twist_for_note () FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.sync_twist_for_activity_tag () FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.sync_twist_for_note_tag () FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.sync_user_on_connect (uuid) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.get_stale_user_syncs (timestamp with time zone, integer) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.get_stale_twist_syncs (timestamp with time zone, integer) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.get_priority_twist_owner_contact (uuid) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.get_pending_user_sync (uuid) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.mark_user_sync_complete (uuid) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.upsert_activity (jsonb, jsonb) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.get_primary_contact_id (uuid) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.get_accessible_twists (uuid, uuid) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.is_accessible_twist (bigint, uuid, uuid) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.get_users_with_priority_access (uuid) FROM PUBLIC;

REVOKE UPDATE ON TABLE public.activity_tag FROM authenticated;

REVOKE UPDATE ON TABLE public.note_tag FROM authenticated;

-- Trigger function cannot be called via RPC, but REVOKE for defense-in-depth
REVOKE EXECUTE ON FUNCTION public.insert_email_domain () FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.upsert_user_contact (uuid, text, text, text) FROM PUBLIC;

-- Trigger function cannot be called via RPC, but REVOKE for defense-in-depth
REVOKE EXECUTE ON FUNCTION public.sync_user_contact_trigger () FROM PUBLIC;

-- Trigger functions cannot be called via RPC, but REVOKE for defense-in-depth
REVOKE EXECUTE ON FUNCTION public.sync_priority_contact_on_insert () FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.sync_priority_contact_on_update () FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.sync_priority_contact_on_delete () FROM PUBLIC;

