SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.accounts (calendar)
    RETURNS SETOF account
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        account.*
    FROM
        account
    WHERE
        account.id = $1.account_id
$function$;

CREATE OR REPLACE FUNCTION public.calendars (event_x)
    RETURNS SETOF calendar
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        calendar.*
    FROM
        calendar
    WHERE
        calendar.id = $1.calendar_id
$function$;

ALTER VIEW "public"."invitation_admin" SET ( security_invoker = FALSE);
ALTER VIEW "public"."event_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."waitlist_admin" SET ( security_invoker = FALSE);
ALTER VIEW expenditure SET ( security_invoker = TRUE);
ALTER VIEW expenditure_monthly SET ( security_invoker = TRUE);
ALTER VIEW expenditure_rolling SET ( security_invoker = TRUE);
ALTER VIEW "public"."sync_admin" SET ( security_invoker = FALSE);
