-- Modify "activate_invited_user" function
CREATE OR REPLACE FUNCTION "public"."activate_invited_user" ("p_user_id" uuid) RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    c_system_instance_id CONSTANT uuid := '0199b6f4-ae64-7718-0000-000000000001'::uuid;
    v_root_priority_id uuid;
    v_fyi_priority_id uuid;
    v_default_role_id uuid;
    v_new_path ltree;
    -- Sentinel sidebar orders so the Inbox and FYI default to the last two
    -- focuses in their role (Inbox then FYI), while user focuses — which take a
    -- now()-epoch-ms order (~1.7e12) — sort above them. See user.priority's
    -- COALESCE(order, epoch_ms(created_at)) and priorities_list._byOrder.
    c_inbox_order CONSTANT double precision := 1e15;
    c_fyi_order CONSTANT double precision := 2e15;
    v_plot_team_group_id uuid;
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
        -- Already active: no new welcome thread was created, so welcome_thread_id
        -- is NULL. Callers use it to dispatch classify jobs for the welcome
        -- thread's internal-team fanout rows; there is nothing new to dispatch.
        RETURN jsonb_build_object('activated', FALSE, 'already_active', TRUE, 'root_priority_id', v_root_priority_id, 'welcome_thread_id', NULL);
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
    -- The Personal role gets its own FYI focus (child of the root in the legacy
    -- ltree, role_id set, is_fyi TRUE), gathering low-signal mail. A normal,
    -- reorderable focus that defaults just below the role's Inbox; muted by
    -- default (early_notifications_enabled = FALSE, no notify_window). Newspaper
    -- icon. No key — idx_priority_key_per_root forbids duplicate keys per root,
    -- and the FYI is identified by is_fyi, not a key.
    INSERT INTO public.priority
        (created_by, user_id, title, path, color, icon, role_id, is_fyi,
         early_notifications_enabled)
    VALUES
        (p_user_id, p_user_id, 'FYI', generate_path(v_new_path), 0, 'newspaper',
         v_default_role_id, TRUE, FALSE)
    RETURNING
        id INTO v_fyi_priority_id;
    -- Seed sentinel sidebar orders so the Inbox then the FYI default to the
    -- bottom two of the role; user focuses (now()-epoch-ms order) sort above.
    INSERT INTO public.priority_setting (user_id, priority_id, key, value)
    VALUES
        (p_user_id, v_root_priority_id, 'order', to_jsonb(c_inbox_order)),
        (p_user_id, v_fyi_priority_id, 'order', to_jsonb(c_fyi_order))
    ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
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
        -- for peer-filing purposes. icon is the stable Plot logo URL (NOT
        -- 'twist:<id>', which resolves client-side via the per-user Plot
        -- twist_instance and would fall back to the generic twist icon when
        -- that instance is archived / not yet synced).
        -- contacts: the synthetic "Plot Team" sender (so the row header
        -- attributes the thread to Plot Team, same as the shared onboarding
        -- threads) PLUS the user's own contact (load-bearing for the user's
        -- own visibility — _otherContactIds excludes self, so only "Plot Team"
        -- shows). groups carries the Plot Team group so replies reach the team.
        -- ONBOARDING:BEGIN welcome-user
        INSERT INTO public.thread (created_by, icon, title, preview, key, topic, contacts, groups)
            VALUES (c_system_instance_id, 'https://plot.day/assets/plot-icon.svg',
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
            VALUES (c_system_instance_id, c_system_instance_id, v_welcome_thread_id, now() + interval '1 millisecond', 'Welcome! For your first 30 days you get unlimited connections on the Free plan — connect as many of your apps as you like. After 30 days you''ll continue on Free with up to 2 connections; add a $5/mo connection add-on for more, or upgrade to Pro for unlimited. Everything you''ve set up stays.', 'core-trial')
        ON CONFLICT (thread_id, link_id, key) WHERE key IS NOT NULL DO NOTHING;
-- ONBOARDING:END welcome-user
    END IF;
    -- Priority routing is learned from user moves (thread_priority.user_moved).
    -- New users start with no training examples; incoming threads land in the
    -- root priority (Inbox) until the user moves one into a focus they create.
    -- classify_thread_for_user then picks that focus up automatically for
    -- similar future threads.
    -- welcome_thread_id lets the caller dispatch classify jobs for the welcome
    -- thread's internal-team fanout rows. Those rows are created by the
    -- AFTER INSERT ON thread peer/group triggers with classify_at = now() but
    -- nothing in-database can enqueue a Cloudflare Queue job, so without the
    -- caller dispatching they'd sit unclassified until the hourly sweep. NULL
    -- when the Plot Team group wasn't seeded (no welcome thread was created).
    RETURN jsonb_build_object('activated', TRUE, 'already_active', FALSE, 'root_priority_id', v_root_priority_id, 'welcome_thread_id', v_welcome_thread_id);
END;
$$;
