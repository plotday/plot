-- Update onboarding thread copy to match the in-app rename: the activity
-- feed section "Today" is now "Doing", and the button that puts a thread
-- on it is "To do" instead of "Do today". "Finish" is unchanged.
--
-- Data-only migration. Targets the system Plot twist's onboarding threads
-- by (key, twist_id) with defensive LIKE guards on the prior copy from
-- migrations 20260510144325 / 20260511232411, so re-running is a no-op
-- once applied.

DO $$
DECLARE
    c_twist_package_id CONSTANT uuid := '0199b6f4-ae64-7718-8a02-44716f30358f';
    v_plot_twist_id bigint;
    v_thread_id uuid;
BEGIN
    SELECT id INTO v_plot_twist_id
    FROM twist
    WHERE twist_package_id = c_twist_package_id
      AND environment = 'public'
    LIMIT 1;

    IF v_plot_twist_id IS NULL THEN
        RETURN;
    END IF;

    -- 1. Welcome to Plot! — three notes
    SELECT id INTO v_thread_id
    FROM thread
    WHERE key = 'welcome' AND twist_id = v_plot_twist_id
    LIMIT 1;

    IF v_thread_id IS NOT NULL THEN
        -- Note 1: definitions block — update only the Threads bullet so it
        -- references the renamed button ("To do" instead of "Do today").
        UPDATE note
        SET content =
'Plot is your workspace for making progress on what matters most. **Priorities**, **Threads**, and **Notes** are the core building blocks of Plot:

- **Priorities**: The roles, goals, and projects in your life — the areas you direct your focus and energy toward. Examples include Work, Personal, Launch New Product, Team Leader, and Learn French.
- **Threads**: Everything related to something you work on, collected in one place. A thread can contain notes, messages to collaborators, links syncing with external items, and chats with twists. You move each thread through your day by tapping **To do**, scheduling it for a future day, or marking it **Finish** when you''re done with your part.
- **Notes**: The content within threads. Notes can be personal notes, messages to others, or synced comments with connected apps. Individual notes can be marked as tasks and assigned to people.'
        WHERE thread_id = v_thread_id
          AND content LIKE '%tapping **Do today**, scheduling it for a future day%';

        -- Note 2: To do / Schedule / Finish explainer.
        UPDATE note
        SET content =
'When a thread needs your attention, tap **To do** at the start of the row — it could mean reading and thinking, or rolling up your sleeves to take action. You can also **Schedule** a thread for a specific day. Doing and scheduling build your personal action plan; it''s not a shared project board, it''s your own list.

When you''re done with your part, tap **Finish**. This marks any of your tasks in the thread as done and completes linked items in connected apps — for example, closing a Linear ticket. You (and others) might pick a thread back up and finish it multiple times as work progresses. There''s also a separate **Done** tag you can add to mark a thread as complete for good for everyone.

**Tip:** Long-press the To do / Finish button (or right-click on desktop) to pick a different date or time instead of today.'
        WHERE thread_id = v_thread_id
          AND content LIKE '%Long-press the Do today / Finish button%';

        -- Note 3: Activity sections — rename "Today" to "Doing" in the
        -- section list and in the drag-between-sections instructions.
        UPDATE note
        SET content =
'Each priority has an **Activity** view organized into four sections:

- **Doing** — what you''re working on now, in the order you plan to handle it
- **Scheduled** — what you''ve scheduled for tomorrow, Friday, next week, etc., one section per day
- **New** — unread threads waiting for your attention
- **Done** — everything else, in reverse chronological order

Drag a thread between sections to move it: drop on Doing to start it now, on a future day to schedule it ahead, on New to come back later, or on Done to finish. Within a section, drag to reorder.

The **Agenda** is your day across every priority — every block you''ve started or scheduled, sorted by time. Open it from the Agenda tile on the priorities list (or the bottom nav on mobile). Drag a priority block in the agenda to reorder your day or move it to a different time.

Drag a thread under an event in the Agenda to set an **event agenda** that''s shared with other invitees who are also using Plot. Event agendas carry forward across recurring meetings, so you can review progress next time.'
        WHERE thread_id = v_thread_id
          AND content LIKE '%**Today** — what you''re doing today%';
    END IF;

    -- 2. Getting Around — touch gestures
    SELECT id INTO v_thread_id
    FROM thread
    WHERE key = 'getting-around' AND twist_id = v_plot_twist_id
    LIMIT 1;

    IF v_thread_id IS NOT NULL THEN
        UPDATE note
        SET content =
'**Touch Gestures**

- **Swipe right** on a thread: short swipe to **To do**, long swipe to **Schedule** for another day
- **Swipe left** on a thread: short swipe to **Finish** (when scheduled), long swipe to open the thread **menu**
- **Long press** a thread, priority, or agenda block to drag and reorder
- **Drag a thread between Activity sections** — drop on Doing to start now, on a future-day section to schedule it ahead, on New to mark it unread, or on Done to finish
- **Long press the To do / Finish button** at the start of a thread row to schedule it for a specific date and time instead of today
- **Tap a thread''s icon** to edit its title, icon, or priority
- **Drag a priority header** in the agenda to reorder priorities or move the whole block (with its threads) to another time or day; **drag a thread under an event** to add it to that event''s shared agenda
- **Share** a link from another app to Plot using the share sheet (iOS and Android)'
        WHERE thread_id = v_thread_id
          AND content LIKE '%short swipe to **Do today**%';
    END IF;
END $$;
