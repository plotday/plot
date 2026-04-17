-- Update onboarding thread copy to reflect the renamed Start/Finish
-- commands, now called "Add to agenda" and "Remove from agenda".
--
-- Data-only migration: targets notes on the system Plot twist's onboarding
-- threads (keyed by thread.key) and rewrites the note content. Matches the
-- old copy defensively so re-running is a no-op once applied.

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

    -- Welcome to Plot!
    SELECT id INTO v_thread_id
    FROM thread
    WHERE key = 'welcome' AND twist_id = v_plot_twist_id
    LIMIT 1;

    IF v_thread_id IS NOT NULL THEN
        UPDATE note
        SET content =
'Plot is your workspace for making progress on what matters most. **Priorities**, **Threads**, and **Notes** are the core building blocks of Plot:

- **Priorities**: The roles, goals, and projects in your life — the areas you direct your focus and energy toward. Examples include Work, Personal, Launch New Product, Team Leader, and Learn French.
- **Threads**: Everything related to something you work on, collected in one place. A thread can contain notes, messages to collaborators, links syncing with external items, and chats with twists. Threads are the things you add to your agenda, schedule, and remove when done.
- **Notes**: The content within threads. Notes can be personal notes, messages to others, or synced comments with connected apps. Individual notes can be marked as tasks and assigned to people.'
        WHERE thread_id = v_thread_id
          AND content LIKE '%Threads are the core thing you Start, Schedule, and Finish%';

        UPDATE note
        SET content =
'When a thread needs your attention, you **Add it to your agenda** — it could be as simple as reading and thinking, or it could mean taking action. You can also **Schedule** a thread to choose when you want to act on it. Adding and scheduling build your personal agenda — it''s not a shared project board, it''s your own action plan.

When you''re done with your part, you **Remove it from your agenda**. This marks any of your tasks in the thread as done and completes linked items in connected apps — for example, closing a Linear ticket. You (and others) might add and remove a thread from your agenda multiple times as work progresses. There''s also a separate **Done** tag you can add to mark a thread as complete for good for everyone.'
        WHERE thread_id = v_thread_id
          AND content LIKE '%When a thread needs your attention, you **Start** it%';

        UPDATE note
        SET content =
'The **Agenda** is everything you plan to work on — threads you''ve added to your agenda and scheduled, arranged in your preferred order. You can reorder items freely, move them to a different time or date, or remove them without losing the thread.

The **Activity** view shows what''s happening across your priorities — new threads, updates, and unread items. From Activity, you can **Add to agenda** (act on it now) or **Schedule** (act on it later).

A useful pattern: when a meeting or event appears in Activity from a calendar connection, tap **Add to agenda** to create a planning slot — useful for blocking time to prepare or to follow up afterward.'
        WHERE thread_id = v_thread_id
          AND content LIKE '%by Starting (act on it now) or Scheduling%';
    END IF;

    -- Getting Around
    SELECT id INTO v_thread_id
    FROM thread
    WHERE key = 'getting-around' AND twist_id = v_plot_twist_id
    LIMIT 1;

    IF v_thread_id IS NOT NULL THEN
        UPDATE note
        SET content =
'**Touch Gestures**

- **Long press** on items to open the menu
- **Swipe right** on threads: Add to agenda (or Remove from agenda if already added)
- **Swipe left** on threads: Schedule for later
- **Share** a link from another app to Plot using the share sheet (iOS and Android)'
        WHERE thread_id = v_thread_id
          AND content LIKE '%Swipe right** on threads: Start (or Finish if already started)%';
    END IF;
END $$;
