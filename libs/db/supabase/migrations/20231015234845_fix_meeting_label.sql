SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.event_label_ids (e event_x)
    RETURNS bigint[]
    LANGUAGE plpgsql
    STABLE
    AS $function$
DECLARE
    result bigint[] = '{}'::bigint[];
BEGIN
    IF e.type <> 'meeting' THEN
        RETURN result;
    END IF;
    result := result || 1;
    result := result || CASE WHEN e.invitee_count = 2 THEN
        2
    WHEN e.invitee_count <= 4 THEN
        3
    WHEN e.invitee_count <= 7 THEN
        4
    WHEN e.invitee_count <= 15 THEN
        5
    WHEN e.invitee_count <= 30 THEN
        6
    ELSE
        7
    END;
    IF e.internal = 'internal'::event_internal THEN
        result := result || 8;
    END IF;
    IF e.internal = 'external'::event_internal THEN
        result := result || 9;
    END IF;
    result := result || CASE WHEN e.minutes <= 20 THEN
        10
    WHEN e.minutes < 40 THEN
        11
    WHEN e.minutes < 50 THEN
        12
    WHEN e.minutes < 75 THEN
        13
    WHEN e.minutes < 101 THEN
        14
    WHEN e.minutes < 131 THEN
        15
    WHEN e.minutes < 161 THEN
        16
    WHEN e.minutes <= 180 THEN
        17
    WHEN e.minutes <= 300 THEN
        18
    WHEN e.minutes <= 420 THEN
        19
    ELSE
        20
    END;
    IF e.series IS NOT NULL THEN
        result := result || 21;
    END IF;
    IF e.created_at IS NOT NULL AND EXTRACT(EPOCH FROM (LOWER(e.at) - e.created_at)) < 18 * 60 * 60 THEN
        result := result || 22;
    END IF;
    IF e.minutes < 30 OR (MOD(e.minutes, 30) >= 10 AND MOD(e.minutes, 30) <= 15) THEN
        result := result || 23;
    END IF;
    IF e.initiated = TRUE THEN
        result := result || 24;
    END IF;
    RETURN result;
END;
$function$;

ALTER VIEW gap SET ( security_invoker = TRUE);
ALTER VIEW gap_monthly SET ( security_invoker = TRUE);
ALTER VIEW gap_daily SET ( security_invoker = TRUE);
ALTER VIEW "public"."invitation_admin" SET ( security_invoker = FALSE);
ALTER VIEW "public"."event_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."waitlist_admin" SET ( security_invoker = FALSE);
ALTER VIEW expenditure SET ( security_invoker = TRUE);
ALTER VIEW expenditure_monthly SET ( security_invoker = TRUE);
ALTER VIEW expenditure_rolling SET ( security_invoker = TRUE);
ALTER VIEW prep_monthly SET ( security_invoker = TRUE);
ALTER VIEW "public"."sync_admin" SET ( security_invoker = FALSE);
