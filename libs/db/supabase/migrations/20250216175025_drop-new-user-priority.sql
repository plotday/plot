DROP TRIGGER create_default_priority_on_auth_user_created ON auth.users;

DROP FUNCTION IF EXISTS "public"."create_default_priority" ();

DROP FUNCTION IF EXISTS "public"."generate_path" (parent text);

ALTER TABLE "public"."priority"
    ALTER COLUMN "created_by" DROP NOT NULL;

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.generate_path (parent ltree DEFAULT NULL::LTREE)
    RETURNS ltree
    LANGUAGE plpgsql
    AS $function$
DECLARE
    characters text := 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    random_path text := '';
    prefix text := '';
    random_int integer;
BEGIN
    IF parent IS NOT NULL THEN
        prefix := extensions.ltree2text (parent) || '.';
    END IF;
    FOR i IN 1..4 LOOP
        random_int := floor(random() * length(characters))::integer + 1;
        random_path := random_path || substr(characters, random_int, 1);
    END LOOP;
    RETURN extensions.text2ltree (prefix || random_path);
END;
$function$;

CREATE OR REPLACE FUNCTION public.insert_priority_user ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
BEGIN
    IF extensions.nlevel (NEW.path) = 1 THEN
        INSERT INTO public.priority_user (created_at, updated_at, user_id, priority_id)
            VALUES (now(), now(), NEW.created_by, NEW.id);
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.parent_path (p ltree)
    RETURNS ltree
    LANGUAGE plpgsql
    IMMUTABLE
    AS $function$
BEGIN
    IF extensions.nlevel (p) = 1 THEN
        RETURN p;
    END IF;
    RETURN subpath (p, 0, extensions.nlevel (p) - 1);
END;
$function$;

CREATE OR REPLACE FUNCTION public.replace_parent_path (parent_path ltree, child_path ltree, new_parent_path ltree)
    RETURNS ltree
    LANGUAGE plpgsql
    AS $function$
BEGIN
    IF child_path = parent_path THEN
        RETURN new_parent_path;
    ELSIF child_path <@ parent_path THEN
        RETURN new_parent_path || subpath (child_path, extensions.nlevel (parent_path));
    ELSE
        RETURN child_path;
    END IF;
END;
$function$;

ALTER VIEW note_x SET (security_invoker = TRUE);

ALTER VIEW gap SET (security_invoker = TRUE);

ALTER VIEW gap_monthly SET (security_invoker = TRUE);

ALTER VIEW gap_daily SET (security_invoker = TRUE);

ALTER VIEW insight SET (security_invoker = TRUE);

ALTER VIEW "admin"."sync" SET (security_invoker = FALSE);

ALTER VIEW "admin"."invitation" SET (security_invoker = FALSE);

ALTER VIEW activity_x SET (security_invoker = TRUE);

ALTER VIEW "public"."event_invitees" SET (security_invoker = TRUE);

ALTER VIEW "public"."event_x" SET (security_invoker = TRUE);

ALTER VIEW "admin"."user" SET (security_invoker = FALSE);

ALTER VIEW balance_without_children SET (security_invoker = TRUE);

ALTER VIEW balance SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_children" SET (security_invoker = TRUE);

