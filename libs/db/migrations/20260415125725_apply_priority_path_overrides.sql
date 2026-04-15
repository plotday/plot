-- Apply priority_setting path overrides to the actual priority.path column.
-- Now that priorities are per-user, paths should live on priority.path directly
-- rather than as per-user override settings.
--
-- The single_root_priorities migration created path overrides in priority_setting
-- for all root-level priorities (to consolidate under a single root), but only
-- applied them to actual priority.path for @plot.app and @plot.twist-dev.
-- This migration completes that work for all remaining overrides.

-- Step 1: Temporarily drop the root validation trigger.
-- Multiple roots legitimately co-exist during this migration (they're being moved),
-- so the trigger would spuriously block some updates.
DROP TRIGGER IF EXISTS validate_priority_root_trigger ON public.priority;

-- Step 2: Apply same-user path overrides.
-- The priority is owned by the same user who has the path setting.
-- We move the priority itself AND all its user-owned descendants.
DO $$
DECLARE
    v_override RECORD;
    v_current_path ltree;
    v_new_path ltree;
BEGIN
    FOR v_override IN
        SELECT
            ps.user_id,
            ps.priority_id,
            (ps.value #>> '{}')::ltree AS new_path
        FROM priority_setting ps
        JOIN priority p ON p.id = ps.priority_id AND p.user_id = ps.user_id
        WHERE ps.key = 'path'
          AND (ps.value #>> '{}')::ltree != p.path
        ORDER BY nlevel(p.path) ASC  -- shallowest first (process parents before children)
    LOOP
        v_new_path := v_override.new_path;

        -- Re-read current path inside the loop, because a parent override processed
        -- earlier in this loop may have already moved this priority.
        SELECT path INTO v_current_path
        FROM priority WHERE id = v_override.priority_id;

        -- Move descendants first (while they're still under v_current_path).
        UPDATE priority
        SET path = v_new_path || subpath(path, nlevel(v_current_path))
        WHERE user_id = v_override.user_id
          AND path <@ v_current_path
          AND id != v_override.priority_id;

        -- Move the priority itself.
        UPDATE priority
        SET path = v_new_path
        WHERE id = v_override.priority_id;

        -- Remove the override now that it's been applied.
        DELETE FROM priority_setting
        WHERE user_id = v_override.user_id
          AND priority_id = v_override.priority_id
          AND key = 'path';
    END LOOP;
END;
$$;

-- Step 3: Apply cross-user path overrides.
-- The priority is owned by a different user (e.g., a team-shared priority now
-- owned by the team admin). The setting user needs their own personal priority
-- row at the override path, and their thread_priority entries updated to point to it.
DO $$
DECLARE
    v_override RECORD;
    v_new_priority_id uuid;
    v_child RECORD;
    v_child_new_path ltree;
    v_child_new_priority_id uuid;
BEGIN
    FOR v_override IN
        SELECT
            ps.user_id AS setting_user_id,
            ps.priority_id AS source_priority_id,
            p.path AS source_path,
            p.title AS source_title,
            (ps.value #>> '{}')::ltree AS new_path
        FROM priority_setting ps
        JOIN priority p ON p.id = ps.priority_id AND p.user_id != ps.user_id
        WHERE ps.key = 'path'
          AND (ps.value #>> '{}')::ltree != p.path
        ORDER BY nlevel(p.path) ASC
    LOOP
        -- Check if a priority already exists for the setting user at the target path.
        SELECT id INTO v_new_priority_id
        FROM priority
        WHERE user_id = v_override.setting_user_id
          AND path = v_override.new_path;

        IF v_new_priority_id IS NULL THEN
            -- Create a personal priority for the setting user at the target path.
            INSERT INTO priority (
                id, user_id, created_by, updated_by, title, path, created_at, updated_at
            )
            SELECT
                gen_random_uuid(),
                v_override.setting_user_id,
                v_override.setting_user_id,
                0,
                p.title,
                v_override.new_path,
                now(),
                now()
            FROM priority p
            WHERE p.id = v_override.source_priority_id
            RETURNING id INTO v_new_priority_id;
        END IF;

        -- Redirect the setting user's thread_priority entries that currently point
        -- to the source priority over to the new personal priority.
        UPDATE thread_priority
        SET priority_id = v_new_priority_id
        WHERE user_id = v_override.setting_user_id
          AND priority_id = v_override.source_priority_id;

        -- Handle descendant priorities of the source where the setting user has threads.
        -- Create corresponding personal priorities under the new parent and redirect.
        FOR v_child IN
            SELECT DISTINCT
                src_child.id   AS child_source_id,
                src_child.path AS child_source_path,
                src_child.title AS child_title,
                nlevel(src_child.path) AS child_level
            FROM thread_priority tp
            JOIN priority src_child ON src_child.id = tp.priority_id
            WHERE tp.user_id = v_override.setting_user_id
              AND src_child.path <@ v_override.source_path
              AND src_child.id != v_override.source_priority_id
            ORDER BY nlevel(src_child.path) ASC
        LOOP
            -- Compute the new path: replace source prefix with new parent path.
            v_child_new_path := v_override.new_path
                || subpath(v_child.child_source_path, nlevel(v_override.source_path));

            SELECT id INTO v_child_new_priority_id
            FROM priority
            WHERE user_id = v_override.setting_user_id
              AND path = v_child_new_path;

            IF v_child_new_priority_id IS NULL THEN
                INSERT INTO priority (
                    id, user_id, created_by, updated_by, title, path, created_at, updated_at
                )
                VALUES (
                    gen_random_uuid(),
                    v_override.setting_user_id,
                    v_override.setting_user_id,
                    0,
                    v_child.child_title,
                    v_child_new_path,
                    now(),
                    now()
                )
                RETURNING id INTO v_child_new_priority_id;
            END IF;

            UPDATE thread_priority
            SET priority_id = v_child_new_priority_id
            WHERE user_id = v_override.setting_user_id
              AND priority_id = v_child.child_source_id;
        END LOOP;

        -- Remove the cross-user override.
        DELETE FROM priority_setting
        WHERE user_id = v_override.setting_user_id
          AND priority_id = v_override.source_priority_id
          AND key = 'path';
    END LOOP;
END;
$$;

-- Step 4: Recreate the root validation trigger.
-- By this point every user should have exactly one root priority.
CREATE TRIGGER validate_priority_root_trigger
    BEFORE INSERT OR UPDATE OF path, user_id ON public.priority
    FOR EACH ROW
    EXECUTE FUNCTION public.validate_priority_root ();

-- Step 5: Update functions and recreate user.priority view with simplified path logic.
-- Path overrides have all been baked into priority.path directly, so the CASE
-- expression reading from priority_setting_inherited is no longer needed.
-- Modify "activate_invited_user" function
CREATE OR REPLACE FUNCTION "public"."activate_invited_user" ("p_user_id" uuid) RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_root_priority_id uuid;
    v_new_path ltree;
BEGIN
    -- Already has a root priority?
    SELECT id INTO v_root_priority_id
    FROM public.priority
    WHERE user_id = p_user_id
      AND nlevel(path) = 1
    ORDER BY created_at ASC
    LIMIT 1;

    IF v_root_priority_id IS NOT NULL THEN
        RETURN jsonb_build_object('activated', FALSE, 'already_active', TRUE, 'root_priority_id', v_root_priority_id);
    END IF;

    -- Create the root priority. default_priority_user_id fills user_id
    -- from created_by, so the new row is fully owned by the user.
    v_new_path := generate_path(NULL);
    INSERT INTO public.priority (created_by, user_id, title, path, color)
        VALUES (p_user_id, p_user_id, 'Everything', v_new_path, 0)
    RETURNING id INTO v_root_priority_id;

    -- Create Using Plot (@plot.app)
    INSERT INTO public.priority (created_by, user_id, title, path, color, key, default_thread_icon)
    VALUES (p_user_id, p_user_id, 'Using Plot', v_new_path || generate_path(NULL), 7, '@plot.app', 'https://plot.day/assets/plot-icon.svg');

    -- Add priority rules for auto-filing
    -- 1. Everyone topic -> Using Plot
    INSERT INTO public.priority_rule (user_id, priority_id, type, criteria)
    SELECT p_user_id, p.id, 'contact_topics', jsonb_build_object('topics', ARRAY[t.id::text])
    FROM public.priority p
    CROSS JOIN public.topic t
    WHERE p.user_id = p_user_id AND p.key = '@plot.app'
      AND t.auto_maintained = TRUE AND t.team_id IS NULL AND t.name = 'Everyone';

    -- 2. User topic -> Using Plot
    INSERT INTO public.priority_rule (user_id, priority_id, type, criteria)
    SELECT p_user_id, p.id, 'contact_topics', jsonb_build_object('topics', ARRAY[t.id::text])
    FROM public.priority p
    CROSS JOIN public.topic t
    WHERE p.user_id = p_user_id AND p.key = '@plot.app'
      AND t.auto_user_id = p_user_id;

    -- 3. Team admin topics -> Using Plot
    INSERT INTO public.priority_rule (user_id, priority_id, type, criteria)
    SELECT p_user_id, p.id, 'contact_topics', jsonb_build_object('topics', ARRAY[t.id::text])
    FROM public.priority p
    CROSS JOIN public.topic t
    JOIN public.team_user tu ON tu.team_id = t.auto_team_admin_team_id AND tu.user_id = p_user_id
    WHERE p.user_id = p_user_id AND p.key = '@plot.app'
      AND t.auto_team_admin_team_id IS NOT NULL;

    RETURN jsonb_build_object('activated', TRUE, 'already_active', FALSE, 'root_priority_id', v_root_priority_id);
END;
$$;
-- Modify "validate_priority_root" function
CREATE OR REPLACE FUNCTION "public"."validate_priority_root" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_root_path ltree;
BEGIN
    -- Ensure each user has only one root priority (nlevel=1)
    IF nlevel(NEW.path) = 1 THEN
        IF EXISTS (
            SELECT 1 FROM priority
            WHERE user_id = NEW.user_id AND nlevel(path) = 1 AND id != NEW.id
        ) THEN
            RAISE EXCEPTION 'User already has a root priority';
        END IF;
    ELSE
        -- Ensure all other priorities are descendants of the root
        SELECT path INTO v_root_path
        FROM priority
        WHERE user_id = NEW.user_id AND nlevel(path) = 1;

        IF v_root_path IS NULL THEN
            -- Root might be being inserted in the same transaction
            -- (e.g. by activate_invited_user). If no root yet exists,
            -- and this isn't a root, it's invalid.
            RAISE EXCEPTION 'User must have a root priority before adding sub-priorities';
        END IF;

        IF NOT v_root_path @> NEW.path THEN
            RAISE EXCEPTION 'Priority path % must be under root path %', NEW.path, v_root_path;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
-- Create "upsert_priority" function
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
        INSERT INTO priority (id, user_id, archived_at, title, color, path, created_by, updated_by)
            VALUES (_input.id, upsert_priority.user_id, _input.archived_at, _input.title, CASE WHEN _is_creator THEN
                    _input.color
                ELSE
                    NULL
                END, _input.path, _input.created_by, _input.updated_by)
        ON CONFLICT (id)
            DO UPDATE SET
                archived_at = _input.archived_at,
                title = _input.title,
                color = CASE WHEN _is_creator THEN
                    _input.color
                ELSE
                    priority.color
                END,
                updated_by = _input.updated_by
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
-- Modify "priority" view
CREATE OR REPLACE VIEW "user"."priority" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
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
  "attention_window",
  "see_within_requests",
  "see_within_updates",
  "attention_window_set",
  "see_within_requests_set",
  "see_within_updates_set",
  "inherit_members"
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
                    WHEN priority_setting.key = 'attention_window'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS attention_window_set,
            max(
                CASE
                    WHEN priority_setting.key = 'see_within_requests'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS see_within_requests_set,
            max(
                CASE
                    WHEN priority_setting.key = 'see_within_updates'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS see_within_updates_set,
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
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'color'::text THEN (priority_setting_inherited.value #>> '{}'::text[])::integer
                    ELSE NULL::integer
                END) AS color,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'attention_window'::text THEN priority_setting_inherited.value::text
                    ELSE NULL::text
                END)::jsonb AS attention_window,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'see_within_requests'::text THEN priority_setting_inherited.value::text
                    ELSE NULL::text
                END)::jsonb AS see_within_requests,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'see_within_updates'::text THEN priority_setting_inherited.value::text
                    ELSE NULL::text
                END)::jsonb AS see_within_updates,
            max(priority_setting_inherited.updated_at) AS updated_at
           FROM public.priority_setting_inherited
          GROUP BY priority_setting_inherited.user_id, priority_setting_inherited.priority_id
        )
 SELECT p.user_id,
    p.id,
    p.created_at,
    GREATEST(direct.updated_at, p.updated_at, COALESCE(upu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone), inh.updated_at) AS updated_at,
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
    inh.color,
    p.key,
    COALESCE(upu.unread, false) AS unread,
    'member'::text AS role,
    inh.attention_window,
    inh.see_within_requests,
    inh.see_within_updates,
    COALESCE(direct.attention_window_set, false) AS attention_window_set,
    COALESCE(direct.see_within_requests_set, false) AS see_within_requests_set,
    COALESCE(direct.see_within_updates_set, false) AS see_within_updates_set,
    p.inherit_members
   FROM public.priority p
     LEFT JOIN user_root ur ON ur.user_id = p.user_id
     LEFT JOIN direct_settings direct ON direct.user_id = p.user_id AND direct.priority_id = p.id
     LEFT JOIN inherited_settings inh ON inh.user_id = p.user_id AND inh.priority_id = p.id
     LEFT JOIN "user".priority_unread upu ON upu.user_id = p.user_id AND upu.priority_id = p.id;
