CREATE FUNCTION extract_minutes (r tstzrange)
    RETURNS integer
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN round((EXTRACT(epoch FROM (upper(r) - lower(r))) / (60)::numeric))::integer;
END;
$function$;

