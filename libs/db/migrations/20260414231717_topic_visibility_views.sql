-- Drop "priority_propagate_team_id_update" trigger
DROP TRIGGER "priority_propagate_team_id_update" ON "public"."priority";
-- Drop "priority" view
DROP VIEW "user"."priority" CASCADE;
-- Modify "priority" table
ALTER TABLE "public"."priority" DROP COLUMN "team_id";
-- Drop "priority_propagate_team_id" trigger
DROP TRIGGER "priority_propagate_team_id" ON "public"."priority";
-- Create "auto_maintain_team_admin_topic" function
CREATE FUNCTION "public"."auto_maintain_team_admin_topic" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
        v_topic_id uuid;
        v_contact_id uuid;
        BEGIN
        -- Only handle team admins
        IF (TG_OP = 'INSERT' OR TG_OP = 'UPDATE') AND NEW.role != 'admin' THEN
        -- If user is no longer an admin, remove from topic
        SELECT id INTO v_topic_id FROM topic WHERE auto_team_admin_team_id = NEW.team_id;
        IF v_topic_id IS NOT NULL THEN
            SELECT contact_id INTO v_contact_id FROM user_contact WHERE user_id = NEW.user_id AND "primary" = TRUE;
            IF v_contact_id IS NOT NULL THEN
                DELETE FROM topic_member WHERE topic_id = v_topic_id AND contact_id = v_contact_id;
            END IF;
            DELETE FROM topic_admin WHERE topic_id = v_topic_id AND user_id = NEW.user_id;
        END IF;
        RETURN NEW;
        END IF;

        -- Get or create topic
        SELECT id INTO v_topic_id FROM topic WHERE auto_team_admin_team_id = COALESCE(NEW.team_id, OLD.team_id);
        IF v_topic_id IS NULL AND TG_OP != 'DELETE' THEN
        INSERT INTO topic (name, type, team_id, auto_team_admin_team_id, created_by, auto_maintained)
        SELECT t.name || ' Admins', 'team', t.id, t.id, NEW.user_id, TRUE
        FROM team t WHERE t.id = NEW.team_id
        RETURNING id INTO v_topic_id;
        END IF;

        IF v_topic_id IS NULL THEN
        RETURN COALESCE(NEW, OLD);
        END IF;

        SELECT contact_id INTO v_contact_id FROM user_contact WHERE user_id = COALESCE(NEW.user_id, OLD.user_id) AND "primary" = TRUE;

        IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND NEW.role = 'admin') THEN
        IF v_contact_id IS NOT NULL THEN
            INSERT INTO topic_member (topic_id, contact_id) VALUES (v_topic_id, v_contact_id) ON CONFLICT DO NOTHING;
        END IF;
        INSERT INTO topic_admin (topic_id, user_id) VALUES (v_topic_id, COALESCE(NEW.user_id, OLD.user_id)) ON CONFLICT DO NOTHING;
        ELSIF TG_OP = 'DELETE' THEN
        IF v_contact_id IS NOT NULL THEN
            DELETE FROM topic_member WHERE topic_id = v_topic_id AND contact_id = v_contact_id;
        END IF;
        DELETE FROM topic_admin WHERE topic_id = v_topic_id AND user_id = OLD.user_id;
        END IF;

        RETURN COALESCE(NEW, OLD);
        END;
$$;
-- Create trigger "auto_maintain_team_admin_topic"
CREATE TRIGGER "auto_maintain_team_admin_topic" AFTER DELETE OR INSERT OR UPDATE OF "role" ON "public"."team_user" FOR EACH ROW EXECUTE FUNCTION "public"."auto_maintain_team_admin_topic"();
-- Create "auto_maintain_twist_admin_topic" function
CREATE FUNCTION "public"."auto_maintain_twist_admin_topic" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
        v_topic_id uuid;
        v_contact_id uuid;
        BEGIN
        SELECT id INTO v_topic_id FROM topic WHERE auto_twist_admin_id = COALESCE(NEW.id, OLD.id);
        IF v_topic_id IS NULL AND TG_OP != 'DELETE' THEN
        INSERT INTO topic (name, type, auto_twist_admin_id, created_by, auto_maintained)
        VALUES ('Twist Admins', 'private', NEW.id, COALESCE(NEW.user_id, (SELECT id FROM "user" LIMIT 1)), TRUE)
        RETURNING id INTO v_topic_id;
        END IF;

        IF v_topic_id IS NULL THEN
        RETURN COALESCE(NEW, OLD);
        END IF;

        IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
        IF NEW.user_id IS NOT NULL THEN
            SELECT contact_id INTO v_contact_id FROM user_contact WHERE user_id = NEW.user_id AND "primary" = TRUE;
            IF v_contact_id IS NOT NULL THEN
                INSERT INTO topic_member (topic_id, contact_id) VALUES (v_topic_id, v_contact_id) ON CONFLICT DO NOTHING;
            END IF;
            INSERT INTO topic_admin (topic_id, user_id) VALUES (v_topic_id, NEW.user_id) ON CONFLICT DO NOTHING;
        END IF;
        -- Handle publisher_id if needed, but for now we focus on user_id
        ELSIF TG_OP = 'DELETE' THEN
        -- Cascades take care of it
        END IF;

        RETURN COALESCE(NEW, OLD);
        END;
$$;
-- Create trigger "auto_maintain_twist_admin_topic"
CREATE TRIGGER "auto_maintain_twist_admin_topic" AFTER DELETE OR INSERT OR UPDATE OF "publisher_id", "user_id" ON "public"."twist_admin" FOR EACH ROW EXECUTE FUNCTION "public"."auto_maintain_twist_admin_topic"();
-- Create "auto_maintain_user_topic" function
CREATE FUNCTION "public"."auto_maintain_user_topic" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
        v_topic_id uuid;
        v_contact_id uuid;
        BEGIN
        SELECT id INTO v_topic_id FROM topic WHERE auto_user_id = NEW.user_id;
        IF v_topic_id IS NULL THEN
        INSERT INTO topic (name, type, auto_user_id, created_by, auto_maintained)
        VALUES ('Account Topic', 'private', NEW.user_id, NEW.user_id, TRUE)
        RETURNING id INTO v_topic_id;
        END IF;

        SELECT contact_id INTO v_contact_id FROM user_contact WHERE user_id = NEW.user_id AND "primary" = TRUE AND linked = TRUE AND archived_at IS NULL;

        IF v_contact_id IS NOT NULL THEN
        INSERT INTO topic_member (topic_id, contact_id) VALUES (v_topic_id, v_contact_id) ON CONFLICT DO NOTHING;
        END IF;
        INSERT INTO topic_admin (topic_id, user_id) VALUES (v_topic_id, NEW.user_id) ON CONFLICT DO NOTHING;

        RETURN NEW;
        END;
$$;
-- Create trigger "auto_maintain_user_topic"
CREATE TRIGGER "auto_maintain_user_topic" AFTER INSERT OR UPDATE OF "archived_at", "linked", "primary" ON "public"."user_contact" FOR EACH ROW EXECUTE FUNCTION "public"."auto_maintain_user_topic"();
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

    -- Create Twist Development (@plot.twist-dev)
    INSERT INTO public.priority (created_by, user_id, title, path, color, key)
    VALUES (p_user_id, p_user_id, 'Twist Development', v_new_path || generate_path(NULL), 3, '@plot.twist-dev');

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

    -- 4. Twist/Connector admin topics -> Twist Development
    INSERT INTO public.priority_rule (user_id, priority_id, type, criteria)
    SELECT p_user_id, p.id, 'contact_topics', jsonb_build_object('topics', ARRAY[t.id::text])
    FROM public.priority p
    CROSS JOIN public.topic t
    JOIN public.twist_admin ta ON ta.id = t.auto_twist_admin_id AND ta.user_id = p_user_id
    WHERE p.user_id = p_user_id AND p.key = '@plot.twist-dev'
      AND t.auto_twist_admin_id IS NOT NULL;

    RETURN jsonb_build_object('activated', TRUE, 'already_active', FALSE, 'root_priority_id', v_root_priority_id);
END;
$$;
-- Modify "move_priority" function
CREATE OR REPLACE FUNCTION "public"."move_priority" ("p_priority_id" uuid, "p_new_parent_path" public.ltree) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_old_path ltree;
    v_new_path ltree;
    v_priority_label text;
BEGIN
    -- Get the current path of the priority being moved
    SELECT
        path INTO v_old_path
    FROM
        public.priority
    WHERE
        id = p_priority_id;
    -- If priority doesn't exist, raise an exception
    IF v_old_path IS NULL THEN
        RAISE EXCEPTION 'Priority with id % not found', p_priority_id;
    END IF;
    -- Prevent moving a priority to be a descendant of itself
    IF p_new_parent_path IS NOT NULL AND (p_new_parent_path <@ v_old_path OR p_new_parent_path = v_old_path) THEN
        RAISE EXCEPTION 'Cannot move priority to be a descendant of itself';
    END IF;
    -- Extract the last label from the current path (the priority's own identifier)
    v_priority_label := ltree2text (subpath (v_old_path, -1));
    -- Calculate the new path
    IF p_new_parent_path IS NULL THEN
        -- Moving to root level
        v_new_path := text2ltree (v_priority_label);
    ELSE
        -- Moving under a parent
        v_new_path := text2ltree (ltree2text (p_new_parent_path) || '.' || v_priority_label);
    END IF;
    -- Update all priorities whose path starts with the old path
    -- This includes the priority itself and all its descendants
    UPDATE
        public.priority
    SET
        path = CASE
        -- For the priority itself, use the new path directly
        WHEN path = v_old_path THEN
            v_new_path
            -- For descendants, replace the old path prefix with the new path
        ELSE
            text2ltree (ltree2text (v_new_path) || '.' || ltree2text (subpath (path, nlevel (v_old_path))))
        END
    WHERE
        path <@ v_old_path
        OR path = v_old_path;
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
-- Create "priority" view
CREATE VIEW "user"."priority" (
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
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'path'::text THEN priority_setting_inherited.value #>> '{}'::text[]
                    ELSE NULL::text
                END) AS path_value,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'path'::text THEN priority_setting_inherited.source_path::text
                    ELSE NULL::text
                END) AS path_source,
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
        CASE
            WHEN inh.path_value IS NOT NULL THEN
            CASE
                WHEN inh.path_source IS NOT NULL AND p.path OPERATOR(public.<>) inh.path_source::public.ltree AND public.subpath(p.path, public.nlevel(inh.path_source::public.ltree)) OPERATOR(public.<>) ''::public.ltree THEN inh.path_value::public.ltree OPERATOR(public.||) public.subpath(p.path, public.nlevel(inh.path_source::public.ltree))
                ELSE inh.path_value::public.ltree
            END
            ELSE p.path
        END AS path,
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
    _parent_visual_path ltree;
    _label text;
    _parent_actual_path ltree;
    _actual_path ltree;
    _is_move boolean;
    _priority_exists boolean;
    _old_actual_path ltree;
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
    END IF;
    -- For existing priorities, compute what the new actual path would be
    -- This is needed for move detection since global_path is a computed column
    IF _priority_exists THEN
        _old_actual_path := _old.global_path;
        IF _old_actual_path IS NULL THEN
            SELECT
                path INTO _old_actual_path
            FROM
                priority
            WHERE
                id = _input.id;
        END IF;
        IF nlevel (_input.path) > 1 THEN
            -- Extract parent path and label from visual path
            _parent_visual_path := subpath (_input.path, 0, nlevel (_input.path) - 1);
            _label := text(subpath (_input.path, nlevel (_input.path) - 1, 1));
            -- Look up parent's ID and actual path from visual path
            SELECT
                global_path INTO _parent_actual_path
            FROM
                "user".priority
            WHERE
                user_id = upsert_priority.user_id
                AND path = _parent_visual_path
            LIMIT 1;
            IF _parent_actual_path IS NULL THEN
                RAISE EXCEPTION 'Parent priority not found'
                    USING HINT = 'parent_visual_path=' || _parent_visual_path::text;
            END IF;
            -- Compute what the new actual path would be
            _actual_path := _parent_actual_path || _label::ltree;
        ELSE
            -- Root level priority (nlevel = 1)
            _actual_path := _input.path;
        END IF;
    END IF;
    -- Detect if this is a move (actual path changed on existing priority)
    _is_move := (_priority_exists
        AND _actual_path IS NOT NULL
        AND _old_actual_path IS DISTINCT FROM _actual_path);
    -- If the visual path hasn't changed, this is not a move.
    -- The visual-to-actual path resolution can produce false positives for shared
    -- root priorities (where visual path includes personal root prefix or alias).
    IF _is_move AND _old IS NOT NULL AND _input.path IS NOT DISTINCT FROM _old.path THEN
        _is_move := FALSE;
        _actual_path := _old_actual_path;
    END IF;
    IF _is_move THEN
        -- Prevent circular reference
        IF _actual_path <@ _old_actual_path OR _actual_path = _old_actual_path THEN
            RAISE EXCEPTION 'Cannot move priority to be a descendant of itself'
                USING HINT = 'old_path=' || _old_actual_path::text || ', new_path=' || _actual_path::text;
        END IF;
        -- In the per-user model every priority belongs to a single user's
        -- tree, so every actual move is a straight ltree relocation. The
        -- old shared-tree / aliased-tree / visual-alias branches are dead.
        PERFORM move_priority (_input.id, _parent_actual_path);
        _actual_path := NULL;
    END IF;
    -- Translate visual path to actual path for new sub-priorities
    IF _is_move IS NOT TRUE AND NOT _priority_exists AND nlevel (_input.path) > 1 THEN
        _parent_visual_path := subpath (_input.path, 0, nlevel (_input.path) - 1);
        _label := text(subpath (_input.path, nlevel (_input.path) - 1, 1));
        SELECT
            global_path INTO _parent_actual_path
        FROM
            "user".priority
        WHERE
            user_id = upsert_priority.user_id
            AND path = _parent_visual_path
        LIMIT 1;
        IF _parent_actual_path IS NOT NULL THEN
            _actual_path := _parent_actual_path || _label::ltree;
        ELSE
            _actual_path := _input.path;
        END IF;
    ELSIF _is_move IS NOT TRUE THEN
        _actual_path := _input.path;
    END IF;
    -- Get the priority's default color for initializing new priority_settings
    SELECT
        color INTO _priority_default_color
    FROM
        priority
    WHERE
        id = _input.id;
    -- Update priority table
    IF _actual_path IS NOT NULL THEN
        INSERT INTO priority (id, user_id, archived_at, title, color, path, created_by, updated_by)
            VALUES (_input.id, upsert_priority.user_id, _input.archived_at, _input.title, CASE WHEN _is_creator THEN
                    _input.color
                ELSE
                    NULL
                END, _actual_path, _input.created_by, _input.updated_by)
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
        -- For moves, just update non-path fields
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
-- Drop "propagate_team_id" function
DROP FUNCTION "public"."propagate_team_id";
-- Drop "propagate_team_id_to_descendants" function
DROP FUNCTION "public"."propagate_team_id_to_descendants";
