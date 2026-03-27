-- Modify "share_priority" function
CREATE OR REPLACE FUNCTION "public"."share_priority" ("p_user_id" uuid, "p_priority_id" uuid, "p_add_actor_ids" uuid[], "p_remove_actor_ids" uuid[], "p_role" text DEFAULT 'member') RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
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
    v_recipient_org_root record;
    v_child record;
    v_relative ltree;
    v_target_path ltree;
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
        -- Check if root is user's personal priority or an org root
        IF v_root_priority_id IS NOT NULL THEN
            SELECT
                EXISTS (
                    SELECT
                        1
                    FROM
                        public.priority_user pu
                        JOIN public.priority rp ON rp.id = pu.priority_id
                    WHERE
                        pu.priority_id = v_root_priority_id
                        AND pu.user_id = p_user_id
                        AND (pu.personal = TRUE OR rp.organization_id IS NOT NULL)
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
                text2ltree (ltree2text (v_new_path) || '.' || ltree2text (subpath (path, nlevel (v_old_path))))
            END
        WHERE
            path <@ v_old_path
            OR path = v_old_path;
        -- Create priority_setting with old path to preserve visual location
        INSERT INTO public.priority_setting (user_id, priority_id, key, value)
            VALUES (p_user_id, p_priority_id, 'path', to_jsonb(ltree2text(v_old_path)))
        ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        -- Create priority_user for current user (non-personal) for the extracted priority
        INSERT INTO public.priority_user (user_id, priority_id, personal)
            VALUES (p_user_id, p_priority_id, FALSE)
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET
                archived_at = NULL,
                personal = FALSE;
        v_extracted := TRUE;
        -- Re-nest previously extracted children back under the new path.
        -- When children were shared/extracted before the parent, they got their own
        -- top-level paths. Now that the parent is being shared, move them back under
        -- it so the hierarchy is correct for future sharing.
        FOR v_child IN
            SELECT ps.priority_id AS child_id,
                   (ps.value #>> '{}')::ltree AS alias_path,
                   cp.path AS current_path
            FROM public.priority_setting ps
            JOIN public.priority cp ON cp.id = ps.priority_id
            WHERE ps.user_id = p_user_id
              AND ps.key = 'path'
              AND (ps.value #>> '{}')::ltree <@ v_old_path
              AND (ps.value #>> '{}')::ltree != v_old_path
              AND NOT (cp.path <@ v_new_path)
            ORDER BY nlevel((ps.value #>> '{}')::ltree) ASC
        LOOP
            -- Compute relative position from old parent path
            -- e.g. alias 'k.plot.a' relative to old path 'k.plot' gives 'a'
            v_relative := subpath(v_child.alias_path, nlevel(v_old_path));
            v_target_path := v_new_path || v_relative;
            -- Move child and all its descendants under the new parent path
            UPDATE public.priority
            SET path = CASE
                WHEN path = v_child.current_path THEN v_target_path
                ELSE text2ltree(ltree2text(v_target_path) || '.' ||
                     ltree2text(subpath(path, nlevel(v_child.current_path))))
                END
            WHERE path <@ v_child.current_path;
            -- Delete the sharer's now-redundant path alias
            -- (it will be inherited from the parent's alias)
            DELETE FROM public.priority_setting
            WHERE user_id = p_user_id
              AND priority_id = v_child.child_id
              AND key = 'path';
        END LOOP;
    END IF;
    -- Ensure the sharer's own contact is in priority_contact
    INSERT INTO priority_contact (priority_id, contact_id)
    SELECT p_priority_id, c.id
    FROM contact c
    WHERE c.user_id = p_user_id AND c."primary" = TRUE AND c.archived_at IS NULL
    ON CONFLICT (priority_id, contact_id) DO NOTHING;
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
            -- Reset invitation sent_at if this is a re-invitation after full removal
            -- Only reset if the contact has no other active priority invitations
            WITH other_invitations AS (
                SELECT COUNT(*) as count
                FROM public.priority_contact
                WHERE contact_id = v_actor_id
                  AND invited_at IS NOT NULL
                  AND priority_id != p_priority_id
            )
            UPDATE public.contact_invitation
            SET sent_at = now()
            WHERE contact_id = v_actor_id
              AND (SELECT count FROM other_invitations) = 0;
            IF v_contact.user_id IS NOT NULL THEN
                -- Contact is an existing user - also create priority_user
                INSERT INTO public.priority_user (user_id, priority_id, personal, role)
                    VALUES (v_contact.user_id, p_priority_id, FALSE, p_role)
                ON CONFLICT (user_id, priority_id)
                    DO UPDATE SET
                        archived_at = NULL;
                -- If this is an org priority and recipient is an org member,
                -- create priority_settings to map it under their org root
                IF v_priority.organization_id IS NOT NULL THEN
                    SELECT
                        p.id, p.path INTO v_recipient_org_root
                    FROM
                        public.priority p
                        JOIN public.priority_user pu ON pu.priority_id = p.id
                    WHERE
                        p.organization_id = v_priority.organization_id
                        AND pu.user_id = v_contact.user_id
                        AND pu.archived_at IS NULL
                        AND nlevel (p.path) = 1;
                    IF v_recipient_org_root IS NOT NULL THEN
                        -- Map shared priority visually under recipient's org root
                        INSERT INTO public.priority_setting (user_id, priority_id, key, value)
                            VALUES (v_contact.user_id, p_priority_id, 'path', to_jsonb(ltree2text(text2ltree(ltree2text(v_recipient_org_root.path) || '.' || ltree2text(subpath((SELECT path FROM public.priority WHERE id = p_priority_id), -1))))))
                        ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
                    END IF;
                END IF;
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
$$;
-- Modify "priority" view
CREATE OR REPLACE VIEW "user"."priority" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "archived_at",
  "created_by",
  "updated_by",
  "root",
  "personal",
  "title",
  "path",
  "global_path",
  "top_order",
  "order",
  "pomodoro",
  "color",
  "key",
  "organization_id",
  "unread",
  "role",
  "attention_window",
  "see_within_requests",
  "see_within_updates",
  "attention_window_set",
  "see_within_requests_set",
  "see_within_updates_set",
  "inherit_members"
) AS SELECT DISTINCT ON (user_id, id) user_id,
    id,
    created_at,
    updated_at,
    archived_at,
    created_by,
    updated_by,
    root,
    personal,
    title,
    path,
    global_path,
    top_order,
    "order",
    pomodoro,
    color,
    key,
    organization_id,
    unread,
    role,
    attention_window,
    see_within_requests,
    see_within_updates,
    attention_window_set,
    see_within_requests_set,
    see_within_updates_set,
    inherit_members
   FROM ( SELECT pu.user_id,
            p.id,
            p.created_at,
            GREATEST(settings.updated_at, pu.updated_at, p.updated_at, COALESCE(upu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone), inherited.updated_at) AS updated_at,
            GREATEST(pu.archived_at, p.archived_at) AS archived_at,
            p.created_by,
            p.updated_by,
            (pu.personal = true OR p.organization_id IS NOT NULL) AND p.id = root.id AS root,
            user_root.path OPERATOR(public.@>) p.path AS personal,
            COALESCE(settings.title, p.title) AS title,
                CASE
                    WHEN inherited.path_value IS NOT NULL THEN
                    CASE
                        WHEN inherited.path_source IS NOT NULL AND p.path OPERATOR(public.<>) inherited.path_source::public.ltree AND public.subpath(p.path, public.nlevel(inherited.path_source::public.ltree)) OPERATOR(public.<>) ''::public.ltree THEN inherited.path_value::public.ltree OPERATOR(public.||) public.subpath(p.path, public.nlevel(inherited.path_source::public.ltree))
                        ELSE inherited.path_value::public.ltree
                    END
                    WHEN user_root.path OPERATOR(public.@>) p.path THEN p.path
                    ELSE user_root.path OPERATOR(public.||) p.path
                END AS path,
            p.path AS global_path,
            settings.top_order,
            COALESCE(settings."order", (EXTRACT(epoch FROM p.created_at) * 1000::numeric)::double precision) AS "order",
            inherited.pomodoro,
            inherited.color,
            p.key,
            p.organization_id,
            COALESCE(upu.unread, false) AS unread,
            "user".get_effective_role(pu.user_id, p.id) AS role,
            inherited.attention_window,
            inherited.see_within_requests,
            inherited.see_within_updates,
            COALESCE(settings.attention_window_set, false) AS attention_window_set,
            COALESCE(settings.see_within_requests_set, false) AS see_within_requests_set,
            COALESCE(settings.see_within_updates_set, false) AS see_within_updates_set,
            p.inherit_members,
                CASE
                    WHEN p.id = root.id THEN 0
                    ELSE public.nlevel(p.path) - public.nlevel(root.path)
                END AS _root_distance
           FROM public.priority_user pu
             JOIN public.priority root ON pu.priority_id = root.id
             JOIN public.priority_user pu_root ON pu.user_id = pu_root.user_id AND pu_root.personal = true
             JOIN public.priority user_root ON pu_root.priority_id = user_root.id
             JOIN public.priority p ON root.path OPERATOR(public.@>) p.path AND (p.id = root.id OR NOT (EXISTS ( SELECT 1
                   FROM public.priority blocker
                  WHERE blocker.path OPERATOR(public.<@) root.path AND p.path OPERATOR(public.<@) blocker.path AND blocker.path OPERATOR(public.<>) root.path AND blocker.inherit_members = false)))
             LEFT JOIN ( SELECT priority_setting.user_id,
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
                  GROUP BY priority_setting.user_id, priority_setting.priority_id) settings ON settings.user_id = pu.user_id AND settings.priority_id = p.id
             LEFT JOIN ( SELECT priority_setting_inherited.user_id,
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
                  GROUP BY priority_setting_inherited.user_id, priority_setting_inherited.priority_id) inherited ON inherited.user_id = pu.user_id AND inherited.priority_id = p.id
             LEFT JOIN "user".priority_unread upu ON upu.user_id = pu.user_id AND upu.priority_id = p.id
          WHERE pu.archived_at IS NULL) inner_q
  ORDER BY user_id, id, _root_distance;
