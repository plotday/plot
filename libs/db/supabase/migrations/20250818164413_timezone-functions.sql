SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.tstzrange_to_daterange (p_range tstzrange, p_timezone text DEFAULT 'UTC' ::text)
    RETURNS daterange
    LANGUAGE plpgsql
    IMMUTABLE
    AS $function$
BEGIN
    RETURN daterange((lower(p_range) AT TIME ZONE p_timezone)::date, (upper(p_range) AT TIME ZONE p_timezone)::date,
    -- preserve inclusive/exclusive bounds of original p_range
    CASE WHEN lower_inc(p_range)
        AND upper_inc(p_range) THEN
        '[]'
    WHEN lower_inc(p_range) THEN
        '[)'
    WHEN upper_inc(p_range) THEN
        '(]'
    ELSE
        '()'
    END)::daterange;
END;
$function$;

CREATE OR REPLACE FUNCTION public.user_activity_occurrence_tz (p_timezone text DEFAULT 'UTC' ::text)
    RETURNS TABLE (
        user_id uuid,
        id uuid,
        occurrence uuid,
        updated_at timestamp with time zone,
        range_at tstzrange,
        range_on daterange,
        at tstzrange,
        "on" daterange,
        title text,
        note text,
        tags jsonb,
        RANGE daterange)
    LANGUAGE plpgsql
    STABLE
    AS $function$
BEGIN
    RETURN QUERY
    SELECT
        uao.user_id,
        uao.id,
        uao.occurrence,
        uao.updated_at,
        uao.range_at,
        uao.range_on,
        uao.at,
        uao.on,
        uao.title,
        uao.note,
        uao.tags,
        CASE WHEN uao.range_at IS NOT NULL THEN
            tstzrange_to_daterange (uao.range_at, p_timezone)
        ELSE
            uao.range_on
        END AS "range"
    FROM
        user_activity_occurrence uao;
END;
$function$;

CREATE OR REPLACE FUNCTION public.user_activity_tz (p_timezone text DEFAULT 'UTC' ::text)
    RETURNS TABLE (
        user_id uuid,
        id uuid,
        created_at timestamp with time zone,
        updated_at timestamp with time zone,
        created_by uuid,
        updated_by integer,
        deleted_at timestamp with time zone,
        priority_id uuid,
        path ltree,
        "order" double precision,
        draft boolean,
        private boolean,
        title text,
        note text,
        do_on date,
        done_at timestamp with time zone,
        at tstzrange,
        "on" daterange,
        duration interval,
        recurrence_rule text,
        recurrence_exdates timestamp with time zone[],
        recurrence_dates timestamp with time zone[],
        range_at tstzrange,
        range_on daterange,
        RANGE daterange)
    LANGUAGE plpgsql
    STABLE
    AS $function$
BEGIN
    RETURN QUERY
    SELECT
        ua.user_id,
        ua.id,
        ua.created_at,
        ua.updated_at,
        ua.created_by,
        ua.updated_by,
        ua.deleted_at,
        ua.priority_id,
        ua.path,
        ua.order,
        ua.draft,
        ua.private,
        ua.title,
        ua.note,
        ua.do_on,
        ua.done_at,
        ua.at,
        ua.on,
        ua.duration,
        ua.recurrence_rule,
        ua.recurrence_exdates,
        ua.recurrence_dates,
        ua.range_at,
        ua.range_on,
        CASE WHEN ua.range_at IS NOT NULL THEN
            tstzrange_to_daterange (ua.range_at, p_timezone)
        ELSE
            ua.range_on
        END AS "range"
    FROM
        user_activity ua;
END;
$function$;

ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_children" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_occurrence" SET ( security_invoker = TRUE);
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
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW balance_without_children SET ( security_invoker = TRUE);
ALTER VIEW balance SET ( security_invoker = TRUE);
ALTER VIEW "public"."agent_x" SET ( security_invoker = TRUE);
