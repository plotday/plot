-- upsert_role — server-side role create/update for /sync/roles (Plan 2).
--
-- Takes the caller's user_id and a partial role row (p_role jsonb) and:
--   1. Upserts the role row (id, name, color, order, the three notification
--      columns). Omitted keys are left unchanged on update.
--   2. On INSERT of a *new* role, also creates that role's Inbox focus AND its
--      FYI focus: priorities with is_inbox / is_fyi = TRUE, role_id = <new role>,
--      and a synthesized child-of-root path (so the still-present
--      validate_priority_root trigger and the path NOT NULL constraint are
--      satisfied during the expand phase). The Inbox copies the role's colour +
--      notification template; the FYI is muted (no notifications) with a fixed
--      newspaper icon. Both get sentinel sidebar orders so they default to the
--      bottom two of the role (Inbox then FYI), below user focuses.
--   3. On ARCHIVE (incoming archived_at non-null on an existing role):
--      refuse if the role still has a non-archived focus other than its Inbox
--      and FYI (archive-only-when-empty), or if it is the user's last
--      non-archived role; otherwise archive the role and its Inbox + FYI focuses.
--
-- Returns the role id.
CREATE OR REPLACE FUNCTION "user".upsert_role (user_id uuid, p_role jsonb)
    RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
-- Resolve ambiguous bare identifiers (e.g. the priority_setting ON CONFLICT
-- target `user_id`, which collides with this function's `user_id` parameter) to
-- the table column, matching upsert_priority.
#variable_conflict use_column
DECLARE
    _role_id uuid := COALESCE((p_role ->> 'id')::uuid, uuidv7 ());
    _exists boolean;
    _archiving boolean := (p_role ? 'archived_at') AND (p_role ->> 'archived_at') IS NOT NULL;
    _root_path ltree;
    _inbox_id uuid;
    _fyi_id uuid;
    -- Sentinel sidebar orders: Inbox then FYI default to the bottom two of the
    -- role; user focuses (now()-epoch-ms order ~1.7e12) sort above them.
    c_inbox_order CONSTANT double precision := 1e15;
    c_fyi_order CONSTANT double precision := 2e15;
BEGIN
    -- SELECT EXISTS always yields a boolean row (never NULL on no-match), unlike
    -- SELECT TRUE INTO which assigns NULL when no row matches.
    SELECT
        EXISTS (
            SELECT 1 FROM public.role r
            WHERE r.id = _role_id
                AND r.user_id = upsert_role.user_id) INTO _exists;

    IF _archiving AND _exists THEN
        -- archive-only-when-empty: the role must have no live focuses other than
        -- its auto-managed Inbox and FYI.
        IF EXISTS (
            SELECT 1 FROM public.priority p
            WHERE p.role_id = _role_id
                AND NOT p.is_inbox
                AND NOT p.is_fyi
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
            AND (is_inbox OR is_fyi);
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

    -- New role -> auto-create its Inbox and FYI focuses.
    IF NOT _exists THEN
        -- Synthesize a child-of-root path (mirrors upsert_priority's flat-client
        -- path synthesis). Both sit directly under the user's root.
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
        WHERE r.id = _role_id
        RETURNING id INTO _inbox_id;
        -- The role's FYI focus: muted (no notifications), fixed newspaper icon,
        -- no key (idx_priority_key_per_root forbids duplicate keys per root; the
        -- FYI is identified by is_fyi).
        INSERT INTO public.priority (id, user_id, created_by, title, color, icon,
            is_fyi, role_id, early_notifications_enabled, path)
        SELECT
            uuidv7 (), upsert_role.user_id, upsert_role.user_id, 'FYI', r.color,
            'newspaper', TRUE, r.id, FALSE,
            CASE WHEN _root_path IS NULL THEN generate_path (NULL)
                ELSE _root_path || generate_path (NULL) END
        FROM public.role r
        WHERE r.id = _role_id
        RETURNING id INTO _fyi_id;
        -- Sentinel sidebar orders so the Inbox then the FYI default to the
        -- bottom two of the role; user focuses (now()-epoch-ms order) sort above.
        INSERT INTO public.priority_setting (user_id, priority_id, key, value)
        VALUES
            (upsert_role.user_id, _inbox_id, 'order', to_jsonb(c_inbox_order)),
            (upsert_role.user_id, _fyi_id, 'order', to_jsonb(c_fyi_order))
        ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
    END IF;

    RETURN _role_id;
END;
$function$;
