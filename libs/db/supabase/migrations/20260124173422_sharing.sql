SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.sync_user_for_priority_user ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_users_to_notify uuid[] := '{}';
    v_user_id uuid;
    v_prev_update_at timestamptz;
    v_prev_sync_at timestamptz;
    v_current_sync_at timestamptz;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users with access to the priority (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN user_priority_expanded upe ON upe.priority_id = n.priority_id
    WHERE
        upe.archived_at IS NULL LOOP
            SELECT
                last_update_at,
                last_sync_at INTO v_prev_update_at,
                v_prev_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'priority_member';
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'priority_member', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
            SELECT
                last_sync_at INTO v_current_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'priority_member';
            IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at) THEN
                v_users_to_notify := array_append(v_users_to_notify, v_user_id);
            END IF;
        END LOOP;
    IF array_length(v_users_to_notify, 1) > 0 THEN
        PERFORM
            call_user_sync_api (v_users_to_notify);
    END IF;
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.accept_invitations_on_signup ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $function$
DECLARE
    v_contact_id uuid;
BEGIN
    -- Get the contact_id for this user (by email)
    SELECT
        id INTO v_contact_id
    FROM
        public.contact
    WHERE
        email = NEW.email
        AND archived_at IS NULL;
    IF v_contact_id IS NOT NULL THEN
        -- Create priority_user entries for pending invitations (from priority_contact)
        INSERT INTO public.priority_user (user_id, priority_id)
        SELECT
            NEW.id,
            pc.priority_id
        FROM
            public.priority_contact pc
        WHERE
            pc.contact_id = v_contact_id
            AND pc.archived_at IS NULL
        ON CONFLICT
            DO NOTHING;
        -- Note: priority_contact remains - status changes from 'invited' to 'accepted' in priority_member view
        -- Activate the user (creates root priority, settings, sets status to active)
        -- This is idempotent and safe to call multiple times
        PERFORM
            public.activate_invited_user (NEW.id);
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE VIEW "public"."priority_member" AS
SELECT
    pc.contact_id,
    pc.priority_id,
    pc.created_at,
    GREATEST (pc.created_at, COALESCE(pu.updated_at, pc.created_at)) AS updated_at,
    COALESCE(pc.archived_at, pu.archived_at) AS archived_at,
    CASE WHEN ((c.user_id IS NOT NULL)
        AND (pu.user_id IS NOT NULL)) THEN
        'accepted'::text
    ELSE
        'invited'::text
    END AS status,
    pc.invited_by,
    COALESCE(pu.personal, FALSE) AS personal
FROM ((priority_contact pc
        JOIN contact c ON (c.id = pc.contact_id))
    LEFT JOIN priority_user pu ON (((pu.user_id = c.user_id)
                AND (pu.priority_id = pc.priority_id)
                AND (pu.archived_at IS NULL))))
WHERE (((pu.user_id IS NOT NULL)
        OR (pc.invited_by IS NOT NULL))
    AND (pc.archived_at IS NULL));

CREATE OR REPLACE FUNCTION public.redeem_invitation_token (p_user_id uuid, p_token text)
    RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_contact_id uuid;
    v_contact_user_id uuid;
BEGIN
    -- Find contact_invitation with this token
    SELECT
        ci.contact_id,
        c.user_id INTO v_contact_id,
        v_contact_user_id
    FROM
        public.contact_invitation ci
        JOIN public.contact c ON c.id = ci.contact_id
    WHERE
        ci.token = p_token;
    IF v_contact_id IS NULL THEN
        RETURN jsonb_build_object('success', FALSE, 'error', 'invalid_token');
    END IF;
    -- Check if contact already linked to a DIFFERENT user
    IF v_contact_user_id IS NOT NULL AND v_contact_user_id != p_user_id THEN
        RETURN jsonb_build_object('success', FALSE, 'error', 'contact_linked_to_other_user');
    END IF;
    -- Link contact to user (if not already linked)
    UPDATE
        public.contact
    SET
        user_id = p_user_id
    WHERE
        id = v_contact_id
        AND (user_id IS NULL
            OR user_id = p_user_id);
    -- Delete the invitation token (one-time use)
    DELETE FROM public.contact_invitation
    WHERE contact_id = v_contact_id;
    -- Accept any pending invitations for this contact (from priority_contact)
    INSERT INTO public.priority_user (user_id, priority_id)
    SELECT
        p_user_id,
        pc.priority_id
    FROM
        public.priority_contact pc
    WHERE
        pc.contact_id = v_contact_id
        AND pc.archived_at IS NULL
    ON CONFLICT
        DO NOTHING;
    -- Note: priority_contact remains - status changes from 'invited' to 'accepted' in priority_member view
    -- Activate the user (creates root priority, settings, sets status to active)
    -- This is idempotent and safe to call multiple times
    PERFORM
        public.activate_invited_user (p_user_id);
    RETURN jsonb_build_object('success', TRUE, 'contact_id', v_contact_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.share_priority (p_user_id uuid, p_priority_id uuid, p_add_actor_ids uuid[], p_remove_actor_ids uuid[])
    RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_priority record;
    v_root_priority record;
    v_is_under_personal boolean := FALSE;
    v_old_path ltree;
    v_new_path ltree;
    v_extracted boolean := FALSE;
    v_actor_id uuid;
    v_contact record;
    v_priority_label text;
BEGIN
    -- Validate user has access to the priority
    IF NOT public.user_has_priority_access (p_user_id, p_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;
    -- Get priority details
    SELECT
        * INTO v_priority
    FROM
        public.priority
    WHERE
        id = p_priority_id;
    IF v_priority IS NULL THEN
        RAISE EXCEPTION 'Priority not found';
    END IF;
    v_old_path := v_priority.path;
    -- Check if extraction is needed:
    -- 1. Priority is NOT at top level (nlevel > 1)
    -- 2. Top-level priority is user's personal root
    IF nlevel (v_priority.path) > 1 THEN
        -- Get the root priority
        SELECT
            p.* INTO v_root_priority
        FROM
            public.priority p
        WHERE
            p.path = subltree (v_priority.path, 0, 1);
        -- Check if root is user's personal priority
        IF v_root_priority IS NOT NULL THEN
            SELECT
                EXISTS (
                    SELECT
                        1
                    FROM
                        public.priority_user pu
                    WHERE
                        pu.priority_id = v_root_priority.id
                        AND pu.user_id = p_user_id
                        AND pu.personal = TRUE
                        AND pu.archived_at IS NULL) INTO v_is_under_personal;
        END IF;
    END IF;
    -- Perform extraction if needed
    IF v_is_under_personal THEN
        -- Generate new top-level path
        v_new_path := public.generate_path (NULL);
        -- Update priority and all descendants
        -- Extract the last label from the current path (the priority's own identifier)
        v_priority_label := ltree2text (subpath (v_old_path, -1));
        -- The new root path is the generated path for the priority itself
        -- For descendants, append their relative path from the old location
        UPDATE
            public.priority
        SET
            path = CASE WHEN path = v_old_path THEN
                v_new_path
            ELSE
                -- For descendants, replace the old path prefix with the new path
                text2ltree (ltree2text (v_new_path) || ltree2text (subpath (path, nlevel (v_old_path))))
            END
        WHERE
            path <@ v_old_path
            OR path = v_old_path;
        -- Create priority_settings with old path to preserve visual location
        INSERT INTO public.priority_settings (user_id, priority_id, path)
            VALUES (p_user_id, p_priority_id, v_old_path)
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET
                path = EXCLUDED.path;
        -- Create priority_user for current user (non-personal) for the extracted priority
        INSERT INTO public.priority_user (user_id, priority_id, personal)
            VALUES (p_user_id, p_priority_id, FALSE)
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET
                archived_at = NULL;
        v_extracted := TRUE;
    END IF;
    -- Process additions
    IF p_add_actor_ids IS NOT NULL THEN
        FOREACH v_actor_id IN ARRAY p_add_actor_ids LOOP
            -- Get contact info to check if user_id is set
            SELECT
                * INTO v_contact
            FROM
                public.contact
            WHERE
                id = v_actor_id
                AND archived_at IS NULL;
            IF v_contact IS NULL THEN
                -- Skip invalid actor_ids
                CONTINUE;
            END IF;
            -- Create priority_contact for all contacts (both users and non-users)
            INSERT INTO public.priority_contact (priority_id, contact_id, invited_by)
                VALUES (p_priority_id, v_actor_id, p_user_id)
            ON CONFLICT (priority_id, contact_id)
                DO UPDATE SET
                    archived_at = NULL,
                    invited_by = COALESCE(priority_contact.invited_by, EXCLUDED.invited_by);
            IF v_contact.user_id IS NOT NULL THEN
                -- Contact is an existing user - also create priority_user
                INSERT INTO public.priority_user (user_id, priority_id, personal)
                    VALUES (v_contact.user_id, p_priority_id, FALSE)
                ON CONFLICT (user_id, priority_id)
                    DO UPDATE SET
                        archived_at = NULL;
            END IF;
        END LOOP;
    END IF;
    -- Process removals
    IF p_remove_actor_ids IS NOT NULL THEN
        FOREACH v_actor_id IN ARRAY p_remove_actor_ids LOOP
            -- Get contact info
            SELECT
                * INTO v_contact
            FROM
                public.contact
            WHERE
                id = v_actor_id;
            IF v_contact IS NULL THEN
                -- Skip invalid actor_ids
                CONTINUE;
            END IF;
            -- Archive priority_contact (for all contacts)
            UPDATE
                public.priority_contact
            SET
                archived_at = now()
            WHERE
                contact_id = v_actor_id
                AND priority_id = p_priority_id
                AND archived_at IS NULL;
            IF v_contact.user_id IS NOT NULL THEN
                -- Archive priority_user for users
                UPDATE
                    public.priority_user
                SET
                    archived_at = now()
                WHERE
                    user_id = v_contact.user_id
                    AND priority_id = p_priority_id
                    AND archived_at IS NULL;
            END IF;
        END LOOP;
    END IF;
    -- Return result
    RETURN jsonb_build_object('id', p_priority_id, 'extracted', v_extracted, 'oldPath', CASE WHEN v_extracted THEN
            ltree2text (v_old_path)
        ELSE
            NULL
        END, 'newPath', CASE WHEN v_extracted THEN
            ltree2text (v_new_path)
        ELSE
            ltree2text (v_old_path)
        END);
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_user_for_priority_contact ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_users_to_notify_actor uuid[] := '{}';
    v_users_to_notify_member uuid[] := '{}';
    v_user_id uuid;
    v_prev_update_at timestamptz;
    v_prev_sync_at timestamptz;
    v_current_sync_at timestamptz;
BEGIN
    -- priority_contact doesn't have updated_at, use created_at or archived_at
    SELECT
        MAX(GREATEST (created_at, COALESCE(archived_at, created_at))) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users with access to the priority (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN user_priority_expanded upe ON upe.priority_id = n.priority_id
    WHERE
        upe.archived_at IS NULL LOOP
            -- Handle actor entity (priority_contact contributes to actor view)
            SELECT
                last_update_at,
                last_sync_at INTO v_prev_update_at,
                v_prev_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'actor';
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'actor', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
            SELECT
                last_sync_at INTO v_current_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'actor';
            IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at) THEN
                v_users_to_notify_actor := array_append(v_users_to_notify_actor, v_user_id);
            END IF;
            -- Handle priority_member entity (priority_contact contributes to priority_member view)
            SELECT
                last_update_at,
                last_sync_at INTO v_prev_update_at,
                v_prev_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'priority_member';
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'priority_member', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
            SELECT
                last_sync_at INTO v_current_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'priority_member';
            IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at) THEN
                v_users_to_notify_member := array_append(v_users_to_notify_member, v_user_id);
            END IF;
        END LOOP;
    IF array_length(v_users_to_notify_actor, 1) > 0 THEN
        PERFORM
            call_user_sync_api (v_users_to_notify_actor);
    END IF;
    IF array_length(v_users_to_notify_member, 1) > 0 THEN
        PERFORM
            call_user_sync_api (v_users_to_notify_member);
    END IF;
    RETURN NULL;
END;
$function$;

CREATE TRIGGER user_sync_priority_user_insert
    AFTER INSERT ON public.priority_user REFERENCING NEW TABLE AS new_table
    FOR EACH STATEMENT
    EXECUTE FUNCTION sync_user_for_priority_user ();

CREATE TRIGGER user_sync_priority_user_update
    AFTER UPDATE ON public.priority_user REFERENCING NEW TABLE AS new_table
    FOR EACH STATEMENT
    EXECUTE FUNCTION sync_user_for_priority_user ();

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
