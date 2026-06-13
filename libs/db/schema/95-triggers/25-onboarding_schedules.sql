-- Automatic per-user thread_state seeding for global onboarding threads.
-- Fires when a user is linked to one of the global onboarding threads
-- (usually via joining the "Everyone" group).
--
-- Writes to thread_state with the active flag and importance that control
-- both the unified feed section (Doing for active) and the Updates ordering.
-- Per-user "do on this date" intent is stored via thread_state."on".
CREATE OR REPLACE FUNCTION public.file_onboarding_schedules ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_thread_key text;
    v_date_offset integer;
    v_order integer;
    v_active boolean;
    v_importance smallint;
BEGIN
    -- Skip if explicitly requested (e.g. during repair migrations for existing users)
    IF current_setting('plot.skip_onboarding_schedules', true) = 'true' THEN
        RETURN NEW;
    END IF;

    SELECT key INTO v_thread_key FROM public.thread WHERE id = NEW.thread_id;

    -- ONBOARDING:BEGIN schedules
    IF v_thread_key IN ('welcome', 'getting-around') THEN
        CASE v_thread_key
            WHEN 'welcome' THEN v_date_offset := 0; v_order := 100; v_active := TRUE; v_importance := 95;
            WHEN 'getting-around' THEN v_date_offset := 0; v_order := 400; v_active := FALSE; v_importance := 80;
        END CASE;

        INSERT INTO public.thread_state (user_id, thread_id, active, importance, "order", "on")
        VALUES (NEW.user_id, NEW.thread_id, v_active, v_importance, v_order,
            CASE WHEN v_date_offset = 0 THEN daterange('1970-01-01', NULL)
                 ELSE daterange((CURRENT_DATE + v_date_offset), NULL) END)
        ON CONFLICT (user_id, thread_id) DO NOTHING;
    END IF;
-- ONBOARDING:END schedules

    RETURN NEW;
END;
$$;

CREATE TRIGGER file_onboarding_schedules
    AFTER INSERT ON public.thread_priority
    FOR EACH ROW
    EXECUTE FUNCTION public.file_onboarding_schedules ();
