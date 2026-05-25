-- Hand-edited ordering: atlas put the CREATE OR REPLACE for user.upsert_priority
-- at the top, but the DROP VIEW "user"."priority" below fails because
-- upsert_priority depends on the view's row type. The DROP is changed to
-- CASCADE (which transitively drops upsert_priority), and upsert_priority is
-- recreated at the bottom of this migration once the new view exists.
-- Create "upsert_priority_attention" function
CREATE FUNCTION "user"."upsert_priority_attention" ("p_user_id" uuid, "p_priority_id" uuid, "p_respond_schedule_enabled" boolean DEFAULT NULL::boolean, "p_set_respond_schedule_enabled" boolean DEFAULT false, "p_respond_window" jsonb DEFAULT NULL::jsonb, "p_set_respond_window" boolean DEFAULT false, "p_respond_within" jsonb DEFAULT NULL::jsonb, "p_set_respond_within" boolean DEFAULT false, "p_early_notifications_enabled" boolean DEFAULT NULL::boolean, "p_set_early_notifications_enabled" boolean DEFAULT false, "p_notify_window" jsonb DEFAULT NULL::jsonb, "p_set_notify_window" boolean DEFAULT false, "p_see_within" jsonb DEFAULT NULL::jsonb, "p_set_see_within" boolean DEFAULT false) RETURNS void LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
BEGIN
    PERFORM "user".assert_priority_access(p_user_id, p_priority_id);

    IF p_set_respond_schedule_enabled THEN
        IF p_respond_schedule_enabled IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (p_user_id, p_priority_id, 'respond_schedule_enabled', to_jsonb(p_respond_schedule_enabled))
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE priority_setting.user_id = p_user_id
              AND priority_setting.priority_id = p_priority_id AND key = 'respond_schedule_enabled';
        END IF;
    END IF;

    IF p_set_respond_window THEN
        IF p_respond_window IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (p_user_id, p_priority_id, 'respond_window', p_respond_window)
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE priority_setting.user_id = p_user_id
              AND priority_setting.priority_id = p_priority_id AND key = 'respond_window';
        END IF;
    END IF;

    IF p_set_respond_within THEN
        IF p_respond_within IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (p_user_id, p_priority_id, 'respond_within', p_respond_within)
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE priority_setting.user_id = p_user_id
              AND priority_setting.priority_id = p_priority_id AND key = 'respond_within';
        END IF;
    END IF;

    IF p_set_early_notifications_enabled THEN
        IF p_early_notifications_enabled IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (p_user_id, p_priority_id, 'early_notifications_enabled', to_jsonb(p_early_notifications_enabled))
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE priority_setting.user_id = p_user_id
              AND priority_setting.priority_id = p_priority_id AND key = 'early_notifications_enabled';
        END IF;
    END IF;

    IF p_set_notify_window THEN
        IF p_notify_window IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (p_user_id, p_priority_id, 'notify_window', p_notify_window)
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE priority_setting.user_id = p_user_id
              AND priority_setting.priority_id = p_priority_id AND key = 'notify_window';
        END IF;
    END IF;

    IF p_set_see_within THEN
        IF p_see_within IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (p_user_id, p_priority_id, 'see_within', p_see_within)
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE priority_setting.user_id = p_user_id
              AND priority_setting.priority_id = p_priority_id AND key = 'see_within';
        END IF;
    END IF;

    -- Bump the priority's seq so the user view re-emits with the new
    -- inherited values (the seq protocol is driven off priority.updated_at).
    UPDATE priority SET updated_at = now() WHERE id = p_priority_id;
END;
$$;
-- Drop "priority" view (CASCADE: also drops upsert_priority, which depends
-- on the view's row type and is recreated at the bottom of this migration).
DROP VIEW "user"."priority" CASCADE;
-- Modify "priority_setting_inherited" view
CREATE OR REPLACE VIEW "public"."priority_setting_inherited" (
  "user_id",
  "priority_id",
  "key",
  "value",
  "source_path",
  "updated_at"
) AS WITH all_sources AS (
         SELECT ps.user_id,
            p.id AS priority_id,
            ps.key,
            ps.value,
            parent.path AS source_path,
            ps.updated_at,
            public.nlevel(p.path) - public.nlevel(parent.path) AS distance,
            0 AS source_type
           FROM public.priority_setting ps
             JOIN public.priority parent ON ps.priority_id = parent.id
             JOIN public.priority p ON p.path OPERATOR(public.<@) parent.path AND p.user_id = parent.user_id
          WHERE ps.key = ANY (ARRAY['pomodoro'::text, 'color'::text, 'respond_schedule_enabled'::text, 'respond_window'::text, 'respond_within'::text, 'early_notifications_enabled'::text, 'notify_window'::text, 'see_within'::text])
        UNION ALL
         SELECT p.user_id,
            p.id AS priority_id,
            'color'::text AS key,
            to_jsonb(parent.color) AS value,
            parent.path AS source_path,
            parent.updated_at,
            public.nlevel(p.path) - public.nlevel(parent.path) AS distance,
            1 AS source_type
           FROM public.priority p
             JOIN public.priority parent ON p.path OPERATOR(public.<@) parent.path AND parent.user_id = p.user_id
          WHERE parent.color IS NOT NULL
        )
 SELECT DISTINCT ON (user_id, priority_id, key) user_id,
    priority_id,
    key,
    value,
    source_path,
    updated_at
   FROM all_sources
  ORDER BY user_id, priority_id, key, distance, source_type;
-- Create "priority" view
CREATE VIEW "user"."priority" (
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
  "default_contacts",
  "default_groups",
  "default_invite_emails"
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
            max(
                CASE
                    WHEN priority_setting.key = 'early_notifications_enabled'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS early_notifications_enabled_set,
            max(
                CASE
                    WHEN priority_setting.key = 'notify_window'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS notify_window_set,
            max(
                CASE
                    WHEN priority_setting.key = 'see_within'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS see_within_set,
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
    inh.early_notifications_enabled,
    inh.notify_window,
    inh.see_within,
    COALESCE(direct.respond_schedule_enabled_set, false) AS respond_schedule_enabled_set,
    COALESCE(direct.respond_window_set, false) AS respond_window_set,
    COALESCE(direct.respond_within_set, false) AS respond_within_set,
    COALESCE(direct.early_notifications_enabled_set, false) AS early_notifications_enabled_set,
    COALESCE(direct.notify_window_set, false) AS notify_window_set,
    COALESCE(direct.see_within_set, false) AS see_within_set,
    p.inherit_members,
    p.config,
    p.default_contacts,
    p.default_groups,
    p.default_invite_emails
   FROM public.priority p
     LEFT JOIN user_root ur ON ur.user_id = p.user_id
     LEFT JOIN direct_settings direct ON direct.user_id = p.user_id AND direct.priority_id = p.id
     LEFT JOIN inherited_settings inh ON inh.user_id = p.user_id AND inh.priority_id = p.id
     LEFT JOIN "user".priority_unread upu ON upu.user_id = p.user_id AND upu.priority_id = p.id;
-- Drop "upsert_priority_attention" function
DROP FUNCTION "user"."upsert_priority_attention" (uuid, uuid, jsonb, boolean, jsonb, boolean);

-- ------------------------------------------------------------------
-- Data migration: response-times rework
-- ------------------------------------------------------------------
-- Drop the legacy 'attention_window' (quiet hours) key. The rework replaces
-- it with the inverted 'notify_window' (active hours) — different semantics,
-- so no automatic backfill; existing overrides are dropped and users fall
-- back to the new root default. priority_setting is read by the
-- user.priority view but is not itself a synced sync-cursor table; the
-- priority.updated_at bump below republishes the affected rows.
DELETE FROM priority_setting WHERE key = 'attention_window';

-- Seed the five new keys onto each user's root priority so existing users
-- get the same defaults that account.ts seeds for new users. ON CONFLICT
-- DO NOTHING preserves any rows that already exist (e.g. if a future
-- migration ran in a partial state).
INSERT INTO priority_setting (user_id, priority_id, key, value)
SELECT
    p.user_id,
    p.id,
    key_value.key,
    key_value.value
FROM priority p
CROSS JOIN LATERAL (
    VALUES
        ('respond_schedule_enabled'::text, 'true'::jsonb),
        ('respond_window', '[{"days":[1,2,3,4,5],"start":"09:00","end":"17:00"}]'::jsonb),
        ('respond_within', '{"value":4,"unit":"hours"}'::jsonb),
        ('early_notifications_enabled', 'true'::jsonb),
        ('notify_window', '[{"days":[1,2,3,4,5,6,7],"start":"08:00","end":"20:00"}]'::jsonb),
        -- see_within may or may not already exist (depending on whether the
        -- prior migration's see_within_requests rename had source rows to
        -- carry forward). Seed it for any root that's still missing it.
        ('see_within', '{"value":30,"unit":"minutes"}'::jsonb)
) AS key_value(key, value)
WHERE nlevel(p.path) = 1
ON CONFLICT (user_id, priority_id, key) DO NOTHING;

-- Schema added new columns to user.priority (the inherited respond_* /
-- notify_window keys plus the *_set flags). Existing priority rows have
-- stale seq values so clients on a stamped horizon would never re-pull
-- and never pick up the new columns. Bump every priority's updated_at
-- once to force the seq trigger to fire.
UPDATE priority SET updated_at = now();

-- Recreate user.upsert_priority after the view exists. CASCADE on the view
-- drop above removed it; the function definition itself is unchanged.
CREATE OR REPLACE FUNCTION "user"."upsert_priority" ("user_id" uuid, "p_priority" jsonb) RETURNS "user"."priority" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
#variable_conflict use_column
DECLARE
    _input "user"."priority";
    _old "user"."priority";
    v_row "user"."priority";
    _priority_id uuid;
    _is_creator boolean;
    _priority_default_color integer;
    _is_move boolean;
    _priority_exists boolean;
    _old_path ltree;
BEGIN
    -- Extract input fields from JSONB into the view's row type
    _input := jsonb_populate_record(NULL::"user"."priority", p_priority || jsonb_build_object('user_id', upsert_priority.user_id));
    _is_creator := (_input.created_by = upsert_priority.user_id);
    -- Check if priority already exists (to distinguish INSERT from UPDATE)
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                priority
            WHERE
                id = _input.id) INTO _priority_exists;
    -- Viewer enforcement: viewers cannot create new priorities
    -- For existing priorities, allow through (only priority_settings changes like reordering)
    IF NOT _priority_exists AND nlevel(_input.path) > 1 THEN
        DECLARE
            _parent_priority_id uuid;
            _parent_path ltree;
        BEGIN
            _parent_path := subpath(_input.path, 0, nlevel(_input.path) - 1);
            SELECT up.id INTO _parent_priority_id
            FROM "user".priority up
            WHERE up.user_id = upsert_priority.user_id AND up.path = _parent_path
            LIMIT 1;
            IF _parent_priority_id IS NOT NULL AND "user".get_effective_role(upsert_priority.user_id, _parent_priority_id) = 'viewer' THEN
                RAISE EXCEPTION 'Viewer members cannot create priorities';
            END IF;
        END;
    END IF;
    -- Look up existing row from view if it exists (replaces OLD trigger variable)
    IF _priority_exists THEN
        SELECT
            * INTO _old
        FROM
            "user".priority up
        WHERE
            up.user_id = upsert_priority.user_id
            AND up.id = _input.id;
        _old_path := _old.path;
    END IF;
    -- Detect if this is a move (path changed on existing priority)
    _is_move := (_priority_exists
        AND _input.path IS DISTINCT FROM _old_path);
    IF _is_move THEN
        -- Prevent circular reference
        IF _input.path <@ _old_path OR _input.path = _old_path THEN
            RAISE EXCEPTION 'Cannot move priority to be a descendant of itself'
                USING HINT = 'old_path=' || _old_path::text || ', new_path=' || _input.path::text;
        END IF;
        -- In the per-user model every priority belongs to a single user's
        -- tree, so every move is a straight ltree relocation.
        DECLARE
            _parent_path ltree;
        BEGIN
            IF nlevel(_input.path) > 1 THEN
                _parent_path := subpath(_input.path, 0, nlevel(_input.path) - 1);
            ELSE
                _parent_path := NULL;
            END IF;
            PERFORM move_priority (_input.id, _parent_path);
        END;
    END IF;
    -- Get the priority's default color for initializing new priority_settings
    SELECT
        color INTO _priority_default_color
    FROM
        priority
    WHERE
        id = _input.id;
    -- Update priority table
    IF NOT _is_move THEN
        INSERT INTO priority (id, user_id, archived_at, title, color, path, created_by, updated_by,
            default_contacts, default_groups, default_invite_emails)
            VALUES (_input.id, upsert_priority.user_id, _input.archived_at, _input.title, CASE WHEN _is_creator THEN
                    _input.color
                ELSE
                    NULL
                END, _input.path, _input.created_by, _input.updated_by,
                COALESCE(_input.default_contacts, '{}'::uuid[]),
                COALESCE(_input.default_groups, '{}'::uuid[]),
                COALESCE(_input.default_invite_emails, '{}'::text[]))
        ON CONFLICT (id)
            DO UPDATE SET
                archived_at = _input.archived_at,
                title = _input.title,
                color = CASE WHEN _is_creator THEN
                    _input.color
                ELSE
                    priority.color
                END,
                updated_by = _input.updated_by,
                default_contacts = COALESCE(_input.default_contacts, priority.default_contacts),
                default_groups = COALESCE(_input.default_groups, priority.default_groups),
                default_invite_emails = COALESCE(_input.default_invite_emails, priority.default_invite_emails)
            RETURNING
                id INTO _priority_id;
    ELSE
        -- For moves, just update non-path fields (path was already updated by move_priority)
        UPDATE
            priority
        SET
            archived_at = _input.archived_at,
            title = _input.title,
            color = CASE WHEN _is_creator THEN
                _input.color
            ELSE
                priority.color
            END,
            updated_by = _input.updated_by,
            default_contacts = COALESCE(_input.default_contacts, priority.default_contacts),
            default_groups = COALESCE(_input.default_groups, priority.default_groups),
            default_invite_emails = COALESCE(_input.default_invite_emails, priority.default_invite_emails)
        WHERE
            id = _input.id
        RETURNING
            id INTO _priority_id;
    END IF;
    -- Always upsert top_order, order, pomodoro, color if provided
    IF NOT _is_move THEN
        IF _input.top_order IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (upsert_priority.user_id, _priority_id, 'top_order', to_jsonb(_input.top_order))
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE user_id = upsert_priority.user_id AND priority_id = _priority_id AND key = 'top_order';
        END IF;
        IF _input."order" IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (upsert_priority.user_id, _priority_id, 'order', to_jsonb(_input."order"))
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        END IF;
        IF _input.pomodoro IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (upsert_priority.user_id, _priority_id, 'pomodoro', to_jsonb(_input.pomodoro))
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE user_id = upsert_priority.user_id AND priority_id = _priority_id AND key = 'pomodoro';
        END IF;
        IF _input.color IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (upsert_priority.user_id, _priority_id, 'color', to_jsonb(COALESCE(_input.color, _priority_default_color)))
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE user_id = upsert_priority.user_id AND priority_id = _priority_id AND key = 'color';
        END IF;
    END IF;
    -- Return the updated row from the view
    SELECT
        * INTO v_row
    FROM
        "user".priority up
    WHERE
        up.user_id = upsert_priority.user_id
        AND up.id = _input.id;
    RETURN v_row;
END;
$$;
