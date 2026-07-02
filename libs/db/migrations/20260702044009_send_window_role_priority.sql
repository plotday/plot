-- Modify "priority" table
ALTER TABLE "public"."priority" ADD COLUMN "send_window" jsonb NULL;
-- Modify "role" table
ALTER TABLE "public"."role" ADD COLUMN "send_window" jsonb NULL;
-- Modify "apply_role_change_to_focus" function
CREATE OR REPLACE FUNCTION "public"."apply_role_change_to_focus" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    old_role public.role%ROWTYPE;
    new_role public.role%ROWTYPE;
BEGIN
    IF NEW.role_id IS NOT DISTINCT FROM OLD.role_id THEN
        RETURN NEW;
    END IF;
    IF NEW.role_id IS NULL THEN
        RETURN NEW;  -- focus cleared of its role; nothing to follow
    END IF;
    SELECT * INTO new_role FROM public.role WHERE id = NEW.role_id;
    IF new_role.id IS NULL THEN
        RETURN NEW;  -- dangling role_id; leave the focus's values as-is
    END IF;
    -- old_role is a NULL/zero row when OLD.role_id IS NULL (a focus getting its
    -- first role). Then `NEW.x IS NOT DISTINCT FROM old_role.x` is true only when
    -- NEW.x is NULL, so a value-less focus adopts the new role while a
    -- concrete-valued focus keeps its value as an override — the intended rule.
    SELECT * INTO old_role FROM public.role WHERE id = OLD.role_id;

    -- The Inbox always follows its (new) role.
    IF NEW.is_inbox THEN
        NEW.color := new_role.color;
        NEW.early_notifications_enabled := new_role.early_notifications_enabled;
        NEW.notify_window := new_role.notify_window;
        NEW.see_within := new_role.see_within;
        NEW.send_window := new_role.send_window;
        RETURN NEW;
    END IF;

    IF NEW.color IS NOT DISTINCT FROM old_role.color THEN
        NEW.color := new_role.color;
    END IF;

    IF NEW.early_notifications_enabled IS NOT DISTINCT FROM old_role.early_notifications_enabled
        AND NEW.notify_window IS NOT DISTINCT FROM old_role.notify_window
        AND NEW.see_within IS NOT DISTINCT FROM old_role.see_within THEN
        NEW.early_notifications_enabled := new_role.early_notifications_enabled;
        NEW.notify_window := new_role.notify_window;
        NEW.see_within := new_role.see_within;
    END IF;

    -- send_window follows independently (mirrors propagate_role_to_focuses).
    IF NEW.send_window IS NOT DISTINCT FROM old_role.send_window THEN
        NEW.send_window := new_role.send_window;
    END IF;

    RETURN NEW;
END;
$$;
-- Modify "propagate_role_to_focuses" function
CREATE OR REPLACE FUNCTION "public"."propagate_role_to_focuses" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.color IS DISTINCT FROM OLD.color THEN
        UPDATE priority
        SET color = NEW.color
        WHERE role_id = NEW.id
          AND archived_at IS NULL
          AND (is_inbox OR color IS NOT DISTINCT FROM OLD.color);
    END IF;

    IF NEW.early_notifications_enabled IS DISTINCT FROM OLD.early_notifications_enabled
        OR NEW.notify_window IS DISTINCT FROM OLD.notify_window
        OR NEW.see_within IS DISTINCT FROM OLD.see_within THEN
        UPDATE priority
        SET early_notifications_enabled = NEW.early_notifications_enabled,
            notify_window = NEW.notify_window,
            see_within = NEW.see_within
        WHERE role_id = NEW.id
          AND archived_at IS NULL
          AND (is_inbox OR (
              early_notifications_enabled IS NOT DISTINCT FROM OLD.early_notifications_enabled
              AND notify_window IS NOT DISTINCT FROM OLD.notify_window
              AND see_within IS NOT DISTINCT FROM OLD.see_within));
    END IF;

    -- send_window follows independently of the notification trio, so a focus
    -- that overrode notifications still follows the role's send window (and
    -- vice versa).
    IF NEW.send_window IS DISTINCT FROM OLD.send_window THEN
        UPDATE priority
        SET send_window = NEW.send_window
        WHERE role_id = NEW.id
          AND archived_at IS NULL
          AND (is_inbox OR send_window IS NOT DISTINCT FROM OLD.send_window);
    END IF;

    RETURN NEW;
END;
$$;
-- Modify "upsert_role" function
CREATE OR REPLACE FUNCTION "user"."upsert_role" ("user_id" uuid, "p_role" jsonb) RETURNS uuid LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
-- Resolve ambiguous bare identifiers (e.g. the priority_setting ON CONFLICT
-- target `user_id`, which collides with this function's `user_id` parameter) to
-- the table column, matching upsert_priority.
#variable_conflict use_column
DECLARE
    _role_id uuid := COALESCE((p_role ->> 'id')::uuid, uuidv7 ());
    _exists boolean;
    _archiving boolean := (p_role ? 'archived_at') AND (p_role ->> 'archived_at') IS NOT NULL;
    _root_path ltree;
    _inbox_id uuid;
    _fyi_id uuid;
    -- Sentinel sidebar orders: Inbox then FYI default to the bottom two of the
    -- role; user focuses (now()-epoch-ms order ~1.7e12) sort above them.
    c_inbox_order CONSTANT double precision := 1e15;
    c_fyi_order CONSTANT double precision := 2e15;
BEGIN
    -- SELECT EXISTS always yields a boolean row (never NULL on no-match), unlike
    -- SELECT TRUE INTO which assigns NULL when no row matches.
    SELECT
        EXISTS (
            SELECT 1 FROM public.role r
            WHERE r.id = _role_id
                AND r.user_id = upsert_role.user_id) INTO _exists;

    IF _archiving AND _exists THEN
        -- archive-only-when-empty: the role must have no live focuses other than
        -- its auto-managed Inbox and FYI.
        IF EXISTS (
            SELECT 1 FROM public.priority p
            WHERE p.role_id = _role_id
                AND NOT p.is_inbox
                AND NOT p.is_fyi
                AND p.archived_at IS NULL) THEN
            RAISE EXCEPTION 'role_not_empty' USING ERRCODE = 'check_violation';
        END IF;
        -- never archive the user's last non-archived role.
        IF (
            SELECT count(*) FROM public.role r
            WHERE r.user_id = upsert_role.user_id
                AND r.archived_at IS NULL) <= 1 THEN
            RAISE EXCEPTION 'role_last' USING ERRCODE = 'check_violation';
        END IF;
        UPDATE public.role
        SET archived_at = (p_role ->> 'archived_at')::timestamptz
        WHERE id = _role_id
            AND public.role.user_id = upsert_role.user_id;
        UPDATE public.priority
        SET archived_at = (p_role ->> 'archived_at')::timestamptz
        WHERE role_id = _role_id
            AND (is_inbox OR is_fyi);
        RETURN _role_id;
    END IF;

    INSERT INTO public.role (id, user_id, created_by, name, color, "order",
        early_notifications_enabled, notify_window, see_within, send_window)
        VALUES (_role_id, upsert_role.user_id, upsert_role.user_id,
            COALESCE(p_role ->> 'name', 'Role'),
            COALESCE((p_role ->> 'color')::integer, 0),
            (p_role ->> 'order')::double precision,
            (p_role ->> 'early_notifications_enabled')::boolean,
            CASE WHEN p_role ? 'notify_window' THEN p_role -> 'notify_window' END,
            CASE WHEN p_role ? 'see_within' THEN p_role -> 'see_within' END,
            CASE WHEN p_role ? 'send_window' THEN p_role -> 'send_window' END)
    ON CONFLICT (id)
        DO UPDATE SET
            name = COALESCE(p_role ->> 'name', role.name),
            color = COALESCE((p_role ->> 'color')::integer, role.color),
            "order" = COALESCE((p_role ->> 'order')::double precision, role."order"),
            early_notifications_enabled = CASE WHEN p_role ? 'early_notifications_enabled'
                THEN (p_role ->> 'early_notifications_enabled')::boolean
                ELSE role.early_notifications_enabled END,
            notify_window = CASE WHEN p_role ? 'notify_window'
                THEN p_role -> 'notify_window' ELSE role.notify_window END,
            see_within = CASE WHEN p_role ? 'see_within'
                THEN p_role -> 'see_within' ELSE role.see_within END,
            send_window = CASE WHEN p_role ? 'send_window'
                THEN p_role -> 'send_window' ELSE role.send_window END;

    -- New role -> auto-create its Inbox and FYI focuses.
    IF NOT _exists THEN
        -- Synthesize a child-of-root path (mirrors upsert_priority's flat-client
        -- path synthesis). Both sit directly under the user's root.
        SELECT
            path INTO _root_path
        FROM public.priority
        WHERE public.priority.user_id = upsert_role.user_id
            AND nlevel(path) = 1
        ORDER BY created_at ASC
        LIMIT 1;
        INSERT INTO public.priority (id, user_id, created_by, title, color, is_inbox,
            role_id, early_notifications_enabled, notify_window, see_within,
            send_window, path)
        SELECT
            uuidv7 (), upsert_role.user_id, upsert_role.user_id, 'Inbox', r.color,
            TRUE, r.id, r.early_notifications_enabled, r.notify_window, r.see_within,
            r.send_window,
            CASE WHEN _root_path IS NULL THEN generate_path (NULL)
                ELSE _root_path || generate_path (NULL) END
        FROM public.role r
        WHERE r.id = _role_id
        RETURNING id INTO _inbox_id;
        -- The role's FYI focus: muted (no notifications), fixed newspaper icon,
        -- no key (idx_priority_key_per_root forbids duplicate keys per root; the
        -- FYI is identified by is_fyi).
        INSERT INTO public.priority (id, user_id, created_by, title, color, icon,
            is_fyi, role_id, early_notifications_enabled, path)
        SELECT
            uuidv7 (), upsert_role.user_id, upsert_role.user_id, 'FYI', r.color,
            'newspaper', TRUE, r.id, FALSE,
            CASE WHEN _root_path IS NULL THEN generate_path (NULL)
                ELSE _root_path || generate_path (NULL) END
        FROM public.role r
        WHERE r.id = _role_id
        RETURNING id INTO _fyi_id;
        -- Sentinel sidebar orders so the Inbox then the FYI default to the
        -- bottom two of the role; user focuses (now()-epoch-ms order) sort above.
        INSERT INTO public.priority_setting (user_id, priority_id, key, value)
        VALUES
            (upsert_role.user_id, _inbox_id, 'order', to_jsonb(c_inbox_order)),
            (upsert_role.user_id, _fyi_id, 'order', to_jsonb(c_fyi_order))
        ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
    END IF;

    RETURN _role_id;
END;
$$;
-- Drop "upsert_priority_attention" function
DROP FUNCTION "user"."upsert_priority_attention" (uuid, uuid, boolean, boolean, jsonb, boolean, jsonb, boolean);
-- Create "upsert_priority_attention" function
CREATE FUNCTION "user"."upsert_priority_attention" ("p_user_id" uuid, "p_priority_id" uuid, "p_early_notifications_enabled" boolean DEFAULT NULL::boolean, "p_set_early_notifications_enabled" boolean DEFAULT false, "p_notify_window" jsonb DEFAULT NULL::jsonb, "p_set_notify_window" boolean DEFAULT false, "p_see_within" jsonb DEFAULT NULL::jsonb, "p_set_see_within" boolean DEFAULT false, "p_send_window" jsonb DEFAULT NULL::jsonb, "p_set_send_window" boolean DEFAULT false) RETURNS void LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
BEGIN
    PERFORM "user".assert_priority_access(p_user_id, p_priority_id);

    -- Notifications are concrete columns on priority now (follow-if-matching;
    -- see 95-triggers/30-role-propagation.sql). Old clients send "set + null =
    -- inherit"; there is no inherit anymore, so a null value means "follow the
    -- role" — resolve it to the focus's role's current value via scalar
    -- subqueries (which yield NULL when the focus has no role yet, pre-backfill;
    -- NULL = app default).
    UPDATE public.priority p
    SET early_notifications_enabled = CASE
            WHEN p_set_early_notifications_enabled THEN
                COALESCE(p_early_notifications_enabled,
                    (SELECT r.early_notifications_enabled FROM public.role r WHERE r.id = p.role_id))
            ELSE p.early_notifications_enabled END,
        notify_window = CASE
            WHEN p_set_notify_window THEN
                COALESCE(p_notify_window,
                    (SELECT r.notify_window FROM public.role r WHERE r.id = p.role_id))
            ELSE p.notify_window END,
        see_within = CASE
            WHEN p_set_see_within THEN
                COALESCE(p_see_within,
                    (SELECT r.see_within FROM public.role r WHERE r.id = p.role_id))
            ELSE p.see_within END,
        send_window = CASE
            WHEN p_set_send_window THEN
                COALESCE(p_send_window,
                    (SELECT r.send_window FROM public.role r WHERE r.id = p.role_id))
            ELSE p.send_window END
    WHERE p.id = p_priority_id AND p.user_id = p_user_id;

    -- The UPDATE above fires set_priority_updated_at, bumping priority.seq so
    -- the user view re-emits with the new values.
END;
$$;
-- Modify "role" view
CREATE OR REPLACE VIEW "user"."role" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "archived_at",
  "created_by",
  "name",
  "color",
  "order",
  "early_notifications_enabled",
  "notify_window",
  "see_within",
  "send_window"
) AS SELECT user_id,
    id,
    created_at,
    updated_at,
    seq,
    archived_at,
    created_by,
    name,
    color,
    "order",
    early_notifications_enabled,
    notify_window,
    see_within,
    send_window
   FROM public.role r;
-- Modify "priority" view
CREATE OR REPLACE VIEW "user"."priority" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "archived_at",
  "created_by",
  "updated_by",
  "root",
  "title",
  "path",
  "global_path",
  "top_order",
  "order",
  "pomodoro",
  "color",
  "key",
  "unread",
  "role",
  "respond_schedule_enabled",
  "respond_window",
  "respond_within",
  "early_notifications_enabled",
  "notify_window",
  "see_within",
  "respond_schedule_enabled_set",
  "respond_window_set",
  "respond_within_set",
  "early_notifications_enabled_set",
  "notify_window_set",
  "see_within_set",
  "inherit_members",
  "config",
  "icon",
  "notification_cleared_at",
  "role_id",
  "is_inbox",
  "is_fyi",
  "send_window",
  "send_window_set"
) AS WITH user_root AS (
         SELECT DISTINCT ON (p_1.user_id) p_1.user_id,
            p_1.id AS root_id,
            p_1.path AS root_path
           FROM public.priority p_1
          WHERE public.nlevel(p_1.path) = 1
          ORDER BY p_1.user_id, p_1.created_at
        ), direct_settings AS (
         SELECT priority_setting.user_id,
            priority_setting.priority_id,
            max(
                CASE
                    WHEN priority_setting.key = 'top_order'::text THEN (priority_setting.value #>> '{}'::text[])::double precision
                    ELSE NULL::double precision
                END) AS top_order,
            max(
                CASE
                    WHEN priority_setting.key = 'order'::text THEN (priority_setting.value #>> '{}'::text[])::double precision
                    ELSE NULL::double precision
                END) AS "order",
            max(
                CASE
                    WHEN priority_setting.key = 'title'::text THEN priority_setting.value #>> '{}'::text[]
                    ELSE NULL::text
                END) AS title,
            max(
                CASE
                    WHEN priority_setting.key = 'color'::text THEN (priority_setting.value #>> '{}'::text[])::integer
                    ELSE NULL::integer
                END) AS color,
            max(
                CASE
                    WHEN priority_setting.key = 'respond_schedule_enabled'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS respond_schedule_enabled_set,
            max(
                CASE
                    WHEN priority_setting.key = 'respond_window'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS respond_window_set,
            max(
                CASE
                    WHEN priority_setting.key = 'respond_within'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS respond_within_set,
            max(priority_setting.updated_at) AS updated_at
           FROM public.priority_setting
          GROUP BY priority_setting.user_id, priority_setting.priority_id
        ), inherited_settings AS (
         SELECT priority_setting_inherited.user_id,
            priority_setting_inherited.priority_id,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'pomodoro'::text THEN (priority_setting_inherited.value #>> '{}'::text[])::integer
                    ELSE NULL::integer
                END) AS pomodoro,
            bool_or(
                CASE
                    WHEN priority_setting_inherited.key = 'respond_schedule_enabled'::text THEN (priority_setting_inherited.value #>> '{}'::text[])::boolean
                    ELSE NULL::boolean
                END) AS respond_schedule_enabled,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'respond_window'::text THEN priority_setting_inherited.value::text
                    ELSE NULL::text
                END)::jsonb AS respond_window,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'respond_within'::text THEN priority_setting_inherited.value::text
                    ELSE NULL::text
                END)::jsonb AS respond_within,
            bool_or(
                CASE
                    WHEN priority_setting_inherited.key = 'early_notifications_enabled'::text THEN (priority_setting_inherited.value #>> '{}'::text[])::boolean
                    ELSE NULL::boolean
                END) AS early_notifications_enabled,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'notify_window'::text THEN priority_setting_inherited.value::text
                    ELSE NULL::text
                END)::jsonb AS notify_window,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'see_within'::text THEN priority_setting_inherited.value::text
                    ELSE NULL::text
                END)::jsonb AS see_within,
            max(priority_setting_inherited.updated_at) AS updated_at
           FROM public.priority_setting_inherited
          GROUP BY priority_setting_inherited.user_id, priority_setting_inherited.priority_id
        )
 SELECT p.user_id,
    p.id,
    p.created_at,
    GREATEST(direct.updated_at, p.updated_at, COALESCE(upu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone), inh.updated_at) AS updated_at,
    p.seq,
    p.archived_at,
    p.created_by,
    p.updated_by,
    p.id = ur.root_id AS root,
    COALESCE(direct.title, p.title) AS title,
    p.path,
    p.path AS global_path,
    direct.top_order,
    COALESCE(direct."order", (EXTRACT(epoch FROM p.created_at) * 1000::numeric)::double precision) AS "order",
    inh.pomodoro,
    COALESCE(direct.color, p.color) AS color,
    p.key,
    COALESCE(upu.unread, false) AS unread,
    'member'::text AS role,
    inh.respond_schedule_enabled,
    inh.respond_window,
    inh.respond_within,
    p.early_notifications_enabled,
    p.notify_window,
    p.see_within,
    COALESCE(direct.respond_schedule_enabled_set, false) AS respond_schedule_enabled_set,
    COALESCE(direct.respond_window_set, false) AS respond_window_set,
    COALESCE(direct.respond_within_set, false) AS respond_within_set,
    p.early_notifications_enabled IS NOT NULL AS early_notifications_enabled_set,
    p.notify_window IS NOT NULL AS notify_window_set,
    p.see_within IS NOT NULL AS see_within_set,
    p.inherit_members,
    p.config,
    p.icon,
    p.notification_cleared_at,
    p.role_id,
    p.is_inbox,
    p.is_fyi,
    p.send_window,
    p.send_window IS NOT NULL AS send_window_set
   FROM public.priority p
     LEFT JOIN user_root ur ON ur.user_id = p.user_id
     LEFT JOIN direct_settings direct ON direct.user_id = p.user_id AND direct.priority_id = p.id
     LEFT JOIN inherited_settings inh ON inh.user_id = p.user_id AND inh.priority_id = p.id
     LEFT JOIN "user".priority_unread upu ON upu.user_id = p.user_id AND upu.priority_id = p.id;
