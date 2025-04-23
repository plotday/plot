DROP TRIGGER IF EXISTS "upsert_priority_x" ON "public"."priority_x";

ALTER TABLE "public"."priority_user"
    DROP CONSTRAINT "priority_user_user_path_unique";

DROP VIEW IF EXISTS "public"."balance";

DROP VIEW IF EXISTS "public"."priority_children";

DROP VIEW IF EXISTS "public"."priority_x";

DROP INDEX IF EXISTS "public"."priority_user_user_path_unique";

ALTER TABLE "public"."priority_user"
    ADD COLUMN "is_default" boolean NOT NULL DEFAULT FALSE;

ALTER TABLE "public"."priority_user"
    ADD COLUMN "path" ltree;

ALTER TABLE "public"."priority_user"
    DROP COLUMN "path";

CREATE UNIQUE INDEX priority_user_user_id_idx ON public.priority_user USING btree (user_id)
WHERE (is_default = TRUE);

CREATE UNIQUE INDEX priority_user_unique ON public.priority_user USING btree (user_id, priority_id);

ALTER TABLE "public"."priority_user"
    ADD CONSTRAINT "priority_user_unique" UNIQUE USING INDEX "priority_user_unique";

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.handle_priority_x_upsert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
DECLARE
    _priority_id uuid;
BEGIN
    _priority_id := NEW.id;
    IF (OLD IS NULL OR (NEW.name IS DISTINCT FROM OLD.name OR NEW.path IS DISTINCT FROM OLD.path OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at)) THEN
        INSERT INTO priority (id, name, path, draft, created_by, deleted_at)
            VALUES (NEW.id, NEW.name, NEW.path, NEW.draft, auth.uid (), NEW.deleted_at)
        ON CONFLICT (id)
            DO UPDATE SET
                name = NEW.name, path = NEW.path, draft = NEW.draft, deleted_at = NEW.deleted_at
            RETURNING
                id INTO _priority_id;
    END IF;
    IF (OLD IS NULL AND (NEW.order IS NOT NULL OR NEW.pomodoro IS NOT NULL OR NEW.color IS NOT NULL OR NEW.is_default IS NOT NULL)) OR (OLD IS NOT NULL AND (NEW."order" IS DISTINCT FROM OLD."order" OR NEW.pomodoro IS DISTINCT FROM OLD.pomodoro OR NEW.color IS DISTINCT FROM OLD.color OR NEW.is_default IS DISTINCT FROM OLD.is_default)) THEN
        INSERT INTO priority_user (user_id, priority_id, "order", pomodoro, color, is_default)
            VALUES (auth.uid (), _priority_id, NEW.order, COALESCE(NEW.pomodoro, 25 * 60), COALESCE(NEW.color, 0), COALESCE(NEW.is_default, FALSE))
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET
                "order" = COALESCE(NEW.order, priority_user."order"), pomodoro = COALESCE(NEW.pomodoro, priority_user.pomodoro), color = COALESCE(NEW.color, priority_user.color), is_default = COALESCE(NEW.is_default, priority_user.is_default);
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE VIEW "public"."priority_x" AS
SELECT
    c2.id,
    cu.user_id,
    c2.created_at,
    GREATEST (cs.updated_at, cu.updated_at, c2.updated_at) AS updated_at,
    GREATEST (cu.deleted_at, c2.deleted_at) AS deleted_at,
    c2.draft,
    c2.name,
    replace_parent_path (c1.path, c2.path, COALESCE(cs.path, c1.path)) AS path,
    COALESCE(cs."order", (((EXTRACT(epoch FROM CURRENT_TIMESTAMP) * (1000)::numeric))::double precision * (10)::double precision)) AS "order",
    cs.pomodoro,
    cs.color,
    cs.is_default
FROM (((priority_user cu
            JOIN priority c1 ON (cu.priority_id = c1.id))
        JOIN priority c2 ON (c1.path @> c2.path))
    LEFT JOIN priority_user cs ON (((cs.user_id = cu.user_id)
                AND (c2.id = cs.priority_id))));

CREATE OR REPLACE VIEW "public"."priority_children" AS
SELECT
    a.id,
    c.id AS child_id
FROM (priority_x a
    JOIN priority c ON (c.path <@ a.path));

CREATE OR REPLACE VIEW "public"."balance" AS
SELECT
    b.user_id,
    b.day,
    NULL::uuid AS priority_id,
    b.type,
    sum(b.count) AS count,
    (sum(b.seconds))::integer AS seconds,
    max(b.updated_at) AS updated_at
FROM
    balance_without_children b
WHERE (b.priority_id IS NULL)
GROUP BY
    b.user_id,
    b.day,
    b.type
UNION ALL
SELECT
    b.user_id,
    b.day,
    b.priority_id,
    b.type,
    sum(b.count) AS count,
    (sum(b.seconds))::integer AS seconds,
    max(b.updated_at) AS updated_at
FROM (balance_without_children b
    JOIN priority_children ac ON (b.priority_id = ac.child_id))
WHERE (b.priority_id IS NOT NULL)
GROUP BY
    b.user_id,
    b.day,
    b.priority_id,
    b.type;

CREATE TRIGGER upsert_priority_x
    INSTEAD OF INSERT OR UPDATE ON public.priority_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_priority_x_upsert ();

CREATE OR REPLACE FUNCTION public.generate_path (parent text DEFAULT NULL::text)
    RETURNS text
    LANGUAGE plpgsql
    AS $function$
DECLARE
    characters text := 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    random_path text := '';
    prefix text := '';
    random_int integer;
BEGIN
    IF parent IS NOT NULL THEN
        prefix := parent || '.';
    END IF;
    FOR i IN 1..4 LOOP
        random_int := floor(random() * length(characters))::integer + 1;
        random_path := random_path || substr(characters, random_int, 1);
    END LOOP;
    RETURN prefix || random_path;
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_default_priority ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO ''
    AS $function$
DECLARE
    priority_id bigint;
BEGIN
    INSERT INTO "public"."priority" ("name", "path", "created_by")
        VALUES ('Personal', generate_path (), NEW.id)
    RETURNING
        id INTO priority_id;
    INSERT INTO "public"."priority_user" ("user_id", "priority_id")
        VALUES (NEW.id, priority_id);
    INSERT INTO "public"."priority_user" ("user_id", "priority_id", "order", "is_default")
        VALUES (NEW.id, priority_id, 0, TRUE);
    RETURN new;
END;
$function$;

CREATE TRIGGER create_default_priority_on_auth_user_created
    AFTER INSERT ON auth.users FOR EACH ROW
    EXECUTE PROCEDURE public.create_default_priority ();

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

