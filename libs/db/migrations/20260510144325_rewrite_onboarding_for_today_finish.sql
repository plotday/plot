-- Rewrite onboarding thread copy for the Today/Scheduled/New/Done
-- workflow: rename "Add to agenda"/"Remove from agenda" → "Do today"/
-- "Finish", reframe Activity as four-section thread management with
-- drag-between-sections, and Agenda as the universal /agenda day view.
--
-- Data-only migration. Targets the system Plot twist's onboarding
-- threads by (key, twist_id) with defensive LIKE guards on the existing
-- copy from migrations 20260417205228 / 20260418053100 / 20260430155537
-- / 20260504021529, so re-running is a no-op once applied.

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
        -- Note 1: definitions of Priorities/Threads/Notes. Update only the
        -- Threads bullet so it matches the new Do today / Schedule / Finish
        -- vocabulary.
        UPDATE note
        SET content =
'Plot is your workspace for making progress on what matters most. **Priorities**, **Threads**, and **Notes** are the core building blocks of Plot:

- **Priorities**: The roles, goals, and projects in your life — the areas you direct your focus and energy toward. Examples include Work, Personal, Launch New Product, Team Leader, and Learn French.
- **Threads**: Everything related to something you work on, collected in one place. A thread can contain notes, messages to collaborators, links syncing with external items, and chats with twists. You move each thread through your day by tapping **Do today**, scheduling it for a future day, or marking it **Finish** when you''re done with your part.
- **Notes**: The content within threads. Notes can be personal notes, messages to others, or synced comments with connected apps. Individual notes can be marked as tasks and assigned to people.'
        WHERE thread_id = v_thread_id
          AND content LIKE '%Threads are the things you add to your agenda, schedule, and remove when done%';

        -- Note 2: rewrite the Add/Remove explainer around Do today / Finish
        -- and update the long-press tip to reference the renamed button.
        UPDATE note
        SET content =
'When a thread needs your attention, tap **Do today** at the start of the row — it could mean reading and thinking, or rolling up your sleeves to take action. You can also **Schedule** a thread for a specific day. Doing today and scheduling build your personal action plan; it''s not a shared project board, it''s your own list.

When you''re done with your part, tap **Finish**. This marks any of your tasks in the thread as done and completes linked items in connected apps — for example, closing a Linear ticket. You (and others) might do today and finish a thread multiple times as work progresses. There''s also a separate **Done** tag you can add to mark a thread as complete for good for everyone.

**Tip:** Long-press the Do today / Finish button (or right-click on desktop) to pick a different date or time instead of today.'
        WHERE thread_id = v_thread_id
          AND content LIKE '%Long-press on the add/remove button at the start of the thread row%';

        -- Note 3: replace the old Agenda-vs-Activity framing with the new
        -- model — Activity has four sections with drag-between-sections,
        -- and the universal Agenda lives at /agenda across all priorities.
        UPDATE note
        SET content =
'Each priority has an **Activity** view organized into four sections:

- **Today** — what you''re doing today, in the order you plan to handle it
- **Scheduled** — what you''ve scheduled for tomorrow, Friday, next week, etc., one section per day
- **New** — unread threads waiting for your attention
- **Done** — everything else, in reverse chronological order

Drag a thread between sections to move it: drop on Today to do it now, on a future day to schedule it ahead, on New to come back later, or on Done to finish. Within a section, drag to reorder.

The **Agenda** is your day across every priority — every block you''ve started or scheduled, sorted by time. Open it from the Agenda tile on the priorities list (or the bottom nav on mobile). Drag a priority block in the agenda to reorder your day or move it to a different time.

Drag a thread under an event in the Agenda to set an **event agenda** that''s shared with other invitees who are also using Plot. Event agendas carry forward across recurring meetings, so you can review progress next time.'
        WHERE thread_id = v_thread_id
          AND content LIKE '%The **Agenda** is everything you plan to work on, organized by priority%';
    END IF;

    -- 2. Getting Around — touch gestures + keyboard
    SELECT id INTO v_thread_id
    FROM thread
    WHERE key = 'getting-around' AND twist_id = v_plot_twist_id
    LIMIT 1;

    IF v_thread_id IS NOT NULL THEN
        -- Touch gestures: rename swipe-right + long-press-button bullets,
        -- add a new bullet for dragging threads between Activity sections.
        UPDATE note
        SET content =
'**Touch Gestures**

- **Long press** on items to open the menu
- **Swipe right** on threads: Do today (or Finish if already on today)
- **Swipe left** on threads: Schedule for later
- **Long press the Do today / Finish button** at the start of a thread row to schedule it for a specific date and time instead of today
- **Drag a thread between Activity sections** — drop on Today to do it now, on a future-day section to schedule it ahead, on New to mark it unread, or on Done to finish
- **Tap a thread''s icon** to edit its title, icon, or priority — **long press the icon** to jump straight to moving it to another priority
- **Drag a priority header** in the agenda to reorder priorities or move the whole block (with its threads) to another time or day; **drag a thread under an event** to add it to that event''s shared agenda
- **Share** a link from another app to Plot using the share sheet (iOS and Android)'
        WHERE thread_id = v_thread_id
          AND content LIKE '%Swipe right** on threads: Add to agenda%';

        -- Keyboard nav: soften the ⌘⇧A bullet so it doesn''t describe the
        -- legacy two-tab toggle. The priority page is single-pane Activity
        -- now and the Agenda lives at its own route.
        UPDATE note
        SET content =
'**Keyboard Navigation**

- **⌘/** (Ctrl+/ on Windows): Search across all your threads and priorities
- **⌘K** (Ctrl+K on Windows): Open the command palette for quick actions
- **Up/Down arrows**: Select a note within a thread, then ⌘K (Ctrl+K) to open commands for that note
- **⌘⇧A** (Ctrl+Shift+A on Windows): Focus the current list — the Activity feed on a priority, or the universal Agenda
- **⌘Up/Down** (Ctrl+Up/Down on Windows): Open previous/next thread
- **⌘T** (Ctrl+T on Windows): Make the focused note a task (or mark done)
- **⌘⇧T** (Ctrl+Shift+T on Windows): Assign the focused note
- **⌘D** (Ctrl+D on Windows): Mark done / not done
- **⌘⇧D** (Ctrl+Shift+D on Windows): Schedule thread
- **⌘Delete** (Ctrl+Backspace on Windows): Archive thread
- **⌘N** (Ctrl+N on Windows): Create a new thread (⌘⌥N / Ctrl+Alt+N on web browsers)
- **⌘Enter** (Ctrl+Enter on Windows): On the new thread page, create a task instead of a note'
        WHERE thread_id = v_thread_id
          AND content LIKE '%Focus the agenda or activity list; press again to switch between them%';
    END IF;

    -- 3. Clean up without losing anything — preview + first note
    SELECT id INTO v_thread_id
    FROM thread
    WHERE key = 'clean-up' AND twist_id = v_plot_twist_id
    LIMIT 1;

    IF v_thread_id IS NOT NULL THEN
        UPDATE thread
        SET preview =
'Archive removes mistakes and hides priorities you''re no longer working in. To finish a thread, tap **Finish** instead.'
        WHERE id = v_thread_id
          AND preview LIKE '%To finish a thread, **Remove it from your agenda** instead%';

        UPDATE note
        SET content =
'**Archive a thread** when it shouldn''t have been created — a duplicate, a stray, or a mistake. Archive isn''t how you mark work done: when you''ve finished your part, tap **Finish** instead. That keeps the thread in Activity for everyone and completes your tasks plus any linked items in connected apps.

**Archive a priority** when you''re no longer working in that area. The priority and everything inside it disappears from your main view.

Archive hides items everywhere — for you and anyone you share with. Nothing is deleted; you can bring items back anytime.'
        WHERE thread_id = v_thread_id
          AND content LIKE '%when you''ve finished your part, **Remove it from your agenda** instead%';
    END IF;
END $$;
