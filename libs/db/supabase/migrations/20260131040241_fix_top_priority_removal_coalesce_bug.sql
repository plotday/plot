SET ROLE "postgres";
SET check_function_bodies = false;
CREATE OR REPLACE FUNCTION public.create_email_delivery(p_idempotency_key text, p_template text, p_to_addresses text[], p_subject text, p_template_props jsonb DEFAULT NULL::jsonb, p_max_retries integer DEFAULT 10)
 RETURNS TABLE(id uuid, status text, already_sent boolean)
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_existing_id UUID;
  v_existing_status TEXT;
BEGIN
  -- Check for existing email
  SELECT ed.id, ed.status INTO v_existing_id, v_existing_status
  FROM email_delivery ed
  WHERE ed.idempotency_key = p_idempotency_key;

  IF v_existing_id IS NOT NULL THEN
    -- Email already exists
    RETURN QUERY SELECT
      v_existing_id,
      v_existing_status,
      (v_existing_status = 'sent')::BOOLEAN;
    RETURN;
  END IF;

  -- Create new email
  RETURN QUERY
  INSERT INTO email_delivery (
    idempotency_key,
    template,
    to_addresses,
    subject,
    template_props,
    max_retries,
    status
  ) VALUES (
    p_idempotency_key,
    p_template,
    p_to_addresses,
    p_subject,
    p_template_props,
    p_max_retries,
    'pending'
  )
  RETURNING email_delivery.id, email_delivery.status, FALSE;
END;
$function$;
CREATE OR REPLACE FUNCTION public.handle_user_priority_upsert()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    _priority_id uuid;
    _is_creator boolean;
    _priority_default_color integer;
    _parent_visual_path ltree;
    _label text;
    _parent_id uuid;
    _parent_actual_path ltree;
    _actual_path ltree;
    -- Variables for move detection
    _is_move boolean;
    _is_visual_move boolean := FALSE;
    _user_personal_root_path ltree;
    _old_is_personal boolean;
    _new_is_personal boolean;
    _aliased_root_id uuid;
    _aliased_root_visual_path ltree;
    _aliased_root_actual_path ltree;
    _within_aliased_tree boolean;
    _priority_exists boolean;
    _old_actual_path ltree;
    -- For storing OLD path when OLD.global_path is NULL
BEGIN
    _priority_id := NEW.id;
    _is_creator := (NEW.created_by = COALESCE(auth.uid (), NEW.user_id));
    -- Check if priority already exists (to distinguish INSERT from UPDATE)
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                priority
            WHERE
                id = NEW.id) INTO _priority_exists;
    -- For existing priorities, compute what the new actual path would be
    -- This is needed for move detection since NEW.global_path is NULL (computed column)
    -- Also get OLD path if not available (happens with INSERT ... ON CONFLICT)
    IF _priority_exists THEN
        -- Get the old actual path from the database if OLD.global_path is NULL
        -- This happens when using INSERT ... ON CONFLICT (upsert)
        _old_actual_path := OLD.global_path;
        IF _old_actual_path IS NULL THEN
            SELECT
                path INTO _old_actual_path
            FROM
                priority
            WHERE
                id = NEW.id;
        END IF;
        IF nlevel (NEW.path) > 1 THEN
            -- Extract parent path and label from visual path
            _parent_visual_path := subpath (NEW.path, 0, nlevel (NEW.path) - 1);
            _label := text(subpath (NEW.path, nlevel (NEW.path) - 1, 1));
            -- Look up parent's ID and actual path from visual path
            SELECT
                id,
                global_path INTO _parent_id,
                _parent_actual_path
            FROM
                user_priority
            WHERE
                user_id = COALESCE(auth.uid (), NEW.user_id)
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
                _actual_path := NEW.path;
            END IF;
        END IF;
        -- Detect if this is a move (actual path changed on existing priority)
        -- Use computed actual path instead of NEW.global_path (which is NULL)
        _is_move := (_priority_exists
            AND _actual_path IS NOT NULL
            AND _old_actual_path IS DISTINCT FROM _actual_path);
        IF _is_move THEN
            -- This is a move operation
            -- Block moving root priorities
            IF NEW.root THEN
                RAISE EXCEPTION 'Cannot move root priority'
                    USING HINT = 'Root priorities define access boundaries and cannot be moved';
                END IF;
                -- Get user's personal root path (actual path)
                SELECT
                    p.path INTO _user_personal_root_path
                FROM
                    priority_user pu
                    JOIN priority p ON pu.priority_id = p.id
                WHERE
                    pu.user_id = COALESCE(auth.uid (), NEW.user_id)
                    AND pu.personal = TRUE
                    AND pu.archived_at IS NULL
                LIMIT 1;
                -- Determine if old and new locations are under personal root using global_path
                _old_is_personal := (_user_personal_root_path @> _old_actual_path);
                -- Determine if new location is under personal root using computed actual path
                -- (actual path was already computed before move detection)
                _new_is_personal := (_user_personal_root_path @> _actual_path);
                -- Prevent circular reference
                IF _actual_path <@ _old_actual_path OR _actual_path = _old_actual_path THEN
                    RAISE EXCEPTION 'Cannot move priority to be a descendant of itself'
                        USING HINT = 'old_path=' || _old_actual_path::text || ', new_path=' || _actual_path::text;
                    END IF;
                    -- Check if move is within an aliased tree
                    -- Find the deepest ancestor with priority_settings that creates an alias
                    _within_aliased_tree := FALSE;
                    _aliased_root_id := NULL;
                    IF NOT _old_is_personal AND _new_is_personal THEN
                        -- Look for aliased ancestor by checking priority_settings
                        -- Find deepest ancestor where both old and new global paths are under the aliased root's actual path
                        SELECT
                            ps.priority_id,
                            ps.path,
                            p.path INTO _aliased_root_id,
                            _aliased_root_visual_path,
                            _aliased_root_actual_path
                        FROM
                            priority_settings ps
                            JOIN priority p ON ps.priority_id = p.id
                        WHERE
                            ps.user_id = COALESCE(auth.uid (), NEW.user_id)
                            AND ps.path IS NOT NULL
                            AND NEW.path <@ ps.path
                            -- New visual path is under this aliased path
                            AND OLD.path <@ ps.path
                            -- Old visual path is also under this aliased path
                            AND ps.path != p.path
                            -- Visual path differs from actual (indicates alias)
                            AND _old_actual_path <@ p.path
                            -- Old actual path is under the aliased root's actual path
                            AND _actual_path <@ p.path
                            -- New actual path is also under the aliased root's actual path
                        ORDER BY
                            nlevel (ps.path) DESC
                            -- Deepest first
                        LIMIT 1;
                        IF _aliased_root_id IS NOT NULL THEN
                            _within_aliased_tree := TRUE;
                        END IF;
                    END IF;
                    -- Determine move type and execute appropriate action
                    IF (_old_is_personal AND _new_is_personal) OR (NOT _old_is_personal AND NOT _new_is_personal) THEN
                        -- Type 1: Actual move (within personal tree or within/between shared trees)
                        PERFORM
                            move_priority (NEW.id, _parent_actual_path);
                        _actual_path := NULL;
                        -- Path updated by move_priority, don't update priority_settings.path
                    ELSIF NOT _old_is_personal
                            AND _new_is_personal
                            AND _within_aliased_tree THEN
                            -- Type 3: Actual move within aliased tree
                            -- Both old and new are under the same aliased root
                            -- This is a real organizational change within the shared tree
                            PERFORM
                                move_priority (NEW.id, _parent_actual_path);
                        _actual_path := NULL;
                        -- Path updated by move_priority, don't update priority_settings.path
                    ELSIF NOT _old_is_personal
                            AND _new_is_personal THEN
                            -- Type 2: Visual move (aliasing shared priority under personal root)
                            -- Set priority_settings.path to create visual alias
                            -- Actual path remains unchanged
                            -- This happens in the priority_settings update section below
                            _actual_path := NULL;
                        _is_visual_move := TRUE;
                        -- Don't change actual path, but DO update priority_settings.path with NEW.path
                    ELSIF _old_is_personal
                            AND NOT _new_is_personal THEN
                            -- Moving personal priority into shared tree - block this
                            RAISE EXCEPTION 'Cannot move personal priority into shared tree'
                            USING HINT = 'Use Share dialog to share a personal priority';
                        END IF;
                    END IF;
                    -- Translate visual path to actual path for new sub-priorities
                    -- For root priorities or existing priorities, use path as-is
                    IF _is_move IS NOT TRUE AND NOT _priority_exists AND nlevel (NEW.path) > 1 THEN
                        -- Extract parent path and label from visual path
                        _parent_visual_path := subpath (NEW.path, 0, nlevel (NEW.path) - 1);
                        _label := text(subpath (NEW.path, nlevel (NEW.path) - 1, 1));
                        -- Look up parent's actual path via user_priority view (which has global_path)
                        SELECT
                            global_path INTO _parent_actual_path
                        FROM
                            user_priority
                        WHERE
                            user_id = COALESCE(auth.uid (), NEW.user_id)
                            AND path = _parent_visual_path
                        LIMIT 1;
                        IF _parent_actual_path IS NOT NULL THEN
                            -- Compute actual path for new priority
                            _actual_path := _parent_actual_path || _label::ltree;
                        ELSE
                            -- Fallback: parent not found, use path as-is (shouldn't happen)
                            _actual_path := NEW.path;
                        END IF;
                    ELSIF _is_move IS NOT TRUE THEN
                        -- Use provided path as-is (root priority or existing non-move update)
                        _actual_path := NEW.path;
                    END IF;
                    -- Get the priority's default color for initializing new priority_settings
                    SELECT
                        color INTO _priority_default_color
                    FROM
                        priority
                    WHERE
                        id = NEW.id;
                    -- Update priority table fields (title, archived_at, updated_by, color)
                    -- Note: For moves, path was already updated by move_priority()
                    -- We always update for new priorities, moves, or when any fields are provided
                    IF TRUE THEN
                        -- Only insert/update if path was computed (for new priorities)
                        -- For moves, path was already updated by move_priority()
                        IF _actual_path IS NOT NULL THEN
                            INSERT INTO priority (id, archived_at, title, color, path, created_by, updated_by)
                                VALUES (NEW.id, NEW.archived_at, NEW.title, CASE WHEN _is_creator THEN
                                        NEW.color
                                    ELSE
                                        NULL
                                    END, _actual_path, NEW.created_by, NEW.updated_by)
                            ON CONFLICT (id)
                                DO UPDATE SET
                                    archived_at = NEW.archived_at,
                                    title = NEW.title,
                                    color = CASE WHEN _is_creator THEN
                                        NEW.color
                                    ELSE
                                        priority.color
                                    END,
                                    updated_by = NEW.updated_by
                                RETURNING
                                    id INTO _priority_id;
                        ELSE
                            -- For moves, just update non-path fields
                            UPDATE
                                priority
                            SET
                                archived_at = NEW.archived_at,
                                title = NEW.title,
                                color = CASE WHEN _is_creator THEN
                                    NEW.color
                                ELSE
                                    priority.color
                                END,
                                updated_by = NEW.updated_by
                            WHERE
                                id = NEW.id
                            RETURNING
                                id INTO _priority_id;
                        END IF;
                    END IF;
                    -- Update priority_settings for user-specific inherited fields
                    -- Only update when:
                    -- 1. This is a visual move (Type 2) - always update path
                    -- 2. Explicit settings are provided AND this is not a non-visual move
                    IF _is_visual_move THEN
                        -- Visual move: create/update path alias
                        INSERT INTO priority_settings (user_id, priority_id, path, top_order, "order", pomodoro, color)
                            VALUES (COALESCE(auth.uid (), NEW.user_id), _priority_id, NEW.path, NEW.top_order, NEW.order, NEW.pomodoro, COALESCE(NEW.color, _priority_default_color))
                        ON CONFLICT (user_id, priority_id)
                            DO UPDATE SET
                                path = NEW.path,
                                top_order = NEW.top_order,
                                "order" = NEW.order,
                                pomodoro = NEW.pomodoro,
                                color = NEW.color;
                    ELSIF NOT _is_move
                            AND (NEW."top_order" IS NOT NULL
                                OR NEW."order" IS NOT NULL
                                OR NEW."pomodoro" IS NOT NULL
                                OR NEW."color" IS NOT NULL) THEN
                            -- Non-move update with explicit settings
                            INSERT INTO priority_settings (user_id, priority_id, path, top_order, "order", pomodoro, color)
                                VALUES (COALESCE(auth.uid (), NEW.user_id), _priority_id, NULL, NEW.top_order, NEW.order, NEW.pomodoro, COALESCE(NEW.color, _priority_default_color))
                            ON CONFLICT (user_id, priority_id)
                                DO UPDATE SET
                                    top_order = NEW.top_order,
                                    "order" = NEW.order,
                                    pomodoro = NEW.pomodoro,
                                    color = NEW.color;
                    END IF;
                    RETURN NEW;
END;
$function$;
CREATE OR REPLACE FUNCTION public.increment_email_retry(p_idempotency_key text, p_error text)
 RETURNS TABLE(retry_count integer, max_retries integer, should_expire boolean)
 LANGUAGE plpgsql
AS $function$
BEGIN
  UPDATE email_delivery
  SET
    retry_count = email_delivery.retry_count + 1,
    last_error = p_error,
    last_attempt_at = now(),
    status = 'failed'
  WHERE idempotency_key = p_idempotency_key
  RETURNING
    email_delivery.retry_count,
    email_delivery.max_retries,
    (email_delivery.retry_count >= email_delivery.max_retries)::BOOLEAN
  INTO increment_email_retry.retry_count, increment_email_retry.max_retries, increment_email_retry.should_expire;

  RETURN NEXT;
END;
$function$;
ALTER FUNCTION public.mark_email_expired SECURITY INVOKER;
ALTER FUNCTION public.mark_email_sent SECURITY INVOKER;
CREATE OR REPLACE TRIGGER set_activity_source_priority_root_trigger BEFORE INSERT OR UPDATE OF source, priority_id ON public.activity FOR EACH ROW EXECUTE FUNCTION public.set_activity_source_priority_root();
CREATE OR REPLACE TRIGGER update_activity_last_note_created_at_on_status_change AFTER UPDATE OF draft, archived_at ON public.note FOR EACH ROW WHEN (old.draft IS DISTINCT FROM new.draft OR old.archived_at IS DISTINCT FROM new.archived_at) EXECUTE FUNCTION public.update_activity_on_note_change();

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
