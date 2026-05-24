-- Automatic scheduling for global onboarding threads.
-- Fires when a user is linked to one of the global onboarding threads
-- (usually via joining the "Everyone" group).
--
-- Also seeds the per-user thread_unread row with a custom importance so the
-- onboarding sequence sorts top-down in the Catch up tab starting with the
-- per-user "Welcome to Plot!" thread (handled in activate_invited_user) and
-- continuing through the global set in their natural reading order. The
-- file_thread_priority_on_group_member_change trigger that fires next does a
-- bulk thread_unread insert with ON CONFLICT DO NOTHING, so the importance
-- we seed here wins.
CREATE OR REPLACE FUNCTION public.file_onboarding_schedules ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_thread_key text;
    v_date_offset integer;
    v_order integer;
    v_action text;
    v_importance smallint;
BEGIN
    -- Skip if explicitly requested (e.g. during repair migrations for existing users)
    IF current_setting('plot.skip_onboarding_schedules', true) = 'true' THEN
        RETURN NEW;
    END IF;

    SELECT key INTO v_thread_key FROM public.thread WHERE id = NEW.thread_id;

    IF v_thread_key IN ('welcome', 'priorities', 'connections', 'getting-around', 'invest-your-time', 'twists', 'notifications', 'clean-up') THEN
        -- action partitions each thread into the Activity feed action tab:
        --   'do'   — threads that ask the user to take a concrete action
        --            (matches the keys handled by file_onboarding_todos).
        --   'read' — informational threads with no actionable todo.
        -- importance controls Catch up ordering (higher = nearer the top).
        -- Values descend in the natural reading order; 'welcome-user'
        -- (importance 100, handled in activate_invited_user) sits above
        -- the global 'welcome' here.
        CASE v_thread_key
            WHEN 'welcome'           THEN v_date_offset := 0; v_order := 100; v_action := 'read'; v_importance := 95;
            WHEN 'priorities'        THEN v_date_offset := 0; v_order := 200; v_action := 'do';   v_importance := 90;
            WHEN 'connections'       THEN v_date_offset := 0; v_order := 300; v_action := 'do';   v_importance := 85;
            WHEN 'getting-around'    THEN v_date_offset := 0; v_order := 400; v_action := 'read'; v_importance := 80;
            WHEN 'invest-your-time'  THEN v_date_offset := 1; v_order := 50;  v_action := 'read'; v_importance := 75;
            WHEN 'twists'            THEN v_date_offset := 1; v_order := 100; v_action := 'do';   v_importance := 70;
            WHEN 'notifications'     THEN v_date_offset := 2; v_order := 100; v_action := 'do';   v_importance := 65;
            WHEN 'clean-up'          THEN v_date_offset := 3; v_order := 100; v_action := 'read'; v_importance := 60;
        END CASE;

        IF v_date_offset = 0 THEN
            -- "Started" status (epoch sentinel)
            INSERT INTO public.schedule (thread_id, user_id, "order", reason, action, "on")
            VALUES (NEW.thread_id, NEW.user_id, v_order, 'add', v_action, daterange('1970-01-01', NULL))
            ON CONFLICT (thread_id, user_id) WHERE user_id IS NOT NULL AND occurrence IS NULL DO NOTHING;
        ELSE
            -- Scheduled for a future date relative to join time
            INSERT INTO public.schedule (thread_id, user_id, "order", reason, action, "on")
            VALUES (NEW.thread_id, NEW.user_id, v_order, 'add', v_action, daterange((CURRENT_DATE + v_date_offset), NULL))
            ON CONFLICT (thread_id, user_id) WHERE user_id IS NOT NULL AND occurrence IS NULL DO NOTHING;
        END IF;

        -- Pre-seed the unread row with the desired importance. The bulk
        -- insert in file_thread_priority_on_group_member_change runs after
        -- this per-row trigger and uses ON CONFLICT DO NOTHING, so this
        -- value wins for onboarding threads while non-onboarding threads
        -- keep the default importance of 50.
        INSERT INTO public.thread_unread (user_id, thread_id, urgency, importance)
        VALUES (NEW.user_id, NEW.thread_id, 'inform-updates', v_importance)
        ON CONFLICT (user_id, thread_id) DO NOTHING;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER file_onboarding_schedules
    AFTER INSERT ON public.thread_priority
    FOR EACH ROW
    EXECUTE FUNCTION public.file_onboarding_schedules ();
