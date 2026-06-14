-- Create "default_role_id" function first: the backfill UPDATE below calls it.
CREATE FUNCTION "public"."default_role_id" ("p_user_id" uuid) RETURNS uuid LANGUAGE sql STABLE SET "search_path" = public AS $$
SELECT id
    FROM public.role
    WHERE user_id = p_user_id
      AND archived_at IS NULL
    ORDER BY created_at ASC
    LIMIT 1
$$;
-- Require every focus to have a role unless it is the global FYI focus. Added
-- NOT VALID first, then VALIDATE in a separate statement, so the existing-row
-- scan does not hold an ACCESS EXCLUSIVE lock for its full duration — Squawk
-- rejects a plain validating ADD CONSTRAINT in migrations/ for this reason.
ALTER TABLE "public"."priority" ADD CONSTRAINT "priority_role_or_fyi" CHECK ((role_id IS NOT NULL) OR is_fyi) NOT VALID;
-- Backfill: file every live, role-less, non-FYI focus under its owner's default
-- role (their oldest live role) before validating. Mirrors the focus-roles
-- expand backfill; the UPDATE fires apply_role_change_to_focus so each focus
-- adopts its new role's colour/notifications (a value-less focus follows; an
-- overridden one keeps its value) and bumps priority.seq so clients re-pull.
-- Runs after default_role_id exists; the NOT VALID constraint already checks
-- these UPDATEs, which set role_id non-null, so they pass.
UPDATE public.priority p
   SET role_id = public.default_role_id(p.user_id)
 WHERE p.role_id IS NULL
   AND p.is_fyi = FALSE
   AND p.archived_at IS NULL;
ALTER TABLE "public"."priority" VALIDATE CONSTRAINT "priority_role_or_fyi";
-- Modify "activate_invited_user" function
CREATE OR REPLACE FUNCTION "public"."activate_invited_user" ("p_user_id" uuid) RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    c_system_instance_id CONSTANT uuid := '0199b6f4-ae64-7718-0000-000000000001'::uuid;
    c_twist_package_id CONSTANT uuid := '0199b6f4-ae64-7718-8a02-44716f30358f'::uuid;
    v_root_priority_id uuid;
    v_default_role_id uuid;
    v_new_path ltree;
    v_plot_team_group_id uuid;
    v_plot_twist_id bigint;
    v_user_contact_id uuid;
    v_welcome_thread_id uuid;
BEGIN
    -- Already has a root priority?
    SELECT
        id INTO v_root_priority_id
    FROM
        public.priority
    WHERE
        user_id = p_user_id
        AND nlevel (path) = 1
    ORDER BY
        created_at ASC
    LIMIT 1;
    IF v_root_priority_id IS NOT NULL THEN
        RETURN jsonb_build_object('activated', FALSE, 'already_active', TRUE, 'root_priority_id', v_root_priority_id);
    END IF;
    -- Every user gets a default "Personal" role (theme 0); the root priority
    -- becomes its Inbox. Create the role FIRST so the root can be inserted with
    -- role_id already set: the priority_role_or_fyi CHECK is evaluated at INSERT
    -- time, so the old "insert root, then UPDATE role_id" ordering would now
    -- fail. Mirrors the focus-roles backfill so new users match existing ones,
    -- guaranteeing every user has >=1 role and no role-less focus.
    -- default_role_user_id fills "order"; the root's colour is 0 and
    -- notifications NULL, so the Inbox trivially follows the role.
    INSERT INTO public.role (created_by, user_id, name, color)
        VALUES (p_user_id, p_user_id, 'Personal', 0)
    RETURNING
        id INTO v_default_role_id;
    -- Create the root priority as that role's Inbox. default_priority_user_id
    -- fills user_id from created_by, so the new row is fully owned by the user.
    v_new_path := generate_path (NULL);
    INSERT INTO public.priority (created_by, user_id, title, path, color, role_id, is_inbox)
        VALUES (p_user_id, p_user_id, 'Everything', v_new_path, 0, v_default_role_id, TRUE)
    RETURNING
        id INTO v_root_priority_id;
    -- Every user gets one global, role-less FYI focus (child of the root in the
    -- legacy ltree, role_id NULL, is_fyi TRUE). Muted by default
    -- (early_notifications_enabled = FALSE, no notify_window). The classifier
    -- files low-signal mail here; it renders just above "Everything".
    INSERT INTO public.priority
        (created_by, user_id, title, path, color, key, role_id, is_fyi,
         early_notifications_enabled)
    VALUES
        (p_user_id, p_user_id, 'FYI', generate_path(v_new_path), 0, 'fyi',
         NULL, TRUE, FALSE);
    -- Resolve the Plot Team group once — used for the welcome thread's
    -- groups array (so the user's first message reaches the Plot team).
    -- Prefer the full "Plot" team's auto-maintained group (everyone on the
    -- team, what we want in prod); fall back to the Plot publisher admin
    -- group for environments where the Plot team doesn't exist yet.
    SELECT
        COALESCE((
            SELECT
                g.id
            FROM public.group g
            JOIN public.team t ON t.id = g.team_id
            WHERE
                g.auto_maintained = TRUE
                AND g.auto_team_admin_team_id IS NULL
                AND t.name = 'Plot' LIMIT 1), (
        SELECT
            g.id
        FROM public.group g
        WHERE
            g.auto_maintained = TRUE
            AND g.auto_publisher_id = (
                SELECT
                    id
                FROM public.publisher
            WHERE
                name = 'Plot' LIMIT 1)
LIMIT 1)) INTO v_plot_team_group_id;
    -- No special hardcoded focuses are seeded. Onboarding threads (the
    -- per-user welcome below and the shared global onboarding set) land in
    -- the user's Inbox/root via classify_thread_for_user's root_fallback and
    -- a shared topic = 'onboarding'. The user organizes them however they
    -- like; moving one into a focus carries the rest along (topic match).
    -- Seed a per-user welcome thread authored by the shared system Plot
    -- twist_instance (same pattern as the global onboarding threads). The
    -- thread is visible only to the new user (via contacts) and the Plot
    -- Team (via groups). It pins to the top of the user's agenda with
    -- order = 50, ahead of the global 'welcome' thread (order = 100).
    --
    -- Skipped entirely when the Plot Team group hasn't been seeded yet —
    -- avoids noisy welcomes in ephemeral test databases that don't have
    -- the Plot publisher/team bootstrapped.
    IF v_plot_team_group_id IS NOT NULL THEN
        SELECT
            id INTO v_plot_twist_id
        FROM
            public.twist
        WHERE
            twist_package_id = c_twist_package_id
            AND environment = 'public'
        LIMIT 1;
        -- The API worker inserts the primary contact row a moment after
        -- this trigger runs, so user_contact may not exist yet. Seed it
        -- ourselves via upsert_user_contact (idempotent via ON CONFLICT
        -- (email) + ON CONFLICT (user_id, contact_id)) so the welcome
        -- thread's contacts array has the user's primary contact from
        -- the start.
        DECLARE v_user_email text;
        v_user_name text;
        v_user_avatar text;
        BEGIN
            SELECT
                email,
                name,
                avatar_url INTO v_user_email,
                v_user_name,
                v_user_avatar
            FROM
                public."user"
            WHERE
                id = p_user_id;
            IF v_user_email IS NOT NULL THEN
                PERFORM
                    public.upsert_user_contact (p_user_id, v_user_email, v_user_name, v_user_avatar);
            END IF;
        END;
        SELECT
            contact_id INTO v_user_contact_id
        FROM
            public.user_contact
        WHERE
            user_id = p_user_id
            AND "primary" = TRUE
            AND linked = TRUE
            AND archived_at IS NULL
        LIMIT 1;
        -- twist_id is intentionally NULL: welcome-user is a per-user thread
        -- and must not participate in cross-user (twist_id, key) dedup. The
        -- twist_instance_id in created_by is what makes this "twist-authored"
        -- for peer-filing purposes; icon preserves the visual attribution.
        -- contacts: the synthetic "Plot Team" sender (so the row header
        -- attributes the thread to Plot Team, same as the shared onboarding
        -- threads) PLUS the user's own contact (load-bearing for the user's
        -- own visibility — _otherContactIds excludes self, so only "Plot Team"
        -- shows). groups carries the Plot Team group so replies reach the team.
        -- ONBOARDING:BEGIN welcome-user
        INSERT INTO public.thread (created_by, icon, title, preview, key, topic, contacts, groups)
            VALUES (c_system_instance_id, CASE WHEN v_plot_twist_id IS NOT NULL THEN 'twist:' || v_plot_twist_id::text END,
                'Welcome to Plot!', 'We''re so glad something brought you here.', 'welcome-user', 'onboarding',
                ARRAY[c_system_instance_id] || (CASE WHEN v_user_contact_id IS NOT NULL THEN ARRAY[v_user_contact_id] ELSE ARRAY[]::uuid[] END),
                ARRAY[v_plot_team_group_id])
        RETURNING id INTO v_welcome_thread_id;
        INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
            VALUES (v_welcome_thread_id, p_user_id, v_root_priority_id)
        ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;
        INSERT INTO public.thread_state (user_id, thread_id, importance, "order", "on")
            VALUES (p_user_id, v_welcome_thread_id, 100, 50, daterange('1970-01-01', NULL))
        ON CONFLICT (user_id, thread_id) DO NOTHING;
        INSERT INTO public.note (author_id, created_by, thread_id, source_created_at, content, key)
            VALUES (c_system_instance_id, c_system_instance_id, v_welcome_thread_id, now() + interval '0 millisecond', 'We''re so glad something brought you here.
Maybe you''re trying to get traction on something new by bringing all the scattered pieces together.
You might be part of a team doing big things and want to overcome collaboration overhead.
Perhaps your life is full of many good things and you want to give them all your best.

Plot is built for making progress on what matters and getting more done with others.
Rather than chasing Inbox Zero, we believe in investing your time and attention based on your priorities.
Plot supports you working with others in the areas you choose while gathering everything else for the right time.

We''d love to hear what you''re working on and how Plot can help. Feel free to reply in this thread that includes the Plot team.', 'welcome')
        ON CONFLICT (thread_id, link_id, key) WHERE key IS NOT NULL DO NOTHING;
        INSERT INTO public.note (author_id, created_by, thread_id, source_created_at, content, key)
            VALUES (c_system_instance_id, c_system_instance_id, v_welcome_thread_id, now() + interval '1 millisecond', 'Your account has been upgraded to the **Core plan** free for 30 days so you can try up to 5 connections and 2 twists. You can choose to keep the upgrade or go **Pro** at any time. Otherwise, after 30 days, you''ll automatically continue on the Free plan, which includes unlimited history and sharing. Any connections or twists over your new limit will be archived.', 'core-trial')
        ON CONFLICT (thread_id, link_id, key) WHERE key IS NOT NULL DO NOTHING;
-- ONBOARDING:END welcome-user
    END IF;
    -- Priority routing is learned from user moves (thread_priority.user_moved).
    -- New users start with no training examples; incoming threads land in the
    -- root priority (Inbox) until the user moves one into a focus they create.
    -- classify_thread_for_user then picks that focus up automatically for
    -- similar future threads.
    RETURN jsonb_build_object('activated', TRUE, 'already_active', FALSE, 'root_priority_id', v_root_priority_id);
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
    -- Flat-client compatibility: clients on the flattened model (apiVersion
    -- >= 4) have no nesting and do not send a path. Keep the existing path on
    -- update; on insert synthesize a child-of-root path so nested (old)
    -- clients can still place the new focus under the user's root. path is
    -- NOT NULL, so this must never leave it null.
    IF _input.path IS NULL THEN
        IF _priority_exists THEN
            _input.path := _old_path;
        ELSE
            DECLARE
                _root_path ltree;
            BEGIN
                SELECT
                    path INTO _root_path
                FROM priority
                WHERE user_id = upsert_priority.user_id AND nlevel(path) = 1
                ORDER BY created_at ASC
                LIMIT 1;
                IF _root_path IS NULL THEN
                    -- No root yet: treat this as the root itself.
                    _input.path := generate_path(NULL);
                ELSE
                    _input.path := _root_path || generate_path(NULL);
                END IF;
            END;
        END IF;
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
    -- For a NEW focus, default the role + colour so it starts out following a
    -- role. Existing focuses keep their stored role (role change is modal-only
    -- and guarded by present-key semantics in the ON CONFLICT branch below).
    IF NOT _priority_exists THEN
        -- Role: explicit from input (API >= 5), else the user's default role
        -- (their oldest live role — the Personal role). Every user has >= 1 role
        -- after backfill / activation, so this is non-null for live focuses and
        -- satisfies the priority_role_or_fyi CHECK.
        IF _input.role_id IS NULL THEN
            _input.role_id := public.default_role_id (upsert_priority.user_id);
        END IF;
        -- Colour: the creator's chosen colour, else the role's colour, so a
        -- new focus starts out following its role.
        IF _input.color IS NULL THEN
            SELECT color INTO _input.color
            FROM public.role
            WHERE id = _input.role_id;
        END IF;
    END IF;
    -- Update priority table
    IF NOT _is_move THEN
        INSERT INTO priority (id, user_id, archived_at, title, color, icon, path, role_id, created_by, updated_by, description, notification_cleared_at)
            VALUES (_input.id, upsert_priority.user_id, _input.archived_at, _input.title, CASE WHEN _is_creator THEN
                    _input.color
                ELSE
                    NULL
                END, _input.icon, _input.path, _input.role_id, _input.created_by, _input.updated_by, p_priority ->> 'description', _input.notification_cleared_at)
        ON CONFLICT (id)
            DO UPDATE SET
                archived_at = _input.archived_at,
                title = _input.title,
                color = CASE WHEN _is_creator THEN
                    _input.color
                ELSE
                    priority.color
                END,
                -- COALESCE: old (nested) clients don't send icon; preserve the
                -- existing value rather than wiping it on every edit.
                icon = COALESCE(_input.icon, priority.icon),
                updated_by = _input.updated_by,
                -- Present-key semantics: only overwrite description when the
                -- caller actually sent it; preserve it otherwise. facet_filters
                -- is owned by the server-side derivation, never set here.
                description = CASE WHEN p_priority ? 'description'
                    THEN p_priority ->> 'description' ELSE priority.description END,
                -- Role change is modal-only (API >= 5): only move the focus when
                -- the caller explicitly sent role_id, so old clients (which don't
                -- send it) never reassign the focus. A non-null sent role_id fires
                -- apply_role_change_to_focus (BEFORE UPDATE OF role_id) for
                -- follow-if-matching colour/notification adoption.
                role_id = CASE WHEN (p_priority ? 'role_id') AND _input.role_id IS NOT NULL
                    THEN _input.role_id ELSE priority.role_id END,
                notification_cleared_at = GREATEST(priority.notification_cleared_at, _input.notification_cleared_at)
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
            icon = COALESCE(_input.icon, priority.icon),
            updated_by = _input.updated_by,
            notification_cleared_at = GREATEST(priority.notification_cleared_at, _input.notification_cleared_at)
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
$$;
