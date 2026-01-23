CREATE TABLE "public"."contact_invitation" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "contact_id" uuid NOT NULL,
    "token" text NOT NULL,
    "sent_at" timestamp with time zone NOT NULL DEFAULT now()
);

ALTER TABLE "public"."contact_invitation" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."priority_invitation" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid_v7 (),
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone,
    "priority_id" uuid NOT NULL,
    "contact_id" uuid NOT NULL,
    "invited_by" uuid NOT NULL
);

ALTER TABLE "public"."priority_invitation" ENABLE ROW LEVEL SECURITY;

CREATE UNIQUE INDEX contact_invitation_contact_unique ON public.contact_invitation USING btree (contact_id);

CREATE UNIQUE INDEX contact_invitation_pkey ON public.contact_invitation USING btree (id);

CREATE UNIQUE INDEX contact_invitation_token_key ON public.contact_invitation USING btree (token);

CREATE INDEX idx_contact_invitation_token ON public.contact_invitation USING btree (token);

CREATE INDEX idx_priority_invitation_contact ON public.priority_invitation USING btree (contact_id)
WHERE (archived_at IS NULL);

CREATE INDEX idx_priority_invitation_priority ON public.priority_invitation USING btree (priority_id)
WHERE (archived_at IS NULL);

CREATE UNIQUE INDEX priority_invitation_pkey ON public.priority_invitation USING btree (id);

CREATE UNIQUE INDEX priority_invitation_unique ON public.priority_invitation USING btree (priority_id, contact_id);

ALTER TABLE "public"."contact_invitation"
    ADD CONSTRAINT "contact_invitation_pkey" PRIMARY KEY USING INDEX "contact_invitation_pkey";

ALTER TABLE "public"."priority_invitation"
    ADD CONSTRAINT "priority_invitation_pkey" PRIMARY KEY USING INDEX "priority_invitation_pkey";

ALTER TABLE "public"."contact_invitation"
    ADD CONSTRAINT "contact_invitation_contact_id_fkey" FOREIGN KEY (contact_id) REFERENCES contact (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."contact_invitation" validate CONSTRAINT "contact_invitation_contact_id_fkey";

ALTER TABLE "public"."contact_invitation"
    ADD CONSTRAINT "contact_invitation_contact_unique" UNIQUE USING INDEX "contact_invitation_contact_unique";

ALTER TABLE "public"."contact_invitation"
    ADD CONSTRAINT "contact_invitation_token_key" UNIQUE USING INDEX "contact_invitation_token_key";

ALTER TABLE "public"."priority_invitation"
    ADD CONSTRAINT "priority_invitation_contact_id_fkey" FOREIGN KEY (contact_id) REFERENCES contact (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_invitation" validate CONSTRAINT "priority_invitation_contact_id_fkey";

ALTER TABLE "public"."priority_invitation"
    ADD CONSTRAINT "priority_invitation_invited_by_fkey" FOREIGN KEY (invited_by) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_invitation" validate CONSTRAINT "priority_invitation_invited_by_fkey";

ALTER TABLE "public"."priority_invitation"
    ADD CONSTRAINT "priority_invitation_priority_id_fkey" FOREIGN KEY (priority_id) REFERENCES priority (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_invitation" validate CONSTRAINT "priority_invitation_priority_id_fkey";

ALTER TABLE "public"."priority_invitation"
    ADD CONSTRAINT "priority_invitation_unique" UNIQUE USING INDEX "priority_invitation_unique";

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
        -- Create priority_user entries for pending invitations
        INSERT INTO public.priority_user (user_id, priority_id)
        SELECT
            NEW.id,
            pi.priority_id
        FROM
            public.priority_invitation pi
        WHERE
            pi.contact_id = v_contact_id
            AND pi.archived_at IS NULL
        ON CONFLICT
            DO NOTHING;
        -- Archive the invitations
        UPDATE
            public.priority_invitation
        SET
            archived_at = now()
        WHERE
            contact_id = v_contact_id
            AND archived_at IS NULL;
        -- Activate the user (creates root priority, settings, sets status to active)
        -- This is idempotent and safe to call multiple times
        PERFORM
            public.activate_invited_user (NEW.id);
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.activate_invited_user (p_user_id uuid)
    RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $function$
DECLARE
    v_current_status text;
    v_root_priority_id uuid;
    v_root_priority_path ltree;
    v_new_path ltree;
    v_activation_performed boolean := FALSE;
BEGIN
    -- Check if user is already active
    SELECT
        raw_app_meta_data ->> 'status' INTO v_current_status
    FROM
        auth.users
    WHERE
        id = p_user_id;
    -- If already active, return early
    IF v_current_status = 'active' THEN
        -- Find existing root priority
        SELECT
            priority_id INTO v_root_priority_id
        FROM
            public.priority_user
        WHERE
            user_id = p_user_id
            AND personal = TRUE
        LIMIT 1;
        RETURN jsonb_build_object('activated', FALSE, 'already_active', TRUE, 'root_priority_id', v_root_priority_id);
    END IF;
    -- User is not active, proceed with activation
    v_activation_performed := TRUE;
    -- Check if root priority already exists
    SELECT
        priority_id INTO v_root_priority_id
    FROM
        public.priority_user
    WHERE
        user_id = p_user_id
        AND personal = TRUE
    LIMIT 1;
    IF v_root_priority_id IS NULL THEN
        -- Create root priority
        -- Generate path
        v_new_path := generate_path (NULL);
        -- Insert priority
        INSERT INTO public.priority (created_by, title, path, color)
            VALUES (p_user_id, 'Everything', v_new_path, 0)
        RETURNING
            id, path INTO v_root_priority_id, v_root_priority_path;
        -- Mark the priority_user entry as personal (root)
        -- The insert_priority_user trigger already created a priority_user entry
        UPDATE
            public.priority_user
        SET
            personal = TRUE
        WHERE
            user_id = p_user_id
            AND priority_id = v_root_priority_id;
    END IF;
    -- Create priority settings if they don't exist
    INSERT INTO public.priority_settings (user_id, priority_id)
        VALUES (p_user_id, v_root_priority_id)
    ON CONFLICT (user_id, priority_id)
        DO NOTHING;
    -- Set user status to active
    UPDATE
        auth.users
    SET
        raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb) || jsonb_build_object('status', 'active')
    WHERE
        id = p_user_id;
    RETURN jsonb_build_object('activated', TRUE, 'already_active', FALSE, 'root_priority_id', v_root_priority_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_invitation_token (p_contact_id uuid, p_new_token text)
    RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_token text;
    v_sent_at timestamptz;
BEGIN
    -- Check if invitation already exists
    SELECT
        token,
        sent_at INTO v_token,
        v_sent_at
    FROM
        public.contact_invitation
    WHERE
        contact_id = p_contact_id;
    IF v_token IS NOT NULL THEN
        -- Return existing token and sent_at
        RETURN jsonb_build_object('token', v_token, 'sent_at', v_sent_at, 'is_new', FALSE);
    END IF;
    -- Create new invitation with provided token
    INSERT INTO public.contact_invitation (contact_id, token, sent_at)
        VALUES (p_contact_id, p_new_token, now())
    RETURNING
        token, sent_at INTO v_token, v_sent_at;
    RETURN jsonb_build_object('token', v_token, 'sent_at', v_sent_at, 'is_new', TRUE);
END;
$function$;

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
    -- Accept any pending priority_invitations for this contact
    INSERT INTO public.priority_user (user_id, priority_id)
    SELECT
        p_user_id,
        pi.priority_id
    FROM
        public.priority_invitation pi
    WHERE
        pi.contact_id = v_contact_id
        AND pi.archived_at IS NULL
    ON CONFLICT
        DO NOTHING;
    -- Archive the priority_invitations
    UPDATE
        public.priority_invitation
    SET
        archived_at = now()
    WHERE
        contact_id = v_contact_id
        AND archived_at IS NULL;
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
            IF v_contact.user_id IS NOT NULL THEN
                -- Contact is an existing user - create priority_user
                INSERT INTO public.priority_user (user_id, priority_id, personal)
                    VALUES (v_contact.user_id, p_priority_id, FALSE)
                ON CONFLICT (user_id, priority_id)
                    DO UPDATE SET
                        archived_at = NULL;
            ELSE
                -- Contact only - create priority_invitation
                INSERT INTO public.priority_invitation (priority_id, contact_id, invited_by)
                    VALUES (p_priority_id, v_actor_id, p_user_id)
                ON CONFLICT (priority_id, contact_id)
                    DO UPDATE SET
                        archived_at = NULL;
                -- Also create priority_contact so the contact/invitation syncs
                INSERT INTO public.priority_contact (priority_id, contact_id)
                    VALUES (p_priority_id, v_actor_id)
                ON CONFLICT (priority_id, contact_id)
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
            IF v_contact.user_id IS NOT NULL THEN
                -- Archive priority_user
                UPDATE
                    public.priority_user
                SET
                    archived_at = now()
                WHERE
                    user_id = v_contact.user_id
                    AND priority_id = p_priority_id
                    AND archived_at IS NULL;
            END IF;
            -- Always try to archive invitation (contact might have been invited before they had a user)
            UPDATE
                public.priority_invitation
            SET
                archived_at = now()
            WHERE
                contact_id = v_actor_id
                AND priority_id = p_priority_id
                AND archived_at IS NULL;
            -- Also archive priority_contact for non-user contacts
            -- Note: For users, priority_contact archival is handled by the trigger on priority_user
            UPDATE
                public.priority_contact
            SET
                archived_at = now()
            WHERE
                contact_id = v_actor_id
                AND priority_id = p_priority_id
                AND archived_at IS NULL
                -- Only if contact doesn't have a user (otherwise trigger handles it)
                AND NOT EXISTS (
                    SELECT
                        1
                    FROM
                        public.contact c
                    WHERE
                        c.id = v_actor_id
                        AND c.user_id IS NOT NULL);
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

CREATE OR REPLACE FUNCTION public.sync_user_for_priority_invitation ()
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
                AND entity = 'priority_invitation';
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'priority_invitation', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
            SELECT
                last_sync_at INTO v_current_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'priority_invitation';
            IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at) THEN
                v_users_to_notify := array_append(v_users_to_notify, v_user_id);
            END IF;
        END LOOP;
    -- Also notify invitees who have user accounts (so they can see their pending invitations)
    FOR v_user_id IN SELECT DISTINCT
        c.user_id
    FROM
        new_table n
        JOIN contact c ON c.id = n.contact_id
    WHERE
        c.user_id IS NOT NULL
        AND c.archived_at IS NULL LOOP
            SELECT
                last_update_at,
                last_sync_at INTO v_prev_update_at,
                v_prev_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'priority_invitation';
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'priority_invitation', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
            SELECT
                last_sync_at INTO v_current_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'priority_invitation';
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

CREATE OR REPLACE FUNCTION public.update_invitation_sent_at (p_contact_id uuid)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
BEGIN
    UPDATE
        public.contact_invitation
    SET
        sent_at = now()
    WHERE
        contact_id = p_contact_id;
END;
$function$;

CREATE POLICY "Invitees can view their invitations" ON "public"."priority_invitation" AS permissive
    FOR SELECT TO authenticated
        USING ((contact_id IN (
            SELECT
                contact.id
            FROM
                contact
            WHERE ((contact.user_id = auth.uid ()) AND (contact.archived_at IS NULL)))));

CREATE POLICY "Users can manage invitations for their priorities" ON "public"."priority_invitation" AS permissive
    FOR ALL TO authenticated
        USING (user_has_priority_access (auth.uid (), priority_id));

CREATE TRIGGER set_priority_invitation_updated_at
    BEFORE INSERT OR UPDATE ON public.priority_invitation
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER user_sync_priority_invitation_insert
    AFTER INSERT ON public.priority_invitation REFERENCING NEW TABLE AS new_table
    FOR EACH STATEMENT
    EXECUTE FUNCTION sync_user_for_priority_invitation ();

CREATE TRIGGER user_sync_priority_invitation_update
    AFTER UPDATE ON public.priority_invitation REFERENCING NEW TABLE AS new_table
    FOR EACH STATEMENT
    EXECUTE FUNCTION sync_user_for_priority_invitation ();

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
ALTER VIEW "public"."user_priority_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);
