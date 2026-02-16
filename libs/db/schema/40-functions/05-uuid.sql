-- Converts a UUID to a negative integer for the updated_by field.
-- Negative updated_by values indicate twist/API-originated writes.
-- Positive values indicate app client writes.
-- Takes the last 16 hex characters and converts to a 32-bit compatible integer, then negates.
CREATE OR REPLACE FUNCTION public.updated_by_uuid (id uuid)
    RETURNS numeric
    LANGUAGE sql
    IMMUTABLE
    AS $function$
    SELECT
        -1 * (CASE WHEN ('x' ||
        RIGHT (REPLACE(id::text, '-', ''),
            16))::bit(64)::bigint < 0 THEN
            (('x' ||
                RIGHT (REPLACE(id::text, '-', ''),
                    16))::bit(64)::bigint::numeric + 18446744073709551616::numeric) % 2147483647
        ELSE
            ('x' ||
            RIGHT (REPLACE(id::text, '-', ''),
                16))::bit(64)::bigint::numeric % 2147483647
        END)
$function$;

