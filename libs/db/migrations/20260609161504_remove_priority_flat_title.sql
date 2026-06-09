-- Drop "priority" view. CASCADE removes "user".upsert_priority, which depends
-- on the view's composite row type (RETURNS "user"."priority" + local row
-- vars). The function is recreated verbatim after the view below; its body is
-- unchanged, so the schema diff stays clean. (Atlas emits a plain DROP because
-- it does not model the function→view-type dependency.)
DROP VIEW "user"."priority" CASCADE;
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
  "icon"
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
    p.icon
   FROM public.priority p
     LEFT JOIN user_root ur ON ur.user_id = p.user_id
     LEFT JOIN direct_settings direct ON direct.user_id = p.user_id AND direct.priority_id = p.id
     LEFT JOIN inherited_settings inh ON inh.user_id = p.user_id AND inh.priority_id = p.id
     LEFT JOIN "user".priority_unread upu ON upu.user_id = p.user_id AND upu.priority_id = p.id;

-- Recreate "user".upsert_priority (dropped by the CASCADE above). Body is
-- identical to 20260609010004 — only the view it returns changed.
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
    -- Flat-client compatibility: clients on the flattened model (apiVersion
    -- >= 4) have no nesting and do not send a path. Keep the existing path on
    -- update; on insert synthesize a child-of-root path so nested (old)
    -- clients can still place the new focus under the user's root. path is
    -- NOT NULL, so this must never leave it null.
    IF _input.path IS NULL THEN
        IF _priority_exists THEN
            _input.path := _old_path;
        ELSE
            DECLARE
                _root_path ltree;
            BEGIN
                SELECT
                    path INTO _root_path
                FROM priority
                WHERE user_id = upsert_priority.user_id AND nlevel(path) = 1
                ORDER BY created_at ASC
                LIMIT 1;
                IF _root_path IS NULL THEN
                    -- No root yet: treat this as the root itself.
                    _input.path := generate_path(NULL);
                ELSE
                    _input.path := _root_path || generate_path(NULL);
                END IF;
            END;
        END IF;
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
        INSERT INTO priority (id, user_id, archived_at, title, color, icon, path, created_by, updated_by, description)
            VALUES (_input.id, upsert_priority.user_id, _input.archived_at, _input.title, CASE WHEN _is_creator THEN
                    _input.color
                ELSE
                    NULL
                END, _input.icon, _input.path, _input.created_by, _input.updated_by, p_priority ->> 'description')
        ON CONFLICT (id)
            DO UPDATE SET
                archived_at = _input.archived_at,
                title = _input.title,
                color = CASE WHEN _is_creator THEN
                    _input.color
                ELSE
                    priority.color
                END,
                -- COALESCE: old (nested) clients don't send icon; preserve the
                -- existing value rather than wiping it on every edit.
                icon = COALESCE(_input.icon, priority.icon),
                updated_by = _input.updated_by,
                -- Present-key semantics: only overwrite description when the
                -- caller actually sent it; preserve it otherwise. facet_filters
                -- is owned by the server-side derivation, never set here.
                description = CASE WHEN p_priority ? 'description'
                    THEN p_priority ->> 'description' ELSE priority.description END
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
            icon = COALESCE(_input.icon, priority.icon),
            updated_by = _input.updated_by
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

-- Data repair: the prior flat projection sent the ancestry breadcrumb
-- ("Plot › Marketing") as `title`. The client stored it and re-sent it on the
-- next save, so upsert_priority baked the breadcrumb into priority.title.
-- Recover the leaf name by stripping everything up to and including the last
-- " › " separator. Updating priority bumps its seq (set_priority_updated_at),
-- so corrected titles propagate to clients via the normal sync cursor.
UPDATE public.priority
SET title = regexp_replace(title, '^.* › ', '')
WHERE title LIKE '% › %';
