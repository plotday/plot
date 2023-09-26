SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.update_all_event_labels ()
    RETURNS void
    LANGUAGE plpgsql
    AS $function$
BEGIN
    DELETE FROM event_label;
    INSERT INTO event_label (event_id, label_id)
    SELECT
        id AS event_id,
        unnest(event_label_ids (e)) AS label_id
    FROM
        event_x e;
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
ALTER VIEW "public"."sync_admin" SET ( security_invoker = FALSE);
