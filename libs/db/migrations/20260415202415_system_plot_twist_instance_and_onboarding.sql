-- Seed Plot system entities and attribute all onboarding threads to the
-- Plot twist instead of a real user.
--
-- Self-contained: creates the publisher, user, twist admin, twist, and
-- system twist instance if they don't already exist — safe to run against
-- both a fresh dev reset and a production database that already has these rows.
--
-- After this migration, every onboarding thread has:
--   created_by  = system twist instance UUID
--   twist_id    = Plot public twist bigint ID
--   icon        = 'twist:<twist_id>'
-- Notes likewise have author_id / created_by = system twist instance UUID.
-- thread_priority rows are filed automatically by the
-- file_thread_priority_for_topic_members trigger on INSERT.

DO $$
DECLARE
    c_system_instance_id CONSTANT uuid := '0199b6f4-ae64-7718-0000-000000000001';
    c_twist_package_id   CONSTANT uuid := '0199b6f4-ae64-7718-8a02-44716f30358f';
    c_kris_seed_user_id  CONSTANT uuid := '019d8efd-12e2-7ba9-98f1-ec08152ea427';

    v_kris_user_id   uuid;
    v_publisher_id   bigint;
    v_twist_admin_id bigint;
    v_plot_twist_id  bigint;
    v_everyone_topic_id uuid;
    v_thread_id      uuid;
    v_icon           text;
BEGIN
    -- 1. Resolve kris@plot.day (owner of the system twist instance).
    --    If the user already exists (e.g. real production account, or from
    --    a prior sign-in), use that id verbatim and DO NOT touch the row —
    --    we must never alter or relink a live user here. Only seed if kris
    --    is completely absent. When seeding fresh, also create the matching
    --    primary contact so /activate never sees a user without a contact.
    SELECT id INTO v_kris_user_id FROM "user" WHERE email = 'kris@plot.day';

    IF v_kris_user_id IS NULL THEN
        INSERT INTO "user" (id, email, name)
        VALUES (c_kris_seed_user_id, 'kris@plot.day', 'Kris Braun')
        RETURNING id INTO v_kris_user_id;

        -- Seed a primary contact so Base.actorId is resolvable on first
        -- sign-in. The sync_user_contact_from_contact trigger mirrors this
        -- into user_contact with linked=TRUE, primary=TRUE.
        INSERT INTO contact (email, name, user_id, "primary")
        VALUES ('kris@plot.day', 'Kris Braun', v_kris_user_id, TRUE)
        ON CONFLICT (email) DO NOTHING;
    END IF;

    -- 2. Ensure Plot publisher exists
    INSERT INTO publisher (name, url)
    VALUES ('Plot', 'https://plot.day')
    ON CONFLICT DO NOTHING;

    SELECT id INTO v_publisher_id FROM publisher WHERE name = 'Plot' LIMIT 1;

    -- 3. Ensure Plot twist admin exists (keyed by twist_package_id from twists/plot/package.json)
    INSERT INTO twist_admin (twist_package_id, publisher_id, auto_approve)
    VALUES (c_twist_package_id, v_publisher_id, false)
    ON CONFLICT (twist_package_id, user_id) DO NOTHING;

    SELECT id INTO v_twist_admin_id
    FROM twist_admin
    WHERE twist_package_id = c_twist_package_id
    LIMIT 1;

    -- 4. Ensure Plot twist definitions exist (review + public environments)
    INSERT INTO twist (twist_admin_id, environment, name, version, is_source, shared, logo_url)
    VALUES (v_twist_admin_id, 'review', 'Plot', '0.1.0', false, false, 'https://plot.day/assets/plot-icon.svg')
    ON CONFLICT (twist_admin_id, environment) DO NOTHING;

    INSERT INTO twist (twist_admin_id, environment, name, version, is_source, shared, logo_url)
    VALUES (v_twist_admin_id, 'public', 'Plot', '0.1.0', false, false, 'https://plot.day/assets/plot-icon.svg')
    ON CONFLICT (twist_admin_id, environment) DO NOTHING;

    SELECT id INTO v_plot_twist_id
    FROM twist
    WHERE twist_admin_id = v_twist_admin_id AND environment = 'public'
    LIMIT 1;

    v_icon := 'twist:' || v_plot_twist_id::text;

    -- 5. Create the system Plot twist instance (idempotent)
    INSERT INTO twist_instance (id, twist_id, owner_id, name)
    VALUES (c_system_instance_id, v_plot_twist_id, v_kris_user_id, 'Plot')
    ON CONFLICT (id) DO NOTHING;

    -- 6. Ensure the global Everyone topic exists
    SELECT id INTO v_everyone_topic_id
    FROM topic
    WHERE auto_maintained = TRUE AND team_id IS NULL
    LIMIT 1;

    IF v_everyone_topic_id IS NULL THEN
        INSERT INTO topic (created_by, name, auto_maintained)
        VALUES (v_kris_user_id, 'Everyone', TRUE)
        RETURNING id INTO v_everyone_topic_id;
    END IF;

    -- 7. Update threads from migration 20260414233029 that lack twist attribution
    UPDATE thread
    SET created_by = c_system_instance_id,
        twist_id   = v_plot_twist_id,
        icon       = v_icon
    WHERE key IN ('welcome', 'priorities', 'connections', 'getting-around',
                  'twists', 'notifications', 'clean-up')
      AND twist_id IS NULL;

    -- Update notes on those threads (those whose created_by is a user, not our instance)
    UPDATE note n
    SET author_id  = c_system_instance_id,
        created_by = c_system_instance_id
    FROM thread t
    WHERE n.thread_id = t.id
      AND t.key IN ('welcome', 'priorities', 'connections', 'getting-around',
                    'twists', 'notifications', 'clean-up')
      AND n.created_by != c_system_instance_id;

    -- 8. Create onboarding threads that don't exist yet
    --    The file_thread_priority_for_topic_members trigger fires on INSERT and
    --    automatically files thread_priority for current topic members.

    -- Welcome to Plot!
    IF NOT EXISTS (SELECT 1 FROM thread WHERE key = 'welcome' AND twist_id = v_plot_twist_id) THEN
        INSERT INTO thread (created_by, title, preview, key, twist_id, icon, topics)
        VALUES (c_system_instance_id, 'Welcome to Plot!',
                'Plot is your workspace for making progress on what matters.',
                'welcome', v_plot_twist_id, v_icon, ARRAY[v_everyone_topic_id])
        RETURNING id INTO v_thread_id;

        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (0 * interval '1 minute'),
'Plot is your workspace for making progress on what matters most. **Priorities**, **Threads**, and **Notes** are the core building blocks of Plot:

- **Priorities**: The roles, goals, and projects in your life — the areas you direct your focus and energy toward. Examples include Work, Personal, Launch New Product, Team Leader, and Learn French.
- **Threads**: Everything related to something you work on, collected in one place. A thread can contain notes, messages to collaborators, links syncing with external items, and chats with twists. Threads are the core thing you Start, Schedule, and Finish.
- **Notes**: The content within threads. Notes can be personal notes, messages to others, or synced comments with connected apps. Individual notes can be marked as tasks and assigned to people.');

        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (1 * interval '1 minute'),
'When a thread needs your attention, you **Start** it — it could be as simple as reading and thinking, or it could mean taking action. You can also **Schedule** a thread to choose when you want to act on it. Starting and scheduling build your personal agenda — it''s not a shared project board, it''s your own action plan.

When you''re done with your part, you **Finish** the thread. This marks any of your tasks in the thread as done and completes linked items in connected apps — for example, closing a Linear ticket. You (and others) might Start and Finish a thread multiple times as work progresses. There''s also a separate **Done** tag you can add to mark a thread as complete for good for everyone.');

        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (2 * interval '1 minute'),
'The **Agenda** is everything you plan to work on — started and scheduled threads, arranged in your preferred order. You can reorder items freely, move them to a different time or date, or remove them without losing the thread.

The **Activity** view shows what''s happening across your priorities — new threads, updates, and unread items. From Activity, you can add anything to your Agenda by Starting (act on it now) or Scheduling (act on it later).

A useful pattern: when a meeting or event appears in Activity from a calendar connection, tap **Start** to add a planning slot in your Agenda — useful for blocking time to prepare or to follow up afterward.');

        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (3 * interval '1 minute'),
'Threads can contain links to items in external services — documents, calendar events, web pages, issues, and more. These are created by connections (more on that later). Links keep everything related to your work in one place, so you always have the context you need.');
    END IF;

    -- Create your initial Priorities
    IF NOT EXISTS (SELECT 1 FROM thread WHERE key = 'priorities' AND twist_id = v_plot_twist_id) THEN
        INSERT INTO thread (created_by, title, preview, key, twist_id, icon, topics)
        VALUES (c_system_instance_id, 'Create your initial Priorities',
                'Priorities are contexts for focus and often correspond to roles and goals. Nesting priorities creates a hierarchy that lets you organize at different levels of detail.',
                'priorities', v_plot_twist_id, v_icon, ARRAY[v_everyone_topic_id])
        RETURNING id INTO v_thread_id;

        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (0 * interval '1 minute'),
'Priorities are contexts for focus and often correspond to roles (like VP Marketing and Parent) and goals (like Launch New Product and Run a Marathon). **Nesting priorities** creates a hierarchy — for example, Work > Projects > Feature X > Planning — that lets you organize at different levels of detail.');

        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (1 * interval '1 minute'),
'**Viewing a priority shows threads from it and all descendants.** When you view Work, you see everything under Work (including Projects, Feature X, etc.). When you view Work > Projects > Feature X, you only see that specific area. **Everything** is the special priority that shows all your threads across all priorities.');

        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (2 * interval '1 minute'),
'**Best practice:** Organize from broad to specific. Example: Work > Marketing Campaign > Content Strategy, or Personal > Home Renovation > Kitchen Planning. Start with top-level contexts (Work, Personal, Family) then add specific projects within each. This allows you to zoom in for focus, and zoom out to make sure you''re not missing anything.');

        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (3 * interval '1 minute'),
'Create your first priority — for example, **Work** or **Personal**. You can always add more or nest them later.');
    END IF;

    -- Add your Connections
    IF NOT EXISTS (SELECT 1 FROM thread WHERE key = 'connections' AND twist_id = v_plot_twist_id) THEN
        INSERT INTO thread (created_by, title, preview, key, twist_id, icon, topics)
        VALUES (c_system_instance_id, 'Add your Connections',
                'Connections sync items from your other apps and services into Plot, often two-way.',
                'connections', v_plot_twist_id, v_icon, ARRAY[v_everyone_topic_id])
        RETURNING id INTO v_thread_id;

        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (0 * interval '1 minute'),
'**Connections** sync items from your other apps and services into Plot, often two-way. For example, connect your calendar to see events as threads, or connect your email to bring in conversations. You can view and interact with items right from Plot — see and add comments on documents, respond to messages, update issues — the goal is to bring everything into one place.');

        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (1 * interval '1 minute'),
'Each connection has channels you can enable or disable, letting you control exactly what syncs. Use the **Manage connections** command to browse available connections, vote for upcoming ones, and manage which are active.');

        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (2 * interval '1 minute'),
'Set up your first connection using the **Manage connections** command.');
    END IF;

    -- Getting Around
    IF NOT EXISTS (SELECT 1 FROM thread WHERE key = 'getting-around' AND twist_id = v_plot_twist_id) THEN
        INSERT INTO thread (created_by, title, preview, key, twist_id, icon, topics)
        VALUES (c_system_instance_id, 'Getting Around',
                'Keyboard and touch shortcuts',
                'getting-around', v_plot_twist_id, v_icon, ARRAY[v_everyone_topic_id])
        RETURNING id INTO v_thread_id;

        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (0 * interval '1 minute'),
'Plot''s goal is to get you to meaningful work as quickly as possible. Here are some tips for navigating efficiently.');

        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (1 * interval '1 minute'),
'**Keyboard Navigation**

- **⌘/** (Ctrl+/ on Windows): Search across all your threads and priorities
- **⌘K** (Ctrl+K on Windows): Open the command palette for quick actions
- **Up/Down arrows**: Select a note within a thread, then ⌘K (Ctrl+K) to open commands for that note
- **⌘T** (Ctrl+T on Windows): Focus a thread in the agenda list, then Up/Down to navigate and Enter to open the command menu
- **⌘⇧T** (Ctrl+Shift+T on Windows): Switch between agenda and activity feed
- **⌘Up/Down** (Ctrl+Up/Down on Windows): Open previous/next thread
- **⌘D** (Ctrl+D on Windows): Mark done / not done
- **⌘⇧D** (Ctrl+Shift+D on Windows): Schedule thread
- **⌘Delete** (Ctrl+Backspace on Windows): Archive thread
- **⌘N** (Ctrl+N on Windows): Create a new note (⌘⇧N / Ctrl+Shift+N on web browsers)
- **⌘Enter** (Ctrl+Enter on Windows): On the new thread page, create a task instead of a note');

        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (2 * interval '1 minute'),
'**Touch Gestures**

- **Long press** on items to open the menu
- **Swipe right** on threads: Start (or Finish if already started)
- **Swipe left** on threads: Schedule for later
- **Share** a link from another app to Plot using the share sheet (iOS and Android)');
    END IF;

    -- Explore Twists
    IF NOT EXISTS (SELECT 1 FROM thread WHERE key = 'twists' AND twist_id = v_plot_twist_id) THEN
        INSERT INTO thread (created_by, title, preview, key, twist_id, icon, topics)
        VALUES (c_system_instance_id, 'Explore Twists',
                'Twists are automations, workflows, and agents that do helpful things with your threads.',
                'twists', v_plot_twist_id, v_icon, ARRAY[v_everyone_topic_id])
        RETURNING id INTO v_thread_id;

        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (0 * interval '1 minute'),
'**Twists** are automations, workflows, and agents that do helpful things with your threads — often working with items from your connections. For example, a twist might triage your inbox, summarize meeting notes, or create follow-up tasks from action items.');

        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (1 * interval '1 minute'),
'You can also **create your own twists**, either by describing what you want (Plot AI will generate it for you) or by writing code. Custom twists can automate any workflow specific to your needs.');

        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (2 * interval '1 minute'),
'You can also **@mention Plot** in any thread to ask questions about your notes and links. Plot will search your content and answer using AI.');

        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (3 * interval '1 minute'),
'Try **@mentioning Plot** in any thread to ask a question about your notes.');
    END IF;

    -- Set up Notifications
    IF NOT EXISTS (SELECT 1 FROM thread WHERE key = 'notifications' AND twist_id = v_plot_twist_id) THEN
        INSERT INTO thread (created_by, title, preview, key, twist_id, icon, topics)
        VALUES (c_system_instance_id, 'Set up Notifications',
                'Plot delivers notifications based on urgency, not instantly. Adjust per-priority timing to match how you work.',
                'notifications', v_plot_twist_id, v_icon, ARRAY[v_everyone_topic_id])
        RETURNING id INTO v_thread_id;

        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (0 * interval '1 minute'),
'Plot has smart notifications that are timed based on urgency rather than sending everything immediately. This means new messages and updates won''t interrupt you the moment they arrive — instead, they''re delivered within a timeframe you control. If you''re used to getting notified immediately for every message, you may want to adjust these defaults.');

        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (1 * interval '1 minute'),
'Each priority has two timing settings:

- **See requests within** (default: 30 minutes) — how quickly you''re notified about messages and mentions
- **See updates within** (default: 1 hour) — how quickly you''re notified about other changes

To adjust, open a priority''s command menu and choose **Notifications**, or tap the notification icon on a priority. Settings inherit from parent priorities, so you can set timing once at the top level and all children will follow.');

        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (2 * interval '1 minute'),
'Plot also has **quiet hours** (default: 9 PM – 7 AM) during which notifications are silenced. You can customize quiet hours per priority in the same Notifications settings.');

        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (3 * interval '1 minute'),
'Adjust notification timing for your most important priority.');
    END IF;

    -- Clean up without losing anything
    IF NOT EXISTS (SELECT 1 FROM thread WHERE key = 'clean-up' AND twist_id = v_plot_twist_id) THEN
        INSERT INTO thread (created_by, title, preview, key, twist_id, icon, topics)
        VALUES (c_system_instance_id, 'Clean up without losing anything',
                'When something is no longer actively in progress, you can archive it. Archived items are hidden but never deleted.',
                'clean-up', v_plot_twist_id, v_icon, ARRAY[v_everyone_topic_id])
        RETURNING id INTO v_thread_id;

        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (0 * interval '1 minute'),
'When something is no longer actively in progress — a completed project, an old priority, a finished thread — you can **archive it**. Archived items are hidden from your main view but never deleted. You can view archived items or unarchive them anytime.');

        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (1 * interval '1 minute'),
'You can archive both **priorities** and **threads**. Use the command menu on any priority or thread to find the archive option. Archiving a priority hides it and all its threads from the main view.');
    END IF;

END $$;
