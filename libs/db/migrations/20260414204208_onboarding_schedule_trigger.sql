-- Create "file_onboarding_schedules" function
CREATE FUNCTION "public"."file_onboarding_schedules" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_thread_key text;
    v_date_offset integer;
    v_order integer;
BEGIN
    -- Skip if explicitly requested (e.g. during repair migrations for existing users)
    IF current_setting('plot.skip_onboarding_schedules', true) = 'true' THEN
        RETURN NEW;
    END IF;

    SELECT key INTO v_thread_key FROM public.thread WHERE id = NEW.thread_id;

    IF v_thread_key IN ('welcome', 'priorities', 'connections', 'getting-around', 'twists', 'notifications', 'clean-up') THEN
        CASE v_thread_key
            WHEN 'welcome'        THEN v_date_offset := 0; v_order := 100;
            WHEN 'priorities'     THEN v_date_offset := 0; v_order := 200;
            WHEN 'connections'    THEN v_date_offset := 0; v_order := 300;
            WHEN 'getting-around' THEN v_date_offset := 0; v_order := 400;
            WHEN 'twists'         THEN v_date_offset := 1; v_order := 100;
            WHEN 'notifications'  THEN v_date_offset := 2; v_order := 100;
            WHEN 'clean-up'       THEN v_date_offset := 3; v_order := 100;
        END CASE;

        IF v_date_offset = 0 THEN
            -- "Started" status (epoch sentinel)
            INSERT INTO public.schedule (thread_id, user_id, "order", reason, "on")
            VALUES (NEW.thread_id, NEW.user_id, v_order, 'add', daterange('1970-01-01', NULL))
            ON CONFLICT (thread_id, user_id) WHERE user_id IS NOT NULL AND occurrence IS NULL DO NOTHING;
        ELSE
            -- Scheduled for a future date relative to join time
            INSERT INTO public.schedule (thread_id, user_id, "order", reason, "on")
            VALUES (NEW.thread_id, NEW.user_id, v_order, 'add', daterange((CURRENT_DATE + v_date_offset), NULL))
            ON CONFLICT (thread_id, user_id) WHERE user_id IS NOT NULL AND occurrence IS NULL DO NOTHING;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;
-- Create trigger "file_onboarding_schedules"
CREATE TRIGGER "file_onboarding_schedules" AFTER INSERT ON "public"."thread_priority" FOR EACH ROW EXECUTE FUNCTION "public"."file_onboarding_schedules"();
