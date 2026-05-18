-- Helper to assert user access to a priority. In the per-user model a
-- user can access a priority iff they own it (priority.user_id matches).
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
        SELECT 1
        FROM priority p
        WHERE p.id = assert_priority_access.priority_id
          AND p.user_id = assert_priority_access.user_id
    ) THEN
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
    v_canonical_actor_id uuid;
    v_actor_sibling_ids uuid[];
    v_caller_sibling_ids uuid[];
    v_row thread_tag;
BEGIN
    SELECT
        tp.priority_id INTO v_priority_id
    FROM
        thread_priority tp
    WHERE
        tp.thread_id = p_thread_id
        AND tp.user_id = upsert_thread_tag.user_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;
    PERFORM "user".assert_priority_access(upsert_thread_tag.user_id, v_priority_id);

    v_tag_type := get_tag_type(p_tag_id);
    IF v_tag_type = 'compute' THEN
        RAISE EXCEPTION 'Cannot add computed tag (tag_id: %)', p_tag_id;
    END IF;
    -- Viewer enforcement: viewers can only modify count tags
    IF v_tag_type != 'count' AND "user".get_effective_role(user_id, v_priority_id) = 'viewer' THEN
        RAISE EXCEPTION 'Viewer members can only modify count tags';
    END IF;
    -- Resolve actor to canonical primary id and full linked-contact sibling
    -- set. Linked contacts are equivalent identities for ownership and
    -- storage of tag rows.
    v_canonical_actor_id := "user".canonical_contact_id(p_actor_id);
    v_actor_sibling_ids := "user".sibling_contact_ids(p_actor_id);
    v_caller_sibling_ids := "user".user_contact_ids(user_id);
    IF v_tag_type = 'count' AND NOT (v_actor_sibling_ids && v_caller_sibling_ids) THEN
        RAISE EXCEPTION 'Cannot modify count tags for other users (tag_id: %)', p_tag_id;
    END IF;

    -- Archive any sibling-aliased rows so a single canonical row remains.
    -- This collapses prior writes against a non-primary linked contact id
    -- (e.g. before primary flipped) into the current primary.
    IF p_archived_at IS NULL AND array_length(v_actor_sibling_ids, 1) > 1 THEN
        UPDATE thread_tag
        SET archived_at = now(),
            updated_by = COALESCE(p_updated_by, 0)
        WHERE thread_id = p_thread_id
          AND tag_id = p_tag_id
          AND (occurrence IS NOT DISTINCT FROM p_occurrence)
          AND actor_id = ANY(v_actor_sibling_ids)
          AND actor_id != v_canonical_actor_id
          AND archived_at IS NULL;
    END IF;

    INSERT INTO thread_tag (actor_id, thread_id, occurrence, tag_id, updated_by, archived_at)
        VALUES (v_canonical_actor_id, p_thread_id, p_occurrence, p_tag_id, COALESCE(p_updated_by, 0), p_archived_at)
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
    v_canonical_actor_id uuid;
    v_actor_sibling_ids uuid[];
    v_caller_sibling_ids uuid[];
    v_row note_tag;
BEGIN
    SELECT
        tp.priority_id INTO v_priority_id
    FROM
        note n
        JOIN thread_priority tp ON tp.thread_id = n.thread_id
            AND tp.user_id = upsert_note_tag.user_id
    WHERE
        n.id = p_note_id;
    IF v_priority_id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM note WHERE id = p_note_id) THEN
            RAISE EXCEPTION 'Note not found';
        END IF;
        RAISE EXCEPTION 'User does not have access to this note';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

    v_tag_type := get_tag_type(p_tag_id);
    IF v_tag_type = 'compute' THEN
        RAISE EXCEPTION 'Cannot add computed tag (tag_id: %)', p_tag_id;
    END IF;
    -- Resolve actor to canonical primary id and full linked-contact sibling
    -- set. Linked contacts are equivalent identities.
    v_canonical_actor_id := "user".canonical_contact_id(p_actor_id);
    v_actor_sibling_ids := "user".sibling_contact_ids(p_actor_id);
    v_caller_sibling_ids := "user".user_contact_ids(user_id);
    IF v_tag_type = 'count' AND NOT (v_actor_sibling_ids && v_caller_sibling_ids) THEN
        RAISE EXCEPTION 'Cannot modify count tags for other users (tag_id: %)', p_tag_id;
    END IF;

    -- Archive any sibling-aliased rows so a single canonical row remains.
    IF p_archived_at IS NULL AND array_length(v_actor_sibling_ids, 1) > 1 THEN
        UPDATE note_tag
        SET archived_at = now(),
            updated_by = COALESCE(p_updated_by, 0)
        WHERE note_id = p_note_id
          AND tag_id = p_tag_id
          AND actor_id = ANY(v_actor_sibling_ids)
          AND actor_id != v_canonical_actor_id
          AND archived_at IS NULL;
    END IF;

    INSERT INTO note_tag (actor_id, note_id, tag_id, updated_by, archived_at)
        VALUES (v_canonical_actor_id, p_note_id, p_tag_id, COALESCE(p_updated_by, 0), p_archived_at)
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
    p_access_contacts uuid[],
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
    v_row note;
BEGIN
    SELECT
        tp.priority_id INTO v_priority_id
    FROM
        thread_priority tp
    WHERE
        tp.thread_id = p_thread_id
        AND tp.user_id = upsert_note.user_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;

    -- Visibility is established by the thread_priority lookup above. The
    -- read-only viewer gate below uses user_has_thread_write_access(), which
    -- accepts write access via contacts OR non-announce group membership OR
    -- admin of an announce group, and forces announce-only viewers down the
    -- access_contacts path. Don't add a stricter contacts-only check here —
    -- it silently strands notes from users whose write access comes via
    -- group membership rather than direct contact in thread.contacts.

    v_created_by := COALESCE(p_created_by, user_id);
    -- When the user creates directly (not via twist), force author to their contact ID.
    -- This prevents impersonation: clients cannot spoof author_id.
    -- When a twist creates (created_by != user_id), trust the provided author_id.
    IF v_created_by = user_id THEN
        v_author_id := COALESCE("user".user_contact_id(user_id), user_id);
    ELSE
        v_author_id := COALESCE(p_author_id, v_created_by);
    END IF;

    -- Read-only viewer gate. When the writer is a user (not a twist) and
    -- lacks write access to the thread (i.e. only sees it via an announce
    -- group), they may only post private notes that they author and may not
    -- edit other authors' notes.
    IF v_created_by = upsert_note.user_id
       AND NOT "user".user_has_thread_write_access(upsert_note.user_id, p_thread_id)
    THEN
        IF p_access_contacts IS NULL THEN
            RAISE EXCEPTION 'Read-only viewers must scope notes via access_contacts';
        END IF;
        IF p_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM note
            WHERE id = p_id
              AND author_id IS DISTINCT FROM v_author_id
        ) THEN
            RAISE EXCEPTION 'User cannot edit another author''s note';
        END IF;
    END IF;

    IF v_created_by IS DISTINCT FROM user_id THEN
        IF NOT EXISTS (
            SELECT
                1
            FROM
                twist_instance pt
            WHERE
                pt.id = v_created_by
                AND pt.owner_id = upsert_note.user_id) THEN
            RAISE EXCEPTION 'created_by must be user or owned twist_instance';
        END IF;
    END IF;

    IF p_id IS NULL THEN
        INSERT INTO note (id, author_id, created_by, updated_by, archived_at, thread_id, draft, access_contacts, content, actions, mentions, re_note_id, source_created_at, key, merged_from_thread_id)
            VALUES (uuidv7(), v_author_id, v_created_by, COALESCE(p_updated_by, 0), p_archived_at, p_thread_id, COALESCE(p_draft, FALSE), p_access_contacts, p_content, p_actions, p_mentions, p_re_note_id, COALESCE(p_source_created_at, now()), p_key, p_merged_from_thread_id)
        ON CONFLICT (thread_id, link_id, key)
            WHERE key IS NOT NULL
            DO UPDATE SET
                author_id = note.author_id,
                created_by = note.created_by,
                updated_by = EXCLUDED.updated_by,
                archived_at = EXCLUDED.archived_at,
                draft = EXCLUDED.draft,
                access_contacts = EXCLUDED.access_contacts,
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
        INSERT INTO note (id, author_id, created_by, updated_by, archived_at, thread_id, draft, access_contacts, content, actions, mentions, re_note_id, source_created_at, key, merged_from_thread_id)
            VALUES (p_id, v_author_id, v_created_by, COALESCE(p_updated_by, 0), p_archived_at, p_thread_id, COALESCE(p_draft, FALSE), p_access_contacts, p_content, p_actions, p_mentions, p_re_note_id, COALESCE(p_source_created_at, now()), p_key, p_merged_from_thread_id)
        ON CONFLICT (id)
            DO UPDATE SET
                author_id = note.author_id,
                created_by = note.created_by,
                updated_by = EXCLUDED.updated_by,
                archived_at = EXCLUDED.archived_at,
                thread_id = EXCLUDED.thread_id,
                draft = EXCLUDED.draft,
                access_contacts = EXCLUDED.access_contacts,
                content = EXCLUDED.content,
                actions = EXCLUDED.actions,
                mentions = EXCLUDED.mentions,
                re_note_id = EXCLUDED.re_note_id,
                source_created_at = EXCLUDED.source_created_at,
                key = COALESCE(EXCLUDED.key, note.key),
                merged_from_thread_id = EXCLUDED.merged_from_thread_id,
                updated_at = now()
        RETURNING * INTO v_row;
    END IF;

    RETURN v_row;
END;
$function$;

CREATE OR REPLACE FUNCTION "user".upsert_twist_instance (
    user_id uuid,
    p_id uuid,
    p_twist_id bigint,
    p_owner_id uuid,
    p_team_id bigint,
    p_name text,
    p_account_label text,
    p_config jsonb,
    p_archived_at timestamptz
)
    RETURNS twist_instance
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
DECLARE
    v_row twist_instance;
BEGIN
    -- Twist instances are owned by a user and optionally billed to a team.
    -- The caller can only manage their own instances.
    IF p_owner_id IS DISTINCT FROM user_id THEN
        RAISE EXCEPTION 'owner_id must match user_id';
    END IF;

    -- If a team is specified, the caller must be a member.
    IF p_team_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM team_user
            WHERE team_id = p_team_id AND team_user.user_id = upsert_twist_instance.user_id
        ) THEN
            RAISE EXCEPTION 'User is not a member of team %', p_team_id;
        END IF;
    END IF;

    INSERT INTO twist_instance (id, twist_id, owner_id, team_id, name, account_label, options, archived_at)
        VALUES (COALESCE(p_id, uuidv7()), p_twist_id, p_owner_id, p_team_id, p_name, p_account_label, COALESCE(p_config, '{}'::jsonb), p_archived_at)
    ON CONFLICT (id)
        DO UPDATE SET
            name = EXCLUDED.name,
            account_label = EXCLUDED.account_label,
            team_id = EXCLUDED.team_id,
            options = EXCLUDED.options,
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
    p_updated_by integer,
    p_source text DEFAULT 'active',
    p_schedule_id uuid DEFAULT NULL,
    p_occurrence_at timestamptz DEFAULT NULL,
    p_explicit boolean DEFAULT NULL
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

    INSERT INTO session (id, user_id, priority_id, at, precedence, pomodoro, pomodoro_at, archived_at, updated_by, source, schedule_id, occurrence_at, explicit)
        VALUES (
            COALESCE(p_id, uuidv7()),
            user_id,
            p_priority_id,
            p_at,
            COALESCE(p_precedence, 0),
            p_pomodoro,
            p_pomodoro_at,
            p_archived_at,
            COALESCE(p_updated_by, 0),
            COALESCE(p_source, 'active'),
            p_schedule_id,
            p_occurrence_at,
            COALESCE(p_explicit, true)
        )
    ON CONFLICT (id)
        DO UPDATE SET
            priority_id = EXCLUDED.priority_id,
            at = EXCLUDED.at,
            precedence = EXCLUDED.precedence,
            pomodoro = EXCLUDED.pomodoro,
            pomodoro_at = EXCLUDED.pomodoro_at,
            archived_at = EXCLUDED.archived_at,
            updated_by = EXCLUDED.updated_by,
            -- Source/schedule_id/occurrence_at are immutable per session row;
            -- COALESCE so a partial update from the client doesn't clobber them.
            source = COALESCE(EXCLUDED.source, session.source),
            schedule_id = COALESCE(EXCLUDED.schedule_id, session.schedule_id),
            occurrence_at = COALESCE(EXCLUDED.occurrence_at, session.occurrence_at),
            -- Explicit can flip from false -> true (AddTime promotes an
            -- auto-start) but otherwise honors the client value when
            -- provided; NULL means "no change", preserving existing.
            explicit = COALESCE(EXCLUDED.explicit, session.explicit),
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$function$;

CREATE OR REPLACE FUNCTION "user".upsert_user_settings (
    user_id uuid,
    p_enter_behavior enter_behavior,
    p_ai_enabled boolean DEFAULT NULL,
    p_onboarding_completed boolean DEFAULT NULL,
    -- Pass `'1970-01-01T00:00:00Z'::timestamptz` to clear (resume tracking).
    -- NULL leaves the value unchanged so an offline-only field update doesn't
    -- clobber a paused state set on another device.
    p_tracking_paused_at timestamptz DEFAULT NULL
)
    RETURNS user_settings
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
#variable_conflict use_column
DECLARE
    v_row user_settings;
BEGIN
    INSERT INTO user_settings (user_id, enter_behavior, ai_enabled, onboarding_completed, tracking_paused_at)
        VALUES (
            upsert_user_settings.user_id,
            p_enter_behavior,
            p_ai_enabled,
            p_onboarding_completed,
            CASE
                WHEN p_tracking_paused_at = '1970-01-01T00:00:00Z'::timestamptz THEN NULL
                ELSE p_tracking_paused_at
            END
        )
    ON CONFLICT (user_id)
        DO UPDATE SET
            enter_behavior = EXCLUDED.enter_behavior,
            ai_enabled = EXCLUDED.ai_enabled,
            -- Once true, stay true: don't let a NULL from a device that hasn't
            -- pulled yet clobber completion set by another device.
            onboarding_completed = COALESCE(EXCLUDED.onboarding_completed, user_settings.onboarding_completed),
            tracking_paused_at = CASE
                -- Sentinel epoch means "explicit clear" (resume).
                WHEN p_tracking_paused_at = '1970-01-01T00:00:00Z'::timestamptz THEN NULL
                -- NULL from the client means "no change", preserve existing.
                WHEN p_tracking_paused_at IS NULL THEN user_settings.tracking_paused_at
                ELSE p_tracking_paused_at
            END,
            updated_at = now()
    RETURNING * INTO v_row;

    -- Retroactive pause reconciliation: when pause was just set (or moved
    -- earlier), archive any non-archived 'event' session rows for this user
    -- whose recorded interval starts at or after the paused instant. Sessions
    -- of source='active' or 'manual' are user-authored and not touched.
    IF v_row.tracking_paused_at IS NOT NULL THEN
        UPDATE public.session
        SET archived_at = now()
        WHERE user_id = upsert_user_settings.user_id
            AND source = 'event'
            AND archived_at IS NULL
            AND lower(at) >= v_row.tracking_paused_at;
    END IF;

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
        tp.priority_id INTO v_priority_id
    FROM
        thread_priority tp
    WHERE
        tp.thread_id = p_thread_id
        AND tp.user_id = upsert_thread_read.user_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;

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
        tp.priority_id INTO v_priority_id
    FROM
        thread_priority tp
    WHERE
        tp.thread_id = p_thread_id
        AND tp.user_id = delete_thread_read.user_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;

    DELETE FROM thread_read
    WHERE
        thread_read.user_id = delete_thread_read.user_id
        AND thread_read.thread_id = p_thread_id;
END;
$function$;

-- PRECISION BOUNDARY: JavaScript Date (used by the pg driver and client apps)
-- has only millisecond precision, but PostgreSQL timestamptz has microsecond
-- precision. Any >= / <= / = comparison between a client-provided timestamp and
-- a database-stored timestamp MUST truncate the DB value with
-- date_trunc('milliseconds', ...) to avoid sub-millisecond mismatches causing
-- silent failures. See also: updatedSinceCursor() in
-- workers/api/src/app/sync/helpers.ts which documents the same pattern.

CREATE OR REPLACE FUNCTION "user".upsert_thread_unread (
    user_id uuid,
    p_thread_id uuid,
    p_urgency text,
    p_importance smallint DEFAULT 50,
    p_read_at timestamptz DEFAULT NULL::timestamptz,
    p_bumped_at timestamptz DEFAULT NULL::timestamptz,
    p_note_created_at timestamptz DEFAULT NULL::timestamptz
)
    RETURNS thread_unread
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
#variable_conflict use_column
DECLARE
    v_priority_id uuid;
    v_row thread_unread;
BEGIN
    SELECT
        tp.priority_id INTO v_priority_id
    FROM
        thread_priority tp
    WHERE
        tp.thread_id = p_thread_id
        AND tp.user_id = upsert_thread_unread.user_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;

    INSERT INTO thread_unread (user_id, thread_id, urgency, importance, read_at, bumped_at)
        VALUES (upsert_thread_unread.user_id, p_thread_id, p_urgency, p_importance, p_read_at, p_bumped_at)
    ON CONFLICT (user_id, thread_id)
        DO UPDATE SET
            urgency = EXCLUDED.urgency,
            importance = EXCLUDED.importance,
            read_at = CASE
                -- Race condition: user read after the note was created → preserve their read
                -- Truncate to ms precision (see PRECISION BOUNDARY comment above)
                WHEN p_note_created_at IS NOT NULL
                    AND thread_unread.read_at IS NOT NULL
                    AND thread_unread.read_at >= date_trunc('milliseconds', p_note_created_at)
                THEN thread_unread.read_at
                -- New activity or no timestamp context: use caller's value (NULL = unread)
                ELSE EXCLUDED.read_at
            END,
            bumped_at = CASE WHEN p_bumped_at IS NOT NULL THEN p_bumped_at ELSE thread_unread.bumped_at END,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$function$;

CREATE OR REPLACE FUNCTION "user".clear_thread_unread (
    user_id uuid,
    p_thread_id uuid,
    p_read_at timestamptz DEFAULT now(),
    p_bumped_at timestamptz DEFAULT NULL
)
    RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
#variable_conflict use_column
DECLARE
    v_priority_id uuid;
BEGIN
    SELECT
        tp.priority_id INTO v_priority_id
    FROM
        thread_priority tp
    WHERE
        tp.thread_id = p_thread_id
        AND tp.user_id = clear_thread_unread.user_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;

    -- Upsert to handle the race where the user reads a thread before analysis
    -- creates the thread_unread row. If no row exists, INSERT a preemptive read
    -- marker so that when analysis later calls upsert_thread_unread, the
    -- race guard (read_at >= note_created_at) preserves it.
    -- If a row exists, the read_at clear is gated on the client having seen
    -- all current content (p_read_at >= thread's content timestamp). The
    -- bumped_at write is independent: bumping is a user action (Finish) and
    -- must always apply, even when read_at is already set.
    -- Truncate DB timestamp to ms precision (see PRECISION BOUNDARY comment above)
    INSERT INTO thread_unread (user_id, thread_id, urgency, importance, read_at, bumped_at)
        VALUES (clear_thread_unread.user_id, p_thread_id, 'inform-updates', 50, p_read_at, p_bumped_at)
    ON CONFLICT (user_id, thread_id)
        DO UPDATE SET
            read_at = CASE
                WHEN thread_unread.read_at IS NULL
                    AND p_read_at >= date_trunc('milliseconds', (
                        SELECT COALESCE(t.last_note_source_created_at, t.created_at)
                        FROM thread t
                        WHERE t.id = p_thread_id
                    ))
                THEN p_read_at
                ELSE thread_unread.read_at
            END,
            bumped_at = CASE WHEN p_bumped_at IS NOT NULL THEN p_bumped_at ELSE thread_unread.bumped_at END,
            updated_at = now()
        WHERE
            p_bumped_at IS NOT NULL
            OR (thread_unread.read_at IS NULL
                AND p_read_at >= date_trunc('milliseconds', (
                    SELECT COALESCE(t.last_note_source_created_at, t.created_at)
                    FROM thread t
                    WHERE t.id = p_thread_id
                )));
END;
$function$;

CREATE OR REPLACE FUNCTION "user".upsert_priority_attention(
    p_user_id uuid,
    p_priority_id uuid,
    p_attention_window jsonb DEFAULT NULL,
    p_set_attention_window boolean DEFAULT FALSE,
    p_see_within_requests jsonb DEFAULT NULL,
    p_see_within_updates jsonb DEFAULT NULL,
    p_set_see_within_requests boolean DEFAULT FALSE,
    p_set_see_within_updates boolean DEFAULT FALSE
) RETURNS void LANGUAGE plpgsql SET search_path TO 'public', 'user' AS $function$
BEGIN
    PERFORM "user".assert_priority_access(p_user_id, p_priority_id);
    IF p_set_attention_window THEN
        IF p_attention_window IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (p_user_id, p_priority_id, 'attention_window', p_attention_window)
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE priority_setting.user_id = p_user_id
              AND priority_setting.priority_id = p_priority_id AND key = 'attention_window';
        END IF;
    END IF;
    IF p_set_see_within_requests THEN
        IF p_see_within_requests IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (p_user_id, p_priority_id, 'see_within_requests', p_see_within_requests)
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE priority_setting.user_id = p_user_id
              AND priority_setting.priority_id = p_priority_id AND key = 'see_within_requests';
        END IF;
    END IF;
    IF p_set_see_within_updates THEN
        IF p_see_within_updates IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (p_user_id, p_priority_id, 'see_within_updates', p_see_within_updates)
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE priority_setting.user_id = p_user_id
              AND priority_setting.priority_id = p_priority_id AND key = 'see_within_updates';
        END IF;
    END IF;
END; $function$;

-- Upsert a priority_block row, keyed on (priority_id, effective_at).
-- Clients use `effective_at = 'epoch'` for the canonical "current" row
-- (one per priority) and a future timestamp for planned changes. The
-- unique index on (priority_id, effective_at) enforces at-most-one row
-- per slot, so successive adjustments to current pending overwrite in
-- place rather than appending to a timeline.
CREATE OR REPLACE FUNCTION "user".upsert_priority_block (
    user_id uuid,
    p_block jsonb
)
    RETURNS "user"."priority_block"
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
#variable_conflict use_column
DECLARE
    _input "user"."priority_block";
    _new_id uuid;
    v_row "user"."priority_block";
BEGIN
    _input := jsonb_populate_record(NULL::"user"."priority_block", p_block || jsonb_build_object('user_id', upsert_priority_block.user_id));

    PERFORM "user".assert_priority_access(upsert_priority_block.user_id, _input.priority_id);

    INSERT INTO priority_block (id, priority_id, user_id, order_value, effective_at, duration, archived_at, created_by, updated_by)
        VALUES (
            COALESCE(_input.id, uuidv7()),
            _input.priority_id,
            upsert_priority_block.user_id,
            _input.order_value,
            _input.effective_at,
            _input.duration,
            _input.archived_at,
            _input.created_by,
            COALESCE(_input.updated_by, 0)
        )
    ON CONFLICT (priority_id, effective_at)
        DO UPDATE SET
            order_value = EXCLUDED.order_value,
            duration = EXCLUDED.duration,
            archived_at = EXCLUDED.archived_at,
            updated_by = EXCLUDED.updated_by
        RETURNING id INTO _new_id;

    SELECT * INTO v_row
    FROM "user".priority_block
    WHERE id = _new_id AND user_id = upsert_priority_block.user_id;

    RETURN v_row;
END;
$function$;

