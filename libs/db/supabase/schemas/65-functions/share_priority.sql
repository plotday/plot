-- Function to share a priority with other users/contacts
-- Handles extraction from personal tree when needed
CREATE OR REPLACE FUNCTION public.share_priority (p_user_id uuid, p_priority_id uuid, p_add_actor_ids uuid[], p_remove_actor_ids uuid[])
    RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_priority record;
    v_root_priority_id uuid;
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
        -- Get the root priority ID
        SELECT
            p.id INTO v_root_priority_id
        FROM
            public.priority p
        WHERE
            p.path = subltree (v_priority.path, 0, 1);
        -- Check if root is user's personal priority
        IF v_root_priority_id IS NOT NULL THEN
            SELECT
                EXISTS (
                    SELECT
                        1
                    FROM
                        public.priority_user pu
                    WHERE
                        pu.priority_id = v_root_priority_id
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
            INSERT INTO public.priority_contact (priority_id, contact_id, invited_by, invited_at)
                VALUES (p_priority_id, v_actor_id, p_user_id, now())
            ON CONFLICT (priority_id, contact_id)
                DO UPDATE SET
                    invited_at = now(),
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
            -- Cancel invitation for priority_contact (set invited_at to NULL)
            UPDATE
                public.priority_contact
            SET
                invited_at = NULL
            WHERE
                contact_id = v_actor_id
                AND priority_id = p_priority_id
                AND invited_at IS NOT NULL;
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

-- Restrict access: only service_role can call this function
-- This function performs privileged operations bypassing RLS
REVOKE EXECUTE ON FUNCTION public.share_priority (uuid, uuid, uuid[], uuid[]) FROM PUBLIC;

