-- Modify "activate_invited_user" function
CREATE OR REPLACE FUNCTION "public"."activate_invited_user" ("p_user_id" uuid) RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    c_system_instance_id CONSTANT uuid := '0199b6f4-ae64-7718-0000-000000000001';
    c_twist_package_id   CONSTANT uuid := '0199b6f4-ae64-7718-8a02-44716f30358f';
    v_root_priority_id uuid;
    v_using_plot_id    uuid;
    v_new_path ltree;
    v_plot_team_group_id uuid;
    v_plot_twist_id  bigint;
    v_user_contact_id uuid;
    v_welcome_thread_id uuid;
BEGIN
    -- Already has a root priority?
    SELECT id INTO v_root_priority_id
    FROM public.priority
    WHERE user_id = p_user_id
      AND nlevel(path) = 1
    ORDER BY created_at ASC
    LIMIT 1;

    IF v_root_priority_id IS NOT NULL THEN
        RETURN jsonb_build_object('activated', FALSE, 'already_active', TRUE, 'root_priority_id', v_root_priority_id);
    END IF;

    -- Create the root priority. default_priority_user_id fills user_id
    -- from created_by, so the new row is fully owned by the user.
    v_new_path := generate_path(NULL);
    INSERT INTO public.priority (created_by, user_id, title, path, color)
        VALUES (p_user_id, p_user_id, 'Everything', v_new_path, 0)
    RETURNING id INTO v_root_priority_id;

    -- Resolve the Plot Team group once — used for the Using Plot priority
    -- config and for the welcome thread's groups array. Prefer the full
    -- "Plot" team's auto-maintained group (everyone on the team, what we
    -- want in prod); fall back to the Plot publisher admin group for
    -- environments where the Plot team doesn't exist yet.
    SELECT COALESCE(
        (
            SELECT g.id FROM public.group g
            JOIN public.team t ON t.id = g.team_id
            WHERE g.auto_maintained = TRUE
              AND g.auto_team_admin_team_id IS NULL
              AND t.name = 'Plot'
            LIMIT 1
        ),
        (
            SELECT g.id FROM public.group g
            WHERE g.auto_maintained = TRUE
              AND g.auto_publisher_id = (SELECT id FROM public.publisher WHERE name = 'Plot' LIMIT 1)
            LIMIT 1
        )
    ) INTO v_plot_team_group_id;

    -- Create Using Plot (@plot.app). Config pins new threads to the
    -- feedback topic, auto-shares them with the Plot team, and hides the
    -- agenda tab so the priority acts like a feedback channel. The
    -- `groupLabel` is what the UI renders on the locked chip, decoupled
    -- from whatever the underlying group happens to be named locally.
    INSERT INTO public.priority (created_by, user_id, title, path, color, key, default_thread_icon, config)
    VALUES (
        p_user_id,
        p_user_id,
        'Using Plot',
        v_new_path || generate_path(NULL),
        7,
        '@plot.app',
        'https://plot.day/assets/plot-icon.svg',
        jsonb_build_object(
            'topic', 'feedback',
            'group', v_plot_team_group_id::text,
            'groupLabel', 'Plot Team',
            'view', 'activity'
        )
    )
    RETURNING id INTO v_using_plot_id;

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
        SELECT id INTO v_plot_twist_id
        FROM public.twist
        WHERE twist_package_id = c_twist_package_id
          AND environment = 'public'
        LIMIT 1;

        -- The API worker inserts the primary contact row a moment after
        -- this trigger runs, so user_contact may not exist yet. Seed it
        -- ourselves via upsert_user_contact (idempotent via ON CONFLICT
        -- (email) + ON CONFLICT (user_id, contact_id)) so the welcome
        -- thread's contacts array has the user's primary contact from
        -- the start.
        DECLARE
            v_user_email text;
            v_user_name  text;
            v_user_avatar text;
        BEGIN
            SELECT email, name, avatar_url
            INTO v_user_email, v_user_name, v_user_avatar
            FROM public."user"
            WHERE id = p_user_id;

            IF v_user_email IS NOT NULL THEN
                PERFORM public.upsert_user_contact(p_user_id, v_user_email, v_user_name, v_user_avatar);
            END IF;
        END;

        SELECT contact_id INTO v_user_contact_id
        FROM public.user_contact
        WHERE user_id = p_user_id
          AND "primary" = TRUE
          AND linked = TRUE
          AND archived_at IS NULL
        LIMIT 1;

        -- twist_id is intentionally NULL: welcome-user is a per-user thread
        -- and must not participate in cross-user (twist_id, key) dedup. The
        -- twist_instance_id in created_by is what makes this "twist-authored"
        -- for peer-filing purposes; icon preserves the visual attribution.
        INSERT INTO public.thread (created_by, icon, title, preview, key, topic, contacts, groups)
        VALUES (
            c_system_instance_id,
            CASE WHEN v_plot_twist_id IS NOT NULL THEN 'twist:' || v_plot_twist_id::text END,
            'Welcome to Plot!',
            'We''re glad something brought you here.',
            'welcome-user',
            'priority:@plot.app:welcome-user',
            CASE
                WHEN v_user_contact_id IS NOT NULL THEN ARRAY[v_user_contact_id]
                ELSE ARRAY[]::uuid[]
            END,
            ARRAY[v_plot_team_group_id]
        )
        RETURNING id INTO v_welcome_thread_id;

        -- file_thread_priority_peers short-circuits for twist-authored
        -- threads, so file the new user into their own Using Plot manually.
        INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
        VALUES (v_welcome_thread_id, p_user_id, v_using_plot_id)
        ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;

        INSERT INTO public.thread_unread (user_id, thread_id, urgency, importance)
        VALUES (p_user_id, v_welcome_thread_id, 'inform-updates', 50)
        ON CONFLICT (user_id, thread_id) DO NOTHING;

        -- Pin to top of agenda for the new user only. Plot team members
        -- are filed by file_thread_priority_for_group_members but do NOT
        -- receive a schedule row — the welcome stays off their agendas.
        INSERT INTO public.schedule (thread_id, user_id, "order", reason, "on")
        VALUES (v_welcome_thread_id, p_user_id, 50, 'add', daterange('1970-01-01', NULL))
        ON CONFLICT (thread_id, user_id) WHERE user_id IS NOT NULL AND occurrence IS NULL DO NOTHING;

        INSERT INTO public.note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (
            c_system_instance_id,
            c_system_instance_id,
            v_welcome_thread_id,
            now(),
'We''re glad something brought you here. Maybe it''s a project you''re ready to move on, a team you want to work with more clearly, or a sense that more is possible when you direct your best energy into your most important work. We''ve seen too much initiative absorbed by the overhead of modern work — tools built to move us faster that often leave us so busy and scattered that real progress slows to a crawl.

We''re building Plot for a different way of working, one where you choose your focus and have what you need to make progress. We believe human initiative, creativity, and wisdom are what drives meaningful work forward, and technology should create the space for them to thrive.

We''d love to know what brought you to Plot and what you''re hoping to make progress on. Tell us what you''re trying to achieve, where you''re stuck, or what''s not quite working yet. We read every reply and shape Plot through what we''re learning together.'
        );
    END IF;

    -- Onboarding routing is now learned from user moves (thread_priority.user_moved).
    -- New users start with no training examples; incoming threads land in the
    -- root priority until the user moves one into "Using Plot". classify_thread_for_user
    -- then picks that priority up automatically for similar future threads.

    RETURN jsonb_build_object('activated', TRUE, 'already_active', FALSE, 'root_priority_id', v_root_priority_id);
END;
$$;

-- Data migration: rename the existing shared welcome onboarding thread so
-- it no longer collides with the new per-user welcome's title. Scope by
-- twist_id to target only the system-authored onboarding thread.
UPDATE public.thread
SET title = 'Everything in its place'
WHERE key = 'welcome'
  AND twist_id = (
    SELECT id FROM public.twist
    WHERE twist_package_id = '0199b6f4-ae64-7718-8a02-44716f30358f'::uuid
      AND environment = 'public'
    LIMIT 1
  )
  AND title <> 'Everything in its place';

-- Data migration: backfill welcome-user thread for existing users who
-- already have an @plot.app priority but no welcome-user thread filed
-- into it. Mirrors the new seeding in activate_invited_user so a fresh
-- environment and an existing one reach the same state.
DO $$
DECLARE
    c_system_instance_id CONSTANT uuid := '0199b6f4-ae64-7718-0000-000000000001';
    c_twist_package_id   CONSTANT uuid := '0199b6f4-ae64-7718-8a02-44716f30358f';
    v_plot_team_group_id uuid;
    v_plot_twist_id      bigint;
    r                    RECORD;
    v_user_contact_id    uuid;
    v_welcome_thread_id  uuid;
BEGIN
    SELECT COALESCE(
        (
            SELECT g.id FROM public.group g
            JOIN public.team t ON t.id = g.team_id
            WHERE g.auto_maintained = TRUE
              AND g.auto_team_admin_team_id IS NULL
              AND t.name = 'Plot'
            LIMIT 1
        ),
        (
            SELECT g.id FROM public.group g
            WHERE g.auto_maintained = TRUE
              AND g.auto_publisher_id = (SELECT id FROM public.publisher WHERE name = 'Plot' LIMIT 1)
            LIMIT 1
        )
    ) INTO v_plot_team_group_id;

    IF v_plot_team_group_id IS NULL THEN
        RETURN;
    END IF;

    SELECT id INTO v_plot_twist_id
    FROM public.twist
    WHERE twist_package_id = c_twist_package_id
      AND environment = 'public'
    LIMIT 1;

    IF NOT EXISTS (SELECT 1 FROM public.twist_instance WHERE id = c_system_instance_id) THEN
        RETURN;
    END IF;

    FOR r IN
        SELECT p.id AS priority_id, p.user_id
        FROM public.priority p
        WHERE p.key = '@plot.app'
          AND p.archived_at IS NULL
          AND NOT EXISTS (
              SELECT 1 FROM public.thread t
              JOIN public.thread_priority tp ON tp.thread_id = t.id
              WHERE t.key = 'welcome-user'
                AND tp.user_id = p.user_id
                AND t.archived_at IS NULL
          )
    LOOP
        SELECT contact_id INTO v_user_contact_id
        FROM public.user_contact
        WHERE user_id = r.user_id
          AND "primary" = TRUE
          AND linked = TRUE
          AND archived_at IS NULL
        LIMIT 1;

        -- twist_id is intentionally NULL: welcome-user is a per-user thread
        -- and must not participate in cross-user (twist_id, key) dedup. The
        -- twist_instance_id in created_by is what makes this "twist-authored"
        -- for peer-filing purposes; icon preserves the visual attribution.
        INSERT INTO public.thread (created_by, icon, title, preview, key, topic, contacts, groups)
        VALUES (
            c_system_instance_id,
            CASE WHEN v_plot_twist_id IS NOT NULL THEN 'twist:' || v_plot_twist_id::text END,
            'Welcome to Plot!',
            'We''re glad something brought you here.',
            'welcome-user',
            'priority:@plot.app:welcome-user',
            CASE
                WHEN v_user_contact_id IS NOT NULL THEN ARRAY[v_user_contact_id]
                ELSE ARRAY[]::uuid[]
            END,
            ARRAY[v_plot_team_group_id]
        )
        RETURNING id INTO v_welcome_thread_id;

        INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
        VALUES (v_welcome_thread_id, r.user_id, r.priority_id)
        ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;

        INSERT INTO public.thread_unread (user_id, thread_id, urgency, importance)
        VALUES (r.user_id, v_welcome_thread_id, 'inform-updates', 50)
        ON CONFLICT (user_id, thread_id) DO NOTHING;

        INSERT INTO public.schedule (thread_id, user_id, "order", reason, "on")
        VALUES (v_welcome_thread_id, r.user_id, 50, 'add', daterange('1970-01-01', NULL))
        ON CONFLICT (thread_id, user_id) WHERE user_id IS NOT NULL AND occurrence IS NULL DO NOTHING;

        INSERT INTO public.note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (
            c_system_instance_id,
            c_system_instance_id,
            v_welcome_thread_id,
            now(),
'We''re glad something brought you here. Maybe it''s a project you''re ready to move on, a team you want to work with more clearly, or a sense that more is possible when you direct your best energy into your most important work. We''ve seen too much initiative absorbed by the overhead of modern work — tools built to move us faster that often leave us so busy and scattered that real progress slows to a crawl.

We''re building Plot for a different way of working, one where you choose your focus and have what you need to make progress. We believe human initiative, creativity, and wisdom are what drives meaningful work forward, and technology should create the space for them to thrive.

We''d love to know what brought you to Plot and what you''re hoping to make progress on. Tell us what you''re trying to achieve, where you''re stuck, or what''s not quite working yet. We read every reply and shape Plot through what we''re learning together.'
        );
    END LOOP;
END $$;
