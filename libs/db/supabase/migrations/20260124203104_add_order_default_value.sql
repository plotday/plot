DROP TRIGGER IF EXISTS "upsert_user_priority" ON "public"."user_priority";

DROP VIEW IF EXISTS "public"."user_priority";

DROP VIEW IF EXISTS "public"."priority_settings_inherited";

ALTER TABLE "public"."priority_settings"
    ALTER COLUMN "order" SET DEFAULT (EXTRACT(epoch FROM now()) * (1000)::numeric);

-- Populate order for existing priorities based on created_at
UPDATE priority_settings
SET "order" = EXTRACT(epoch FROM p.created_at) * 1000
FROM priority p
WHERE priority_settings.priority_id = p.id
  AND priority_settings."order" IS NULL;

SET check_function_bodies = OFF;

CREATE OR REPLACE VIEW "public"."priority_settings_inherited" AS
WITH inherited_sources AS (
    SELECT
        ps.user_id,
        p.id AS priority_id,
        (nlevel (p.path) - nlevel (parent.path)) AS distance,
        0 AS source_type,
        CASE WHEN ((nlevel (p.path) > nlevel (parent.path))
            AND (subpath (p.path, nlevel (parent.path)) <> ''::ltree)) THEN
            (ps.path || subpath (p.path, nlevel (parent.path)))
        ELSE
            ps.path
        END AS path,
        ps.pomodoro,
        ps.color
    FROM ((priority_settings ps
            JOIN priority parent ON (ps.priority_id = parent.id))
        JOIN priority p ON (p.path <@ parent.path))
    WHERE ((ps.path IS NOT NULL)
        OR (ps.pomodoro IS NOT NULL)
        OR (ps.color IS NOT NULL))
UNION ALL
SELECT
    pu.user_id,
    p.id AS priority_id,
    (nlevel (p.path) - nlevel (parent.path)) AS distance,
    1 AS source_type,
    NULL::ltree AS path,
    NULL::integer AS pomodoro,
    parent.color
FROM (((priority_user pu
            JOIN priority root ON (pu.priority_id = root.id))
        JOIN priority p ON (p.path <@ root.path))
    JOIN priority parent ON (p.path <@ parent.path))
WHERE (parent.color IS NOT NULL))
SELECT DISTINCT ON (user_id, priority_id)
    user_id,
    priority_id,
    path,
    pomodoro,
    color
FROM
    inherited_sources
ORDER BY
    user_id,
    priority_id,
    distance,
    source_type;

CREATE OR REPLACE FUNCTION public.sync_user_for_priority_contact ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_users_to_notify_actor uuid[] := '{}';
    v_users_to_notify_member uuid[] := '{}';
    v_user_id uuid;
    v_prev_update_at timestamptz;
    v_prev_sync_at timestamptz;
    v_current_sync_at timestamptz;
BEGIN
    -- priority_contact doesn't have updated_at, use created_at or archived_at
    SELECT
        MAX(GREATEST (created_at, COALESCE(archived_at, created_at))) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users with access to the priority (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN user_priority_expanded upe ON upe.priority_id = n.priority_id
    WHERE
        upe.archived_at IS NULL LOOP
            -- Handle actor entity (priority_contact contributes to actor view)
            SELECT
                last_update_at,
                last_sync_at INTO v_prev_update_at,
                v_prev_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'actor';
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'actor', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
            SELECT
                last_sync_at INTO v_current_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'actor';
            IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at) THEN
                v_users_to_notify_actor := array_append(v_users_to_notify_actor, v_user_id);
            END IF;
            -- Handle priority_member entity only for actual invitations (invited_by IS NOT NULL)
            IF EXISTS (
                SELECT
                    1
                FROM
                    new_table n2
                WHERE
                    n2.invited_by IS NOT NULL) THEN
            SELECT
                last_update_at,
                last_sync_at INTO v_prev_update_at,
                v_prev_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'priority_member';
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'priority_member', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
            SELECT
                last_sync_at INTO v_current_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'priority_member';
            IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at) THEN
                v_users_to_notify_member := array_append(v_users_to_notify_member, v_user_id);
            END IF;
        END IF;
END LOOP;
    IF array_length(v_users_to_notify_actor, 1) > 0 THEN
        PERFORM
            call_user_sync_api (v_users_to_notify_actor);
    END IF;
    IF array_length(v_users_to_notify_member, 1) > 0 THEN
        PERFORM
            call_user_sync_api (v_users_to_notify_member);
    END IF;
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE VIEW "public"."user_priority" AS
SELECT
    pu.user_id,
    p.id,
    p.created_at,
    GREATEST (settings.updated_at, pu.updated_at, p.updated_at, COALESCE(upu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    GREATEST (pu.archived_at, p.archived_at) AS archived_at,
    p.created_by,
    p.updated_by,
    ((pu.personal = TRUE)
    AND (p.id = root.id)) AS root,
    p.title,
    CASE WHEN (inherited_settings.path IS NOT NULL) THEN
        inherited_settings.path
    WHEN (user_root.path @> p.path) THEN
        p.path
    ELSE
        (user_root.path || p.path)
    END AS path,
    settings.top_order,
    settings."order",
    inherited_settings.pomodoro,
    inherited_settings.color,
    COALESCE(upu.unread, FALSE) AS unread
FROM (((((((priority_user pu
                            JOIN priority root ON (pu.priority_id = root.id))
                        JOIN priority_user pu_root ON (((pu.user_id = pu_root.user_id)
                                    AND (pu_root.personal = TRUE))))
                    JOIN priority user_root ON (pu_root.priority_id = user_root.id))
                JOIN priority p ON (root.path @> p.path))
            LEFT JOIN priority_settings settings ON (((settings.user_id = pu.user_id)
                        AND (p.id = settings.priority_id))))
        LEFT JOIN priority_settings_inherited inherited_settings ON (((inherited_settings.user_id = pu.user_id)
                    AND (p.id = inherited_settings.priority_id))))
    LEFT JOIN user_priority_unread upu ON (((upu.user_id = pu.user_id)
                AND (upu.priority_id = p.id))))
WHERE (pu.archived_at IS NULL);

CREATE TRIGGER upsert_user_priority
    INSTEAD OF INSERT OR UPDATE ON public.user_priority
    FOR EACH ROW
    EXECUTE FUNCTION handle_user_priority_upsert ();

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
ALTER VIEW "public"."priority_twist_activity_update" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_note_create" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_activity_create" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_note_update" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_expanded" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_activity_tag_change" SET ( security_invoker = TRUE);
ALTER VIEW public.priority_member SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);
