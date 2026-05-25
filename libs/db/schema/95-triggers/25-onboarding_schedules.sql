-- Automatic per-user thread_state seeding for global onboarding threads.
-- Fires when a user is linked to one of the global onboarding threads
-- (usually via joining the "Everyone" group).
--
-- Writes to thread_state with the action_type and importance that controls
-- both the activity-feed tab and the Catch up ordering. Per-user "do on this
-- date" intent is stored via thread_state."on".
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
        -- action_type partitions each thread into the Activity feed action tab:
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

        INSERT INTO public.thread_state (user_id, thread_id, action_type, importance, "order", "on")
        VALUES (
            NEW.user_id,
            NEW.thread_id,
            v_action,
            v_importance,
            v_order,
            CASE
                WHEN v_date_offset = 0 THEN daterange('1970-01-01', NULL)
                ELSE daterange((CURRENT_DATE + v_date_offset), NULL)
            END
        )
        ON CONFLICT (user_id, thread_id) DO NOTHING;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER file_onboarding_schedules
    AFTER INSERT ON public.thread_priority
    FOR EACH ROW
    EXECUTE FUNCTION public.file_onboarding_schedules ();
