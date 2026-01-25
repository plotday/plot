DROP TRIGGER IF EXISTS "sync_priority_contact_delete" ON "public"."priority_user";

DROP TRIGGER IF EXISTS "sync_priority_contact_insert" ON "public"."priority_user";

DROP TRIGGER IF EXISTS "sync_priority_contact_update" ON "public"."priority_user";

DROP POLICY "Users can view contacts linked to their priorities" ON "public"."contact";

DROP FUNCTION IF EXISTS "public"."sync_priority_contact_on_delete" ();

DROP FUNCTION IF EXISTS "public"."sync_priority_contact_on_insert" ();

DROP FUNCTION IF EXISTS "public"."sync_priority_contact_on_update" ();

DROP VIEW IF EXISTS "public"."priority_member";

DROP VIEW IF EXISTS "public"."user_actor";

DROP VIEW IF EXISTS "public"."user_priority_actor";

-- Step 1: Add new columns while keeping archived_at temporarily
ALTER TABLE "public"."priority_contact"
    ADD COLUMN "invited_at" timestamp with time zone;

ALTER TABLE "public"."priority_contact"
    ADD COLUMN "updated_at" timestamp with time zone NOT NULL DEFAULT now();

-- Step 2: Migrate existing data
-- For active invitations (archived_at IS NULL), set invited_at = created_at
UPDATE
    priority_contact
SET
    invited_at = created_at
WHERE
    invited_by IS NOT NULL
    AND archived_at IS NULL;

-- For cancelled invitations (archived_at IS NOT NULL), leave invited_at as NULL
-- The cancelled time is already in archived_at, which we'll keep in updated_at
UPDATE
    priority_contact
SET
    updated_at = GREATEST (created_at, COALESCE(archived_at, created_at))
WHERE
    invited_by IS NOT NULL;

-- Step 3: Drop old column
ALTER TABLE "public"."priority_contact"
    DROP COLUMN "archived_at";

SET check_function_bodies = OFF;

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
            AND pc.invited_at IS NOT NULL
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
    GREATEST (pc.updated_at, COALESCE(pu.updated_at, pc.created_at), COALESCE(c.updated_at, pc.created_at)) AS updated_at,
    CASE WHEN ((pc.invited_by IS NOT NULL)
        AND (pc.invited_at IS NULL)) THEN
        pc.updated_at
    ELSE
        pu.archived_at
    END AS archived_at,
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
                AND (pu.priority_id = pc.priority_id))))
WHERE ((pu.user_id IS NOT NULL)
    OR (pc.invited_by IS NOT NULL));

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
        AND pc.invited_at IS NOT NULL
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

CREATE OR REPLACE FUNCTION public.sync_user_for_contact ()
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
    -- Contact changes affect all users with access to priorities where this contact is linked (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN priority_contact pc ON pc.contact_id = n.id
        JOIN user_priority_expanded upe ON upe.priority_id = pc.priority_id
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
    -- Get max updated_at from priority_contact changes
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
            -- Handle priority_member entity only for actual invitations (invited_by IS NOT NULL)
            IF EXISTS (
                SELECT
                    1
                FROM
                    new_table n2
                WHERE
                    n2.invited_by IS NOT NULL) THEN
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

CREATE OR REPLACE FUNCTION public.update_activity_tags (p_activity_id uuid, p_actor_id uuid, p_client_id integer, p_tag_updates jsonb, p_occurrence text DEFAULT NULL::text)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    tag_record record;
    tag_id_int integer;
    is_adding boolean;
    current_tag_type tag_type;
BEGIN
    -- Validate that activity_id is provided
    IF p_activity_id IS NULL THEN
        RAISE EXCEPTION 'p_activity_id must be provided';
    END IF;
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
            -- Prevent insertion of computed tags (tag_id 1-99)
            -- Computed tags should only exist as calculated values
            IF current_tag_type = 'compute' THEN
                RAISE EXCEPTION 'Cannot add computed tag (tag_id: %) - these tags are calculated from activity state', tag_id_int;
            END IF;
            IF is_adding THEN
                -- Adding a tag - use upsert to create or reactivate
                INSERT INTO activity_tag (actor_id, activity_id, occurrence, tag_id, updated_at, archived_at, updated_by)
                    VALUES (p_actor_id, p_activity_id, p_occurrence, tag_id_int, now(), NULL, p_client_id)
                ON CONFLICT (actor_id, activity_id, occurrence, tag_id)
                    DO UPDATE SET
                        archived_at = NULL,
                        updated_at = now(),
                        updated_by = p_client_id;
                -- Ensure priority_contact exists if actor is a contact
                -- This allows contacts to be visible via RLS when tagged on activities
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
                    activity a
                WHERE
                    a.id = p_activity_id
                ON CONFLICT (priority_id,
                    contact_id)
                    DO NOTHING;
            END IF;
        ELSE
            -- Removing a tag - use update to soft delete existing records
            IF current_tag_type = 'toggle' THEN
                -- For toggle tags, remove all users' tags
                UPDATE
                    activity_tag
                SET
                    archived_at = now(),
                    updated_by = p_client_id
                WHERE
                    activity_id = p_activity_id
                    AND tag_id = tag_id_int
                    AND (occurrence IS NOT DISTINCT FROM p_occurrence)
                    AND archived_at IS NULL;
            ELSE
                -- For count/compute tags, only remove current actor's tag
                UPDATE
                    activity_tag
                SET
                    archived_at = now(),
                    updated_by = p_client_id
                WHERE
                    activity_id = p_activity_id
                    AND tag_id = tag_id_int
                    AND actor_id = p_actor_id
                    AND (occurrence IS NOT DISTINCT FROM p_occurrence)
                    AND archived_at IS NULL;
            END IF;
        END IF;
END LOOP;
END;
$function$;

CREATE OR REPLACE VIEW "public"."user_priority_actor" AS
SELECT
    user_id,
    priority_path,
    actor_id,
    created_at,
    updated_at,
    archived_at
FROM (
    SELECT
        upe.user_id,
        p.path AS priority_path,
        pc.contact_id AS actor_id,
        LEAST (COALESCE(pc.created_at, c.created_at), COALESCE(c.created_at, pc.created_at)) AS created_at,
        GREATEST (COALESCE(pc.created_at, c.updated_at), COALESCE(c.updated_at, pc.created_at)) AS updated_at,
        c.archived_at
    FROM (((user_priority_expanded upe
                JOIN priority_contact pc ON (pc.priority_id = upe.priority_id))
            JOIN contact c ON (c.id = pc.contact_id))
        JOIN priority p ON (p.id = pc.priority_id))
UNION ALL
SELECT
    upe.user_id,
    p.path AS priority_path,
    pt.id AS actor_id,
    pt.created_at,
    pt.updated_at,
    pt.archived_at
FROM ((user_priority_expanded upe
        JOIN priority_twist pt ON (pt.priority_id = upe.priority_id))
    JOIN priority p ON (p.id = pt.priority_id))) actors;

CREATE OR REPLACE VIEW "public"."user_actor" AS
WITH upa_agg AS (
    SELECT
        upa.user_id,
        upa.actor_id,
        COALESCE(min(upa.updated_at) FILTER (WHERE (upa.archived_at IS NULL)), max(upa.archived_at)) AS updated_at,
        CASE WHEN (count(*) FILTER (WHERE (upa.archived_at IS NULL)) = 0) THEN
            max(upa.archived_at)
        ELSE
            NULL::timestamp with time zone
        END AS archived_at
    FROM
        user_priority_actor upa
    GROUP BY
        upa.user_id,
        upa.actor_id
)
SELECT
    ua.user_id,
    a.id,
    a.created_at,
    GREATEST (ua.updated_at, a.updated_at) AS updated_at,
    COALESCE(a.archived_at, ua.archived_at) AS archived_at,
    a.type,
    a.name,
    a.email,
    a.avatar_url,
    (EXISTS (
            SELECT
                1
            FROM
                contact c
            WHERE ((c.id = a.id)
                AND (c.user_id = ua.user_id)))) AS self
FROM (upa_agg ua
    JOIN actor a ON (a.id = ua.actor_id));

CREATE POLICY "Users can view contacts linked to their priorities" ON "public"."contact" AS permissive
    FOR SELECT TO authenticated
        USING ((EXISTS (
            SELECT
                1
            FROM
                priority_contact pc
            WHERE ((pc.contact_id = contact.id) AND user_has_priority_access (auth.uid (), pc.priority_id)))));

CREATE TRIGGER set_priority_contact_updated_at
    BEFORE UPDATE ON public.priority_contact
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

ALTER VIEW "public"."user_note" SET (security_invoker = TRUE);

ALTER VIEW "public"."note_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_note_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_twist" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_exception" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_twist_activity_update" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_twist_note_create" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_twist_activity_create" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_twist_note_update" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_expanded" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_settings_inherited" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_twist_activity_tag_change" SET (security_invoker = TRUE);

ALTER VIEW public.priority_member SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child_twist" SET (security_invoker = TRUE);

