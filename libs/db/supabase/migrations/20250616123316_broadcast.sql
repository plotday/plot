SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.notify_user_for_account ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
BEGIN
    PERFORM
        realtime.send (jsonb_build_object('table', 'account'), -- JSONB Payload
            'sync', -- Event name
            'user:' || OLD.user_id::text, -- Topic
            FALSE -- Public / Private flag
);
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_user_for_activity ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
BEGIN
    PERFORM
        realtime.send (jsonb_build_object('table', 'activity'), -- JSONB Payload
            'sync', -- Event name
            'user:' || OLD.created_by::text, -- Topic
            FALSE -- Public / Private flag
);
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_user_for_calendar ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
BEGIN
    PERFORM
        realtime.send (jsonb_build_object('table', 'calendar'), -- JSONB Payload
            'sync', -- Event name
            'user:' || (
                SELECT
                    user_id
                FROM account
                WHERE
                    id = OLD.account_id)::text, -- Topic
            FALSE -- Public / Private flag
);
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_user_for_event ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
BEGIN
    PERFORM
        realtime.send (jsonb_build_object('table', 'event'), -- JSONB Payload
            'sync', -- Event name
            'user:' || OLD.user_id::text, -- Topic
            FALSE -- Public / Private flag
);
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_user_for_priority ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
BEGIN
    PERFORM
        realtime.send (jsonb_build_object('table', 'priority'), -- JSONB Payload
            'sync', -- Event name
            'user:' || OLD.created_by::text, -- Topic
            FALSE -- Public / Private flag
);
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_user_for_session ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
BEGIN
    PERFORM
        realtime.send (jsonb_build_object('table', 'session'), -- JSONB Payload
            'sync', -- Event name
            'user:' || OLD.user_id::text, -- Topic
            FALSE -- Public / Private flag
);
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.redeem_invitation (_user_id bigint, _invitation text)
    RETURNS void
    LANGUAGE plpgsql
    AS $function$
BEGIN
    UPDATE
        "invitation"
    SET
        remaining = remaining - 1
    WHERE
        code = _invitation
        AND remaining > 0;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invitation code % not valid', _invitation;
    END IF;
    BEGIN
        UPDATE
            public.user
        SET
            invitation = _invitation,
            activated_at = now()
        WHERE
            id = _user_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'User % not found', _user_id;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            UPDATE
                "invitation"
            SET
                remaining = remaining + 1
            WHERE
                code = _invitation;
                RAISE;
    END;
END;

$function$;

CREATE TRIGGER handle_account_changes
    AFTER INSERT OR UPDATE ON public.account
    FOR EACH ROW
    EXECUTE FUNCTION notify_user_for_account ();

CREATE TRIGGER handle_activity_changes
    AFTER INSERT OR UPDATE ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION notify_user_for_activity ();

CREATE TRIGGER handle_calendar_changes
    AFTER INSERT OR UPDATE ON public.calendar
    FOR EACH ROW
    EXECUTE FUNCTION notify_user_for_calendar ();

CREATE TRIGGER handle_event_changes
    AFTER INSERT OR UPDATE ON public.event
    FOR EACH ROW
    EXECUTE FUNCTION notify_user_for_event ();

CREATE TRIGGER handle_priority_changes
    AFTER INSERT OR UPDATE ON public.priority
    FOR EACH ROW
    EXECUTE FUNCTION notify_user_for_priority ();

CREATE TRIGGER handle_session_changes
    AFTER INSERT OR UPDATE ON public.session
    FOR EACH ROW
    EXECUTE FUNCTION notify_user_for_session ();

ALTER VIEW "public"."activity_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_children" SET ( security_invoker = TRUE);
ALTER VIEW gap SET ( security_invoker = TRUE);
ALTER VIEW gap_monthly SET ( security_invoker = TRUE);
ALTER VIEW gap_daily SET ( security_invoker = TRUE);
ALTER VIEW insight SET ( security_invoker = TRUE);
ALTER VIEW "admin"."sync" SET ( security_invoker = FALSE);
ALTER VIEW "admin"."invitation" SET ( security_invoker = FALSE);
ALTER VIEW "public"."event_invitees" SET ( security_invoker = TRUE);
ALTER VIEW "public"."event_x" SET ( security_invoker = TRUE);
ALTER VIEW public.calendar_x SET ( security_invoker = TRUE);
ALTER VIEW "admin"."user" SET ( security_invoker = FALSE);
ALTER VIEW balance_without_children SET ( security_invoker = TRUE);
ALTER VIEW balance SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_children" SET ( security_invoker = TRUE);
