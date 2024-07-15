SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.parent_path (p ltree)
    RETURNS ltree
    LANGUAGE plpgsql
    IMMUTABLE
    AS $function$
BEGIN
    RETURN subpath (p, 0, nlevel (p) - 1);
END;
$function$;

-- CREATE INDEX user_parent_path_order_unique ON public.context USING gist (user_id, parent_path(path), "order");
ALTER TABLE "public"."context"
    ADD CONSTRAINT "user_parent_path_order_unique"
    EXCLUDE USING gist (user_id WITH =, parent_path (path) WITH =, "order" WITH =);

