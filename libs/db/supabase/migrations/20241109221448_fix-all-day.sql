SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.calc_all_day (at tstzrange)
    RETURNS boolean
    LANGUAGE plpgsql
    IMMUTABLE
    AS $function$
DECLARE
    seconds integer = calc_seconds (at);
BEGIN
    RETURN seconds >= 60 * 60 * 23;
END;
$function$;

