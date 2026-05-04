-- Document four user-facing gestures in the global onboarding threads:
--   1. Long-press the leading add/remove button on a thread row to schedule
--      the thread to a specific date/time (instead of adding it to today).
--   2. Tap a thread's icon to edit (title/icon/priority); long-press the
--      icon to jump straight to moving it to another priority.
--   3. Drag a priority header in the agenda to reorder priorities or move
--      the whole block (with its threads) to another time or day.
--   4. Drag a thread under an event to set a shared event agenda that's
--      visible to other Plot-using invitees and carried forward across
--      recurring meetings.
--
-- Data-only migration. Targets the `welcome` and `getting-around` threads
-- on the system Plot twist by key + twist_id, and matches existing copy
-- defensively with LIKE guards so re-running is a no-op once applied
-- (mirrors 20260417205228, 20260418153225, 20260430155537).

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
        -- Edit 1: append a long-press scheduling tip to the "Add to agenda"
        -- explainer note. Targets the note that ends with the existing
        -- "Remove it from your agenda" copy from migration 20260417205228.
        UPDATE note
        SET content =
'When a thread needs your attention, you **Add it to your agenda** — it could be as simple as reading and thinking, or it could mean taking action. You can also **Schedule** a thread to choose when you want to act on it. Adding and scheduling build your personal agenda — it''s not a shared project board, it''s your own action plan.

When you''re done with your part, you **Remove it from your agenda**. This marks any of your tasks in the thread as done and completes linked items in connected apps — for example, closing a Linear ticket. You (and others) might add and remove a thread from your agenda multiple times as work progresses. There''s also a separate **Done** tag you can add to mark a thread as complete for good for everyone.

**Tip:** Long-press on the add/remove button at the start of the thread row (or right-click on desktop) to pick a date and time instead of adding it to today.'
        WHERE thread_id = v_thread_id
          AND content LIKE '%When a thread needs your attention, you **Add it to your agenda**%'
          AND content NOT LIKE '%Long-press on the add/remove button%';

        -- Edit 2: replace the agenda explainer note. Tightens the agenda
        -- paragraph, keeps the activity paragraph, and replaces the old
        -- "useful pattern" calendar sentence with a fuller event-agenda
        -- explainer.
        UPDATE note
        SET content =
'The **Agenda** is everything you plan to work on, organized by priority. You can reorder threads within a priority and also reorder priorities. Threads and priorities can also be dragged to new days and times.

The **Activity** view shows what''s happening across your priorities — new threads, updates, and unread items. From Activity, you can **Add to agenda** (act on it now) or **Schedule** (act on it later).

Drag threads under an event to set an **event agenda** that''s shared with other invitees who are also using Plot. You can re-add or schedule these threads at other times, too, if you need to work on them before or after the meeting. Event agendas are carried forward for recurring meetings, making it easy to review progress next time.'
        WHERE thread_id = v_thread_id
          AND content LIKE '%You can reorder items freely, move them to a different time or date%';
    END IF;

    -- Getting Around
    SELECT id INTO v_thread_id
    FROM thread
    WHERE key = 'getting-around' AND twist_id = v_plot_twist_id
    LIMIT 1;

    IF v_thread_id IS NOT NULL THEN
        -- Edit 3: extend the touch-gestures bullet list with the three new
        -- gestures (long-press add/remove, tap/long-press thread icon, drag
        -- priority header / drag thread under event).
        UPDATE note
        SET content =
'**Touch Gestures**

- **Long press** on items to open the menu
- **Swipe right** on threads: Add to agenda (or Remove from agenda if already added)
- **Swipe left** on threads: Schedule for later
- **Long press the add/remove button** at the start of a thread row to schedule it for a specific date and time instead of adding it to today
- **Tap a thread''s icon** to edit its title, icon, or priority — **long press the icon** to jump straight to moving it to another priority
- **Drag a priority header** in the agenda to reorder priorities or move the whole block (with its threads) to another time or day; **drag a thread under an event** to add it to that event''s shared agenda
- **Share** a link from another app to Plot using the share sheet (iOS and Android)'
        WHERE thread_id = v_thread_id
          AND content LIKE '%Swipe right** on threads: Add to agenda%'
          AND content NOT LIKE '%Long press the add/remove button%';
    END IF;
END $$;
