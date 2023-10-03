SET check_function_bodies = OFF;

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
            status = 'active'
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

ALTER VIEW gap SET (security_invoker = TRUE);

ALTER VIEW gap_monthly SET (security_invoker = TRUE);

ALTER VIEW gap_daily SET (security_invoker = TRUE);

ALTER VIEW "public"."invitation_admin" SET (security_invoker = FALSE);

ALTER VIEW "public"."event_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."waitlist_admin" SET (security_invoker = FALSE);

ALTER VIEW expenditure SET (security_invoker = TRUE);

ALTER VIEW expenditure_monthly SET (security_invoker = TRUE);

ALTER VIEW expenditure_rolling SET (security_invoker = TRUE);

ALTER VIEW prep_monthly SET (security_invoker = TRUE);

ALTER VIEW "public"."sync_admin" SET (security_invoker = FALSE);

