-- Update onboarding touch-gesture copy for the unified mobile gesture
-- model: long-press is now the universal reorder-drag trigger (no menu
-- on row long-press), and swipes carry both short and long commands in
-- each direction. Right swipes are time-management (Do today / Schedule);
-- left swipes are completion + menu (Finish / Menu).
--
-- Mirrors the in-app behavior shipped alongside this migration.
--
-- Data-only migration. Targets the system Plot twist's "Getting Around"
-- onboarding thread by (key, twist_id) with a defensive LIKE guard on
-- the existing copy from migration 20260510144325 so re-running is a
-- no-op once applied.

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

    -- Getting Around — Touch Gestures section. Rewrite to describe the
    -- new universal gesture model. Long-press is no longer the menu
    -- trigger; menus now open via a long left swipe, and short swipes
    -- in each direction carry the quick action.
    SELECT id INTO v_thread_id
    FROM thread
    WHERE key = 'getting-around' AND twist_id = v_plot_twist_id
    LIMIT 1;

    IF v_thread_id IS NOT NULL THEN
        UPDATE note
        SET content =
'**Touch Gestures**

- **Swipe right** on a thread: short swipe to **Do today**, long swipe to **Schedule** for another day
- **Swipe left** on a thread: short swipe to **Finish** (when scheduled), long swipe to open the thread **menu**
- **Long press** a thread, priority, or agenda block to drag and reorder
- **Drag a thread between Activity sections** — drop on Today to do it now, on a future-day section to schedule it ahead, on New to mark it unread, or on Done to finish
- **Long press the Do today / Finish button** at the start of a thread row to schedule it for a specific date and time instead of today
- **Tap a thread''s icon** to edit its title, icon, or priority
- **Drag a priority header** in the agenda to reorder priorities or move the whole block (with its threads) to another time or day; **drag a thread under an event** to add it to that event''s shared agenda
- **Share** a link from another app to Plot using the share sheet (iOS and Android)'
        WHERE thread_id = v_thread_id
          AND content LIKE '%Long press** on items to open the menu%';
    END IF;
END $$;
