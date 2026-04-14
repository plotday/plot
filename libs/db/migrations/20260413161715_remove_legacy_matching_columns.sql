-- Drop "link_x" view
DROP VIEW "public"."link_x";
-- Modify "link" table
ALTER TABLE "public"."link" DROP COLUMN "embedding", DROP COLUMN "match";
-- Modify "thread_priority" table
ALTER TABLE "public"."thread_priority" DROP COLUMN "matched", DROP COLUMN "refile_batch_id", DROP COLUMN "previous_priority_id";
-- Set comment to table: "thread_priority"
COMMENT ON TABLE "public"."thread_priority" IS 'Per-user filing of a thread into the user''s priority hierarchy. Each user gets one row per visible thread, pointing at their chosen priority.';
-- Modify "file_thread_priority_for_topic_members" function
CREATE OR REPLACE FUNCTION "public"."file_thread_priority_for_topic_members" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
    v_peer_priority_id uuid;
    v_author_user_id uuid;
BEGIN
    IF NEW.topics IS NULL OR cardinality(NEW.topics) = 0 THEN
        RETURN NEW;
    END IF;

    IF EXISTS (SELECT 1 FROM "public"."user" WHERE id = NEW.created_by) THEN
        v_author_user_id := NEW.created_by;
    ELSE
        SELECT pt.owner_id INTO v_author_user_id
        FROM public.twist_instance pt
        WHERE pt.id = NEW.created_by;
    END IF;

    FOR r IN
        SELECT DISTINCT uc.user_id AS peer_user_id
        FROM unnest(NEW.topics) AS arr(topic_id)
        JOIN public.topic_member tm ON tm.topic_id = arr.topic_id
        JOIN public.user_contact uc
          ON uc.contact_id = tm.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM v_author_user_id
    LOOP
        v_peer_priority_id := public.classify_thread_for_user(r.peer_user_id, NEW.id);
        IF v_peer_priority_id IS NOT NULL THEN
            INSERT INTO thread_priority (thread_id, user_id, priority_id)
            VALUES (NEW.id, r.peer_user_id, v_peer_priority_id)
            ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;

            INSERT INTO thread_unread (user_id, thread_id, urgency, importance)
            VALUES (r.peer_user_id, NEW.id, 'inform-updates', 50)
            ON CONFLICT (user_id, thread_id) DO NOTHING;
        END IF;
    END LOOP;

    RETURN NEW;
END;
$$;
-- Modify "file_thread_priority_on_topic_member_change" function
CREATE OR REPLACE FUNCTION "public"."file_thread_priority_on_topic_member_change" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r_thread RECORD;
    v_peer_user_id uuid;
    v_peer_priority_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT uc.user_id INTO v_peer_user_id
        FROM public.user_contact uc
        WHERE uc.contact_id = NEW.contact_id
          AND uc.linked = TRUE
          AND uc.archived_at IS NULL
        LIMIT 1;

        IF v_peer_user_id IS NULL THEN
            RETURN NEW;
        END IF;

        FOR r_thread IN
            SELECT t.id AS thread_id
            FROM public.thread t
            WHERE NEW.topic_id = ANY(t.topics)
              AND t.archived_at IS NULL
        LOOP
            v_peer_priority_id := public.classify_thread_for_user(v_peer_user_id, r_thread.thread_id);
            IF v_peer_priority_id IS NULL THEN
                CONTINUE;
            END IF;

            INSERT INTO thread_priority (thread_id, user_id, priority_id)
            VALUES (r_thread.thread_id, v_peer_user_id, v_peer_priority_id)
            ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;

            INSERT INTO thread_unread (user_id, thread_id, urgency, importance)
            VALUES (v_peer_user_id, r_thread.thread_id, 'inform-updates', 50)
            ON CONFLICT (user_id, thread_id) DO NOTHING;
        END LOOP;

        RETURN NEW;

    ELSIF TG_OP = 'DELETE' THEN
        SELECT uc.user_id INTO v_peer_user_id
        FROM public.user_contact uc
        WHERE uc.contact_id = OLD.contact_id
          AND uc.linked = TRUE
          AND uc.archived_at IS NULL
        LIMIT 1;

        IF v_peer_user_id IS NULL THEN
            RETURN OLD;
        END IF;

        FOR r_thread IN
            SELECT t.id AS thread_id
            FROM public.thread t
            WHERE OLD.topic_id = ANY(t.topics)
              AND t.archived_at IS NULL
        LOOP
            IF NOT EXISTS (
                SELECT 1 FROM public.thread t2
                WHERE t2.id = r_thread.thread_id
                  AND (
                    t2.contacts && "user".user_contact_ids(v_peer_user_id)
                    OR EXISTS (
                        SELECT 1 FROM unnest(t2.topics) AS tid
                        JOIN topic_member tm2 ON tm2.topic_id = tid
                        JOIN user_contact uc2 ON uc2.contact_id = tm2.contact_id
                            AND uc2.linked = TRUE AND uc2.archived_at IS NULL
                        WHERE uc2.user_id = v_peer_user_id
                          AND tm2.topic_id != OLD.topic_id
                    )
                  )
            ) THEN
                DELETE FROM thread_priority
                WHERE thread_id = r_thread.thread_id
                  AND user_id = v_peer_user_id;

                DELETE FROM thread_unread
                WHERE thread_id = r_thread.thread_id
                  AND user_id = v_peer_user_id;
            END IF;
        END LOOP;

        RETURN OLD;
    END IF;
END;
$$;
-- Modify "file_thread_priority_peers" function
CREATE OR REPLACE FUNCTION "public"."file_thread_priority_peers" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
    v_peer_priority_id uuid;
    v_author_user_id uuid;
    v_old_contacts uuid[];
BEGIN
    IF NEW.contacts IS NULL OR cardinality(NEW.contacts) = 0 THEN
        RETURN NEW;
    END IF;

    -- Compute old contacts for delta (empty on INSERT)
    IF TG_OP = 'UPDATE' THEN
        v_old_contacts := COALESCE(OLD.contacts, ARRAY[]::uuid[]);
    ELSE
        v_old_contacts := ARRAY[]::uuid[];
    END IF;

    -- Exclude the author (user_id or twist_instance owner) from peer filing
    -- so we don't double-insert against the author trigger.
    IF EXISTS (SELECT 1 FROM "public"."user" WHERE id = NEW.created_by) THEN
        v_author_user_id := NEW.created_by;
    ELSE
        SELECT pt.owner_id INTO v_author_user_id
        FROM public.twist_instance pt
        WHERE pt.id = NEW.created_by;
    END IF;

    -- thread_priority for ALL contacts (idempotent via ON CONFLICT DO NOTHING)
    FOR r IN
        SELECT DISTINCT uc.user_id AS peer_user_id
        FROM unnest(NEW.contacts) AS arr(contact_id)
        JOIN public.user_contact uc
          ON uc.contact_id = arr.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM v_author_user_id
    LOOP
        v_peer_priority_id := public.classify_thread_for_user(r.peer_user_id, NEW.id);
        IF v_peer_priority_id IS NOT NULL THEN
            INSERT INTO thread_priority (thread_id, user_id, priority_id)
            VALUES (NEW.id, r.peer_user_id, v_peer_priority_id)
            ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;
        END IF;
    END LOOP;

    -- thread_unread for NEWLY ADDED contacts only, so shared threads
    -- appear as unread for peers. Uses ON CONFLICT DO NOTHING to avoid
    -- overwriting existing read state.
    FOR r IN
        SELECT DISTINCT uc.user_id AS peer_user_id
        FROM unnest(NEW.contacts) AS arr(contact_id)
        JOIN public.user_contact uc
          ON uc.contact_id = arr.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM v_author_user_id
          AND arr.contact_id != ALL(v_old_contacts)
    LOOP
        INSERT INTO thread_unread (user_id, thread_id, urgency, importance)
        VALUES (r.peer_user_id, NEW.id, 'inform-updates', 50)
        ON CONFLICT (user_id, thread_id) DO NOTHING;
    END LOOP;

    RETURN NEW;
END;
$$;
-- Modify "search_notes_and_links" function
CREATE OR REPLACE FUNCTION "public"."search_notes_and_links" ("query_embedding" text, "scope_priority_id" uuid, "requesting_user_id" uuid, "exclude_created_by" uuid DEFAULT NULL::uuid, "similarity_threshold" double precision DEFAULT 0.3, "match_limit" integer DEFAULT 20) RETURNS TABLE ("result_type" text, "result_id" uuid, "thread_id" uuid, "thread_title" text, "priority_id" uuid, "priority_title" text, "content" text, "title" text, "source_url" text, "similarity" double precision) LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    SELECT * FROM (
        -- Notes
        SELECT 'note'::text, n.id, n.thread_id, t.title, tp.priority_id,
               p.title, n.content, NULL::text, NULL::text,
               (1 - (n.embedding <=> query_embedding::halfvec))::float AS similarity
        FROM note n
        JOIN thread t ON t.id = n.thread_id
        JOIN thread_priority tp ON tp.thread_id = t.id AND tp.user_id = requesting_user_id
        JOIN priority p ON p.id = tp.priority_id
        JOIN priority_child pc ON pc.priority_id = scope_priority_id
                              AND pc.child_id = tp.priority_id
        WHERE n.embedding IS NOT NULL
          AND n.archived_at IS NULL AND n.draft = FALSE
          AND t.archived_at IS NULL
          AND t.contacts && "user".user_contact_ids(requesting_user_id)
          AND (n.access_contacts IS NULL OR n.created_by = requesting_user_id
               OR n.access_contacts && "user".user_contact_ids(requesting_user_id))
          AND (exclude_created_by IS NULL OR n.created_by != exclude_created_by)
          AND (1 - (n.embedding <=> query_embedding::halfvec)) >= similarity_threshold

        UNION ALL

        -- Threads (via thread.embedding)
        SELECT 'link'::text, l.id, l.thread_id, t.title, tp.priority_id,
               p.title, l.preview, l.title, l.source_url,
               (1 - (t.embedding <=> query_embedding::halfvec))::float AS similarity
        FROM link l
        JOIN thread t ON t.id = l.thread_id
        JOIN thread_priority tp ON tp.thread_id = t.id AND tp.user_id = requesting_user_id
        JOIN priority p ON p.id = tp.priority_id
        JOIN priority_child pc ON pc.priority_id = scope_priority_id
                              AND pc.child_id = tp.priority_id
        WHERE t.embedding IS NOT NULL AND l.thread_id IS NOT NULL
          AND t.archived_at IS NULL
          AND t.contacts && "user".user_contact_ids(requesting_user_id)
          AND (1 - (t.embedding <=> query_embedding::halfvec)) >= similarity_threshold
    ) combined
    ORDER BY combined.similarity DESC
    LIMIT match_limit;
END;
$$;
-- Modify "setup_plot_app_priority" function
CREATE OR REPLACE FUNCTION "public"."setup_plot_app_priority" ("p_user_id" uuid) RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_priority_id uuid;
    v_priority_path ltree;
    v_created boolean := FALSE;
    v_author_id uuid;
    v_author_contact_id uuid;
    v_thread_id uuid;
    v_note_order integer;
    v_everyone_topic_id uuid;
BEGIN
    -- Onboarding content is authored by the Plot team account; fall back
    -- to the activating user if that account isn't seeded.
    SELECT id INTO v_author_id
    FROM "user"
    WHERE email = 'kris@plot.day'
    LIMIT 1;

    IF v_author_id IS NULL THEN
        v_author_id := p_user_id;
    END IF;

    SELECT id INTO v_author_contact_id
    FROM contact
    WHERE user_id = v_author_id
      AND "primary" = TRUE
    LIMIT 1;

    -- Get or create the "Everyone" announce topic for thread visibility
    SELECT id INTO v_everyone_topic_id
    FROM topic
    WHERE auto_maintained = TRUE AND team_id IS NULL
    LIMIT 1;

    IF v_everyone_topic_id IS NULL THEN
        INSERT INTO topic (name, type, join_policy, created_by, auto_maintained)
            VALUES ('Everyone', 'announce', 'open', v_author_id, TRUE)
        RETURNING id INTO v_everyone_topic_id;
    END IF;

    -- Get or create the per-user @plot.app priority
    SELECT id, path INTO v_priority_id, v_priority_path
    FROM priority
    WHERE key = '@plot.app'
      AND user_id = p_user_id
    LIMIT 1;

    IF v_priority_id IS NULL THEN
        v_priority_path := generate_path (NULL);
        INSERT INTO priority (created_by, user_id, title, path, color, key, updated_by)
            VALUES (p_user_id, p_user_id, 'Using Plot', v_priority_path, 7, '@plot.app', 0)
        RETURNING id INTO v_priority_id;
        v_created := TRUE;
    ELSE
        UPDATE priority
        SET title = 'Using Plot'
        WHERE id = v_priority_id
          AND title != 'Using Plot';
    END IF;

    -- Create onboarding threads if the 'welcome' thread doesn't exist yet
    IF NOT EXISTS (
        SELECT 1 FROM thread t
        JOIN thread_priority tp ON tp.thread_id = t.id
        WHERE tp.priority_id = v_priority_id AND tp.user_id = p_user_id AND t.key = 'welcome'
    ) THEN
        -- Welcome to Plot!
        INSERT INTO thread (created_by, title, preview, key, topics)
            VALUES (v_author_id, 'Welcome to Plot!', 'Plot is your workspace for making progress on what matters.', 'welcome', ARRAY[v_everyone_topic_id])
        RETURNING id INTO v_thread_id;
        INSERT INTO thread_priority (thread_id, user_id, priority_id)
            VALUES (v_thread_id, p_user_id, v_priority_id);
        v_note_order := 0;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'Plot is your workspace for making progress on what matters most. **Priorities**, **Threads**, and **Notes** are the core building blocks of Plot:

- **Priorities**: The roles, goals, and projects in your life — the areas you direct your focus and energy toward. Examples include Work, Personal, Launch New Product, Team Leader, and Learn French.
- **Threads**: Everything related to something you work on, collected in one place. A thread can contain notes, messages to collaborators, links syncing with external items, and chats with twists. Threads are the core thing you Start, Schedule, and Finish.
- **Notes**: The content within threads. Notes can be personal notes, messages to others, or synced comments with connected apps. Individual notes can be marked as tasks and assigned to people.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'When a thread needs your attention, you **Start** it — it could be as simple as reading and thinking, or it could mean taking action. You can also **Schedule** a thread to choose when you want to act on it. Starting and scheduling build your personal agenda — it''s not a shared project board, it''s your own action plan.

When you''re done with your part, you **Finish** the thread. This marks any of your tasks in the thread as done and completes linked items in connected apps — for example, closing a Linear ticket. You (and others) might Start and Finish a thread multiple times as work progresses. There''s also a separate **Done** tag you can add to mark a thread as complete for good for everyone.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'The **Agenda** is everything you plan to work on — started and scheduled threads, arranged in your preferred order. You can reorder items freely, move them to a different time or date, or remove them without losing the thread.

The **Activity** view shows what''s happening across your priorities — new threads, updates, and unread items. From Activity, you can add anything to your Agenda by Starting (act on it now) or Scheduling (act on it later).

A useful pattern: when a meeting or event appears in Activity from a calendar connection, tap **Start** to add a planning slot in your Agenda — useful for blocking time to prepare or to follow up afterward.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'Threads can contain links to items in external services — documents, calendar events, web pages, issues, and more. These are created by connections (more on that later). Links keep everything related to your work in one place, so you always have the context you need.');

        -- Create your initial Priorities
        INSERT INTO thread (created_by, title, preview, key, topics)
            VALUES (v_author_id, 'Create your initial Priorities', 'Priorities are contexts for focus and often correspond to roles and goals. Nesting priorities creates a hierarchy that lets you organize at different levels of detail.', 'priorities', ARRAY[v_everyone_topic_id])
        RETURNING id INTO v_thread_id;
        INSERT INTO thread_priority (thread_id, user_id, priority_id)
            VALUES (v_thread_id, p_user_id, v_priority_id);
        v_note_order := 0;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'Priorities are contexts for focus and often correspond to roles (like VP Marketing and Parent) and goals (like Launch New Product and Run a Marathon). **Nesting priorities** creates a hierarchy — for example, Work > Projects > Feature X > Planning — that lets you organize at different levels of detail.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), '**Viewing a priority shows threads from it and all descendants.** When you view Work, you see everything under Work (including Projects, Feature X, etc.). When you view Work > Projects > Feature X, you only see that specific area. **Everything** is the special priority that shows all your threads across all priorities.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), '**Best practice:** Organize from broad to specific. Example: Work > Marketing Campaign > Content Strategy, or Personal > Home Renovation > Kitchen Planning. Start with top-level contexts (Work, Personal, Family) then add specific projects within each. This allows you to zoom in for focus, and zoom out to make sure you''re not missing anything.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'Create your first priority — for example, **Work** or **Personal**. You can always add more or nest them later.');

        -- Add your Connections
        INSERT INTO thread (created_by, title, preview, key, topics)
            VALUES (v_author_id, 'Add your Connections', 'Connections sync items from your other apps and services into Plot, often two-way.', 'connections', ARRAY[v_everyone_topic_id])
        RETURNING id INTO v_thread_id;
        INSERT INTO thread_priority (thread_id, user_id, priority_id)
            VALUES (v_thread_id, p_user_id, v_priority_id);
        v_note_order := 0;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), '**Connections** sync items from your other apps and services into Plot, often two-way. For example, connect your calendar to see events as threads, or connect your email to bring in conversations. You can view and interact with items right from Plot — see and add comments on documents, respond to messages, update issues — the goal is to bring everything into one place.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'Each connection has channels you can enable or disable, letting you control exactly what syncs. Use the **Manage connections** command to browse available connections, vote for upcoming ones, and manage which are active.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'Set up your first connection using the **Manage connections** command.');

        -- Getting Around
        INSERT INTO thread (created_by, title, preview, key, topics)
            VALUES (v_author_id, 'Getting Around', 'Keyboard and touch shortcuts', 'getting-around', ARRAY[v_everyone_topic_id])
        RETURNING id INTO v_thread_id;
        INSERT INTO thread_priority (thread_id, user_id, priority_id)
            VALUES (v_thread_id, p_user_id, v_priority_id);
        v_note_order := 0;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'Plot''s goal is to get you to meaningful work as quickly as possible. Here are some tips for navigating efficiently.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), '**Keyboard Navigation**

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
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), '**Touch Gestures**

- **Long press** on items to open the menu
- **Swipe right** on threads: Start (or Finish if already started)
- **Swipe left** on threads: Schedule for later
- **Share** a link from another app to Plot using the share sheet (iOS and Android)');

        -- Explore Twists
        INSERT INTO thread (created_by, title, preview, key, topics)
            VALUES (v_author_id, 'Explore Twists', 'Twists are automations, workflows, and agents that do helpful things with your threads.', 'twists', ARRAY[v_everyone_topic_id])
        RETURNING id INTO v_thread_id;
        INSERT INTO thread_priority (thread_id, user_id, priority_id)
            VALUES (v_thread_id, p_user_id, v_priority_id);
        v_note_order := 0;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), '**Twists** are automations, workflows, and agents that do helpful things with your threads — often working with items from your connections. For example, a twist might triage your inbox, summarize meeting notes, or create follow-up tasks from action items.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'You can also **create your own twists**, either by describing what you want (Plot AI will generate it for you) or by writing code. Custom twists can automate any workflow specific to your needs.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'You can also **@mention Plot** in any thread to ask questions about your notes and links. Plot will search your content and answer using AI.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'Try **@mentioning Plot** in any thread to ask a question about your notes.');

        -- Set up Notifications
        INSERT INTO thread (created_by, title, preview, key, topics)
            VALUES (v_author_id, 'Set up Notifications', 'Plot delivers notifications based on urgency, not instantly. Adjust per-priority timing to match how you work.', 'notifications', ARRAY[v_everyone_topic_id])
        RETURNING id INTO v_thread_id;
        INSERT INTO thread_priority (thread_id, user_id, priority_id)
            VALUES (v_thread_id, p_user_id, v_priority_id);
        v_note_order := 0;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'Plot has smart notifications that are timed based on urgency rather than sending everything immediately. This means new messages and updates won''t interrupt you the moment they arrive — instead, they''re delivered within a timeframe you control. If you''re used to getting notified immediately for every message, you may want to adjust these defaults.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'Each priority has two timing settings:

- **See requests within** (default: 30 minutes) — how quickly you''re notified about messages and mentions
- **See updates within** (default: 1 hour) — how quickly you''re notified about other changes

To adjust, open a priority''s command menu and choose **Notifications**, or tap the notification icon on a priority. Settings inherit from parent priorities, so you can set timing once at the top level and all children will follow.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'Plot also has **quiet hours** (default: 9 PM – 7 AM) during which notifications are silenced. You can customize quiet hours per priority in the same Notifications settings.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'Adjust notification timing for your most important priority.');

        -- Clean up without losing anything
        INSERT INTO thread (created_by, title, preview, key, topics)
            VALUES (v_author_id, 'Clean up without losing anything', 'When something is no longer actively in progress, you can archive it. Archived items are hidden but never deleted.', 'clean-up', ARRAY[v_everyone_topic_id])
        RETURNING id INTO v_thread_id;
        INSERT INTO thread_priority (thread_id, user_id, priority_id)
            VALUES (v_thread_id, p_user_id, v_priority_id);
        v_note_order := 0;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'When something is no longer actively in progress — a completed project, an old priority, a finished thread — you can **archive it**. Archived items are hidden from your main view but never deleted. You can view archived items or unarchive them anytime.');
        v_note_order := v_note_order + 1;
        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
            VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (v_note_order * interval '1 second'), 'You can archive both **priorities** and **threads**. Use the command menu on any priority or thread to find the archive option. Archiving a priority hides it and all its threads from the main view.');
    END IF;

    RETURN jsonb_build_object('success', TRUE, 'priority_id', v_priority_id, 'created', v_created);
END;
$$;
-- Modify "upsert_thread" function
CREATE OR REPLACE FUNCTION "user"."upsert_thread" ("user_id" uuid, "p_thread" jsonb, "p_defaults" jsonb DEFAULT '{}') RETURNS "public"."thread" LANGUAGE plpgsql AS $$
DECLARE
    v_result thread;
    v_existing thread;
    v_id uuid;
    -- Variables for derived values
    v_priority_id uuid;
    v_created_by uuid;
    -- Archived status check
    v_is_archived boolean;
BEGIN
    -- Extract required fields from JSONB, with fallback to p_defaults for INSERT
    v_id := COALESCE((p_thread ->> 'id')::uuid, (p_defaults ->> 'id')::uuid);
    v_priority_id := COALESCE((p_thread ->> 'priority_id')::uuid, (p_defaults ->> 'priority_id')::uuid);
    v_created_by := COALESCE((p_thread ->> 'created_by')::uuid, (p_defaults ->> 'created_by')::uuid, user_id);
    -- Generate id if not provided
    -- If key is provided and no id was given, look up existing thread by key + creator
    IF v_id IS NULL THEN
        IF (p_thread ? 'key') AND v_created_by IS NOT NULL THEN
            SELECT id INTO v_id
            FROM thread
            WHERE key = (p_thread ->> 'key')
              AND created_by = v_created_by;
        END IF;
        IF v_id IS NULL THEN
            v_id := uuidv7 ();
        END IF;
    END IF;
    -- Resolve priority_id from existing thread_priority row for this user
    IF v_priority_id IS NULL THEN
        SELECT
            tp.priority_id INTO v_priority_id
        FROM
            thread_priority tp
        WHERE
            tp.thread_id = v_id
            AND tp.user_id = upsert_thread.user_id;
    END IF;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'priority_id must be provided';
    END IF;
    -- Validate access: user must own the target priority
    IF NOT user_has_priority_access(upsert_thread.user_id, v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;
    -- Validate created_by when it differs from user_id
    IF v_created_by IS DISTINCT FROM user_id THEN
        IF NOT EXISTS (
            SELECT
                1
            FROM
                twist_instance pt
            WHERE
                pt.id = v_created_by
                AND pt.owner_id = upsert_thread.user_id) THEN
            RAISE EXCEPTION 'created_by must be user or owned twist_instance';
        END IF;
    END IF;
    -- Fetch the existing thread row (if any) so partial updates can fall
    -- back to current values. Postgres evaluates CHECK constraints on the
    -- INSERT values before ON CONFLICT DO UPDATE kicks in, so the VALUES
    -- clause below must already satisfy the constraints — which means the
    -- INSERT must carry the existing row's values for any field the caller
    -- omitted.
    SELECT * INTO v_existing FROM thread WHERE id = v_id;

    v_is_archived := COALESCE(
        v_existing.archived_at IS NOT NULL
        OR (v_existing.id IS NOT NULL AND NOT EXISTS (
            SELECT 1
            FROM thread_priority tp
            WHERE tp.thread_id = v_existing.id
              AND tp.user_id = upsert_thread.user_id
              AND EXISTS (
                  SELECT 1 FROM priority p
                  WHERE p.id = tp.priority_id
                    AND p.archived_at IS NULL
              )
        )),
        FALSE
    );
    -- Perform the upsert and return the full row.
    -- INSERT values fall through p_thread → p_defaults → v_existing so
    -- that on the UPDATE path the INSERT satisfies CHECK constraints even
    -- when the caller omits fields like title.
    INSERT INTO thread (id, created_by, title, preview, updated_by, sync_depth, contacts, topics, draft, key, icon)
        VALUES (
            v_id,
            v_created_by,
            COALESCE(p_thread ->> 'title', p_defaults ->> 'title', v_existing.title),
            COALESCE(p_thread ->> 'preview', p_defaults ->> 'preview', v_existing.preview),
            COALESCE((p_thread ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, v_existing.updated_by, 0),
            COALESCE((p_thread ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint, v_existing.sync_depth),
            CASE
                WHEN p_thread ? 'contacts' AND jsonb_typeof(p_thread -> 'contacts') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'contacts') elem), ARRAY[]::uuid[])
                WHEN p_defaults ? 'contacts' AND jsonb_typeof(p_defaults -> 'contacts') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'contacts') elem), ARRAY[]::uuid[])
                ELSE COALESCE(v_existing.contacts, ARRAY[]::uuid[])
            END,
            CASE
                WHEN p_thread ? 'topics' AND jsonb_typeof(p_thread -> 'topics') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'topics') elem), ARRAY[]::uuid[])
                WHEN p_defaults ? 'topics' AND jsonb_typeof(p_defaults -> 'topics') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'topics') elem), ARRAY[]::uuid[])
                ELSE COALESCE(v_existing.topics, ARRAY[]::uuid[])
            END,
            COALESCE((p_thread ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, v_existing.draft, FALSE),
            COALESCE(p_thread ->> 'key', p_defaults ->> 'key', v_existing.key),
            COALESCE(p_thread ->> 'icon', p_defaults ->> 'icon', v_existing.icon)
        )
    ON CONFLICT (id)
        DO UPDATE SET
            -- Update fields only if key is present in p_thread
            -- Key absent: keep existing value (unless archived, then use p_defaults)
            -- Key present (even with null): use provided value (allows clearing)
            -- If archived: treat as INSERT and apply p_defaults
            title = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'title', p_defaults ->> 'title', thread.title)
            ELSE
                CASE WHEN p_thread ? 'title' THEN
                    p_thread ->> 'title'
                ELSE
                    thread.title
                END
            END,
            preview = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'preview', p_defaults ->> 'preview', thread.preview)
            ELSE
                CASE WHEN p_thread ? 'preview' THEN
                    p_thread ->> 'preview'
                ELSE
                    thread.preview
                END
            END,
            updated_by = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, thread.updated_by)
            ELSE
                CASE WHEN p_thread ? 'updated_by' THEN
                    (p_thread ->> 'updated_by')::integer
                ELSE
                    thread.updated_by
                END
            END,
            sync_depth = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint, thread.sync_depth)
            ELSE
                CASE WHEN p_thread ? 'sync_depth' THEN
                    (p_thread ->> 'sync_depth')::smallint
                ELSE
                    thread.sync_depth
                END
            END,
            contacts = CASE WHEN v_is_archived THEN
                CASE WHEN p_thread ? 'contacts' AND jsonb_typeof(p_thread -> 'contacts') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'contacts') elem), ARRAY[]::uuid[])
                WHEN p_defaults ? 'contacts' AND jsonb_typeof(p_defaults -> 'contacts') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'contacts') elem), ARRAY[]::uuid[])
                ELSE thread.contacts END
            ELSE
                CASE WHEN p_thread ? 'contacts' AND jsonb_typeof(p_thread -> 'contacts') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'contacts') elem), ARRAY[]::uuid[])
                ELSE
                    thread.contacts
                END
            END,
            topics = CASE WHEN v_is_archived THEN
                CASE WHEN p_thread ? 'topics' AND jsonb_typeof(p_thread -> 'topics') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'topics') elem), ARRAY[]::uuid[])
                WHEN p_defaults ? 'topics' AND jsonb_typeof(p_defaults -> 'topics') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'topics') elem), ARRAY[]::uuid[])
                ELSE thread.topics END
            ELSE
                CASE WHEN p_thread ? 'topics' AND jsonb_typeof(p_thread -> 'topics') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'topics') elem), ARRAY[]::uuid[])
                ELSE
                    thread.topics
                END
            END,
            draft = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, thread.draft)
            ELSE
                CASE WHEN p_thread ? 'draft' THEN
                    (p_thread ->> 'draft')::boolean
                ELSE
                    thread.draft
                END
            END,
            icon = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'icon', p_defaults ->> 'icon', thread.icon)
            ELSE
                CASE WHEN p_thread ? 'icon' THEN
                    p_thread ->> 'icon'
                ELSE
                    thread.icon
                END
            END,
            archived_at = CASE WHEN v_is_archived THEN
                CASE WHEN p_thread ? 'archived_at' THEN
                    (p_thread ->> 'archived_at')::timestamptz
                WHEN p_defaults ? 'archived_at' THEN
                    (p_defaults ->> 'archived_at')::timestamptz
                ELSE
                    thread.archived_at
                END
            ELSE
                CASE WHEN p_thread ? 'archived_at' THEN
                    (p_thread ->> 'archived_at')::timestamptz
                ELSE
                    thread.archived_at
                END
            END,
            created_by = v_created_by
        RETURNING
            * INTO v_result;

    -- Upsert the calling user's thread_priority row. On update, only
    -- change priority_id if the caller explicitly provided one.
    INSERT INTO thread_priority (thread_id, user_id, priority_id)
    VALUES (v_result.id, upsert_thread.user_id, v_priority_id)
    ON CONFLICT ON CONSTRAINT thread_priority_pkey
    DO UPDATE SET
        priority_id = CASE
            WHEN p_thread ? 'priority_id' THEN EXCLUDED.priority_id
            WHEN v_is_archived THEN EXCLUDED.priority_id
            ELSE thread_priority.priority_id
        END,
        updated_at = now();

    -- Peer thread_priority rows are populated by the file_thread_priority_peers
    -- trigger on thread, so both upsert_thread callers and raw inserts from
    -- the twist runtime share the same filing behaviour.

    RETURN v_result;
END;
$$;
-- Create "link_x" view
CREATE VIEW "public"."link_x" (
  "id",
  "created_at",
  "updated_at",
  "thread_id",
  "source",
  "source_created_at",
  "source_priority_root",
  "author_id",
  "twist_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "title",
  "preview",
  "assignee_id",
  "type",
  "status",
  "actions",
  "meta",
  "source_url",
  "logo",
  "channel_id",
  "merged_from_thread_id",
  "priority_id",
  "priority_path"
) AS SELECT l.id,
    l.created_at,
    l.updated_at,
    l.thread_id,
    l.source,
    l.source_created_at,
    l.source_priority_root,
    l.author_id,
    l.twist_id,
    l.created_by,
    l.updated_by,
    l.sync_depth,
    l.title,
    l.preview,
    l.assignee_id,
    l.type,
    l.status,
    l.actions,
    l.meta,
    l.source_url,
    l.logo,
    l.channel_id,
    l.merged_from_thread_id,
    l.priority_id,
    pp.path AS priority_path
   FROM public.link l
     LEFT JOIN public.priority pp ON pp.id = l.priority_id;
-- Drop "find_similar_threads" function
DROP FUNCTION "public"."find_similar_threads";
-- Drop "refile_threads_like" function
DROP FUNCTION "public"."refile_threads_like";
-- Drop "undo_refile_batch" function
DROP FUNCTION "public"."undo_refile_batch";
