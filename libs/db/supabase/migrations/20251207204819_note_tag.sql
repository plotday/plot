ALTER TABLE "public"."activity_tag"
    DROP CONSTRAINT "activity_tag_actor_id_activity_id_note_id_occurrence_tag_id_key";

ALTER TABLE "public"."activity_tag"
    DROP CONSTRAINT "activity_tag_check";

ALTER TABLE "public"."activity_tag"
    DROP CONSTRAINT "activity_tag_note_id_fkey";

DROP FUNCTION IF EXISTS "public"."update_activity_tags" (p_activity_id uuid, p_note_id uuid, p_user_id uuid, p_client_id integer, p_tag_updates jsonb);

DROP VIEW IF EXISTS "public"."priority_tags";

DROP FUNCTION IF EXISTS "public"."update_activity_tags" (p_activity_id uuid, p_user_id uuid, p_client_id integer, p_tag_updates jsonb);

DROP VIEW IF EXISTS "public"."user_activity_tags";

DROP VIEW IF EXISTS "public"."activity_tags";

DROP INDEX IF EXISTS "public"."activity_tag_actor_id_activity_id_note_id_occurrence_tag_id_key";

DROP INDEX IF EXISTS "public"."idx_activity_tag_note_id";

DROP INDEX IF EXISTS "public"."idx_activity_tag_activity_id";

CREATE TABLE "public"."note_tag" (
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone,
    "actor_id" uuid NOT NULL,
    "note_id" uuid NOT NULL,
    "tag_id" integer NOT NULL,
    "updated_by" integer NOT NULL DEFAULT 0
);

ALTER TABLE "public"."note_tag" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."activity_tag"
    DROP COLUMN "note_id";

ALTER TABLE "public"."activity_tag"
    ALTER COLUMN "activity_id" SET NOT NULL;

CREATE UNIQUE INDEX activity_tag_actor_id_activity_id_occurrence_tag_id_key ON public.activity_tag USING btree (actor_id, activity_id, occurrence, tag_id) NULLS NOT DISTINCT;

CREATE INDEX idx_note_tag_note_id ON public.note_tag USING btree (note_id, tag_id)
WHERE (archived_at IS NULL);

CREATE INDEX idx_activity_tag_activity_id ON public.activity_tag USING btree (activity_id, tag_id)
WHERE (archived_at IS NULL);

ALTER TABLE "public"."activity_tag"
    ADD CONSTRAINT "activity_tag_actor_id_activity_id_occurrence_tag_id_key" UNIQUE USING INDEX "activity_tag_actor_id_activity_id_occurrence_tag_id_key";

ALTER TABLE "public"."note_tag"
    ADD CONSTRAINT "note_tag_note_id_fkey" FOREIGN KEY (note_id) REFERENCES note (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."note_tag" validate CONSTRAINT "note_tag_note_id_fkey";

SET check_function_bodies = OFF;

CREATE OR REPLACE VIEW "public"."note_tags" AS
SELECT
    note_id,
    jsonb_object_agg(tag_id, actor_ids) FILTER (WHERE ((actor_ids IS NOT NULL)
    AND (jsonb_array_length(actor_ids) > 0))) AS tags,
max(updated_at) AS updated_at,
(array_agg(updated_by ORDER BY sq.updated_at DESC))[1] AS updated_by
FROM (
    SELECT
        nt.note_id,
        nt.tag_id,
        jsonb_agg(nt.actor_id) FILTER (WHERE (nt.archived_at IS NULL)) AS actor_ids,
    max(COALESCE(nt.archived_at, nt.updated_at)) AS updated_at,
    (array_agg(nt.updated_by ORDER BY nt.updated_at DESC))[1] AS updated_by
FROM
    note_tag nt
GROUP BY
    nt.note_id,
    nt.tag_id) sq
GROUP BY
    note_id;

CREATE OR REPLACE VIEW "public"."user_note_tags" AS
SELECT
    ua.user_id,
    n.id,
    nt.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    nt.tags
FROM ((note_tags nt
        JOIN note n ON (n.id = nt.note_id))
    JOIN user_activity ua ON (ua.id = n.activity_id));

CREATE OR REPLACE VIEW "public"."activity_tags" AS
SELECT
    activity_id,
    occurrence,
    jsonb_object_agg(tag_id, actor_ids) FILTER (WHERE ((actor_ids IS NOT NULL)
    AND (jsonb_array_length(actor_ids) > 0))) AS tags,
max(updated_at) AS updated_at,
(array_agg(updated_by ORDER BY sq.updated_at DESC))[1] AS updated_by
FROM (
    SELECT
        at.activity_id,
        at.occurrence,
        at.tag_id,
        jsonb_agg(at.actor_id) FILTER (WHERE (at.archived_at IS NULL)) AS actor_ids,
    max(COALESCE(at.archived_at, at.updated_at)) AS updated_at,
    (array_agg(at.updated_by ORDER BY at.updated_at DESC))[1] AS updated_by
FROM
    activity_tag at
GROUP BY
    at.activity_id,
    at.occurrence,
    at.tag_id) sq
GROUP BY
    activity_id,
    occurrence;

CREATE OR REPLACE VIEW "public"."priority_tags" AS
SELECT
    a.priority_id,
    at.tag_id,
    count(*) AS count,
    max(COALESCE(at.archived_at, at.updated_at)) AS updated_at
FROM (activity_tag at
    JOIN activity a ON (at.activity_id = a.id))
WHERE ((at.archived_at IS NULL)
    AND (a.archived_at IS NULL))
GROUP BY
    a.priority_id,
    at.tag_id;

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
    -- Validate that activity_id is provided
    IF p_activity_id IS NULL THEN
        RAISE EXCEPTION 'p_activity_id must be provided';
    END IF;
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
                INSERT INTO activity_tag (actor_id, activity_id, occurrence, tag_id, updated_at, archived_at, updated_by)
                    VALUES (p_user_id, p_activity_id, NULL, tag_id_int, now(), NULL, p_client_id)
                ON CONFLICT (actor_id, activity_id, occurrence, tag_id)
                    DO UPDATE SET
                        archived_at = NULL,
                        updated_at = now(),
                        updated_by = p_client_id;
            ELSE
                -- Removing a tag - use update to soft delete existing records
                IF current_tag_type = 'toggle' THEN
                    -- For toggle tags, remove all users' tags
                    UPDATE
                        activity_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        activity_id = p_activity_id
                        AND tag_id = tag_id_int
                        AND archived_at IS NULL;
                ELSE
                    -- For count/compute tags, only remove current user's tag
                    UPDATE
                        activity_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        activity_id = p_activity_id
                        AND tag_id = tag_id_int
                        AND actor_id = p_user_id
                        AND archived_at IS NULL;
                END IF;
            END IF;
        END LOOP;
END;
$function$;

CREATE OR REPLACE VIEW "public"."user_activity_tags" AS
SELECT
    ua.user_id,
    ua.id,
    at.occurrence,
    at.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    at.tags
FROM (activity_tags at
    JOIN user_activity ua ON (ua.id = at.activity_id));

CREATE TRIGGER set_note_tag_updated_at
    BEFORE UPDATE ON public.note_tag
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE OR REPLACE VIEW "public"."user_note" AS
SELECT
    up.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.archived_at,
    n.activity_id,
    n.draft,
    n.private,
    n.note,
    n.links,
    n.mentions
FROM (((note n
            JOIN activity a ON (a.id = n.activity_id))
        JOIN priority p ON (p.id = a.priority_id))
    JOIN user_priority up ON (up.id = a.priority_id))
WHERE (up.archived_at IS NULL);

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
    -- Validate that activity_id is provided
    IF p_activity_id IS NULL THEN
        RAISE EXCEPTION 'p_activity_id must be provided';
    END IF;
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
                INSERT INTO activity_tag (actor_id, activity_id, occurrence, tag_id, updated_at, archived_at, updated_by)
                    VALUES (p_user_id, p_activity_id, NULL, tag_id_int, now(), NULL, p_client_id)
                ON CONFLICT (actor_id, activity_id, occurrence, tag_id)
                    DO UPDATE SET
                        archived_at = NULL,
                        updated_at = now(),
                        updated_by = p_client_id;
            ELSE
                -- Removing a tag - use update to soft delete existing records
                IF current_tag_type = 'toggle' THEN
                    -- For toggle tags, remove all users' tags
                    UPDATE
                        activity_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        activity_id = p_activity_id
                        AND tag_id = tag_id_int
                        AND archived_at IS NULL;
                ELSE
                    -- For count/compute tags, only remove current user's tag
                    UPDATE
                        activity_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        activity_id = p_activity_id
                        AND tag_id = tag_id_int
                        AND actor_id = p_user_id
                        AND archived_at IS NULL;
                END IF;
            END IF;
        END LOOP;
END;
$function$;

CREATE UNIQUE INDEX note_tag_actor_id_note_id_tag_id_key ON public.note_tag USING btree (actor_id, note_id, tag_id) NULLS NOT DISTINCT;

ALTER TABLE "public"."note_tag"
    ADD CONSTRAINT "note_tag_actor_id_note_id_tag_id_key" UNIQUE USING INDEX "note_tag_actor_id_note_id_tag_id_key";

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.update_note_tags (p_note_id uuid, p_user_id uuid, p_client_id integer, p_tag_updates jsonb)
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
    -- Validate that note_id is provided
    IF p_note_id IS NULL THEN
        RAISE EXCEPTION 'p_note_id must be provided';
    END IF;
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
                INSERT INTO note_tag (actor_id, note_id, tag_id, updated_at, archived_at, updated_by)
                    VALUES (p_user_id, p_note_id, tag_id_int, now(), NULL, p_client_id)
                ON CONFLICT (actor_id, note_id, tag_id)
                    DO UPDATE SET
                        archived_at = NULL,
                        updated_at = now(),
                        updated_by = p_client_id;
            ELSE
                -- Removing a tag - use update to soft delete existing records
                IF current_tag_type = 'toggle' THEN
                    -- For toggle tags, remove all users' tags
                    UPDATE
                        note_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        note_id = p_note_id
                        AND tag_id = tag_id_int
                        AND archived_at IS NULL;
                ELSE
                    -- For count/compute tags, only remove current user's tag
                    UPDATE
                        note_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        note_id = p_note_id
                        AND tag_id = tag_id_int
                        AND actor_id = p_user_id
                        AND archived_at IS NULL;
                END IF;
            END IF;
        END LOOP;
END;
$function$;

ALTER VIEW "public"."note_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_note_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."notes" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_exception" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_active_actions" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_settings_inherited" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_base" SET (security_invoker = TRUE);

ALTER VIEW "public"."actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child_twist" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_note" SET (security_invoker = TRUE);

ALTER VIEW "public"."note_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_note_tags" SET (security_invoker = TRUE);

