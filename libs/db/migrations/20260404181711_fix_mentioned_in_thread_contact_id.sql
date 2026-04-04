-- Set comment to column: "author_id" on table: "note"
COMMENT ON COLUMN "public"."note"."author_id" IS 'The actor to credit with creating this note. For notes created by users, this is the user''s contact ID (never the user_id). For notes created by twists, this is the twist''s priority_twist_id.';
-- Set comment to column: "mentions" on table: "note"
COMMENT ON COLUMN "public"."note"."mentions" IS 'Array of actor IDs (contact_id or priority_twist_id) mentioned in this note. For users, this stores their contact_id (not user_id).';
-- Modify "setup_plot_app_priority" function
CREATE OR REPLACE FUNCTION "public"."setup_plot_app_priority" ("p_user_id" uuid) RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_priority_id uuid;
    v_priority_path ltree;
    v_contact_id uuid;
    v_user_root_path ltree;
    v_override_path ltree;
    v_created boolean := FALSE;
    v_thread_id uuid;
BEGIN
    -- Get or create @plot.app priority
    SELECT
        id,
        path INTO v_priority_id,
        v_priority_path
    FROM
        priority
    WHERE
        key = '@plot.app'
    LIMIT 1;
    IF v_priority_id IS NULL THEN
        v_priority_path := generate_path (NULL);
        INSERT INTO priority (created_by, title, path, color, key, updated_by)
            VALUES (p_user_id, 'Using Plot', v_priority_path, 7, '@plot.app', 0)
        RETURNING
            id INTO v_priority_id;
        v_created := TRUE;
        -- Clean up any auto-created personal entry
        DELETE FROM priority_user
        WHERE user_id = p_user_id
            AND priority_id = v_priority_id
            AND personal = TRUE;
    END IF;
    -- Get user's contact_id
    SELECT
        id INTO v_contact_id
    FROM
        contact
    WHERE
        user_id = p_user_id
        AND "primary" = TRUE
    LIMIT 1;
    -- Add priority_contact (idempotent)
    IF v_contact_id IS NOT NULL THEN
        INSERT INTO priority_contact (priority_id, contact_id)
            VALUES (v_priority_id, v_contact_id)
        ON CONFLICT (priority_id, contact_id)
            DO NOTHING;
    END IF;
    -- Add priority_user with viewer role (idempotent - don't overwrite existing role)
    INSERT INTO priority_user (user_id, priority_id, personal, role)
        VALUES (p_user_id, v_priority_id, FALSE, 'viewer')
    ON CONFLICT (user_id, priority_id)
        DO NOTHING;
    -- Position under user's root via priority_settings
    SELECT
        p.path INTO v_user_root_path
    FROM
        priority_user pu
        JOIN priority p ON pu.priority_id = p.id
    WHERE
        pu.user_id = p_user_id
        AND pu.personal = TRUE
    LIMIT 1;
    IF v_user_root_path IS NOT NULL THEN
        v_override_path := generate_path (v_user_root_path);
        INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (p_user_id, v_priority_id, 'path', to_jsonb (ltree2text (v_override_path)))
        ON CONFLICT (user_id, priority_id, key)
            DO UPDATE SET
                value = EXCLUDED.value;
        INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (p_user_id, v_priority_id, 'title', to_jsonb ('Using Plot'::text))
        ON CONFLICT (user_id, priority_id, key)
            DO UPDATE SET
                value = EXCLUDED.value;
    END IF;
    -- Create onboarding threads (only on first creation of the priority)
    IF v_created THEN
        -- Welcome to Plot!
        INSERT INTO thread (created_by, priority_id, title, preview, key)
            VALUES (p_user_id, v_priority_id, 'Welcome to Plot!', 'Plot is your workspace for making progress on what matters.', 'welcome')
        RETURNING
            id INTO v_thread_id;
        INSERT INTO note (author_id, created_by, thread_id, content)
            VALUES (p_user_id, p_user_id, v_thread_id, 'Plot is your workspace for making progress on what matters most. **Priorities**, **Threads**, and **Notes** are the core building blocks of Plot:

- **Priorities**: The roles, goals, and projects in your life — the areas you direct your focus and energy toward. Examples include Work, Personal, Launch New Product, Team Leader, and Learn French.
- **Threads**: Everything related to something you work on, collected in one place. A thread can contain notes, messages to collaborators, links syncing with external items, and chats with twists. Threads are the core thing you Start, Schedule, and Finish.
- **Notes**: The content within threads. Notes can be personal notes, messages to others, or synced comments with connected apps. Individual notes can be marked as tasks and assigned to people.');
        INSERT INTO note (author_id, created_by, thread_id, content)
            VALUES (p_user_id, p_user_id, v_thread_id, 'When a thread needs your attention, you **Start** it — it could be as simple as reading and thinking, or it could mean taking action. You can also **Schedule** a thread to choose when you want to act on it. Starting and scheduling build your personal agenda — it''s not a shared project board, it''s your own action plan.

When you''re done with your part, you **Finish** the thread. This marks any of your tasks in the thread as done and completes linked items in connected apps — for example, closing a Linear ticket. You (and others) might Start and Finish a thread multiple times as work progresses. There''s also a separate **Done** tag you can add to mark a thread as complete for good for everyone.');
        INSERT INTO note (author_id, created_by, thread_id, content)
            VALUES (p_user_id, p_user_id, v_thread_id, 'The **Agenda** is everything you plan to work on — started and scheduled threads, arranged in your preferred order. You can reorder items freely, move them to a different time or date, or remove them without losing the thread.

The **Activity** view shows what''s happening across your priorities — new threads, updates, and unread items. From Activity, you can add anything to your Agenda by Starting (act on it now) or Scheduling (act on it later).

A useful pattern: when a meeting or event appears in Activity from a calendar connection, tap **Start** to add a planning slot in your Agenda — useful for blocking time to prepare or to follow up afterward.');
        INSERT INTO note (author_id, created_by, thread_id, content)
            VALUES (p_user_id, p_user_id, v_thread_id, 'Threads can contain links to items in external services — documents, calendar events, web pages, issues, and more. These are created by connections (more on that later). Links keep everything related to your work in one place, so you always have the context you need.');
        -- Create your initial Priorities
        INSERT INTO thread (created_by, priority_id, title, preview, key)
            VALUES (p_user_id, v_priority_id, 'Create your initial Priorities', 'Priorities are contexts for focus and often correspond to roles and goals. Nesting priorities creates a hierarchy that lets you organize at different levels of detail.', 'priorities')
        RETURNING
            id INTO v_thread_id;
        INSERT INTO note (author_id, created_by, thread_id, content)
            VALUES (p_user_id, p_user_id, v_thread_id, 'Priorities are contexts for focus and often correspond to roles (like VP Marketing and Parent) and goals (like Launch New Product and Run a Marathon). **Nesting priorities** creates a hierarchy — for example, Work > Projects > Feature X > Planning — that lets you organize at different levels of detail.');
        INSERT INTO note (author_id, created_by, thread_id, content)
            VALUES (p_user_id, p_user_id, v_thread_id, '**Viewing a priority shows threads from it and all descendants.** When you view Work, you see everything under Work (including Projects, Feature X, etc.). When you view Work > Projects > Feature X, you only see that specific area. **Everything** is the special priority that shows all your threads across all priorities.');
        INSERT INTO note (author_id, created_by, thread_id, content)
            VALUES (p_user_id, p_user_id, v_thread_id, '**Best practice:** Organize from broad to specific. Example: Work > Marketing Campaign > Content Strategy, or Personal > Home Renovation > Kitchen Planning. Start with top-level contexts (Work, Personal, Family) then add specific projects within each. This allows you to zoom in for focus, and zoom out to make sure you''re not missing anything.');
        INSERT INTO note (author_id, created_by, thread_id, content)
            VALUES (p_user_id, p_user_id, v_thread_id, 'Create your first priority — for example, **Work** or **Personal**. You can always add more or nest them later.');
        -- Add your Connections
        INSERT INTO thread (created_by, priority_id, title, preview, key)
            VALUES (p_user_id, v_priority_id, 'Add your Connections', 'Connections sync items from your other apps and services into Plot, often two-way.', 'connections')
        RETURNING
            id INTO v_thread_id;
        INSERT INTO note (author_id, created_by, thread_id, content)
            VALUES (p_user_id, p_user_id, v_thread_id, '**Connections** sync items from your other apps and services into Plot, often two-way. For example, connect your calendar to see events as threads, or connect your email to bring in conversations. You can view and interact with items right from Plot — see and add comments on documents, respond to messages, update issues — the goal is to bring everything into one place.');
        INSERT INTO note (author_id, created_by, thread_id, content)
            VALUES (p_user_id, p_user_id, v_thread_id, 'Each connection has channels you can enable or disable, letting you control exactly what syncs. Use the **Manage connections** command to browse available connections, vote for upcoming ones, and manage which are active.');
        INSERT INTO note (author_id, created_by, thread_id, content)
            VALUES (p_user_id, p_user_id, v_thread_id, 'Set up your first connection using the **Manage connections** command.');
        -- Getting Around
        INSERT INTO thread (created_by, priority_id, title, preview, key)
            VALUES (p_user_id, v_priority_id, 'Getting Around', 'Keyboard and touch shortcuts', 'getting-around')
        RETURNING
            id INTO v_thread_id;
        INSERT INTO note (author_id, created_by, thread_id, content)
            VALUES (p_user_id, p_user_id, v_thread_id, 'Plot''s goal is to get you to meaningful work as quickly as possible. Here are some tips for navigating efficiently.');
        INSERT INTO note (author_id, created_by, thread_id, content)
            VALUES (p_user_id, p_user_id, v_thread_id, '**Keyboard Navigation**

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
        INSERT INTO note (author_id, created_by, thread_id, content)
            VALUES (p_user_id, p_user_id, v_thread_id, '**Touch Gestures**

- **Long press** on items to open the menu
- **Swipe right** on threads: Start (or Finish if already started)
- **Swipe left** on threads: Schedule for later
- **Share** a link from another app to Plot using the share sheet (iOS and Android)');
        -- Explore Twists
        INSERT INTO thread (created_by, priority_id, title, preview, key)
            VALUES (p_user_id, v_priority_id, 'Explore Twists', 'Twists are automations, workflows, and agents that do helpful things with your threads.', 'twists')
        RETURNING
            id INTO v_thread_id;
        INSERT INTO note (author_id, created_by, thread_id, content)
            VALUES (p_user_id, p_user_id, v_thread_id, '**Twists** are automations, workflows, and agents that do helpful things with your threads — often working with items from your connections. For example, a twist might triage your inbox, summarize meeting notes, or create follow-up tasks from action items.');
        INSERT INTO note (author_id, created_by, thread_id, content)
            VALUES (p_user_id, p_user_id, v_thread_id, 'You can also **create your own twists**, either by describing what you want (Plot AI will generate it for you) or by writing code. Custom twists can automate any workflow specific to your needs.');
        INSERT INTO note (author_id, created_by, thread_id, content)
            VALUES (p_user_id, p_user_id, v_thread_id, 'You can also **@mention Plot** in any thread to ask questions about your notes and links. Plot will search your content and answer using AI.');
        INSERT INTO note (author_id, created_by, thread_id, content)
            VALUES (p_user_id, p_user_id, v_thread_id, 'Try **@mentioning Plot** in any thread to ask a question about your notes.');
        -- Set up Notifications
        INSERT INTO thread (created_by, priority_id, title, preview, key)
            VALUES (p_user_id, v_priority_id, 'Set up Notifications', 'Plot delivers notifications based on urgency, not instantly. Adjust per-priority timing to match how you work.', 'notifications')
        RETURNING
            id INTO v_thread_id;
        INSERT INTO note (author_id, created_by, thread_id, content)
            VALUES (p_user_id, p_user_id, v_thread_id, 'Plot has smart notifications that are timed based on urgency rather than sending everything immediately. This means new messages and updates won''t interrupt you the moment they arrive — instead, they''re delivered within a timeframe you control. If you''re used to getting notified immediately for every message, you may want to adjust these defaults.');
        INSERT INTO note (author_id, created_by, thread_id, content)
            VALUES (p_user_id, p_user_id, v_thread_id, 'Each priority has two timing settings:

- **See requests within** (default: 30 minutes) — how quickly you''re notified about messages and mentions
- **See updates within** (default: 1 hour) — how quickly you''re notified about other changes

To adjust, open a priority''s command menu and choose **Notifications**, or tap the notification icon on a priority. Settings inherit from parent priorities, so you can set timing once at the top level and all children will follow.');
        INSERT INTO note (author_id, created_by, thread_id, content)
            VALUES (p_user_id, p_user_id, v_thread_id, 'Plot also has **quiet hours** (default: 9 PM – 7 AM) during which notifications are silenced. You can customize quiet hours per priority in the same Notifications settings.');
        INSERT INTO note (author_id, created_by, thread_id, content)
            VALUES (p_user_id, p_user_id, v_thread_id, 'Adjust notification timing for your most important priority.');
        -- Clean up without losing anything
        INSERT INTO thread (created_by, priority_id, title, preview, key)
            VALUES (p_user_id, v_priority_id, 'Clean up without losing anything', 'When something is no longer actively in progress, you can archive it. Archived items are hidden but never deleted.', 'clean-up')
        RETURNING
            id INTO v_thread_id;
        INSERT INTO note (author_id, created_by, thread_id, content)
            VALUES (p_user_id, p_user_id, v_thread_id, 'When something is no longer actively in progress — a completed project, an old priority, a finished thread — you can **archive it**. Archived items are hidden from your main view but never deleted. You can view archived items or unarchive them anytime.');
        INSERT INTO note (author_id, created_by, thread_id, content)
            VALUES (p_user_id, p_user_id, v_thread_id, 'You can archive both **priorities** and **threads**. Use the command menu on any priority or thread to find the archive option. Archiving a priority hides it and all its threads from the main view.');
    END IF;
    RETURN jsonb_build_object('success', TRUE, 'priority_id', v_priority_id);
END;
$$;
-- Modify "mentioned_in_thread" function
CREATE OR REPLACE FUNCTION "user"."mentioned_in_thread" ("user_id" uuid, "thread_id" uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.note
            WHERE
                note.thread_id = mentioned_in_thread.thread_id
                AND note.archived_at IS NULL
                AND "user".user_contact_id(mentioned_in_thread.user_id) = ANY (note.mentions));
$$;
-- Modify "note" view
CREATE OR REPLACE VIEW "user"."note" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "archived_at",
  "thread_id",
  "draft",
  "private",
  "content",
  "actions",
  "mentions",
  "re_note_id",
  "merged_from_thread_id"
) AS SELECT upe.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.archived_at,
    n.thread_id,
    n.draft,
    n.private,
    n.content,
    n.actions,
    n.mentions,
    n.re_note_id,
    n.merged_from_thread_id
   FROM public.note n
     JOIN public.thread a ON a.id = n.thread_id
     JOIN "user".priority_expanded upe ON upe.priority_id = a.priority_id
  WHERE (n.draft = false OR n.created_by = upe.user_id) AND (n.private = false OR n.created_by = upe.user_id OR ("user".user_contact_id(upe.user_id) = ANY (n.mentions)) OR upe.role = 'member'::text) AND (a.draft = false OR a.created_by = upe.user_id) AND
        CASE
            WHEN a.private = false THEN true
            WHEN a.created_by = upe.user_id THEN true
            WHEN upe.role = 'member'::text THEN true
            ELSE "user".mentioned_in_thread(upe.user_id, a.id)
        END
UNION ALL
 SELECT upe.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    COALESCE(n.archived_at, n.updated_at) AS archived_at,
    n.thread_id,
    n.draft,
    n.private,
    NULL::text AS content,
    NULL::jsonb AS actions,
    NULL::uuid[] AS mentions,
    n.re_note_id,
    n.merged_from_thread_id
   FROM public.note n
     JOIN public.thread a ON a.id = n.thread_id
     JOIN "user".priority_expanded upe ON upe.priority_id = a.priority_id
  WHERE (n.draft = false OR n.created_by = upe.user_id) AND (a.draft = false OR a.created_by = upe.user_id) AND upe.role <> 'member'::text AND (n.private = true AND n.created_by <> upe.user_id AND NOT ("user".user_contact_id(upe.user_id) = ANY (COALESCE(n.mentions, '{}'::uuid[]))) OR a.private = true AND a.created_by <> upe.user_id AND NOT "user".mentioned_in_thread(upe.user_id, a.id));
-- Modify "note_tags" view
CREATE OR REPLACE VIEW "user"."note_tags" (
  "user_id",
  "id",
  "updated_at",
  "archived_at",
  "priority_id",
  "priority_path",
  "tags"
) AS SELECT ua.user_id,
    n.id,
    nt.updated_at,
    ua.archived_at,
    ua.priority_id,
    ua.priority_path,
    nt.tags
   FROM public.note_tags nt
     JOIN public.note n ON n.id = nt.note_id
     JOIN "user".thread ua ON ua.id = n.thread_id
  WHERE (n.draft = false OR n.created_by = ua.user_id) AND (n.private = false OR n.created_by = ua.user_id OR ("user".user_contact_id(ua.user_id) = ANY (n.mentions)));
