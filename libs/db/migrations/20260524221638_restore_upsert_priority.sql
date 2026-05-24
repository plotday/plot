-- The previous migration's CASCADE drop of "user"."priority" inadvertently
-- dropped "user".upsert_priority (the function returns the view's row type).
-- Atlas's diff doesn't detect the gap because the schema file still defines
-- the function and the dev replica retains it; only the worktree DB lost it.
-- Recreate it from the schema to bring the actual DB back in sync.
CREATE OR REPLACE FUNCTION "user".upsert_priority (
    user_id uuid,
    p_priority jsonb
)
    RETURNS "user"."priority"
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
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
    _input := jsonb_populate_record(NULL::"user"."priority", p_priority || jsonb_build_object('user_id', upsert_priority.user_id));
    _is_creator := (_input.created_by = upsert_priority.user_id);
    SELECT
        EXISTS (
            SELECT 1 FROM priority WHERE id = _input.id
        ) INTO _priority_exists;
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
    IF _priority_exists THEN
        SELECT * INTO _old
        FROM "user".priority up
        WHERE up.user_id = upsert_priority.user_id AND up.id = _input.id;
        _old_path := _old.path;
    END IF;
    _is_move := (_priority_exists AND _input.path IS DISTINCT FROM _old_path);
    IF _is_move THEN
        IF _input.path <@ _old_path OR _input.path = _old_path THEN
            RAISE EXCEPTION 'Cannot move priority to be a descendant of itself'
                USING HINT = 'old_path=' || _old_path::text || ', new_path=' || _input.path::text;
        END IF;
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
    SELECT color INTO _priority_default_color FROM priority WHERE id = _input.id;
    IF NOT _is_move THEN
        INSERT INTO priority (id, user_id, archived_at, title, color, path, created_by, updated_by,
            default_contacts, default_groups, default_invite_emails)
            VALUES (_input.id, upsert_priority.user_id, _input.archived_at, _input.title,
                CASE WHEN _is_creator THEN _input.color ELSE NULL END,
                _input.path, _input.created_by, _input.updated_by,
                COALESCE(_input.default_contacts, '{}'::uuid[]),
                COALESCE(_input.default_groups, '{}'::uuid[]),
                COALESCE(_input.default_invite_emails, '{}'::text[]))
        ON CONFLICT (id)
            DO UPDATE SET
                archived_at = _input.archived_at,
                title = _input.title,
                color = CASE WHEN _is_creator THEN _input.color ELSE priority.color END,
                updated_by = _input.updated_by,
                default_contacts = COALESCE(_input.default_contacts, priority.default_contacts),
                default_groups = COALESCE(_input.default_groups, priority.default_groups),
                default_invite_emails = COALESCE(_input.default_invite_emails, priority.default_invite_emails)
            RETURNING id INTO _priority_id;
    ELSE
        UPDATE priority
        SET
            archived_at = _input.archived_at,
            title = _input.title,
            color = CASE WHEN _is_creator THEN _input.color ELSE priority.color END,
            updated_by = _input.updated_by,
            default_contacts = COALESCE(_input.default_contacts, priority.default_contacts),
            default_groups = COALESCE(_input.default_groups, priority.default_groups),
            default_invite_emails = COALESCE(_input.default_invite_emails, priority.default_invite_emails)
        WHERE id = _input.id
        RETURNING id INTO _priority_id;
    END IF;
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
    SELECT * INTO v_row
    FROM "user".priority up
    WHERE up.user_id = upsert_priority.user_id AND up.id = _input.id;
    RETURN v_row;
END;
$function$;
