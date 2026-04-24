-- Modify "upsert_user_contact" function
CREATE OR REPLACE FUNCTION "public"."upsert_user_contact" ("user_id" uuid, "user_email" text, "user_name" text, "avatar_url" text) RETURNS uuid LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    _contact_id uuid;
    _existing_user_id uuid;
    _should_be_primary boolean;
BEGIN
    -- Check if this email is already linked to a different user
    SELECT c.user_id INTO _existing_user_id
    FROM public.contact c
    WHERE c.email = user_email;

    IF _existing_user_id IS NOT NULL
       AND upsert_user_contact.user_id IS NOT NULL
       AND _existing_user_id IS DISTINCT FROM upsert_user_contact.user_id THEN
        RAISE EXCEPTION 'email_already_linked: This email is already associated with another account'
            USING ERRCODE = 'unique_violation';
    END IF;

    -- Decide up front whether this contact should be the user's primary.
    -- Setting primary on the INSERT itself (instead of a follow-up UPDATE)
    -- is load-bearing: sync_user_contact_from_contact → auto_maintain_everyone_group
    -- only adds the user to the Everyone group on user_contact INSERT with
    -- primary=TRUE. A later primary-flip fires the UPDATE branch, which
    -- only handles eviction — the user would never be added.
    _should_be_primary := upsert_user_contact.user_id IS NOT NULL
        AND NOT EXISTS (
            SELECT 1 FROM public.contact c
            WHERE c.user_id = upsert_user_contact.user_id AND c."primary"
        );

    -- Upsert contact record for the user
    INSERT INTO public.contact (email, name, avatar_url, user_id, "primary")
        VALUES (user_email, user_name, avatar_url, user_id, _should_be_primary)
    ON CONFLICT (email)
        DO UPDATE SET
            name = COALESCE(EXCLUDED.name, contact.name),
            avatar_url = COALESCE(EXCLUDED.avatar_url, contact.avatar_url),
            user_id = COALESCE(EXCLUDED.user_id, contact.user_id),
            "primary" = contact."primary" OR _should_be_primary,
            updated_at = now()
        RETURNING
            id INTO _contact_id;
    RETURN _contact_id;
END;
$$;
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

        INSERT INTO public.note (author_id, created_by, thread_id, source_created_at, content, key)
        VALUES (
            c_system_instance_id,
            c_system_instance_id,
            v_welcome_thread_id,
            now(),
'We''re glad something brought you here. Maybe it''s a project you''re ready to move on, a team you want to work with more clearly, or a sense that more is possible when you direct your best energy into your most important work. We''ve seen too much initiative absorbed by the overhead of modern work — tools built to move us faster that often leave us so busy and scattered that real progress slows to a crawl.

We''re building Plot for a different way of working, one where you choose your focus and have what you need to make progress. We believe human initiative, creativity, and wisdom are what drives meaningful work forward, and technology should create the space for them to thrive.

We''d love to know what brought you to Plot and what you''re hoping to make progress on. Tell us what you''re trying to achieve, where you''re stuck, or what''s not quite working yet. We read every reply and shape Plot through what we''re learning together.',
            'welcome'
        );

        -- Announce the reverse trial on the same thread so the user sees
        -- plan status alongside their onboarding message. TrialReminder DO
        -- adds reminder-7day / reminder-2day / upgraded notes here later
        -- via addTrialNote() (keyed on note.key for idempotency).
        INSERT INTO public.note (author_id, created_by, thread_id, source_created_at, content, key)
        VALUES (
            c_system_instance_id,
            c_system_instance_id,
            v_welcome_thread_id,
            now() + interval '1 millisecond',
            'You have the **Core plan** free for 30 days — that''s up to 5 connections and 2 twists. We''ll let you know before your trial ends.',
            'core-trial'
        )
        ON CONFLICT (thread_id, key) DO NOTHING;
    END IF;

    -- Onboarding routing is now learned from user moves (thread_priority.user_moved).
    -- New users start with no training examples; incoming threads land in the
    -- root priority until the user moves one into "Using Plot". classify_thread_for_user
    -- then picks that priority up automatically for similar future threads.

    RETURN jsonb_build_object('activated', TRUE, 'already_active', FALSE, 'root_priority_id', v_root_priority_id);
END;
$$;

-- Data repair: add stranded primary contacts to Everyone so the trigger
-- cascade backfills thread_priority + schedule + todo rows for the 7
-- onboarding threads. Targets users whose primary self-link missed the
-- INSERT-with-primary=TRUE path (every signup since 20260419214419
-- introduced upsert_user_contact in activate_invited_user). Mark the
-- resulting thread_unread rows as read so the restoration doesn't
-- surface a wave of "new unread" threads or trigger digest emails.
DO $$
DECLARE
    v_everyone_group_id uuid;
    v_mark_cutoff timestamptz := clock_timestamp();
BEGIN
    SELECT id INTO v_everyone_group_id
    FROM "group"
    WHERE auto_maintained = TRUE
      AND team_id IS NULL
      AND auto_publisher_id IS NULL
      AND auto_team_admin_team_id IS NULL
      AND name = 'Everyone';

    IF v_everyone_group_id IS NULL THEN
        RETURN;
    END IF;

    INSERT INTO group_member (group_id, contact_id)
    SELECT v_everyone_group_id, uc.contact_id
    FROM user_contact uc
    WHERE uc.linked = TRUE
      AND uc."primary" = TRUE
      AND uc.archived_at IS NULL
      AND uc.source = 'self'
      AND NOT EXISTS (
          SELECT 1 FROM group_member gm
          WHERE gm.group_id = v_everyone_group_id
            AND gm.contact_id = uc.contact_id
      )
    ON CONFLICT (group_id, contact_id) DO NOTHING;

    UPDATE thread_unread tu
    SET read_at = now()
    FROM thread t
    WHERE tu.thread_id = t.id
      AND tu.read_at IS NULL
      AND tu.updated_at >= v_mark_cutoff
      AND t.key IN ('welcome', 'priorities', 'connections', 'getting-around',
                    'twists', 'notifications', 'clean-up');
END $$;
