-- Create "fallback_inbox_id" function
CREATE FUNCTION "user"."fallback_inbox_id" ("p_user_id" uuid) RETURNS uuid LANGUAGE sql STABLE AS $$
SELECT inbox.id
    FROM public.role r
    JOIN public.priority inbox
        ON inbox.role_id = r.id
        AND inbox.is_inbox
        AND inbox.archived_at IS NULL
    WHERE r.user_id = p_user_id
        AND r.archived_at IS NULL
    ORDER BY r.created_at ASC
    LIMIT 1;
$$;
-- Modify "effective_priority_id" function
CREATE OR REPLACE FUNCTION "user"."effective_priority_id" ("p_priority_id" uuid, "p_user_id" uuid) RETURNS uuid LANGUAGE sql STABLE AS $$
SELECT
        CASE
        WHEN p_priority_id IS NULL THEN "user".fallback_inbox_id (p_user_id)
        WHEN EXISTS (
            SELECT 1 FROM priority p
            WHERE p.id = p_priority_id AND p.archived_at IS NOT NULL
        ) THEN COALESCE(
            (SELECT inbox.id
                FROM priority arch
                JOIN priority inbox
                    ON inbox.role_id = arch.role_id
                    AND inbox.is_inbox
                    AND inbox.archived_at IS NULL
                WHERE arch.id = p_priority_id),
            "user".fallback_inbox_id (p_user_id))
        ELSE p_priority_id
        END;
$$;
-- Create "upsert_role" function
CREATE FUNCTION "user"."upsert_role" ("user_id" uuid, "p_role" jsonb) RETURNS uuid LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    _role_id uuid := COALESCE((p_role ->> 'id')::uuid, uuidv7 ());
    _exists boolean;
    _archiving boolean := (p_role ? 'archived_at') AND (p_role ->> 'archived_at') IS NOT NULL;
    _root_path ltree;
BEGIN
    -- SELECT EXISTS always yields a boolean row (never NULL on no-match), unlike
    -- SELECT TRUE INTO which assigns NULL when no row matches.
    SELECT
        EXISTS (
            SELECT 1 FROM public.role r
            WHERE r.id = _role_id
                AND r.user_id = upsert_role.user_id) INTO _exists;

    IF _archiving AND _exists THEN
        -- archive-only-when-empty: the role must have no live non-Inbox focuses.
        IF EXISTS (
            SELECT 1 FROM public.priority p
            WHERE p.role_id = _role_id
                AND NOT p.is_inbox
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
            AND is_inbox;
        RETURN _role_id;
    END IF;

    INSERT INTO public.role (id, user_id, created_by, name, color, "order",
        early_notifications_enabled, notify_window, see_within)
        VALUES (_role_id, upsert_role.user_id, upsert_role.user_id,
            COALESCE(p_role ->> 'name', 'Role'),
            COALESCE((p_role ->> 'color')::integer, 0),
            (p_role ->> 'order')::double precision,
            (p_role ->> 'early_notifications_enabled')::boolean,
            CASE WHEN p_role ? 'notify_window' THEN p_role -> 'notify_window' END,
            CASE WHEN p_role ? 'see_within' THEN p_role -> 'see_within' END)
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
                THEN p_role -> 'see_within' ELSE role.see_within END;

    -- New role -> auto-create its Inbox focus.
    IF NOT _exists THEN
        -- Synthesize a child-of-root path (mirrors upsert_priority's flat-client
        -- path synthesis). The Inbox sits directly under the user's root.
        SELECT
            path INTO _root_path
        FROM public.priority
        WHERE public.priority.user_id = upsert_role.user_id
            AND nlevel(path) = 1
        ORDER BY created_at ASC
        LIMIT 1;
        INSERT INTO public.priority (id, user_id, created_by, title, color, is_inbox,
            role_id, early_notifications_enabled, notify_window, see_within, path)
        SELECT
            uuidv7 (), upsert_role.user_id, upsert_role.user_id, 'Inbox', r.color,
            TRUE, r.id, r.early_notifications_enabled, r.notify_window, r.see_within,
            CASE WHEN _root_path IS NULL THEN generate_path (NULL)
                ELSE _root_path || generate_path (NULL) END
        FROM public.role r
        WHERE r.id = _role_id;
    END IF;

    RETURN _role_id;
END;
$$;
