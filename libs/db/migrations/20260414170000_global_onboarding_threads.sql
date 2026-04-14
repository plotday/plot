-- Transition onboarding threads from per-user copies to a single global set
-- using the "Everyone" topic for visibility.

DO $$
DECLARE
    v_author_id uuid;
    v_author_contact_id uuid;
    v_everyone_topic_id uuid;
    v_thread_id uuid;
BEGIN
    -- 1. Identify the Plot Team author
    SELECT id INTO v_author_id
    FROM "user"
    WHERE email = 'kris@plot.day'
    LIMIT 1;

    -- Fallback to any user if kris@plot.day doesn't exist (shouldn't happen in prod)
    IF v_author_id IS NULL THEN
        SELECT id INTO v_author_id FROM "user" LIMIT 1;
    END IF;

    -- Atlas robust: return if no users exist yet
    IF v_author_id IS NULL THEN
        RETURN;
    END IF;

    SELECT id INTO v_author_contact_id
    FROM contact
    WHERE user_id = v_author_id
      AND "primary" = TRUE
    LIMIT 1;

    -- 2. Get the "Everyone" announce topic
    SELECT id INTO v_everyone_topic_id
    FROM topic
    WHERE auto_maintained = TRUE AND team_id IS NULL
    LIMIT 1;

    -- 3. Delete all existing onboarding threads (cascades to thread_priority, notes, etc.)
    DELETE FROM thread
    WHERE key IN (
        'welcome', 'priorities', 'connections', 'getting-around',
        'twists', 'notifications', 'clean-up'
    );

    -- 4. Create the single global set of onboarding threads
    
    -- Welcome to Plot!
    INSERT INTO thread (created_by, title, preview, key, topics)
        VALUES (v_author_id, 'Welcome to Plot!', 'Plot is your workspace for making progress on what matters.', 'welcome', ARRAY[v_everyone_topic_id])
    RETURNING id INTO v_thread_id;
    
    INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (0 * interval '1 minute'), 'Plot is your workspace for making progress on what matters most. **Priorities**, **Threads**, and **Notes** are the core building blocks of Plot:

- **Priorities**: The roles, goals, and projects in your life — the areas you direct your focus and energy toward. Examples include Work, Personal, Launch New Product, Team Leader, and Learn French.
- **Threads**: Everything related to something you work on, collected in one place. A thread can contain notes, messages to collaborators, links syncing with external items, and chats with twists. Threads are the core thing you Start, Schedule, and Finish.
- **Notes**: The content within threads. Notes can be personal notes, messages to others, or synced comments with connected apps. Individual notes can be marked as tasks and assigned to people.');
    INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (1 * interval '1 minute'), 'When a thread needs your attention, you **Start** it — it could be as simple as reading and thinking, or it could mean taking action. You can also **Schedule** a thread to choose when you want to act on it. Starting and scheduling build your personal agenda — it''s not a shared project board, it''s your own action plan.

When you''re done with your part, you **Finish** the thread. This marks any of your tasks in the thread as done and completes linked items in connected apps — for example, closing a Linear ticket. You (and others) might Start and Finish a thread multiple times as work progresses. There''s also a separate **Done** tag you can add to mark a thread as complete for good for everyone.');
    INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (2 * interval '1 minute'), 'The **Agenda** is everything you plan to work on — started and scheduled threads, arranged in your preferred order. You can reorder items freely, move them to a different time or date, or remove them without losing the thread.

The **Activity** view shows what''s happening across your priorities — new threads, updates, and unread items. From Activity, you can add anything to your Agenda by Starting (act on it now) or Scheduling (act on it later).

A useful pattern: when a meeting or event appears in Activity from a calendar connection, tap **Start** to add a planning slot in your Agenda — useful for blocking time to prepare or to follow up afterward.');
    INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (3 * interval '1 minute'), 'Threads can contain links to items in external services — documents, calendar events, web pages, issues, and more. These are created by connections (more on that later). Links keep everything related to your work in one place, so you always have the context you need.');

    -- Create your initial Priorities
    INSERT INTO thread (created_by, title, preview, key, topics)
        VALUES (v_author_id, 'Create your initial Priorities', 'Priorities are contexts for focus and often correspond to roles and goals. Nesting priorities creates a hierarchy that lets you organize at different levels of detail.', 'priorities', ARRAY[v_everyone_topic_id])
    RETURNING id INTO v_thread_id;
    
    INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (0 * interval '1 minute'), 'Priorities are contexts for focus and often correspond to roles (like VP Marketing and Parent) and goals (like Launch New Product and Run a Marathon). **Nesting priorities** creates a hierarchy — for example, Work > Projects > Feature X > Planning — that lets you organize at different levels of detail.');
    INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (1 * interval '1 minute'), '**Viewing a priority shows threads from it and all descendants.** When you view Work, you see everything under Work (including Projects, Feature X, etc.). When you view Work > Projects > Feature X, you only see that specific area. **Everything** is the special priority that shows all your threads across all priorities.');
    INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (2 * interval '1 minute'), '**Best practice:** Organize from broad to specific. Example: Work > Marketing Campaign > Content Strategy, or Personal > Home Renovation > Kitchen Planning. Start with top-level contexts (Work, Personal, Family) then add specific projects within each. This allows you to zoom in for focus, and zoom out to make sure you''re not missing anything.');
    INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (3 * interval '1 minute'), 'Create your first priority — for example, **Work** or **Personal**. You can always add more or nest them later.');

    -- Add your Connections
    INSERT INTO thread (created_by, title, preview, key, topics)
        VALUES (v_author_id, 'Add your Connections', 'Connections sync items from your other apps and services into Plot, often two-way.', 'connections', ARRAY[v_everyone_topic_id])
    RETURNING id INTO v_thread_id;
    
    INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (0 * interval '1 minute'), '**Connections** sync items from your other apps and services into Plot, often two-way. For example, connect your calendar to see events as threads, or connect your email to bring in conversations. You can view and interact with items right from Plot — see and add comments on documents, respond to messages, update issues — the goal is to bring everything into one place.');
    INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (1 * interval '1 minute'), 'Each connection has channels you can enable or disable, letting you control exactly what syncs. Use the **Manage connections** command to browse available connections, vote for upcoming ones, and manage which are active.');
    INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (2 * interval '1 minute'), 'Set up your first connection using the **Manage connections** command.');

    -- Getting Around
    INSERT INTO thread (created_by, title, preview, key, topics)
        VALUES (v_author_id, 'Getting Around', 'Keyboard and touch shortcuts', 'getting-around', ARRAY[v_everyone_topic_id])
    RETURNING id INTO v_thread_id;
    
    INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (0 * interval '1 minute'), 'Plot''s goal is to get you to meaningful work as quickly as possible. Here are some tips for navigating efficiently.');
    INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (1 * interval '1 minute'), '**Keyboard Navigation**

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
        VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (2 * interval '1 minute'), '**Touch Gestures**

- **Long press** on items to open the menu
- **Swipe right** on threads: Start (or Finish if already started)
- **Swipe left** on threads: Schedule for later
- **Share** a link from another app to Plot using the share sheet (iOS and Android)');

    -- Explore Twists
    INSERT INTO thread (created_by, title, preview, key, topics)
        VALUES (v_author_id, 'Explore Twists', 'Twists are automations, workflows, and agents that do helpful things with your threads.', 'twists', ARRAY[v_everyone_topic_id])
    RETURNING id INTO v_thread_id;
    
    INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (0 * interval '1 minute'), '**Twists** are automations, workflows, and agents that do helpful things with your threads — often working with items from your connections. For example, a twist might triage your inbox, summarize meeting notes, or create follow-up tasks from action items.');
    INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (1 * interval '1 minute'), 'You can also **create your own twists**, either by describing what you want (Plot AI will generate it for you) or by writing code. Custom twists can automate any workflow specific to your needs.');
    INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (2 * interval '1 minute'), 'You can also **@mention Plot** in any thread to ask questions about your notes and links. Plot will search your content and answer using AI.');
    INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (3 * interval '1 minute'), 'Try **@mentioning Plot** in any thread to ask a question about your notes.');

    -- Set up Notifications
    INSERT INTO thread (created_by, title, preview, key, topics)
        VALUES (v_author_id, 'Set up Notifications', 'Plot delivers notifications based on urgency, not instantly. Adjust per-priority timing to match how you work.', 'notifications', ARRAY[v_everyone_topic_id])
    RETURNING id INTO v_thread_id;
    
    INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (0 * interval '1 minute'), 'Plot has smart notifications that are timed based on urgency rather than sending everything immediately. This means new messages and updates won''t interrupt you the moment they arrive — instead, they''re delivered within a timeframe you control. If you''re used to getting notified immediately for every message, you may want to adjust these defaults.');
    INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (1 * interval '1 minute'), 'Each priority has two timing settings:

- **See requests within** (default: 30 minutes) — how quickly you''re notified about messages and mentions
- **See updates within** (default: 1 hour) — how quickly you''re notified about other changes

To adjust, open a priority''s command menu and choose **Notifications**, or tap the notification icon on a priority. Settings inherit from parent priorities, so you can set timing once at the top level and all children will follow.');
    INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (2 * interval '1 minute'), 'Plot also has **quiet hours** (default: 9 PM – 7 AM) during which notifications are silenced. You can customize quiet hours per priority in the same Notifications settings.');
    INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (3 * interval '1 minute'), 'Adjust notification timing for your most important priority.');

    -- Clean up without losing anything
    INSERT INTO thread (created_by, title, preview, key, topics)
        VALUES (v_author_id, 'Clean up without losing anything', 'When something is no longer actively in progress, you can archive it. Archived items are hidden but never deleted.', 'clean-up', ARRAY[v_everyone_topic_id])
    RETURNING id INTO v_thread_id;
    
    INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (0 * interval '1 minute'), 'When something is no longer actively in progress — a completed project, an old priority, a finished thread — you can **archive it**. Archived items are hidden from your main view but never deleted. You can view archived items or unarchive them anytime.');
    INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (1 * interval '1 minute'), 'You can archive both **priorities** and **threads**. Use the command menu on any priority or thread to find the archive option. Archiving a priority hides it and all its threads from the main view.');
END $$;

-- Drop the per-user setup function
DROP FUNCTION IF EXISTS public.setup_plot_app_priority (uuid);
