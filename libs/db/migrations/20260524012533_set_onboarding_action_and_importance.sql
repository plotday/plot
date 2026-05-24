-- Modify "activate_invited_user" function
CREATE OR REPLACE FUNCTION "public"."activate_invited_user" ("p_user_id" uuid) RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    c_system_instance_id CONSTANT uuid := '0199b6f4-ae64-7718-0000-000000000001';
    c_twist_package_id CONSTANT uuid := '0199b6f4-ae64-7718-8a02-44716f30358f';
    v_root_priority_id uuid;
    v_using_plot_id uuid;
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
    -- Create the root priority. default_priority_user_id fills user_id
    -- from created_by, so the new row is fully owned by the user.
    v_new_path := generate_path (NULL);
    INSERT INTO public.priority (created_by, user_id, title, path, color)
        VALUES (p_user_id, p_user_id, 'Everything', v_new_path, 0)
    RETURNING
        id INTO v_root_priority_id;
    -- Resolve the Plot Team group once — used for the Using Plot priority
    -- config and for the welcome thread's groups array. Prefer the full
    -- "Plot" team's auto-maintained group (everyone on the team, what we
    -- want in prod); fall back to the Plot publisher admin group for
    -- environments where the Plot team doesn't exist yet.
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
    -- Create Using Plot (@plot.app). Config pins new threads to the
    -- feedback topic, auto-shares them with the Plot team, and hides the
    -- agenda tab so the priority acts like a feedback channel. The
    -- `groupLabel` is what the UI renders on the locked chip, decoupled
    -- from whatever the underlying group happens to be named locally.
    INSERT INTO public.priority (created_by, user_id, title, path, color, key, default_thread_icon, config)
        VALUES (p_user_id, p_user_id, 'Using Plot', v_new_path || generate_path (NULL), 7, '@plot.app', 'https://plot.day/assets/plot-icon.svg', jsonb_build_object('topic', 'feedback', 'group', v_plot_team_group_id::text, 'groupLabel', 'Plot Team', 'view', 'activity'))
    RETURNING
        id INTO v_using_plot_id;
    -- Pin Using Plot to the bottom of the priorities list. The user.priority
    -- view falls back to `extract(epoch FROM created_at) * 1000` when no
    -- explicit order setting exists, which would put this priority above
    -- anything the user creates later (the activation row is the oldest).
    -- 1e15 sits well past any plausible epoch_ms value so every
    -- naturally-defaulted order sorts ahead of it.
    INSERT INTO public.priority_setting (user_id, priority_id, key, value)
        VALUES (p_user_id, v_using_plot_id, 'order', to_jsonb(1e15::double precision));
    -- Twist Development (@plot.twist-dev) is created lazily on first deploy
    -- via ensure_twist_dev_priority, so users who never develop twists don't
    -- carry an unused priority.
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
        INSERT INTO public.thread (created_by, icon, title, preview, key, topic, contacts, groups)
            VALUES (c_system_instance_id, CASE WHEN v_plot_twist_id IS NOT NULL THEN
                    'twist:' || v_plot_twist_id::text
                END, 'Welcome to Plot!', 'Glad something brought you here.', 'welcome-user', 'priority:@plot.app:welcome-user', CASE WHEN v_user_contact_id IS NOT NULL THEN
                    ARRAY[v_user_contact_id]
                ELSE
                    ARRAY[]::uuid[]
                END, ARRAY[v_plot_team_group_id])
        RETURNING
            id INTO v_welcome_thread_id;
        -- file_thread_priority_peers short-circuits for twist-authored
        -- threads, so file the new user into their own Using Plot manually.
        INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
            VALUES (v_welcome_thread_id, p_user_id, v_using_plot_id)
        ON CONFLICT ON CONSTRAINT thread_priority_pkey
            DO NOTHING;
        -- importance = 100 puts this thread at the top of Catch up, above
        -- the global onboarding sequence seeded by file_onboarding_schedules
        -- (which starts at importance = 95 for the 'welcome' thread).
        INSERT INTO public.thread_unread (user_id, thread_id, urgency, importance)
            VALUES (p_user_id, v_welcome_thread_id, 'inform-updates', 100)
        ON CONFLICT (user_id, thread_id)
            DO NOTHING;
        -- Pin to top of agenda for the new user only. Plot team members
        -- are filed by file_thread_priority_for_group_members but do NOT
        -- receive a schedule row — the welcome stays off their agendas.
        -- action = 'read' places it in the Read tab of the activity feed
        -- (informational thread with no actionable todo).
        INSERT INTO public.schedule (thread_id, user_id, "order", reason, action, "on")
            VALUES (v_welcome_thread_id, p_user_id, 50, 'add', 'read', daterange('1970-01-01', NULL))
        ON CONFLICT (thread_id, user_id)
    WHERE
        user_id IS NOT NULL
        AND occurrence IS NULL
            DO NOTHING;
        INSERT INTO public.note (author_id, created_by, thread_id, source_created_at, content, key)
            VALUES (c_system_instance_id, c_system_instance_id, v_welcome_thread_id, now(), 'Glad something brought you here. Maybe it''s a project you''re ready to move on, a team you want to work with more clearly, or a sense that more is possible when you direct your best energy into your most important work. Too much initiative gets absorbed by the overhead of modern work — tools built to move us faster that often leave us so busy and scattered that real progress slows to a crawl.

Plot is being built for a different way of working, one where you choose your focus and have what you need to make progress. Human initiative, creativity, and wisdom drive meaningful work forward, and technology should create the space for them to thrive.

We''d love to know what brought you to Plot and what you''re hoping to make progress on. Tell us what you''re trying to achieve, where you''re stuck, or what''s not quite working yet. We read every reply and shape Plot through what we''re learning together.', 'welcome')
        ON CONFLICT (thread_id, link_id, key)
            WHERE key IS NOT NULL
            DO NOTHING;
        -- Announce the reverse trial on the same thread so the user sees
        -- plan status alongside their onboarding message. TrialReminder DO
        -- adds reminder-7day / reminder-2day / upgraded notes here later
        -- via addTrialNote() (keyed on note.key for idempotency).
        INSERT INTO public.note (author_id, created_by, thread_id, source_created_at, content, key)
            VALUES (c_system_instance_id, c_system_instance_id, v_welcome_thread_id, now() + interval '1 millisecond', 'Your account has been upgraded to the **Core plan** free for 30 days so you can try up to 5 connections and 2 twists. You can choose to keep the upgrade or go **Pro** at any time. Otherwise, after 30 days, you''ll automatically continue on the Free plan, which includes unlimited history and sharing. Any connections or twists over your new limit will be archived.', 'core-trial')
        ON CONFLICT (thread_id, link_id, key)
            WHERE key IS NOT NULL
            DO NOTHING;
    END IF;
    -- Onboarding routing is now learned from user moves (thread_priority.user_moved).
    -- New users start with no training examples; incoming threads land in the
    -- root priority until the user moves one into "Using Plot". classify_thread_for_user
    -- then picks that priority up automatically for similar future threads.
    RETURN jsonb_build_object('activated', TRUE, 'already_active', FALSE, 'root_priority_id', v_root_priority_id);
END;
$$;
-- Modify "file_onboarding_schedules" function
CREATE OR REPLACE FUNCTION "public"."file_onboarding_schedules" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_thread_key text;
    v_date_offset integer;
    v_order integer;
    v_action text;
    v_importance smallint;
BEGIN
    -- Skip if explicitly requested (e.g. during repair migrations for existing users)
    IF current_setting('plot.skip_onboarding_schedules', true) = 'true' THEN
        RETURN NEW;
    END IF;

    SELECT key INTO v_thread_key FROM public.thread WHERE id = NEW.thread_id;

    IF v_thread_key IN ('welcome', 'priorities', 'connections', 'getting-around', 'invest-your-time', 'twists', 'notifications', 'clean-up') THEN
        -- action partitions each thread into the Activity feed action tab:
        --   'do'   — threads that ask the user to take a concrete action
        --            (matches the keys handled by file_onboarding_todos).
        --   'read' — informational threads with no actionable todo.
        -- importance controls Catch up ordering (higher = nearer the top).
        -- Values descend in the natural reading order; 'welcome-user'
        -- (importance 100, handled in activate_invited_user) sits above
        -- the global 'welcome' here.
        CASE v_thread_key
            WHEN 'welcome'           THEN v_date_offset := 0; v_order := 100; v_action := 'read'; v_importance := 95;
            WHEN 'priorities'        THEN v_date_offset := 0; v_order := 200; v_action := 'do';   v_importance := 90;
            WHEN 'connections'       THEN v_date_offset := 0; v_order := 300; v_action := 'do';   v_importance := 85;
            WHEN 'getting-around'    THEN v_date_offset := 0; v_order := 400; v_action := 'read'; v_importance := 80;
            WHEN 'invest-your-time'  THEN v_date_offset := 1; v_order := 50;  v_action := 'read'; v_importance := 75;
            WHEN 'twists'            THEN v_date_offset := 1; v_order := 100; v_action := 'do';   v_importance := 70;
            WHEN 'notifications'     THEN v_date_offset := 2; v_order := 100; v_action := 'do';   v_importance := 65;
            WHEN 'clean-up'          THEN v_date_offset := 3; v_order := 100; v_action := 'read'; v_importance := 60;
        END CASE;

        IF v_date_offset = 0 THEN
            -- "Started" status (epoch sentinel)
            INSERT INTO public.schedule (thread_id, user_id, "order", reason, action, "on")
            VALUES (NEW.thread_id, NEW.user_id, v_order, 'add', v_action, daterange('1970-01-01', NULL))
            ON CONFLICT (thread_id, user_id) WHERE user_id IS NOT NULL AND occurrence IS NULL DO NOTHING;
        ELSE
            -- Scheduled for a future date relative to join time
            INSERT INTO public.schedule (thread_id, user_id, "order", reason, action, "on")
            VALUES (NEW.thread_id, NEW.user_id, v_order, 'add', v_action, daterange((CURRENT_DATE + v_date_offset), NULL))
            ON CONFLICT (thread_id, user_id) WHERE user_id IS NOT NULL AND occurrence IS NULL DO NOTHING;
        END IF;

        -- Pre-seed the unread row with the desired importance. The bulk
        -- insert in file_thread_priority_on_group_member_change runs after
        -- this per-row trigger and uses ON CONFLICT DO NOTHING, so this
        -- value wins for onboarding threads while non-onboarding threads
        -- keep the default importance of 50.
        INSERT INTO public.thread_unread (user_id, thread_id, urgency, importance)
        VALUES (NEW.user_id, NEW.thread_id, 'inform-updates', v_importance)
        ON CONFLICT (user_id, thread_id) DO NOTHING;
    END IF;

    RETURN NEW;
END;
$$;

-- Backfill: apply the new action + importance values to existing onboarding
-- threads so the change is visible to users who signed up before this
-- migration ran. Joins thread by (key, twist_id) to scope to the system
-- Plot twist's onboarding set; welcome-user is scoped by key alone since
-- its twist_id is intentionally NULL.
DO $$
DECLARE
    c_twist_package_id CONSTANT uuid := '0199b6f4-ae64-7718-8a02-44716f30358f';
    v_plot_twist_id bigint;
BEGIN
    SELECT id INTO v_plot_twist_id
    FROM public.twist
    WHERE twist_package_id = c_twist_package_id
      AND environment = 'public'
    LIMIT 1;

    -- Per-user welcome thread from activate_invited_user.
    UPDATE public.schedule s
    SET action = 'read'
    FROM public.thread t
    WHERE s.thread_id = t.id
      AND t.key = 'welcome-user'
      AND s.user_id IS NOT NULL
      AND s.occurrence IS NULL
      AND s.action IS DISTINCT FROM 'read';

    UPDATE public.thread_unread tu
    SET importance = 100
    FROM public.thread t
    WHERE tu.thread_id = t.id
      AND t.key = 'welcome-user'
      AND tu.importance IS DISTINCT FROM 100;

    -- Global onboarding threads — only proceed when the Plot twist exists
    -- (skipped on ephemeral databases that haven't bootstrapped it).
    IF v_plot_twist_id IS NOT NULL THEN
        WITH mapping (key, action, importance) AS (
            VALUES
                ('welcome'::text,          'read'::text, 95::smallint),
                ('priorities',             'do',         90),
                ('connections',            'do',         85),
                ('getting-around',         'read',       80),
                ('invest-your-time',       'read',       75),
                ('twists',                 'do',         70),
                ('notifications',          'do',         65),
                ('clean-up',               'read',       60)
        )
        UPDATE public.schedule s
        SET action = m.action
        FROM public.thread t
        JOIN mapping m ON m.key = t.key
        WHERE s.thread_id = t.id
          AND t.twist_id = v_plot_twist_id
          AND s.user_id IS NOT NULL
          AND s.occurrence IS NULL
          AND s.action IS DISTINCT FROM m.action;

        WITH mapping (key, importance) AS (
            VALUES
                ('welcome'::text,        95::smallint),
                ('priorities',           90),
                ('connections',          85),
                ('getting-around',       80),
                ('invest-your-time',     75),
                ('twists',               70),
                ('notifications',        65),
                ('clean-up',             60)
        )
        UPDATE public.thread_unread tu
        SET importance = m.importance
        FROM public.thread t
        JOIN mapping m ON m.key = t.key
        WHERE tu.thread_id = t.id
          AND t.twist_id = v_plot_twist_id
          AND tu.importance IS DISTINCT FROM m.importance;
    END IF;
END $$;
