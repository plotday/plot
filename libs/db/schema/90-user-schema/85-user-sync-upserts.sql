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

CREATE OR REPLACE FUNCTION "user".upsert_activity_tag (
    user_id uuid,
    p_actor_id uuid,
    p_activity_id uuid,
    p_tag_id integer,
    p_occurrence text DEFAULT NULL::text,
    p_updated_by integer DEFAULT 0,
    p_archived_at timestamptz DEFAULT NULL::timestamptz
)
    RETURNS activity_tag
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
DECLARE
    v_priority_id uuid;
    v_tag_type tag_type;
    v_row activity_tag;
BEGIN
    SELECT
        priority_id INTO v_priority_id
    FROM
        activity
    WHERE
        id = p_activity_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Activity not found';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

    v_tag_type := get_tag_type(p_tag_id);
    IF v_tag_type = 'compute' THEN
        RAISE EXCEPTION 'Cannot add computed tag (tag_id: %)', p_tag_id;
    END IF;
    IF v_tag_type = 'count' AND p_actor_id != "user".user_contact_id(user_id) THEN
        RAISE EXCEPTION 'Cannot modify count tags for other users (tag_id: %)', p_tag_id;
    END IF;

    INSERT INTO activity_tag (actor_id, activity_id, occurrence, tag_id, updated_by, archived_at)
        VALUES (p_actor_id, p_activity_id, p_occurrence, p_tag_id, COALESCE(p_updated_by, 0), p_archived_at)
    ON CONFLICT (actor_id, activity_id, occurrence, tag_id)
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
        JOIN activity a ON a.id = n.activity_id
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

CREATE OR REPLACE FUNCTION "user".upsert_activity_exception (
    user_id uuid,
    p_id uuid,
    p_activity_id uuid,
    p_occurrence text,
    p_archived_at timestamptz DEFAULT NULL::timestamptz,
    p_updated_by integer DEFAULT 0,
    p_at tstzrange DEFAULT NULL::tstzrange,
    p_on daterange DEFAULT NULL::daterange,
    p_duration interval DEFAULT NULL::interval,
    p_done_at timestamptz DEFAULT NULL::timestamptz,
    p_title text DEFAULT NULL::text,
    p_preview text DEFAULT NULL::text,
    p_meta jsonb DEFAULT NULL::jsonb
)
    RETURNS activity_exception
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
DECLARE
    v_priority_id uuid;
    v_row activity_exception;
BEGIN
    SELECT
        priority_id INTO v_priority_id
    FROM
        activity
    WHERE
        id = p_activity_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Activity not found';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

    INSERT INTO activity_exception (id, activity_id, occurrence, archived_at, updated_by, at, "on", duration, done_at, title, preview, meta)
        VALUES (COALESCE(p_id, uuidv7()), p_activity_id, p_occurrence, p_archived_at, COALESCE(p_updated_by, 0), p_at, p_on, p_duration, p_done_at, p_title, p_preview, p_meta)
    ON CONFLICT (activity_id, occurrence)
        DO UPDATE SET
            archived_at = EXCLUDED.archived_at,
            updated_by = EXCLUDED.updated_by,
            at = EXCLUDED.at,
            "on" = EXCLUDED."on",
            duration = EXCLUDED.duration,
            done_at = EXCLUDED.done_at,
            title = EXCLUDED.title,
            preview = EXCLUDED.preview,
            meta = EXCLUDED.meta,
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
    p_activity_id uuid,
    p_draft boolean,
    p_private boolean,
    p_content text,
    p_links jsonb,
    p_mentions uuid[],
    p_re_note_id uuid,
    p_source_created_at timestamptz,
    p_key text
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
        priority_id INTO v_priority_id
    FROM
        activity
    WHERE
        id = p_activity_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Activity not found';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

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
        INSERT INTO note (id, author_id, created_by, updated_by, archived_at, activity_id, draft, private, content, links, mentions, re_note_id, source_created_at, key)
            VALUES (uuidv7(), v_author_id, v_created_by, COALESCE(p_updated_by, 0), p_archived_at, p_activity_id, COALESCE(p_draft, FALSE), COALESCE(p_private, FALSE), p_content, p_links, p_mentions, p_re_note_id, COALESCE(p_source_created_at, now()), p_key)
        ON CONFLICT (activity_id, key)
            DO UPDATE SET
                author_id = EXCLUDED.author_id,
                created_by = EXCLUDED.created_by,
                updated_by = EXCLUDED.updated_by,
                archived_at = EXCLUDED.archived_at,
                draft = EXCLUDED.draft,
                private = EXCLUDED.private,
                content = EXCLUDED.content,
                links = EXCLUDED.links,
                mentions = EXCLUDED.mentions,
                re_note_id = EXCLUDED.re_note_id,
                source_created_at = EXCLUDED.source_created_at,
                key = EXCLUDED.key,
                updated_at = now()
        RETURNING * INTO v_row;
    ELSE
        INSERT INTO note (id, author_id, created_by, updated_by, archived_at, activity_id, draft, private, content, links, mentions, re_note_id, source_created_at, key)
            VALUES (p_id, v_author_id, v_created_by, COALESCE(p_updated_by, 0), p_archived_at, p_activity_id, COALESCE(p_draft, FALSE), COALESCE(p_private, FALSE), p_content, p_links, p_mentions, p_re_note_id, COALESCE(p_source_created_at, now()), p_key)
        ON CONFLICT (id)
            DO UPDATE SET
                author_id = EXCLUDED.author_id,
                created_by = EXCLUDED.created_by,
                updated_by = EXCLUDED.updated_by,
                archived_at = EXCLUDED.archived_at,
                draft = EXCLUDED.draft,
                private = EXCLUDED.private,
                content = EXCLUDED.content,
                links = EXCLUDED.links,
                mentions = EXCLUDED.mentions,
                re_note_id = EXCLUDED.re_note_id,
                source_created_at = EXCLUDED.source_created_at,
                key = EXCLUDED.key,
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
        VALUES (user_id, p_priority_id, p_archived_at, COALESCE(p_personal, FALSE))
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
    PERFORM "user".assert_priority_access(user_id, p_priority_id);
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
DECLARE
    v_row "user"."priority";
BEGIN
    INSERT INTO "user"."priority"
    SELECT
        (jsonb_populate_record(NULL::"user"."priority", p_priority || jsonb_build_object('user_id', user_id))).*
    RETURNING * INTO v_row;

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
    p_enter_behavior enter_behavior
)
    RETURNS user_settings
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
#variable_conflict use_column
DECLARE
    v_row user_settings;
BEGIN
    INSERT INTO user_settings (user_id, enter_behavior)
        VALUES (upsert_user_settings.user_id, p_enter_behavior)
    ON CONFLICT (user_id)
        DO UPDATE SET
            enter_behavior = EXCLUDED.enter_behavior,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$function$;

CREATE OR REPLACE FUNCTION "user".upsert_activity_read (
    user_id uuid,
    p_activity_id uuid,
    p_read_at timestamptz
)
    RETURNS activity_read
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
DECLARE
    v_priority_id uuid;
    v_row activity_read;
BEGIN
    SELECT
        priority_id INTO v_priority_id
    FROM
        activity
    WHERE
        id = p_activity_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Activity not found';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

    INSERT INTO activity_read (user_id, activity_id, read_at)
        VALUES (user_id, p_activity_id, COALESCE(p_read_at, now()))
    ON CONFLICT (user_id, activity_id)
        DO UPDATE SET
            read_at = EXCLUDED.read_at,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$function$;

CREATE OR REPLACE FUNCTION "user".delete_activity_read (
    user_id uuid,
    p_activity_id uuid
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
        activity
    WHERE
        id = p_activity_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Activity not found';
    END IF;
    PERFORM "user".assert_priority_access(delete_activity_read.user_id, v_priority_id);

    DELETE FROM activity_read
    WHERE
        activity_read.user_id = delete_activity_read.user_id
        AND activity_read.activity_id = p_activity_id;
END;
$function$;
