DROP TRIGGER IF EXISTS "upsert_activity_x" ON "public"."activity_x";

DROP POLICY "Users can view all tags" ON "public"."tag";

DROP POLICY "Users can update activity_tag for activities in their accessibl" ON "public"."activity_tag";

ALTER TABLE "public"."activity_tag"
    DROP CONSTRAINT "activity_tag_tag_id_fkey";

ALTER TABLE "public"."tag"
    DROP CONSTRAINT "tag_emoji_key";

ALTER TABLE "public"."activity_tag"
    DROP CONSTRAINT "activity_tag_activity_id_fkey";

DROP VIEW IF EXISTS "public"."activity_children";

DROP VIEW IF EXISTS "public"."activity_x";

DROP VIEW IF EXISTS "public"."priority_tags";

DROP VIEW IF EXISTS "public"."activity_tags";

ALTER TABLE "public"."tag"
    DROP CONSTRAINT "tag_pkey";

DROP INDEX IF EXISTS "public"."tag_emoji_key";

DROP INDEX IF EXISTS "public"."tag_pkey";

DROP TABLE "public"."tag";

ALTER TYPE "public"."tag_type" RENAME TO "tag_type__old_version_to_be_dropped";

CREATE TYPE "public"."tag_type" AS enum (
    'toggle',
    'count',
    'compute'
);

DROP TYPE "public"."tag_type__old_version_to_be_dropped";

ALTER TABLE "public"."activity_tag"
    DROP COLUMN "created_at";

ALTER TABLE "public"."activity_tag"
    ADD COLUMN "updated_at" timestamp with time zone NOT NULL DEFAULT now();

ALTER TABLE "public"."activity_tag"
    ALTER COLUMN "activity_id" SET NOT NULL;

ALTER TABLE "public"."activity_tag"
    ALTER COLUMN "tag_id" SET NOT NULL;

ALTER TABLE "public"."activity_tag"
    ADD CONSTRAINT "activity_tag_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES activity (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."activity_tag" validate CONSTRAINT "activity_tag_activity_id_fkey";

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.get_tag_type (tag_id integer)
    RETURNS tag_type
    LANGUAGE plpgsql
    IMMUTABLE
    AS $function$
BEGIN
    IF tag_id BETWEEN 1 AND 99 THEN
        RETURN 'compute'::tag_type;
    ELSIF tag_id BETWEEN 100 AND 999 THEN
        RETURN 'toggle'::tag_type;
    ELSE
        RETURN 'count'::tag_type;
    END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_activity_tags (p_activity_id uuid, p_user_id uuid, p_client_id integer, p_tag_updates jsonb)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    tag_record record;
    tag_id_int integer;
    is_adding boolean;
    current_tag_type tag_type;
BEGIN
    -- Iterate through the tag updates JSON object
    FOR tag_record IN
    SELECT
        key,
        value
    FROM
        jsonb_each(p_tag_updates)
        LOOP
            -- Convert key to integer and value to boolean
            tag_id_int := tag_record.key::integer;
            is_adding := tag_record.value::boolean;
            -- Get tag type using the get_tag_type function
            current_tag_type := get_tag_type (tag_id_int);
            IF is_adding THEN
                -- Adding a tag - use upsert to create or reactivate
                INSERT INTO activity_tag (user_id, activity_id, tag_id, updated_at, deleted_at, updated_by)
                    VALUES (p_user_id, p_activity_id, tag_id_int, now(), NULL, p_client_id)
                ON CONFLICT (user_id, activity_id, tag_id)
                    DO UPDATE SET
                        deleted_at = NULL,
                        updated_at = now(),
                        updated_by = p_client_id;
            ELSE
                -- Removing a tag - use update to soft delete existing records
                IF current_tag_type = 'toggle' THEN
                    -- For toggle tags, remove all users' tags
                    UPDATE
                        activity_tag
                    SET
                        deleted_at = now(),
                        updated_by = p_client_id
                    WHERE
                        activity_id = p_activity_id
                        AND tag_id = tag_id_int
                        AND deleted_at IS NULL;
                ELSE
                    -- For count/compute tags, only remove current user's tag
                    UPDATE
                        activity_tag
                    SET
                        deleted_at = now(),
                        updated_by = p_client_id
                    WHERE
                        activity_id = p_activity_id
                        AND tag_id = tag_id_int
                        AND user_id = p_user_id
                        AND deleted_at IS NULL;
                END IF;
            END IF;
        END LOOP;
END;
$function$;

CREATE OR REPLACE VIEW "public"."activity_tags" AS
SELECT
    sq.activity_id,
    jsonb_object_agg(sq.tag_id, sq.user_ids) AS tags,
    sq.updated_at,
    sq.updated_by
FROM (
    SELECT
        at.activity_id,
        at.tag_id,
        jsonb_agg(at.user_id) AS user_ids,
        max(COALESCE(at.deleted_at, at.updated_at)) AS updated_at,
        (array_agg(at.updated_by ORDER BY COALESCE(at.deleted_at, at.updated_at) DESC))[1] AS updated_by
    FROM
        activity_tag at
    WHERE (at.deleted_at IS NULL)
GROUP BY
    at.activity_id,
    at.tag_id) sq
GROUP BY
    sq.activity_id,
    sq.updated_at,
    sq.updated_by;

CREATE OR REPLACE VIEW "public"."activity_x" AS
SELECT
    a.id,
    pu.user_id,
    a.created_at,
    GREATEST (a.updated_at, COALESCE(tags.updated_at, a.updated_at)) AS updated_at,
    CASE WHEN (COALESCE(tags.updated_at, a.updated_at) > a.updated_at) THEN
        tags.updated_by
    ELSE
        a.updated_by
    END AS updated_by,
    a.deleted_at,
    a.created_by,
    a.priority_id,
    a.path,
    a.draft,
    a.private,
    a.do_at,
    a.done_at,
    a.title,
    a.note,
    a.event_series,
    a."order",
    (COALESCE(a.done_at, (a.do_at)::timestamp with time zone, a.created_at))::date AS day,
    tags.tags
FROM (((priority_user pu
            JOIN priority p ON (((pu.priority_id = p.id)
                        OR (p.path <@ (
                                SELECT
                                    priority.path
                                FROM
                                    priority
                            WHERE (priority.id = pu.priority_id))))))
        JOIN activity a ON (a.priority_id = p.id))
    LEFT JOIN activity_tags tags ON (tags.activity_id = a.id))
WHERE ((pu.deleted_at IS NULL)
    AND (p.deleted_at IS NULL));

CREATE OR REPLACE VIEW "public"."priority_tags" AS
SELECT
    a.priority_id,
    at.tag_id,
    count(*) AS count,
    max(COALESCE(at.deleted_at, at.updated_at)) AS updated_at
FROM (activity_tag at
    JOIN activity a ON (at.activity_id = a.id))
WHERE ((at.deleted_at IS NULL)
    AND (a.deleted_at IS NULL)
    AND (nlevel (a.path) = 1))
GROUP BY
    a.priority_id,
    at.tag_id;

CREATE OR REPLACE VIEW "public"."activity_children" AS
SELECT
    a.id,
    c.id AS child_id
FROM (activity_x a
    JOIN activity c ON (c.path <@ a.path));

CREATE POLICY "Users can update activity_tag for activities in their accessibl" ON "public"."activity_tag" AS permissive
    FOR UPDATE TO public
        USING (((user_id = auth.uid ()) OR (EXISTS (
            SELECT
                1
            FROM
                activity a
            WHERE ((a.id = activity_tag.activity_id) AND user_has_priority_access (auth.uid (), a.priority_id) AND (get_tag_type (activity_tag.tag_id) = 'toggle'::tag_type))))))
        WITH CHECK ((user_id = auth.uid ()));

CREATE TRIGGER set_activity_tag_updated_at
    BEFORE UPDATE ON public.activity_tag
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER upsert_activity_x
    INSTEAD OF INSERT OR UPDATE ON public.activity_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_activity_x_upsert ();

ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_children" SET ( security_invoker = TRUE);
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
ALTER VIEW balance_without_children SET ( security_invoker = TRUE);
ALTER VIEW balance SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_children" SET ( security_invoker = TRUE);
ALTER VIEW "public"."agent_x" SET ( security_invoker = TRUE);
