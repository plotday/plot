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
        -- importance = 100 puts this thread at the top of Updates, above
        -- the global onboarding sequence seeded by file_onboarding_schedules
        -- (which starts at importance = 95 for the 'welcome' thread).
        -- to_read = TRUE places it on the user's reading list (informational
        -- thread with no actionable todo). Plot team members are filed by
        -- file_thread_priority_for_group_members but do NOT receive a
        -- thread_state row — the welcome stays off their agendas.
        INSERT INTO public.thread_state (user_id, thread_id, to_read, importance, "order", "on")
            VALUES (p_user_id, v_welcome_thread_id, TRUE, 100, 50, daterange('1970-01-01', NULL))
        ON CONFLICT (user_id, thread_id)
            DO NOTHING;
        INSERT INTO public.note (author_id, created_by, thread_id, source_created_at, content, key)
            VALUES (c_system_instance_id, c_system_instance_id, v_welcome_thread_id, now(), 'Glad something brought you here. Maybe it''s a project you want to move forward, a team you want to work with more clearly, or a sense that more is possible when you direct your best energy into the work only you can do.

Plot is built for collaborating without getting buried — every conversation has a place, and the best of your day stays yours. Tell us what you''re trying to make progress on, where you''re stuck, or what''s not quite working yet. We read every reply.', 'welcome')
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
    v_active boolean;
    v_to_read boolean;
    v_importance smallint;
BEGIN
    -- Skip if explicitly requested (e.g. during repair migrations for existing users)
    IF current_setting('plot.skip_onboarding_schedules', true) = 'true' THEN
        RETURN NEW;
    END IF;

    SELECT key INTO v_thread_key FROM public.thread WHERE id = NEW.thread_id;

    IF v_thread_key IN ('welcome', 'priorities', 'connections', 'getting-around', 'twists', 'notifications', 'clean-up') THEN
        -- Onboarding partitions each thread into the unified feed:
        --   active=true  — threads that ask the user to take a concrete
        --                  action (matches the keys handled by
        --                  file_onboarding_todos). Lands in Doing.
        --   to_read=true — informational threads with no actionable todo.
        --                  Lands in the user's reading list.
        -- importance controls Updates ordering (higher = nearer the top).
        -- Values descend in the natural reading order; 'welcome-user'
        -- (importance 100, handled in activate_invited_user) sits above
        -- the global 'welcome' here.
        CASE v_thread_key
            WHEN 'welcome'           THEN v_date_offset := 0; v_order := 100; v_active := FALSE; v_to_read := TRUE;  v_importance := 95;
            WHEN 'priorities'        THEN v_date_offset := 0; v_order := 200; v_active := TRUE;  v_to_read := FALSE; v_importance := 90;
            WHEN 'connections'       THEN v_date_offset := 0; v_order := 300; v_active := TRUE;  v_to_read := FALSE; v_importance := 85;
            WHEN 'getting-around'    THEN v_date_offset := 0; v_order := 400; v_active := FALSE; v_to_read := TRUE;  v_importance := 80;
            WHEN 'twists'            THEN v_date_offset := 1; v_order := 100; v_active := TRUE;  v_to_read := FALSE; v_importance := 70;
            WHEN 'notifications'     THEN v_date_offset := 2; v_order := 100; v_active := TRUE;  v_to_read := FALSE; v_importance := 65;
            WHEN 'clean-up'          THEN v_date_offset := 3; v_order := 100; v_active := FALSE; v_to_read := TRUE;  v_importance := 60;
        END CASE;

        INSERT INTO public.thread_state (user_id, thread_id, active, to_read, importance, "order", "on")
        VALUES (
            NEW.user_id,
            NEW.thread_id,
            v_active,
            v_to_read,
            v_importance,
            v_order,
            CASE
                WHEN v_date_offset = 0 THEN daterange('1970-01-01', NULL)
                ELSE daterange((CURRENT_DATE + v_date_offset), NULL)
            END
        )
        ON CONFLICT (user_id, thread_id) DO NOTHING;
    END IF;

    RETURN NEW;
END;
$$;

-- Data migration: replace note content on the global onboarding threads
-- ('welcome', 'getting-around') and the per-user welcome-user thread to
-- match the post-2026-05-22 unified feed model (Doing/Scheduled/Activity
-- with updates pinned atop Doing; `active`/`task`/`to_read` booleans;
-- ⌘D/⌘T/⌘E hover toggles) and the "Collaborate and carry on" marketing
-- positioning. Scopes by (thread.key, twist_id) to target only the system
-- Plot twist's onboarding set; welcome-user is scoped by key alone since
-- its twist_id is intentionally NULL.
DO $migration$
DECLARE
    c_twist_package_id CONSTANT uuid := '0199b6f4-ae64-7718-8a02-44716f30358f';
    v_plot_twist_id bigint;
BEGIN
    SELECT id INTO v_plot_twist_id
    FROM public.twist
    WHERE twist_package_id = c_twist_package_id
      AND environment = 'public'
    LIMIT 1;

    -- Global threads: identify notes by their ordinal position within the
    -- thread (ROW_NUMBER over source_created_at), matching the original
    -- INSERT order in 20260414233029_global_onboarding_threads.sql.
    IF v_plot_twist_id IS NOT NULL THEN
        WITH ordered AS (
            SELECT n.id,
                   t.key AS thread_key,
                   ROW_NUMBER() OVER (
                       PARTITION BY n.thread_id ORDER BY n.source_created_at
                   ) AS ordinal
            FROM public.note n
            JOIN public.thread t ON t.id = n.thread_id
            WHERE t.twist_id = v_plot_twist_id
              AND t.key IN ('welcome', 'getting-around')
        ),
        replacements (thread_key, ordinal, new_content) AS (
            VALUES
                (
                    'welcome'::text,
                    1::int,
                    $note$Plot is your workspace for collaborating without losing yourself in tools. **Priorities**, **Threads**, and **Notes** are the building blocks:

- **Priorities** are the roles, goals, and projects you direct your focus toward — Work, Personal, Launch New Product, Learn French.
- **Threads** are everything related to one piece of work, collected in one place: notes, messages, events, links to items in other apps, chats with twists.
- **Notes** are the content inside threads — your own, messages to others, or comments synced back to a connected app. Any note can be marked as a task.$note$
                ),
                (
                    'welcome',
                    2,
                    $note$When a thread needs your attention, mark it **To do** (⌘D) — it moves into the **Doing** section of your agenda and feed. You can also **Schedule** it (⌘⇧D) to act on it later, or add it to your **Task list** (⌘T) or **Reading list** (⌘E) for a lighter-touch follow-up. When you finish your part, mark it done — your tasks are completed and linked items in connected apps are updated (e.g. closing a Linear ticket).$note$
                ),
                (
                    'welcome',
                    3,
                    $note$Your activity feed groups everything into three sections, in order:

- **Doing** — what you're actively working on, with unread updates pinned at the top (most urgent first).
- **Scheduled** — what you've planned for upcoming days.
- **Activity** — recent history across your priorities.

From an update at the top of Doing, mark it **To do** to keep working on it, or **Schedule** it to drop it into a future day.$note$
                ),
                (
                    'getting-around',
                    2,
                    $note$**Keyboard Navigation**

- **⌘/** (Ctrl+/ on Windows): Search across all your threads and priorities
- **⌘K** (Ctrl+K on Windows): Open the command palette
- **⌘D** (Ctrl+D on Windows): To do / Mark done — toggle whether you're doing this thread
- **⌘⇧D** (Ctrl+Shift+D on Windows): Schedule a thread for a future day
- **⌘T** (Ctrl+T on Windows): Add to or remove from your task list
- **⌘E** (Ctrl+E on Windows): Add to or remove from your reading list
- **⌘Up/Down** (Ctrl+Up/Down on Windows): Open previous/next thread
- **⌘Delete** (Ctrl+Backspace on Windows): Archive a thread
- **⌘N** (Ctrl+N on Windows): Create a new note (⌘⇧N / Ctrl+Shift+N on web browsers)
- **⌘Enter** (Ctrl+Enter on Windows): On a new thread, save as a task instead of a note$note$
                ),
                (
                    'getting-around',
                    3,
                    $note$**Touch Gestures**

- **Long press** on items to open the menu
- **Swipe right** on threads: To do (or Mark done if it's already in Doing)
- **Swipe left** on threads: Schedule for later
- **Share** a link from another app to Plot using the share sheet (iOS and Android)$note$
                )
        )
        UPDATE public.note n
        SET content = r.new_content
        FROM ordered o
        JOIN replacements r
          ON r.thread_key = o.thread_key
         AND r.ordinal = o.ordinal
        WHERE n.id = o.id
          AND n.content IS DISTINCT FROM r.new_content;
    END IF;

    -- Per-user welcome-user thread (twist_id IS NULL). The current
    -- activate_invited_user INSERT keys this note as 'welcome', but the
    -- legacy 20260419214419 INSERT left note.key NULL, so match by
    -- "everything in the welcome-user thread except the core-trial note".
    UPDATE public.note n
    SET content = $note$Glad something brought you here. Maybe it's a project you want to move forward, a team you want to work with more clearly, or a sense that more is possible when you direct your best energy into the work only you can do.

Plot is built for collaborating without getting buried — every conversation has a place, and the best of your day stays yours. Tell us what you're trying to make progress on, where you're stuck, or what's not quite working yet. We read every reply.$note$
    FROM public.thread t
    WHERE n.thread_id = t.id
      AND t.key = 'welcome-user'
      AND (n.key IS NULL OR n.key = 'welcome')
      AND n.content IS DISTINCT FROM $note$Glad something brought you here. Maybe it's a project you want to move forward, a team you want to work with more clearly, or a sense that more is possible when you direct your best energy into the work only you can do.

Plot is built for collaborating without getting buried — every conversation has a place, and the best of your day stays yours. Tell us what you're trying to make progress on, where you're stuck, or what's not quite working yet. We read every reply.$note$;
END $migration$;
