-- Helper to assert user access to a priority
CREATE OR REPLACE FUNCTION "user".assert_priority_access (user_id uuid, priority_id uuid)
    RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
BEGIN
    IF priority_id IS NULL THEN
        RAISE EXCEPTION 'priority_id must be provided';
    END IF;
    IF NOT EXISTS (
        SELECT
            1
        FROM
            priority_user pu
            JOIN priority pp ON pu.priority_id = pp.id
            JOIN priority p ON p.path <@ pp.path
        WHERE
            pu.user_id = assert_priority_access.user_id
            AND pu.archived_at IS NULL
            AND p.id = assert_priority_access.priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION "user".upsert_thread_tag (
    user_id uuid,
    p_actor_id uuid,
    p_thread_id uuid,
    p_tag_id integer,
    p_occurrence text DEFAULT NULL::text,
    p_updated_by integer DEFAULT 0,
    p_archived_at timestamptz DEFAULT NULL::timestamptz
)
    RETURNS thread_tag
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
DECLARE
    v_priority_id uuid;
    v_tag_type tag_type;
    v_row thread_tag;
BEGIN
    SELECT
        priority_id INTO v_priority_id
    FROM
        thread
    WHERE
        id = p_thread_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

    v_tag_type := get_tag_type(p_tag_id);
    IF v_tag_type = 'compute' THEN
        RAISE EXCEPTION 'Cannot add computed tag (tag_id: %)', p_tag_id;
    END IF;
    -- Viewer enforcement: viewers can only modify count tags
    IF v_tag_type != 'count' AND "user".get_effective_role(user_id, v_priority_id) = 'viewer' THEN
        RAISE EXCEPTION 'Viewer members can only modify count tags';
    END IF;
    IF v_tag_type = 'count' AND p_actor_id != "user".user_contact_id(user_id) THEN
        RAISE EXCEPTION 'Cannot modify count tags for other users (tag_id: %)', p_tag_id;
    END IF;

    INSERT INTO thread_tag (actor_id, thread_id, occurrence, tag_id, updated_by, archived_at)
        VALUES (p_actor_id, p_thread_id, p_occurrence, p_tag_id, COALESCE(p_updated_by, 0), p_archived_at)
    ON CONFLICT (actor_id, thread_id, occurrence, tag_id)
        DO UPDATE SET
            archived_at = EXCLUDED.archived_at,
            updated_by = EXCLUDED.updated_by,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$function$;

CREATE OR REPLACE FUNCTION "user".upsert_note_tag (
    user_id uuid,
    p_actor_id uuid,
    p_note_id uuid,
    p_tag_id integer,
    p_updated_by integer DEFAULT 0,
    p_archived_at timestamptz DEFAULT NULL::timestamptz
)
    RETURNS note_tag
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
DECLARE
    v_priority_id uuid;
    v_tag_type tag_type;
    v_row note_tag;
BEGIN
    SELECT
        a.priority_id INTO v_priority_id
    FROM
        note n
        JOIN thread a ON a.id = n.thread_id
    WHERE
        n.id = p_note_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Note not found';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

    v_tag_type := get_tag_type(p_tag_id);
    IF v_tag_type = 'compute' THEN
        RAISE EXCEPTION 'Cannot add computed tag (tag_id: %)', p_tag_id;
    END IF;
    -- Viewer enforcement: viewers can only modify count tags
    IF v_tag_type != 'count' AND "user".get_effective_role(user_id, v_priority_id) = 'viewer' THEN
        RAISE EXCEPTION 'Viewer members can only modify count tags';
    END IF;
    IF v_tag_type = 'count' AND p_actor_id != "user".user_contact_id(user_id) THEN
        RAISE EXCEPTION 'Cannot modify count tags for other users (tag_id: %)', p_tag_id;
    END IF;

    INSERT INTO note_tag (actor_id, note_id, tag_id, updated_by, archived_at)
        VALUES (p_actor_id, p_note_id, p_tag_id, COALESCE(p_updated_by, 0), p_archived_at)
    ON CONFLICT (actor_id, note_id, tag_id)
        DO UPDATE SET
            archived_at = EXCLUDED.archived_at,
            updated_by = EXCLUDED.updated_by,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$function$;

CREATE OR REPLACE FUNCTION "user".upsert_note (
    user_id uuid,
    p_id uuid,
    p_author_id uuid,
    p_created_by uuid,
    p_updated_by integer,
    p_archived_at timestamptz,
    p_thread_id uuid,
    p_draft boolean,
    p_private boolean,
    p_content text,
    p_actions jsonb,
    p_mentions uuid[],
    p_re_note_id uuid,
    p_source_created_at timestamptz,
    p_key text,
    p_merged_from_thread_id uuid DEFAULT NULL::uuid
)
    RETURNS note
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
DECLARE
    v_priority_id uuid;
    v_created_by uuid;
    v_author_id uuid;
    v_thread_author_id uuid;
    v_row note;
BEGIN
    SELECT
        priority_id INTO v_priority_id
    FROM
        thread
    WHERE
        id = p_thread_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

    -- Viewer enforcement: force private, auto-mention thread author
    IF "user".get_effective_role(user_id, v_priority_id) = 'viewer' THEN
        p_private := TRUE;
        SELECT n.author_id INTO v_thread_author_id
        FROM note n
        WHERE n.thread_id = p_thread_id
        ORDER BY n.created_at ASC
        LIMIT 1;
        IF v_thread_author_id IS NOT NULL THEN
            IF p_mentions IS NULL THEN
                p_mentions := ARRAY[v_thread_author_id];
            ELSIF NOT (v_thread_author_id = ANY(p_mentions)) THEN
                p_mentions := p_mentions || v_thread_author_id;
            END IF;
        END IF;
    END IF;

    v_created_by := COALESCE(p_created_by, user_id);
    -- When the user creates directly (not via twist), force author to their contact ID.
    -- This prevents impersonation: clients cannot spoof author_id.
    -- When a twist creates (created_by != user_id), trust the provided author_id.
    IF v_created_by = user_id THEN
        v_author_id := COALESCE("user".user_contact_id(user_id), user_id);
    ELSE
        v_author_id := COALESCE(p_author_id, v_created_by);
    END IF;

    IF v_created_by IS DISTINCT FROM user_id THEN
        IF NOT EXISTS (
            SELECT
                1
            FROM
                priority_twist pt
            WHERE
                pt.id = v_created_by
                AND pt.owner_id = upsert_note.user_id) THEN
            RAISE EXCEPTION 'created_by must be user or owned priority_twist';
        END IF;
    END IF;

    IF p_id IS NULL THEN
        INSERT INTO note (id, author_id, created_by, updated_by, archived_at, thread_id, draft, private, content, actions, mentions, re_note_id, source_created_at, key, merged_from_thread_id)
            VALUES (uuidv7(), v_author_id, v_created_by, COALESCE(p_updated_by, 0), p_archived_at, p_thread_id, COALESCE(p_draft, FALSE), COALESCE(p_private, FALSE), p_content, p_actions, p_mentions, p_re_note_id, COALESCE(p_source_created_at, now()), p_key, p_merged_from_thread_id)
        ON CONFLICT (thread_id, key)
            DO UPDATE SET
                author_id = note.author_id,
                created_by = note.created_by,
                updated_by = EXCLUDED.updated_by,
                archived_at = EXCLUDED.archived_at,
                draft = EXCLUDED.draft,
                private = EXCLUDED.private,
                content = EXCLUDED.content,
                actions = EXCLUDED.actions,
                mentions = EXCLUDED.mentions,
                re_note_id = EXCLUDED.re_note_id,
                source_created_at = EXCLUDED.source_created_at,
                key = EXCLUDED.key,
                merged_from_thread_id = EXCLUDED.merged_from_thread_id,
                updated_at = now()
        RETURNING * INTO v_row;
    ELSE
        INSERT INTO note (id, author_id, created_by, updated_by, archived_at, thread_id, draft, private, content, actions, mentions, re_note_id, source_created_at, key, merged_from_thread_id)
            VALUES (p_id, v_author_id, v_created_by, COALESCE(p_updated_by, 0), p_archived_at, p_thread_id, COALESCE(p_draft, FALSE), COALESCE(p_private, FALSE), p_content, p_actions, p_mentions, p_re_note_id, COALESCE(p_source_created_at, now()), p_key, p_merged_from_thread_id)
        ON CONFLICT (id)
            DO UPDATE SET
                author_id = note.author_id,
                created_by = note.created_by,
                updated_by = EXCLUDED.updated_by,
                archived_at = EXCLUDED.archived_at,
                thread_id = EXCLUDED.thread_id,
                draft = EXCLUDED.draft,
                private = EXCLUDED.private,
                content = EXCLUDED.content,
                actions = EXCLUDED.actions,
                mentions = EXCLUDED.mentions,
                re_note_id = EXCLUDED.re_note_id,
                source_created_at = EXCLUDED.source_created_at,
                key = EXCLUDED.key,
                merged_from_thread_id = EXCLUDED.merged_from_thread_id,
                updated_at = now()
        RETURNING * INTO v_row;
    END IF;

    RETURN v_row;
END;
$function$;

CREATE OR REPLACE FUNCTION "user".upsert_priority_user (
    user_id uuid,
    p_priority_id uuid,
    p_archived_at timestamptz,
    p_personal boolean
)
    RETURNS priority_user
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
#variable_conflict use_column
DECLARE
    v_row priority_user;
BEGIN
    IF NOT EXISTS (
        SELECT
            1
        FROM
            priority_user
        WHERE
            user_id = upsert_priority_user.user_id
            AND priority_id = p_priority_id) THEN
        RAISE EXCEPTION 'priority_user not found';
    END IF;

    INSERT INTO priority_user (user_id, priority_id, archived_at, personal)
        VALUES (upsert_priority_user.user_id, p_priority_id, p_archived_at, COALESCE(p_personal, FALSE))
    ON CONFLICT (user_id, priority_id)
        DO UPDATE SET
            archived_at = EXCLUDED.archived_at,
            personal = EXCLUDED.personal,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$function$;

CREATE OR REPLACE FUNCTION "user".upsert_priority_member (
    user_id uuid,
    p_contact_id uuid,
    p_priority_id uuid,
    p_invited_by uuid,
    p_invited_at timestamptz
)
    RETURNS priority_member
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
DECLARE
    v_row priority_member;
BEGIN
    PERFORM "user".assert_priority_access(user_id, p_priority_id);

    -- Viewer enforcement: viewers cannot manage priority members
    IF "user".get_effective_role(user_id, p_priority_id) = 'viewer' THEN
        RAISE EXCEPTION 'Viewer members cannot manage priority members';
    END IF;

    INSERT INTO priority_contact (priority_id, contact_id, invited_by, invited_at)
        VALUES (p_priority_id, p_contact_id, p_invited_by, p_invited_at)
    ON CONFLICT (priority_id, contact_id)
        DO UPDATE SET
            invited_by = EXCLUDED.invited_by,
            invited_at = EXCLUDED.invited_at,
            updated_at = now();

    SELECT
        * INTO v_row
    FROM
        priority_member
    WHERE
        priority_id = p_priority_id
        AND contact_id = p_contact_id;

    RETURN v_row;
END;
$function$;

CREATE OR REPLACE FUNCTION "user".upsert_priority_twist (
    user_id uuid,
    p_id uuid,
    p_priority_id uuid,
    p_twist_id bigint,
    p_owner_id uuid,
    p_name text,
    p_config jsonb,
    p_archived_at timestamptz
)
    RETURNS priority_twist
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
DECLARE
    v_row priority_twist;
BEGIN
    -- Source accounts have NULL priority_id; skip access check for those
    IF p_priority_id IS NOT NULL THEN
        PERFORM "user".assert_priority_access(user_id, p_priority_id);

        -- Viewer enforcement: viewers cannot manage twists
        IF "user".get_effective_role(user_id, p_priority_id) = 'viewer' THEN
            RAISE EXCEPTION 'Viewer members cannot manage twists';
        END IF;
    END IF;
    IF p_owner_id IS DISTINCT FROM user_id THEN
        RAISE EXCEPTION 'owner_id must match user_id';
    END IF;

    INSERT INTO priority_twist (id, priority_id, twist_id, owner_id, name, config, archived_at)
        VALUES (COALESCE(p_id, uuidv7()), p_priority_id, p_twist_id, p_owner_id, p_name, COALESCE(p_config, '{}'::jsonb), p_archived_at)
    ON CONFLICT (id)
        DO UPDATE SET
            name = EXCLUDED.name,
            config = EXCLUDED.config,
            archived_at = EXCLUDED.archived_at,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$function$;

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
    _parent_visual_path ltree;
    _label text;
    _parent_actual_path ltree;
    _actual_path ltree;
    _is_move boolean;
    _is_visual_move boolean := FALSE;
    _user_personal_root_path ltree;
    _old_is_personal boolean;
    _new_is_personal boolean;
    _aliased_root_id uuid;
    _within_aliased_tree boolean;
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
    IF _is_move THEN
        -- Block moving root priorities
        IF _input.root THEN
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
            pu.user_id = upsert_priority.user_id
            AND pu.personal = TRUE
            AND pu.archived_at IS NULL
        LIMIT 1;
        -- Determine if old and new locations are under personal root
        _old_is_personal := (_user_personal_root_path @> _old_actual_path);
        _new_is_personal := (_user_personal_root_path @> _actual_path);
        -- Prevent circular reference
        IF _actual_path <@ _old_actual_path OR _actual_path = _old_actual_path THEN
            RAISE EXCEPTION 'Cannot move priority to be a descendant of itself'
                USING HINT = 'old_path=' || _old_actual_path::text || ', new_path=' || _actual_path::text;
        END IF;
        -- Check if move is within an aliased tree
        _within_aliased_tree := FALSE;
        _aliased_root_id := NULL;
        IF NOT _old_is_personal AND _new_is_personal THEN
            -- Find deepest ancestor where both old and new paths are under the aliased root
            SELECT
                ps.priority_id INTO _aliased_root_id
            FROM
                priority_setting ps
                JOIN priority p ON ps.priority_id = p.id
            WHERE
                ps.user_id = upsert_priority.user_id
                AND ps.key = 'path'
                AND _input.path <@ (ps.value #>> '{}')::ltree
                AND _old.path <@ (ps.value #>> '{}')::ltree
                AND (ps.value #>> '{}')::ltree != p.path
                AND _old_actual_path <@ p.path
                AND _actual_path <@ p.path
            ORDER BY
                nlevel ((ps.value #>> '{}')::ltree) DESC
            LIMIT 1;
            IF _aliased_root_id IS NOT NULL THEN
                _within_aliased_tree := TRUE;
            END IF;
        END IF;
        -- Determine move type and execute appropriate action
        IF _old_is_personal AND _new_is_personal THEN
            -- Type 1a: Actual move within personal tree
            PERFORM
                move_priority (_input.id, _parent_actual_path);
            _actual_path := NULL;
        ELSIF NOT _old_is_personal AND NOT _new_is_personal THEN
            -- Type 1b: Actual move within/between shared trees
            -- Notify users who lose access if the priority moves to a different shared tree
            PERFORM
                notify_displaced_priority_users (_input.id, _old_actual_path, _parent_actual_path);
            PERFORM
                move_priority (_input.id, _parent_actual_path);
            _actual_path := NULL;
        ELSIF NOT _old_is_personal
                AND _new_is_personal
                AND _within_aliased_tree THEN
                -- Type 3: Actual move within aliased tree (no displacement - same root)
                PERFORM
                    move_priority (_input.id, _parent_actual_path);
            _actual_path := NULL;
        ELSIF NOT _old_is_personal
                AND _new_is_personal THEN
                -- Type 4: Actual move from shared tree into personal tree
                -- (was Type 2: visual alias; now corrected to a real path move)
                PERFORM
                    notify_displaced_priority_users (_input.id, _old_actual_path, _parent_actual_path);
                PERFORM
                    move_priority (_input.id, _parent_actual_path);
                _actual_path := NULL;
                -- Clear any existing visual alias now that priority is in the personal tree
                DELETE FROM priority_setting
                WHERE user_id = upsert_priority.user_id AND priority_id = _input.id AND key = 'path';
        ELSIF _old_is_personal
                AND NOT _new_is_personal THEN
                RAISE EXCEPTION 'Cannot move personal priority into shared tree'
                USING HINT = 'Use Share dialog to share a personal priority';
        END IF;
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
        INSERT INTO priority (id, archived_at, title, color, path, created_by, updated_by)
            VALUES (_input.id, _input.archived_at, _input.title, CASE WHEN _is_creator THEN
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
    -- Update priority_setting for user-specific fields
    IF _is_visual_move THEN
        -- Visual move: create/update path alias
        INSERT INTO priority_setting (user_id, priority_id, key, value)
        VALUES (upsert_priority.user_id, _priority_id, 'path', to_jsonb(text(_input.path)))
        ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
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
$function$;

CREATE OR REPLACE FUNCTION "user".upsert_session (
    user_id uuid,
    p_id uuid,
    p_priority_id uuid,
    p_at tstzrange,
    p_precedence smallint,
    p_pomodoro smallint,
    p_pomodoro_at timestamptz,
    p_archived_at timestamptz,
    p_updated_by integer
)
    RETURNS session
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
DECLARE
    v_row session;
BEGIN
    IF p_priority_id IS NOT NULL THEN
        PERFORM "user".assert_priority_access(user_id, p_priority_id);
    END IF;

    IF p_id IS NOT NULL AND EXISTS (
        SELECT
            1
        FROM
            session s
        WHERE
            s.id = p_id
            AND s.user_id <> upsert_session.user_id) THEN
        RAISE EXCEPTION 'Cannot modify another user''s session';
    END IF;

    INSERT INTO session (id, user_id, priority_id, at, precedence, pomodoro, pomodoro_at, archived_at, updated_by)
        VALUES (COALESCE(p_id, uuidv7()), user_id, p_priority_id, p_at, COALESCE(p_precedence, 0), p_pomodoro, p_pomodoro_at, p_archived_at, COALESCE(p_updated_by, 0))
    ON CONFLICT (id)
        DO UPDATE SET
            priority_id = EXCLUDED.priority_id,
            at = EXCLUDED.at,
            precedence = EXCLUDED.precedence,
            pomodoro = EXCLUDED.pomodoro,
            pomodoro_at = EXCLUDED.pomodoro_at,
            archived_at = EXCLUDED.archived_at,
            updated_by = EXCLUDED.updated_by,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$function$;

CREATE OR REPLACE FUNCTION "user".upsert_user_settings (
    user_id uuid,
    p_enter_behavior enter_behavior,
    p_ai_enabled boolean DEFAULT NULL
)
    RETURNS user_settings
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
#variable_conflict use_column
DECLARE
    v_row user_settings;
BEGIN
    INSERT INTO user_settings (user_id, enter_behavior, ai_enabled)
        VALUES (upsert_user_settings.user_id, p_enter_behavior, p_ai_enabled)
    ON CONFLICT (user_id)
        DO UPDATE SET
            enter_behavior = EXCLUDED.enter_behavior,
            ai_enabled = EXCLUDED.ai_enabled,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$function$;

CREATE OR REPLACE FUNCTION "user".upsert_thread_read (
    user_id uuid,
    p_thread_id uuid,
    p_read_at timestamptz,
    p_bumped_at timestamptz DEFAULT NULL::timestamptz
)
    RETURNS thread_read
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
#variable_conflict use_column
DECLARE
    v_priority_id uuid;
    v_row thread_read;
BEGIN
    SELECT
        priority_id INTO v_priority_id
    FROM
        thread
    WHERE
        id = p_thread_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;
    PERFORM "user".assert_priority_access(upsert_thread_read.user_id, v_priority_id);

    INSERT INTO thread_read (user_id, thread_id, read_at, bumped_at)
        VALUES (upsert_thread_read.user_id, p_thread_id, COALESCE(p_read_at, now()), p_bumped_at)
    ON CONFLICT (user_id, thread_id)
        DO UPDATE SET
            read_at = EXCLUDED.read_at,
            bumped_at = CASE WHEN p_bumped_at IS NOT NULL THEN p_bumped_at ELSE thread_read.bumped_at END,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$function$;

CREATE OR REPLACE FUNCTION "user".delete_thread_read (
    user_id uuid,
    p_thread_id uuid
)
    RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
DECLARE
    v_priority_id uuid;
BEGIN
    SELECT
        priority_id INTO v_priority_id
    FROM
        thread
    WHERE
        id = p_thread_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;
    PERFORM "user".assert_priority_access(delete_thread_read.user_id, v_priority_id);

    DELETE FROM thread_read
    WHERE
        thread_read.user_id = delete_thread_read.user_id
        AND thread_read.thread_id = p_thread_id;
END;
$function$;

CREATE OR REPLACE FUNCTION "user".upsert_priority_response_time(
    user_id uuid,
    p_priority_id uuid,
    p_response_window jsonb DEFAULT NULL,
    p_turnaround jsonb DEFAULT NULL,
    p_set_response_window boolean DEFAULT FALSE,
    p_set_turnaround boolean DEFAULT FALSE
) RETURNS void LANGUAGE plpgsql SET search_path TO 'public', 'user' AS $function$
BEGIN
    PERFORM "user".assert_priority_access(
        upsert_priority_response_time.user_id, p_priority_id);
    IF p_set_response_window THEN
        IF p_response_window IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (upsert_priority_response_time.user_id, p_priority_id, 'response_window', p_response_window)
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE user_id = upsert_priority_response_time.user_id
              AND priority_id = p_priority_id AND key = 'response_window';
        END IF;
    END IF;
    IF p_set_turnaround THEN
        IF p_turnaround IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (upsert_priority_response_time.user_id, p_priority_id, 'turnaround', p_turnaround)
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE user_id = upsert_priority_response_time.user_id
              AND priority_id = p_priority_id AND key = 'turnaround';
        END IF;
    END IF;
END; $function$;

