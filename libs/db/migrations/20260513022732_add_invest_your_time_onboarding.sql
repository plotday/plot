-- Add a new global onboarding thread "Invest your time" that teaches the
-- agenda time-investment workflow: ordering priorities, adjusting block
-- durations, dragging into gaps, using the timer, and reviewing logged
-- time in the per-priority time tracking modal.
--
-- Slotted on day +1 alongside "Explore Twists" with order 50 so it sits
-- ahead of twists in the next-day onboarding queue, after the day-zero
-- intros (welcome / priorities / connections / getting-around) have
-- established the basics.
--
-- Mirrors the pattern in 20260417010000_ensure_everyone_group_and_onboarding_filing:
-- thread is owned by the system Plot twist instance, filed via the
-- Everyone group, and backfilled into thread_priority / thread_unread /
-- schedule for every existing Everyone member. The
-- file_onboarding_schedules trigger function is also updated so future
-- users (joining Everyone after this migration) get the same schedule
-- row.

DO $$
DECLARE
    c_system_instance_id CONSTANT uuid := '0199b6f4-ae64-7718-0000-000000000001';
    c_twist_package_id   CONSTANT uuid := '0199b6f4-ae64-7718-8a02-44716f30358f';
    v_plot_twist_id bigint;
    v_everyone_id   uuid;
    v_icon          text;
    v_thread_id     uuid;
BEGIN
    SELECT id INTO v_plot_twist_id
    FROM twist
    WHERE twist_package_id = c_twist_package_id
      AND environment = 'public'
    LIMIT 1;

    SELECT id INTO v_everyone_id
    FROM "group"
    WHERE auto_maintained = TRUE
      AND team_id IS NULL
      AND auto_publisher_id IS NULL
      AND auto_team_admin_team_id IS NULL
      AND name = 'Everyone'
    LIMIT 1;

    -- Bail on ephemeral databases that haven't bootstrapped the Plot
    -- twist or Everyone group yet — the seed step will recreate them.
    IF v_plot_twist_id IS NULL OR v_everyone_id IS NULL THEN
        RETURN;
    END IF;

    v_icon := 'twist:' || v_plot_twist_id::text;

    -- 1. Create the thread if it doesn't already exist.
    SELECT id INTO v_thread_id
    FROM thread
    WHERE key = 'invest-your-time' AND twist_id = v_plot_twist_id
    LIMIT 1;

    IF v_thread_id IS NULL THEN
        INSERT INTO thread (created_by, title, preview, key, twist_id, icon, topic, groups)
        VALUES (c_system_instance_id,
                'Invest your time',
                'Plan your day across your priorities — order them, give each a duration, run a timer, and review the time you logged.',
                'invest-your-time',
                v_plot_twist_id,
                v_icon,
                v_everyone_id::text,
                ARRAY[v_everyone_id])
        RETURNING id INTO v_thread_id;

        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (0 * interval '1 minute'),
'Priorities are where you direct your energy — investing time into them is how progress actually happens. Plot''s **Agenda** is the place to shape that investment for the day: order the priorities you''ll work on, give each one a duration, slot them around the events on your calendar, and run a timer when you''re ready to dig in.');

        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (1 * interval '1 minute'),
'**Plan the day in the Agenda**

Open the Agenda from the priorities list (or the bottom nav on mobile). It lists every priority you''ve started or scheduled for today, top to bottom, alongside any calendar events.

- **Reorder** by dragging a priority header up or down — long press on touch, click and drag with a mouse.
- **Set a duration** for each priority block. On hover, the **+** and **−** buttons next to the block bump it by 15 minutes; on touch, short-swipe right on the header to add 15 minutes or left to remove 15.
- **Drop into a gap** between events by dragging the block where you want it. The block slots in around your meetings, so a 30-minute focus session can land between two calls instead of fighting for the same time.');

        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (2 * interval '1 minute'),
'**Run a timer**

When you''re ready to work on a priority, focus it and **Start timer**. The countdown defaults to the duration on that priority''s agenda block (or 25 minutes if none is set).

- **Add time** bumps the timer up to the next 15-minute boundary — press it again to keep going.
- **Remove time** shrinks the countdown by 15 minutes when you want to wrap up sooner.
- **Switch priorities** by navigating to a different one — Plot automatically closes the active session and starts a fresh short one on the new priority. Press **Add time** there to promote it to a full session.');

        INSERT INTO note (author_id, created_by, thread_id, source_created_at, content)
        VALUES (c_system_instance_id, c_system_instance_id, v_thread_id, now() + (3 * interval '1 minute'),
'**Review the time you logged**

Every priority shows the time you''ve invested this week as a small chip on the right side of its row in the priorities list. Tap the chip to open the **time tracking** modal, which breaks the total down by week and by day, with separate columns for time logged directly on the priority and the rolled-up total including all its child priorities.

The per-day "Just this priority" values are **editable** — tap a cell to bump it up or down. Use it to log offline work, fix a session you forgot to start, or trim time that shouldn''t have counted.');
    END IF;

    -- 2. File thread_priority + thread_unread for every existing Everyone
    --    member. New users joining Everyone after this migration get filed
    --    automatically by file_thread_priority_on_group_member_change.
    INSERT INTO thread_priority (thread_id, user_id, priority_id)
    SELECT v_thread_id,
           uc.user_id,
           public.classify_thread_for_user(uc.user_id, v_thread_id)
    FROM group_member gm
    JOIN user_contact uc
      ON uc.contact_id = gm.contact_id
     AND uc.linked = TRUE
     AND uc.archived_at IS NULL
    WHERE gm.group_id = v_everyone_id
      AND public.classify_thread_for_user(uc.user_id, v_thread_id) IS NOT NULL
    ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;

    INSERT INTO thread_unread (user_id, thread_id, urgency, importance)
    SELECT uc.user_id, v_thread_id, 'inform-updates', 50
    FROM group_member gm
    JOIN user_contact uc
      ON uc.contact_id = gm.contact_id
     AND uc.linked = TRUE
     AND uc.archived_at IS NULL
    WHERE gm.group_id = v_everyone_id
    ON CONFLICT (user_id, thread_id) DO NOTHING;

    -- 3. Backfill schedule rows for existing users. The
    --    file_onboarding_schedules trigger only fires on thread_priority
    --    INSERT and was just updated below to recognize the new key, but
    --    the thread_priority inserts above already fired with the old
    --    function definition — so we file the schedules explicitly here
    --    to match what the new trigger would produce (day +1, order 50).
    INSERT INTO public.schedule (thread_id, user_id, "order", reason, "on")
    SELECT v_thread_id, tp.user_id, 50, 'add', daterange((CURRENT_DATE + 1), NULL)
    FROM thread_priority tp
    WHERE tp.thread_id = v_thread_id
      AND tp.user_id IS NOT NULL
    ON CONFLICT (thread_id, user_id) WHERE user_id IS NOT NULL AND occurrence IS NULL DO NOTHING;
END $$;

-- Extend file_onboarding_schedules so users joining Everyone in the
-- future receive a schedule row for 'invest-your-time' too. Kept in
-- lockstep with libs/db/schema/95-triggers/25-onboarding_schedules.sql.
CREATE OR REPLACE FUNCTION public.file_onboarding_schedules ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_thread_key text;
    v_date_offset integer;
    v_order integer;
BEGIN
    IF current_setting('plot.skip_onboarding_schedules', true) = 'true' THEN
        RETURN NEW;
    END IF;

    SELECT key INTO v_thread_key FROM public.thread WHERE id = NEW.thread_id;

    IF v_thread_key IN ('welcome', 'priorities', 'connections', 'getting-around', 'invest-your-time', 'twists', 'notifications', 'clean-up') THEN
        CASE v_thread_key
            WHEN 'welcome'           THEN v_date_offset := 0; v_order := 100;
            WHEN 'priorities'        THEN v_date_offset := 0; v_order := 200;
            WHEN 'connections'       THEN v_date_offset := 0; v_order := 300;
            WHEN 'getting-around'    THEN v_date_offset := 0; v_order := 400;
            WHEN 'invest-your-time'  THEN v_date_offset := 1; v_order := 50;
            WHEN 'twists'            THEN v_date_offset := 1; v_order := 100;
            WHEN 'notifications'     THEN v_date_offset := 2; v_order := 100;
            WHEN 'clean-up'          THEN v_date_offset := 3; v_order := 100;
        END CASE;

        IF v_date_offset = 0 THEN
            INSERT INTO public.schedule (thread_id, user_id, "order", reason, "on")
            VALUES (NEW.thread_id, NEW.user_id, v_order, 'add', daterange('1970-01-01', NULL))
            ON CONFLICT (thread_id, user_id) WHERE user_id IS NOT NULL AND occurrence IS NULL DO NOTHING;
        ELSE
            INSERT INTO public.schedule (thread_id, user_id, "order", reason, "on")
            VALUES (NEW.thread_id, NEW.user_id, v_order, 'add', daterange((CURRENT_DATE + v_date_offset), NULL))
            ON CONFLICT (thread_id, user_id) WHERE user_id IS NOT NULL AND occurrence IS NULL DO NOTHING;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;
