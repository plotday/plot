-- Drop views (CASCADE to handle complex dependency chain, all recreated below)
DROP VIEW IF EXISTS "user"."priority_expanded" CASCADE;
DROP VIEW IF EXISTS "user"."priority_actor" CASCADE;
-- Modify "priority_user" table
ALTER TABLE "public"."priority_user" ADD COLUMN "role" text NOT NULL DEFAULT 'member';
-- Create "get_effective_role" function (must be before views that reference it)
CREATE FUNCTION "user"."get_effective_role" ("p_user_id" uuid, "p_priority_id" uuid) RETURNS text LANGUAGE sql STABLE SET "search_path" = public AS $$
SELECT
        CASE WHEN bool_or(pu.role = 'member') THEN
            'member'
        ELSE
            COALESCE(MAX(pu.role), NULL)
        END
    FROM
        priority_user pu
        JOIN priority pp ON pu.priority_id = pp.id
        JOIN priority p ON p.path <@ pp.path
    WHERE
        pu.user_id = p_user_id
        AND pu.archived_at IS NULL
        AND p.id = p_priority_id
$$;
-- Create "setup_whats_new_priority" function
CREATE FUNCTION "public"."setup_whats_new_priority" ("p_user_id" uuid) RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_priority_id uuid;
    v_priority_path ltree;
    v_contact_id uuid;
    v_plot_priority_path ltree;
    v_user_root_path ltree;
    v_override_path ltree;
    v_user_root_path_part text;
BEGIN
    -- Get or create @whats-new priority
    SELECT
        id, path INTO v_priority_id, v_priority_path
    FROM
        priority
    WHERE
        key = '@whats-new'
    LIMIT 1;

    IF v_priority_id IS NULL THEN
        v_priority_path := generate_path (NULL);
        INSERT INTO priority (created_by, title, path, color, key, updated_by)
            VALUES (p_user_id, 'What''s New', v_priority_path, 7, '@whats-new', 0)
        RETURNING
            id INTO v_priority_id;
        -- The insert_priority_user trigger won't fire for @whats-new since it starts with @
        -- and isn't @plot, but clean up any personal entry just in case
        DELETE FROM priority_user
        WHERE user_id = p_user_id
            AND priority_id = v_priority_id
            AND personal = TRUE;
    END IF;

    -- Get user's contact_id
    SELECT
        id INTO v_contact_id
    FROM
        contact
    WHERE
        user_id = p_user_id
        AND "primary" = TRUE
    LIMIT 1;

    -- Add priority_contact (idempotent)
    IF v_contact_id IS NOT NULL THEN
        INSERT INTO priority_contact (priority_id, contact_id)
            VALUES (v_priority_id, v_contact_id)
        ON CONFLICT (priority_id, contact_id)
            DO NOTHING;
    END IF;

    -- Add priority_user with viewer role (idempotent - don't overwrite existing role)
    INSERT INTO priority_user (user_id, priority_id, personal, role)
        VALUES (p_user_id, v_priority_id, FALSE, 'viewer')
    ON CONFLICT (user_id, priority_id)
        DO NOTHING;

    -- Position under @plot via priority_settings
    SELECT
        p.path INTO v_user_root_path
    FROM
        priority_user pu
        JOIN priority p ON pu.priority_id = p.id
    WHERE
        pu.user_id = p_user_id
        AND pu.personal = TRUE
    LIMIT 1;

    IF v_user_root_path IS NOT NULL THEN
        v_user_root_path_part := split_part(v_user_root_path::text, '.', 1);
        SELECT
            p.path INTO v_plot_priority_path
        FROM
            priority p
        WHERE
            key = '@plot'
            AND p.path::text LIKE v_user_root_path_part || '%'
        LIMIT 1;

        IF v_plot_priority_path IS NOT NULL THEN
            v_override_path := generate_path (v_plot_priority_path);
            INSERT INTO priority_settings (user_id, priority_id, path, title)
                VALUES (p_user_id, v_priority_id, v_override_path, 'What''s New')
            ON CONFLICT (user_id, priority_id)
                DO UPDATE SET
                    path = EXCLUDED.path,
                    title = EXCLUDED.title;
        END IF;
    END IF;

    RETURN jsonb_build_object('success', TRUE, 'priority_id', v_priority_id);
END;
$$;
-- Create "share_priority" function
CREATE FUNCTION "public"."share_priority" ("p_user_id" uuid, "p_priority_id" uuid, "p_add_actor_ids" uuid[], "p_remove_actor_ids" uuid[], "p_role" text DEFAULT 'member') RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
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
-- Create "priority_expanded" view
CREATE VIEW "user"."priority_expanded" (
  "user_id",
  "priority_id",
  "joined_at",
  "archived_at",
  "role",
  "path"
) AS WITH base AS (
         SELECT pu.user_id,
            c.child_id AS priority_id,
            min(pu.created_at) AS joined_at,
            LEAST(min(pu.archived_at), min(c.archived_at)) AS archived_at,
                CASE
                    WHEN bool_or(pu.role = 'member'::text) THEN 'member'::text
                    ELSE 'viewer'::text
                END AS role
           FROM public.priority_user pu
             JOIN public.priority_child c ON pu.priority_id = c.priority_id
          GROUP BY pu.user_id, c.child_id
        )
 SELECT b.user_id,
    b.priority_id,
    b.joined_at,
    b.archived_at,
    b.role,
        CASE
            WHEN inherited_settings.path IS NOT NULL THEN inherited_settings.path
            WHEN user_root.path OPERATOR(public.@>) p.path THEN p.path
            WHEN parent_inherited_settings.path IS NOT NULL THEN parent_inherited_settings.path OPERATOR(public.||) public.subpath(p.path, public.nlevel(p.path) - 1, 1)::text::public.ltree
            ELSE user_root.path OPERATOR(public.||) p.path
        END AS path
   FROM base b
     LEFT JOIN public.priority p ON p.id = b.priority_id
     LEFT JOIN public.priority_user pu_root ON b.user_id = pu_root.user_id AND pu_root.personal = true
     LEFT JOIN public.priority user_root ON pu_root.priority_id = user_root.id
     LEFT JOIN public.priority_settings_inherited inherited_settings ON inherited_settings.user_id = b.user_id AND inherited_settings.priority_id = b.priority_id
     LEFT JOIN public.priority parent_p ON public.nlevel(p.path) > 1 AND parent_p.path OPERATOR(public.=) public.subpath(p.path, 0, public.nlevel(p.path) - 1)
     LEFT JOIN public.priority_settings_inherited parent_inherited_settings ON parent_inherited_settings.user_id = b.user_id AND parent_p.id = parent_inherited_settings.priority_id;
-- Create "priority_unread" view
CREATE VIEW "user"."priority_unread" (
  "user_id",
  "priority_id",
  "unread",
  "updated_at"
) AS SELECT upe.user_id,
    upe.priority_id,
    true AS unread,
    max(GREATEST(COALESCE(ar.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone),
        CASE
            WHEN a.created_by = upe.user_id THEN COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)
            ELSE COALESCE(a.last_note_created_at, a.created_at)
        END)) AS updated_at
   FROM "user".priority_expanded upe
     JOIN public.thread a ON a.priority_id = upe.priority_id AND a.archived_at IS NULL AND (a.created_by = upe.user_id AND a.last_note_created_at IS NOT NULL AND a.last_note_created_at > upe.joined_at OR (a.created_by IS NULL OR a.created_by <> upe.user_id) AND COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at)
     LEFT JOIN public.thread_read ar ON ar.user_id = upe.user_id AND ar.thread_id = a.id
  GROUP BY upe.user_id, upe.priority_id;
-- Create "priority" view
CREATE VIEW "user"."priority" (
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
  "unread",
  "role"
) AS SELECT pu.user_id,
    p.id,
    p.created_at,
    GREATEST(settings.updated_at, pu.updated_at, p.updated_at, COALESCE(upu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    GREATEST(pu.archived_at, p.archived_at) AS archived_at,
    p.created_by,
    p.updated_by,
    pu.personal = true AND p.id = root.id AS root,
    user_root.path OPERATOR(public.@>) p.path AS personal,
    COALESCE(settings.title, p.title) AS title,
        CASE
            WHEN inherited_settings.path IS NOT NULL THEN inherited_settings.path
            WHEN user_root.path OPERATOR(public.@>) p.path THEN p.path
            WHEN parent_inherited_settings.path IS NOT NULL THEN parent_inherited_settings.path OPERATOR(public.||) public.subpath(p.path, public.nlevel(p.path) - 1, 1)::text::public.ltree
            ELSE user_root.path OPERATOR(public.||) p.path
        END AS path,
    p.path AS global_path,
    settings.top_order,
    COALESCE(settings."order", (EXTRACT(epoch FROM p.created_at) * 1000::numeric)::double precision) AS "order",
    inherited_settings.pomodoro,
    inherited_settings.color,
    p.key,
    COALESCE(upu.unread, false) AS unread,
    "user".get_effective_role(pu.user_id, p.id) AS role
   FROM public.priority_user pu
     JOIN public.priority root ON pu.priority_id = root.id
     JOIN public.priority_user pu_root ON pu.user_id = pu_root.user_id AND pu_root.personal = true
     JOIN public.priority user_root ON pu_root.priority_id = user_root.id
     JOIN public.priority p ON root.path OPERATOR(public.@>) p.path
     LEFT JOIN public.priority parent_p ON public.nlevel(p.path) > 1 AND parent_p.path OPERATOR(public.=) public.subpath(p.path, 0, public.nlevel(p.path) - 1)
     LEFT JOIN public.priority_settings_inherited parent_inherited_settings ON parent_inherited_settings.user_id = pu.user_id AND parent_p.id = parent_inherited_settings.priority_id
     LEFT JOIN public.priority_settings settings ON settings.user_id = pu.user_id AND p.id = settings.priority_id
     LEFT JOIN public.priority_settings_inherited inherited_settings ON inherited_settings.user_id = pu.user_id AND p.id = inherited_settings.priority_id
     LEFT JOIN "user".priority_unread upu ON upu.user_id = pu.user_id AND upu.priority_id = p.id
  WHERE pu.archived_at IS NULL;
-- Modify "update_note_tags" function
CREATE OR REPLACE FUNCTION "user"."update_note_tags" ("user_id" uuid, "p_note_id" uuid, "p_actor_id" uuid, "p_client_id" integer, "p_tag_updates" jsonb) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    tag_record record;
    tag_id_int integer;
    is_adding boolean;
    current_tag_type tag_type;
    target_actor_id uuid;
    v_priority_id uuid;
    v_effective_role text;
BEGIN
    -- Validate that note_id is provided
    IF p_note_id IS NULL THEN
        RAISE EXCEPTION 'p_note_id must be provided';
    END IF;
    -- Validate access to the note's thread priority
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
    IF NOT "user".has_priority_access (user_id, v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this note';
    END IF;
    v_effective_role := "user".get_effective_role(user_id, v_priority_id);
    -- Iterate through the tag updates JSON object
    FOR tag_record IN
    SELECT
        key,
        value
    FROM
        jsonb_each(p_tag_updates)
        LOOP
            -- Parse key: "tagId" or "tagId:actorId"
            IF position(':' in tag_record.key) > 0 THEN
                tag_id_int := split_part(tag_record.key, ':', 1)::integer;
                target_actor_id := split_part(tag_record.key, ':', 2)::uuid;
            ELSE
                tag_id_int := tag_record.key::integer;
                target_actor_id := p_actor_id;
            END IF;
            is_adding := tag_record.value::boolean;
            -- Get tag type using the get_tag_type function
            current_tag_type := get_tag_type (tag_id_int);
            -- Viewer enforcement: viewers can only modify count tags
            IF v_effective_role = 'viewer' AND current_tag_type != 'count' THEN
                RAISE EXCEPTION 'Viewer members can only modify count tags (tag_id: %)', tag_id_int;
            END IF;
            -- Validate computed tags for notes
            -- Notes can have 'todo' (1) and 'done' (3) tags for per-user assignment/completion
            -- But not 'archived' (4), 'attachment' (5), 'link' (6) - those are computed
            IF current_tag_type = 'compute' AND tag_id_int NOT IN (1, 3) THEN
                RAISE EXCEPTION 'Cannot add computed tag (tag_id: %) - this tag is calculated from note state', tag_id_int;
            END IF;
            -- Validate cross-user targeting: only allow for compute tags 1, 3 (todo, done)
            IF target_actor_id != p_actor_id AND (current_tag_type != 'compute' OR tag_id_int NOT IN (1, 3)) THEN
                RAISE EXCEPTION 'Cannot modify this tag for other users (tag_id: %)', tag_id_int;
            END IF;
            IF is_adding THEN
                -- When adding 'done' tag (3), automatically remove 'todo' tag (1) for this actor
                -- This is how individual completion works for multi-assignee notes
                IF tag_id_int = 3 THEN
                    UPDATE
                        note_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        note_id = p_note_id
                        AND tag_id = 1
                        AND actor_id = target_actor_id
                        AND archived_at IS NULL;
                END IF;
                -- Adding a tag - use upsert to create or reactivate
                INSERT INTO note_tag (actor_id, note_id, tag_id, updated_at, archived_at, updated_by)
                    VALUES (target_actor_id, p_note_id, tag_id_int, now(), NULL, p_client_id)
                ON CONFLICT (actor_id, note_id, tag_id)
                    DO UPDATE SET
                        archived_at = NULL,
                        updated_at = now(),
                        updated_by = p_client_id;
            ELSE
                -- Removing a tag - use update to soft delete existing records
                IF current_tag_type = 'toggle' THEN
                    -- For toggle tags, remove all users' tags
                    UPDATE
                        note_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        note_id = p_note_id
                        AND tag_id = tag_id_int
                        AND archived_at IS NULL;
                ELSE
                    -- For count/compute tags, only remove target actor's tag
                    UPDATE
                        note_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        note_id = p_note_id
                        AND tag_id = tag_id_int
                        AND actor_id = target_actor_id
                        AND archived_at IS NULL;
                END IF;
            END IF;
        END LOOP;
END;
$$;
-- Modify "update_thread_tags" function
CREATE OR REPLACE FUNCTION "user"."update_thread_tags" ("user_id" uuid, "p_thread_id" uuid, "p_actor_id" uuid, "p_client_id" integer, "p_tag_updates" jsonb, "p_occurrence" text DEFAULT NULL::text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    tag_record record;
    tag_id_int integer;
    is_adding boolean;
    current_tag_type tag_type;
    v_priority_id uuid;
    v_effective_role text;
BEGIN
    -- Validate that thread_id is provided
    IF p_thread_id IS NULL THEN
        RAISE EXCEPTION 'p_thread_id must be provided';
    END IF;
    -- Validate access to the thread's priority
    SELECT
        a.priority_id INTO v_priority_id
    FROM
        thread a
    WHERE
        a.id = p_thread_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;
    IF NOT "user".has_priority_access (user_id, v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this thread';
    END IF;
    v_effective_role := "user".get_effective_role(user_id, v_priority_id);
    -- Iterate through the tag updates JSON object
    FOR tag_record IN
    SELECT
        key,
        value
    FROM
        jsonb_each(p_tag_updates)
        LOOP
            -- Convert key to integer and value to boolean
            tag_id_int := tag_record.key::integer;
            is_adding := tag_record.value::boolean;
            -- Get tag type using the get_tag_type function
            current_tag_type := get_tag_type (tag_id_int);
            -- Viewer enforcement: viewers can only modify count tags
            IF v_effective_role = 'viewer' AND current_tag_type != 'count' THEN
                RAISE EXCEPTION 'Viewer members can only modify count tags (tag_id: %)', tag_id_int;
            END IF;
            -- Prevent insertion of computed tags (tag_id 1-99)
            -- Computed tags should only exist as calculated values
            IF current_tag_type = 'compute' THEN
                RAISE EXCEPTION 'Cannot add computed tag (tag_id: %) - these tags are calculated from thread state', tag_id_int;
            END IF;
            -- For count tags, enforce that users can only modify their own tags
            -- p_actor_id should match the authenticated user's contact_id
            -- Note: RLS policies already enforce this, but we validate explicitly for clarity
            IF current_tag_type = 'count' THEN
                -- Validate p_actor_id matches current user's contact_id
                IF p_actor_id != "user".user_contact_id (user_id) THEN
                    RAISE EXCEPTION 'Cannot modify count tags for other users (tag_id: %)', tag_id_int;
                END IF;
            END IF;
            IF is_adding THEN
                -- Adding a tag - use upsert to create or reactivate
                INSERT INTO thread_tag (actor_id, thread_id, occurrence, tag_id, updated_at, archived_at, updated_by)
                    VALUES (p_actor_id, p_thread_id, p_occurrence, tag_id_int, now(), NULL, p_client_id)
                ON CONFLICT (actor_id, thread_id, occurrence, tag_id)
                    DO UPDATE SET
                        archived_at = NULL,
                        updated_at = now(),
                        updated_by = p_client_id;
                -- Ensure priority_contact exists if actor is a contact
                -- This allows contacts to be visible via RLS when tagged on threads
                IF EXISTS (
                    SELECT
                        1
                    FROM
                        contact
                    WHERE
                        id = p_actor_id) THEN
                INSERT INTO priority_contact (priority_id, contact_id)
                SELECT
                    a.priority_id,
                    p_actor_id
                FROM
                    thread a
                WHERE
                    a.id = p_thread_id
                ON CONFLICT (priority_id,
                    contact_id)
                    DO NOTHING;
            END IF;
        ELSE
            -- Removing a tag - use update to soft delete existing records
            IF current_tag_type = 'toggle' THEN
                -- For toggle tags, remove all users' tags
                UPDATE
                    thread_tag
                SET
                    archived_at = now(),
                    updated_by = p_client_id
                WHERE
                    thread_id = p_thread_id
                    AND tag_id = tag_id_int
                    AND (occurrence IS NOT DISTINCT FROM p_occurrence)
                    AND archived_at IS NULL;
            ELSE
                -- For count/compute tags, only remove current actor's tag
                UPDATE
                    thread_tag
                SET
                    archived_at = now(),
                    updated_by = p_client_id
                WHERE
                    thread_id = p_thread_id
                    AND tag_id = tag_id_int
                    AND actor_id = p_actor_id
                    AND (occurrence IS NOT DISTINCT FROM p_occurrence)
                    AND archived_at IS NULL;
            END IF;
        END IF;
END LOOP;
END;
$$;
-- Modify "upsert_note" function
CREATE OR REPLACE FUNCTION "user"."upsert_note" ("user_id" uuid, "p_id" uuid, "p_author_id" uuid, "p_created_by" uuid, "p_updated_by" integer, "p_archived_at" timestamptz, "p_thread_id" uuid, "p_draft" boolean, "p_private" boolean, "p_content" text, "p_actions" jsonb, "p_mentions" uuid[], "p_re_note_id" uuid, "p_source_created_at" timestamptz, "p_key" text, "p_merged_from_thread_id" uuid DEFAULT NULL::uuid) RETURNS "public"."note" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
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
$$;
-- Modify "upsert_note_tag" function
CREATE OR REPLACE FUNCTION "user"."upsert_note_tag" ("user_id" uuid, "p_actor_id" uuid, "p_note_id" uuid, "p_tag_id" integer, "p_updated_by" integer DEFAULT 0, "p_archived_at" timestamptz DEFAULT NULL::timestamp with time zone) RETURNS "public"."note_tag" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
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
$$;
-- Modify "upsert_priority" function
CREATE OR REPLACE FUNCTION "user"."upsert_priority" ("user_id" uuid, "p_priority" jsonb) RETURNS "user"."priority" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
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
                priority_settings ps
                JOIN priority p ON ps.priority_id = p.id
            WHERE
                ps.user_id = upsert_priority.user_id
                AND ps.path IS NOT NULL
                AND _input.path <@ ps.path
                AND _old.path <@ ps.path
                AND ps.path != p.path
                AND _old_actual_path <@ p.path
                AND _actual_path <@ p.path
            ORDER BY
                nlevel (ps.path) DESC
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
                UPDATE
                    priority_settings
                SET
                    path = NULL
                WHERE
                    user_id = upsert_priority.user_id
                    AND priority_id = _input.id;
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
    -- Update priority_settings for user-specific fields
    IF _is_visual_move THEN
        -- Visual move: create/update path alias
        INSERT INTO priority_settings (user_id, priority_id, path, top_order, "order", pomodoro, color)
            VALUES (upsert_priority.user_id, _priority_id, _input.path, _input.top_order, _input.order, _input.pomodoro, COALESCE(_input.color, _priority_default_color))
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET
                path = _input.path,
                top_order = _input.top_order,
                "order" = _input.order,
                pomodoro = _input.pomodoro,
                color = _input.color;
    ELSIF NOT _is_move
            AND (_input."top_order" IS NOT NULL
                OR _input."order" IS NOT NULL
                OR _input."pomodoro" IS NOT NULL
                OR _input."color" IS NOT NULL) THEN
            INSERT INTO priority_settings (user_id, priority_id, path, top_order, "order", pomodoro, color)
                VALUES (upsert_priority.user_id, _priority_id, NULL, _input.top_order, _input.order, _input.pomodoro, COALESCE(_input.color, _priority_default_color))
            ON CONFLICT (user_id, priority_id)
                DO UPDATE SET
                    top_order = _input.top_order,
                    "order" = _input.order,
                    pomodoro = _input.pomodoro,
                    color = _input.color;
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
$$;
-- Modify "priority_member" view (moved before upsert_priority_member which returns this type)
CREATE OR REPLACE VIEW "public"."priority_member" (
  "contact_id",
  "priority_id",
  "created_at",
  "updated_at",
  "archived_at",
  "status",
  "invited_by",
  "personal",
  "role"
) AS SELECT pc.contact_id,
    pc.priority_id,
    pc.created_at,
    GREATEST(pc.updated_at, COALESCE(pu.updated_at, pc.created_at), COALESCE(c.updated_at, pc.created_at)) AS updated_at,
        CASE
            WHEN pc.invited_by IS NOT NULL AND pc.invited_at IS NULL THEN pc.updated_at
            ELSE pu.archived_at
        END AS archived_at,
        CASE
            WHEN c.user_id IS NOT NULL AND pu.user_id IS NOT NULL THEN 'accepted'::text
            ELSE 'invited'::text
        END AS status,
    pc.invited_by,
    COALESCE(pu.personal, false) AS personal,
    COALESCE(pu.role, 'member'::text) AS role
   FROM public.priority_contact pc
     JOIN public.contact c ON c.id = pc.contact_id
     LEFT JOIN public.priority_user pu ON pu.user_id = c.user_id AND pu.priority_id = pc.priority_id
  WHERE pu.user_id IS NOT NULL OR pc.invited_by IS NOT NULL;
-- Modify "upsert_priority_member" function
CREATE OR REPLACE FUNCTION "user"."upsert_priority_member" ("user_id" uuid, "p_contact_id" uuid, "p_priority_id" uuid, "p_invited_by" uuid, "p_invited_at" timestamptz) RETURNS "public"."priority_member" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
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
$$;
-- Modify "upsert_priority_twist" function
CREATE OR REPLACE FUNCTION "user"."upsert_priority_twist" ("user_id" uuid, "p_id" uuid, "p_priority_id" uuid, "p_twist_id" bigint, "p_owner_id" uuid, "p_name" text, "p_config" jsonb, "p_archived_at" timestamptz) RETURNS "public"."priority_twist" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
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
$$;
-- Modify "upsert_thread" function
CREATE OR REPLACE FUNCTION "user"."upsert_thread" ("user_id" uuid, "p_thread" jsonb, "p_defaults" jsonb DEFAULT '{}') RETURNS "public"."thread" LANGUAGE plpgsql AS $$
DECLARE
    v_result thread;
    v_id uuid;
    -- Variables for derived values
    v_priority_id uuid;
    v_created_by uuid;
    -- Archived status check
    v_is_archived boolean;
BEGIN
    -- Extract required fields from JSONB, with fallback to p_defaults for INSERT
    v_id := COALESCE((p_thread ->> 'id')::uuid, (p_defaults ->> 'id')::uuid);
    v_priority_id := COALESCE((p_thread ->> 'priority_id')::uuid, (p_defaults ->> 'priority_id')::uuid);
    v_created_by := COALESCE((p_thread ->> 'created_by')::uuid, (p_defaults ->> 'created_by')::uuid, user_id);
    -- Generate id if not provided
    IF v_id IS NULL THEN
        v_id := uuidv7 ();
    END IF;
    -- Resolve priority_id from existing thread if missing
    IF v_priority_id IS NULL THEN
        SELECT
            priority_id INTO v_priority_id
        FROM
            thread
        WHERE
            id = v_id;
    END IF;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'priority_id must be provided';
    END IF;
    -- Validate access to the priority
    IF NOT EXISTS (
        SELECT
            1
        FROM
            priority_user pu
            JOIN priority pp ON pu.priority_id = pp.id
            JOIN priority p ON p.path <@ pp.path
        WHERE
            pu.user_id = upsert_thread.user_id
            AND pu.archived_at IS NULL
            AND p.id = v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;
    -- Enforce viewer restriction: viewers cannot create or modify threads
    IF "user".get_effective_role(user_id, v_priority_id) = 'viewer' THEN
        RAISE EXCEPTION 'Viewer members cannot create or modify threads';
    END IF;
    -- Validate created_by when it differs from user_id
    IF v_created_by IS DISTINCT FROM user_id THEN
        IF NOT EXISTS (
            SELECT
                1
            FROM
                priority_twist pt
            WHERE
                pt.id = v_created_by
                AND pt.owner_id = upsert_thread.user_id) THEN
            RAISE EXCEPTION 'created_by must be user or owned priority_twist';
        END IF;
    END IF;
    -- Check if existing thread is archived (either directly or via priority)
    -- Only relevant for UPDATE path; INSERT path will have NULL and be coalesced to false
    SELECT
        (thread.archived_at IS NOT NULL
            OR NOT EXISTS (
                SELECT
                    1
                FROM
                    "user".priority_expanded upe
                WHERE
                    upe.priority_id = thread.priority_id
                    AND upe.user_id = upsert_thread.user_id
                    AND upe.archived_at IS NULL)) INTO v_is_archived
    FROM
        thread
    WHERE
        id = v_id;
    -- If no existing thread, v_is_archived will be NULL (INSERT path)
    v_is_archived := COALESCE(v_is_archived, FALSE);
    -- Perform the upsert and return the full row
    -- On INSERT: Use COALESCE to fall back to p_defaults for fields not in p_thread
    INSERT INTO thread (id, created_by, priority_id, title, preview, updated_by, sync_depth, private, draft)
        VALUES (v_id, v_created_by, v_priority_id, COALESCE(p_thread ->> 'title', p_defaults ->> 'title'), COALESCE(p_thread ->> 'preview', p_defaults ->> 'preview'), COALESCE((p_thread ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, 0), COALESCE((p_thread ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint), COALESCE((p_thread ->> 'private')::boolean, (p_defaults ->> 'private')::boolean, FALSE), COALESCE((p_thread ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, FALSE))
    ON CONFLICT (id)
        DO UPDATE SET
            -- Update fields only if key is present in p_thread
            -- Key absent: keep existing value (unless archived, then use p_defaults)
            -- Key present (even with null): use provided value (allows clearing)
            -- If archived: treat as INSERT and apply p_defaults
            title = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'title', p_defaults ->> 'title', thread.title)
            ELSE
                CASE WHEN p_thread ? 'title' THEN
                    p_thread ->> 'title'
                ELSE
                    thread.title
                END
            END,
            preview = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'preview', p_defaults ->> 'preview', thread.preview)
            ELSE
                CASE WHEN p_thread ? 'preview' THEN
                    p_thread ->> 'preview'
                ELSE
                    thread.preview
                END
            END,
            updated_by = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, thread.updated_by)
            ELSE
                CASE WHEN p_thread ? 'updated_by' THEN
                    (p_thread ->> 'updated_by')::integer
                ELSE
                    thread.updated_by
                END
            END,
            sync_depth = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint, thread.sync_depth)
            ELSE
                CASE WHEN p_thread ? 'sync_depth' THEN
                    (p_thread ->> 'sync_depth')::smallint
                ELSE
                    thread.sync_depth
                END
            END,
            priority_id = CASE WHEN v_is_archived THEN
                v_priority_id
            ELSE
                CASE WHEN p_thread ? 'priority_id' THEN
                    (p_thread ->> 'priority_id')::uuid
                ELSE
                    thread.priority_id
                END
            END,
            private = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'private')::boolean, (p_defaults ->> 'private')::boolean, thread.private)
            ELSE
                CASE WHEN p_thread ? 'private' THEN
                    (p_thread ->> 'private')::boolean
                ELSE
                    thread.private
                END
            END,
            draft = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, thread.draft)
            ELSE
                CASE WHEN p_thread ? 'draft' THEN
                    (p_thread ->> 'draft')::boolean
                ELSE
                    thread.draft
                END
            END,
            archived_at = CASE WHEN v_is_archived THEN
                CASE WHEN p_thread ? 'archived_at' THEN
                    (p_thread ->> 'archived_at')::timestamptz
                WHEN p_defaults ? 'archived_at' THEN
                    (p_defaults ->> 'archived_at')::timestamptz
                ELSE
                    thread.archived_at
                END
            ELSE
                CASE WHEN p_thread ? 'archived_at' THEN
                    (p_thread ->> 'archived_at')::timestamptz
                ELSE
                    thread.archived_at
                END
            END,
            created_by = v_created_by
        RETURNING
            * INTO v_result;
    RETURN v_result;
END;
$$;
-- Modify "upsert_thread_tag" function
CREATE OR REPLACE FUNCTION "user"."upsert_thread_tag" ("user_id" uuid, "p_actor_id" uuid, "p_thread_id" uuid, "p_tag_id" integer, "p_occurrence" text DEFAULT NULL::text, "p_updated_by" integer DEFAULT 0, "p_archived_at" timestamptz DEFAULT NULL::timestamp with time zone) RETURNS "public"."thread_tag" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
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
$$;
-- Create "thread" view
CREATE VIEW "user"."thread" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "updated_by",
  "archived_at",
  "priority_id",
  "priority_path",
  "draft",
  "private",
  "title",
  "preview",
  "last_note_created_at",
  "last_note_source_created_at",
  "mentions",
  "unread",
  "activity_at",
  "agenda_at"
) AS WITH link_agg AS (
         SELECT link.thread_id,
            max(link.source_created_at) AS source_created_at
           FROM public.link
          GROUP BY link.thread_id
        )
 SELECT upe.user_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone),
        CASE
            WHEN a.archived_at IS NULL AND (a.created_by = upe.user_id AND a.last_note_created_at IS NOT NULL AND a.last_note_created_at > upe.joined_at OR (a.created_by IS NULL OR a.created_by <> upe.user_id) AND COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at) THEN GREATEST(COALESCE(
            CASE
                WHEN ar.read_at >=
                CASE
                    WHEN a.created_by = upe.user_id THEN a.last_note_source_created_at
                    ELSE COALESCE(GREATEST(a.last_note_source_created_at, la.source_created_at, ar.bumped_at), a.created_at)
                END THEN ar.updated_at
                ELSE NULL::timestamp with time zone
            END, '1970-01-01 00:00:00+00'::timestamp with time zone),
            CASE
                WHEN a.created_by = upe.user_id THEN COALESCE(a.last_note_source_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)
                ELSE COALESCE(GREATEST(a.last_note_source_created_at, la.source_created_at, ar.bumped_at), a.created_at)
            END)
            ELSE '1970-01-01 00:00:00+00'::timestamp with time zone
        END) AS updated_at,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at) AS archived_at,
    a.priority_id,
    upe.path AS priority_path,
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.last_note_created_at,
    a.last_note_source_created_at,
    a.mentions,
    COALESCE(
        CASE
            WHEN a.archived_at IS NULL AND (a.created_by = upe.user_id AND a.last_note_created_at IS NOT NULL AND a.last_note_created_at > upe.joined_at OR (a.created_by IS NULL OR a.created_by <> upe.user_id) AND COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at) THEN ar.read_at IS NULL OR ar.read_at <
            CASE
                WHEN a.created_by = upe.user_id THEN a.last_note_source_created_at
                ELSE COALESCE(GREATEST(a.last_note_source_created_at, la.source_created_at, ar.bumped_at), a.created_at)
            END
            ELSE false
        END, false) AS unread,
    COALESCE(GREATEST(a.last_note_source_created_at, la.source_created_at, ar.bumped_at), a.created_at) AS activity_at,
    COALESCE(LEAST(( SELECT COALESCE(lower(s_agg.at), lower(s_agg."on")::timestamp with time zone) AS "coalesce"
           FROM public.schedule s_agg
          WHERE s_agg.thread_id = a.id AND s_agg.user_id IS NULL AND s_agg.archived_at IS NULL
          ORDER BY (COALESCE(lower(s_agg.at), lower(s_agg."on")::timestamp with time zone))
         LIMIT 1), ( SELECT COALESCE(lower(s_agg.at), lower(s_agg."on")::timestamp with time zone) AS "coalesce"
           FROM public.schedule s_agg
          WHERE s_agg.thread_id = a.id AND s_agg.user_id = upe.user_id AND s_agg.archived_at IS NULL
          ORDER BY (COALESCE(lower(s_agg.at), lower(s_agg."on")::timestamp with time zone))
         LIMIT 1)), a.created_at) AS agenda_at
   FROM public.thread_x a
     JOIN "user".priority_expanded upe ON a.priority_id = upe.priority_id
     LEFT JOIN public.thread_read ar ON ar.user_id = upe.user_id AND ar.thread_id = a.id
     LEFT JOIN link_agg la ON la.thread_id = a.id
  WHERE (a.draft = false OR a.created_by = upe.user_id) AND
        CASE
            WHEN a.private = false THEN true
            WHEN a.created_by = upe.user_id THEN true
            ELSE "user".mentioned_in_thread(upe.user_id, a.id)
        END
UNION ALL
 SELECT upe.user_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at, a.updated_at) AS archived_at,
    a.priority_id,
    upe.path AS priority_path,
    a.draft,
    a.private,
    NULL::text AS title,
    NULL::text AS preview,
    a.last_note_created_at,
    a.last_note_source_created_at,
    NULL::uuid[] AS mentions,
    false AS unread,
    a.created_at AS activity_at,
    a.created_at AS agenda_at
   FROM public.thread_x a
     JOIN "user".priority_expanded upe ON a.priority_id = upe.priority_id
  WHERE (a.draft = false OR a.created_by = upe.user_id) AND a.private = true AND a.created_by <> upe.user_id AND NOT "user".mentioned_in_thread(upe.user_id, a.id);
-- Create "note_tags" view
CREATE VIEW "user"."note_tags" (
  "user_id",
  "id",
  "updated_at",
  "archived_at",
  "priority_id",
  "priority_path",
  "tags"
) AS SELECT ua.user_id,
    n.id,
    nt.updated_at,
    ua.archived_at,
    ua.priority_id,
    ua.priority_path,
    nt.tags
   FROM public.note_tags nt
     JOIN public.note n ON n.id = nt.note_id
     JOIN "user".thread ua ON ua.id = n.thread_id
  WHERE (n.draft = false OR n.created_by = ua.user_id) AND (n.private = false OR n.created_by = ua.user_id OR (ua.user_id = ANY (n.mentions)));
-- Create "twist" view
CREATE VIEW "user"."twist" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "archived_at",
  "priority_id",
  "twist_id",
  "twist_environment",
  "is_source",
  "owner_id",
  "name",
  "config",
  "logo_url",
  "logo_url_dark",
  "link_types"
) AS SELECT upe.user_id,
    pt.id,
    pt.created_at,
    pt.updated_at,
    pt.archived_at,
    pt.priority_id,
    pt.twist_id,
    t.environment AS twist_environment,
    t.is_source,
    pt.owner_id,
    pt.name,
    pt.config,
    t.logo_url,
    t.logo_url_dark,
    ( SELECT jsonb_agg(lt.value) AS jsonb_agg
           FROM jsonb_array_elements(t.permissions -> '_providers'::text) p(value),
            LATERAL jsonb_array_elements(p.value -> 'linkTypes'::text) lt(value)) AS link_types
   FROM public.priority_twist pt
     JOIN "user".priority_expanded upe ON upe.priority_id = pt.priority_id
     JOIN public.twist t ON pt.twist_id = t.id
UNION ALL
 SELECT pt.owner_id AS user_id,
    pt.id,
    pt.created_at,
    pt.updated_at,
    pt.archived_at,
    pt.priority_id,
    pt.twist_id,
    t.environment AS twist_environment,
    t.is_source,
    pt.owner_id,
    pt.name,
    pt.config,
    t.logo_url,
    t.logo_url_dark,
    ( SELECT jsonb_agg(lt.value) AS jsonb_agg
           FROM jsonb_array_elements(t.permissions -> '_providers'::text) p(value),
            LATERAL jsonb_array_elements(p.value -> 'linkTypes'::text) lt(value)) AS link_types
   FROM public.priority_twist pt
     JOIN public.twist t ON pt.twist_id = t.id
  WHERE t.is_source = true AND pt.priority_id IS NULL;
-- Create "link" view
CREATE VIEW "user"."link" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "thread_id",
  "source",
  "source_created_at",
  "author_id",
  "twist_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "title",
  "preview",
  "assignee_id",
  "type",
  "status",
  "actions",
  "meta",
  "source_url",
  "logo",
  "priority_id",
  "merged_from_thread_id",
  "priority_path"
) AS SELECT upe.user_id,
    l.id,
    l.created_at,
    l.updated_at,
    l.thread_id,
    l.source,
    l.source_created_at,
    l.author_id,
    l.twist_id,
    l.created_by,
    l.updated_by,
    l.sync_depth,
    l.title,
    l.preview,
    l.assignee_id,
    l.type,
    l.status,
    l.actions,
    l.meta,
    l.source_url,
    l.logo,
    l.priority_id,
    l.merged_from_thread_id,
    upe.path AS priority_path
   FROM public.link_x l
     JOIN "user".priority_expanded upe ON l.priority_id = upe.priority_id;
-- Create "priority_actor" view
CREATE VIEW "user"."priority_actor" (
  "user_id",
  "priority_path",
  "actor_id",
  "created_at",
  "updated_at",
  "archived_at"
) AS SELECT user_id,
    priority_path,
    actor_id,
    created_at,
    updated_at,
    archived_at
   FROM ( SELECT upe.user_id,
            upe.path AS priority_path,
            pc.contact_id AS actor_id,
            LEAST(COALESCE(pc.created_at, c.created_at), COALESCE(c.created_at, pc.created_at)) AS created_at,
            GREATEST(pc.updated_at, c.updated_at) AS updated_at,
                CASE
                    WHEN pc.invited_by IS NOT NULL AND pc.invited_at IS NULL THEN pc.updated_at
                    ELSE c.archived_at
                END AS archived_at
           FROM "user".priority_expanded upe
             JOIN public.priority_contact pc ON pc.priority_id = upe.priority_id
             JOIN public.contact c ON c.id = pc.contact_id
          WHERE NOT (upe.role = 'viewer'::text AND c.user_id IS NOT NULL AND "user".get_effective_role(c.user_id, upe.priority_id) = 'viewer'::text)
        UNION ALL
         SELECT upe.user_id,
            upe.path AS priority_path,
            pt.id AS actor_id,
            pt.created_at,
            pt.updated_at,
            pt.archived_at
           FROM "user".priority_expanded upe
             JOIN public.priority_twist pt ON pt.priority_id = upe.priority_id
        UNION ALL
         SELECT upe.user_id,
            upe.path AS priority_path,
            pt.id AS actor_id,
            pt.created_at,
            GREATEST(pt.updated_at, sc.updated_at) AS updated_at,
            pt.archived_at
           FROM "user".priority_expanded upe
             JOIN public.source_channel sc ON sc.priority_id = upe.priority_id
             JOIN public.priority_twist pt ON pt.id = sc.priority_twist_id AND pt.priority_id IS NULL) actors;
-- Create "actor" view
CREATE VIEW "user"."actor" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "archived_at",
  "type",
  "name",
  "email",
  "avatar_url",
  "self"
) AS WITH upa_agg AS (
         SELECT upa.user_id,
            upa.actor_id,
            COALESCE(min(upa.updated_at) FILTER (WHERE upa.archived_at IS NULL), max(upa.archived_at)) AS updated_at,
                CASE
                    WHEN count(*) FILTER (WHERE upa.archived_at IS NULL) = 0 THEN max(upa.archived_at)
                    ELSE NULL::timestamp with time zone
                END AS archived_at
           FROM "user".priority_actor upa
          GROUP BY upa.user_id, upa.actor_id
        )
 SELECT ua.user_id,
    a.id,
    a.created_at,
    GREATEST(ua.updated_at, a.updated_at) AS updated_at,
    COALESCE(a.archived_at, ua.archived_at) AS archived_at,
    a.type,
    a.name,
    a.email,
    a.avatar_url,
    (EXISTS ( SELECT 1
           FROM public.contact c
          WHERE c.id = a.id AND c.user_id = ua.user_id)) AS self
   FROM upa_agg ua
     JOIN public.actor a ON a.id = ua.actor_id;
-- Create "schedule" view
CREATE VIEW "user"."schedule" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "archived_at",
  "schedule_user_id",
  "order",
  "at",
  "on",
  "recurrence_rule",
  "duration",
  "recurrence_exdates",
  "occurrence",
  "thread_id",
  "link_id",
  "priority_path",
  "range_at",
  "range_on",
  "contacts"
) AS SELECT upe.user_id,
    s.id,
    s.created_at,
    s.updated_at,
    COALESCE(s.archived_at, upe.archived_at) AS archived_at,
    s.user_id AS schedule_user_id,
    s."order",
    s.at,
    s."on",
    s.recurrence_rule,
    s.duration,
    s.recurrence_exdates,
    s.occurrence,
    s.thread_id,
    s.link_id,
    upe.path AS priority_path,
        CASE
            WHEN s.at IS NOT NULL THEN s.at
            ELSE NULL::tstzrange
        END AS range_at,
        CASE
            WHEN s."on" IS NOT NULL THEN s."on"
            ELSE NULL::daterange
        END AS range_on,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', sc.id, 'contact_id', sc.contact_id, 'contact_email', c.email, 'contact_name', c.name, 'contact_user_id', c.user_id, 'status', sc.status, 'role', sc.role, 'archived_at', sc.archived_at, 'updated_at', sc.updated_at) ORDER BY sc.created_at) AS jsonb_agg
           FROM public.schedule_contact sc
             JOIN public.contact c ON c.id = sc.contact_id
          WHERE sc.schedule_id = s.id), '[]'::jsonb) AS contacts
   FROM public.schedule s
     LEFT JOIN public.thread t_thread ON t_thread.id = s.thread_id
     LEFT JOIN public.link l ON l.id = s.link_id
     LEFT JOIN public.thread t_link ON t_link.id = l.thread_id
     JOIN "user".priority_expanded upe ON upe.priority_id = COALESCE(t_thread.priority_id, t_link.priority_id)
  WHERE s.user_id IS NULL OR s.user_id = upe.user_id;
-- Create "thread_tags" view
CREATE VIEW "user"."thread_tags" (
  "user_id",
  "id",
  "archived_at",
  "occurrence",
  "updated_at",
  "priority_id",
  "priority_path",
  "tags"
) AS SELECT ua.user_id,
    ua.id,
    ua.archived_at,
    at.occurrence,
    at.updated_at,
    ua.priority_id,
    ua.priority_path,
    at.tags
   FROM public.thread_tags at
     JOIN "user".thread ua ON ua.id = at.thread_id;
-- Create "note" view
CREATE VIEW "user"."note" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "archived_at",
  "thread_id",
  "draft",
  "private",
  "content",
  "actions",
  "mentions",
  "re_note_id",
  "merged_from_thread_id"
) AS SELECT upe.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.archived_at,
    n.thread_id,
    n.draft,
    n.private,
    n.content,
    n.actions,
    n.mentions,
    n.re_note_id,
    n.merged_from_thread_id
   FROM public.note n
     JOIN public.thread a ON a.id = n.thread_id
     JOIN "user".priority_expanded upe ON upe.priority_id = a.priority_id
  WHERE (n.draft = false OR n.created_by = upe.user_id) AND (n.private = false OR n.created_by = upe.user_id OR (upe.user_id = ANY (n.mentions))) AND (a.draft = false OR a.created_by = upe.user_id) AND
        CASE
            WHEN a.private = false THEN true
            WHEN a.created_by = upe.user_id THEN true
            ELSE "user".mentioned_in_thread(upe.user_id, a.id)
        END
UNION ALL
 SELECT upe.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    COALESCE(n.archived_at, n.updated_at) AS archived_at,
    n.thread_id,
    n.draft,
    n.private,
    NULL::text AS content,
    NULL::jsonb AS actions,
    NULL::uuid[] AS mentions,
    n.re_note_id,
    n.merged_from_thread_id
   FROM public.note n
     JOIN public.thread a ON a.id = n.thread_id
     JOIN "user".priority_expanded upe ON upe.priority_id = a.priority_id
  WHERE (n.draft = false OR n.created_by = upe.user_id) AND (a.draft = false OR a.created_by = upe.user_id) AND (n.private = true AND n.created_by <> upe.user_id AND NOT (upe.user_id = ANY (COALESCE(n.mentions, '{}'::uuid[]))) OR a.private = true AND a.created_by <> upe.user_id AND NOT "user".mentioned_in_thread(upe.user_id, a.id));
-- Drop "share_priority" function
DROP FUNCTION IF EXISTS "public"."share_priority" (uuid, uuid, uuid[], uuid[]);
