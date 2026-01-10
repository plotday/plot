DROP TRIGGER IF EXISTS "upsert_user_priority" ON "public"."user_priority";

DROP VIEW IF EXISTS "public"."priority_tags" CASCADE;

DROP VIEW IF EXISTS "public"."user_activity_exception" CASCADE;

DROP VIEW IF EXISTS "public"."user_activity_tags" CASCADE;

DROP VIEW IF EXISTS "public"."user_note" CASCADE;

DROP VIEW IF EXISTS "public"."user_note_tags" CASCADE;

DROP VIEW IF EXISTS "public"."user_priority" CASCADE;

DROP VIEW IF EXISTS "public"."user_priority_unread" CASCADE;

DROP VIEW IF EXISTS "public"."user_activity" CASCADE;

DROP VIEW IF EXISTS "public"."user_activity_unread" CASCADE;

DROP VIEW IF EXISTS "public"."activity_x" CASCADE;

ALTER TABLE "public"."activity"
    ADD COLUMN "last_note_source_created_at" timestamp with time zone;

-- Populate last_note_source_created_at with existing data
UPDATE activity
SET last_note_source_created_at = (
    SELECT
        MAX(source_created_at)
    FROM
        note
    WHERE
        activity_id = activity.id
        AND draft = FALSE
        AND archived_at IS NULL);

SET check_function_bodies = OFF;

CREATE OR REPLACE VIEW "public"."activity_x" AS
SELECT
    a.id,
    a.created_at,
    a.updated_at,
    a.source_created_at,
    a.author_id,
    a.created_by,
    a.assignee_id,
    a.updated_by,
    a.sync_depth,
    a.archived_at,
    a.priority_id,
    a.type,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.at,
    a."on",
    a.duration,
    a.done_at,
    a.recurrence_rule,
    a.recurrence_exdates,
    a.recurrence_dates,
    a.meta,
    a.source,
    a.created_by_twist_id,
    a.embedding,
    a.pick_priority,
    a.last_note_created_at,
    a.last_note_source_created_at,
    a.source_priority_root,
    p.path AS priority_path,
    m.mentions
FROM ((activity a
        JOIN priority p ON (p.id = a.priority_id))
    LEFT JOIN (
        SELECT
            n.activity_id,
            array_agg(DISTINCT mention.mention) AS mentions
        FROM
            note n,
            LATERAL unnest(n.mentions) mention (mention)
        WHERE ((n.archived_at IS NULL)
            AND (n.mentions IS NOT NULL))
    GROUP BY
        n.activity_id) m ON (m.activity_id = a.id));

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

CREATE OR REPLACE FUNCTION public.update_activity_on_note_change ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
BEGIN
    -- On addition of a non-draft, non-archived note:
    -- Keep the activity read for the note creator if no one else has added notes
    -- since they last marked it read
    IF NEW.draft = FALSE AND NEW.archived_at IS NULL THEN
        -- Upsert activity_read for the note creator
        -- Only update if no other users have created notes since their last read_at
        -- Only track read status for actual users (not twists or contacts)
        INSERT INTO activity_read (user_id, activity_id, read_at)
        SELECT
            NEW.created_by,
            NEW.activity_id,
            NEW.created_at
        WHERE
            -- Only insert if created_by is an actual user from auth.users
            EXISTS (
                SELECT
                    1
                FROM
                    auth.users
                WHERE
                    id = NEW.created_by)
            AND NOT EXISTS (
                -- Check if any other user created notes since this user's last read_at
                SELECT
                    1
                FROM
                    note n
                LEFT JOIN activity_read ar ON ar.user_id = NEW.created_by
                    AND ar.activity_id = NEW.activity_id
            WHERE
                n.activity_id = NEW.activity_id
                AND n.created_by != NEW.created_by
                AND n.draft = FALSE
                AND n.archived_at IS NULL
                AND n.created_at > COALESCE(ar.read_at, '-infinity'::timestamp with time zone))
        ON CONFLICT (user_id,
            activity_id)
            DO UPDATE SET
                read_at = NEW.created_at,
                updated_at = now()
            WHERE
                -- Only update if still no other users have notes since current read_at
                NOT EXISTS (
                    SELECT
                        1
                    FROM
                        note n
                    WHERE
                        n.activity_id = NEW.activity_id
                        AND n.created_by != NEW.created_by
                        AND n.draft = FALSE
                        AND n.archived_at IS NULL
                        AND n.created_at > activity_read.read_at);
        -- Update activity's last_note_created_at and last_note_source_created_at when notes are inserted/deleted
        -- Note: note.updated_at changes do NOT trigger this
        UPDATE
            activity
        SET
            last_note_created_at = (
                SELECT
                    MAX(created_at)
                FROM
                    note
                WHERE
                    activity_id = COALESCE(NEW.activity_id, OLD.activity_id)
                    AND draft = FALSE
                    AND archived_at IS NULL),
            last_note_source_created_at = (
                SELECT
                    MAX(source_created_at)
                FROM
                    note
                WHERE
                    activity_id = COALESCE(NEW.activity_id, OLD.activity_id)
                    AND draft = FALSE
                    AND archived_at IS NULL)
        WHERE
            id = COALESCE(NEW.activity_id, OLD.activity_id);
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE OR REPLACE VIEW "public"."user_activity_unread" AS
SELECT
    upe.user_id,
    a.id AS activity_id,
    (ar.read_at IS NULL) AS unread,
    GREATEST (COALESCE(ar.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone), CASE WHEN (a.created_by = upe.user_id) THEN
            COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)
        ELSE
            COALESCE(a.last_note_created_at, a.created_at)
        END) AS updated_at
FROM ((user_priority_expanded upe
        JOIN activity a ON (((a.priority_id = upe.priority_id)
                    AND (a.archived_at IS NULL)
                    AND (((a.created_by = upe.user_id)
                            AND (a.last_note_created_at IS NOT NULL)
                            AND (a.last_note_created_at > upe.joined_at))
                        OR (((a.created_by IS NULL)
                                OR (a.created_by <> upe.user_id))
                            AND (COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at))))))
    LEFT JOIN activity_read ar ON (((ar.user_id = upe.user_id)
                AND (ar.activity_id = a.id)
                AND (ar.read_at >= CASE WHEN (a.created_by = upe.user_id) THEN
                        a.last_note_created_at
                    ELSE
                        COALESCE(a.last_note_created_at, a.created_at)
                    END))));

CREATE OR REPLACE VIEW "public"."user_note" AS
SELECT
    upe.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.archived_at,
    n.activity_id,
    n.draft,
    n.private,
    n.content,
    n.links,
    n.mentions
FROM ((note n
        JOIN activity a ON (a.id = n.activity_id))
    JOIN user_priority_expanded upe ON (upe.priority_id = a.priority_id));

CREATE OR REPLACE VIEW "public"."user_priority_unread" AS
SELECT
    upe.user_id,
    upe.priority_id,
    TRUE AS unread,
    max(GREATEST (COALESCE(ar.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone), CASE WHEN (a.created_by = upe.user_id) THEN
                COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)
            ELSE
                COALESCE(a.last_note_created_at, a.created_at)
            END)) AS updated_at
FROM ((user_priority_expanded upe
        JOIN activity a ON (((a.priority_id = upe.priority_id)
                    AND (a.archived_at IS NULL)
                    AND (((a.created_by = upe.user_id)
                            AND (a.last_note_created_at IS NOT NULL)
                            AND (a.last_note_created_at > upe.joined_at))
                        OR (((a.created_by IS NULL)
                                OR (a.created_by <> upe.user_id))
                            AND (COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at))))))
    LEFT JOIN activity_read ar ON (((ar.user_id = upe.user_id)
                AND (ar.activity_id = a.id))))
GROUP BY
    upe.user_id,
    upe.priority_id;

CREATE OR REPLACE VIEW "public"."user_activity" AS
SELECT
    upe.user_id,
    a.id,
    a.created_at,
    COALESCE(GREATEST (a.updated_at, a.last_note_source_created_at), a.updated_at) AS updated_at,
    a.source_created_at,
    a.author_id,
    a.assignee_id,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at) AS archived_at,
    a.priority_id,
    a.priority_path,
    a.type,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.at,
    a."on",
    a.duration,
    a.done_at,
    a.recurrence_rule,
    a.recurrence_exdates,
    a.recurrence_dates,
    a.meta,
    a.source,
    a.created_by_twist_id,
    a.last_note_created_at,
    a.last_note_source_created_at,
    a.mentions,
    CASE WHEN (a.done_at IS NOT NULL) THEN
        tstzrange(a.done_at, a.done_at, '[]'::text)
    WHEN ((a.assignee_id IS NOT NULL)
        AND (a.assignee_id <> c.id)) THEN
        tstzrange(GREATEST (a.source_created_at, COALESCE(a.last_note_source_created_at, a.source_created_at)), GREATEST (a.source_created_at, COALESCE(a.last_note_source_created_at, a.source_created_at)), '[]'::text)
    WHEN (a.at IS NOT NULL) THEN
        a.at
    WHEN (a."on" IS NOT NULL) THEN
        NULL::tstzrange
    ELSE
        tstzrange(GREATEST (a.source_created_at, COALESCE(a.last_note_source_created_at, a.source_created_at)), GREATEST (a.source_created_at, COALESCE(a.last_note_source_created_at, a.source_created_at)), '[]'::text)
    END AS range_at,
    CASE WHEN (a.done_at IS NOT NULL) THEN
        NULL::daterange
    WHEN ((a.assignee_id IS NOT NULL)
        AND (a.assignee_id <> c.id)) THEN
        NULL::daterange
    WHEN (a.at IS NOT NULL) THEN
        NULL::daterange
    WHEN (a."on" IS NOT NULL) THEN
        a."on"
    ELSE
        NULL::daterange
    END AS range_on,
    COALESCE(uau.unread, FALSE) AS unread
FROM (((activity_x a
            JOIN user_priority_expanded upe ON (a.priority_id = upe.priority_id))
        LEFT JOIN contact c ON (c.user_id = upe.user_id))
    LEFT JOIN user_activity_unread uau ON (((uau.user_id = upe.user_id)
                AND (uau.activity_id = a.id))));

CREATE OR REPLACE VIEW "public"."user_activity_exception" AS
SELECT
    ua.user_id,
    ua.id,
    COALESCE(ae.archived_at, ua.archived_at) AS archived_at,
    ae.occurrence,
    ae.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    ae.at,
    ae."on",
    ae.title,
    ae.note
FROM (activity_exception ae
    JOIN user_activity ua ON (ua.id = ae.activity_id));

CREATE OR REPLACE VIEW "public"."user_activity_tags" AS
SELECT
    ua.user_id,
    ua.id,
    ua.archived_at,
    at.occurrence,
    at.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    at.tags
FROM (activity_tags at
    JOIN user_activity ua ON (ua.id = at.activity_id));

CREATE OR REPLACE VIEW "public"."user_note_tags" AS
SELECT
    ua.user_id,
    n.id,
    nt.updated_at,
    ua.archived_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    nt.tags
FROM ((note_tags nt
        JOIN note n ON (n.id = nt.note_id))
    JOIN user_activity ua ON (ua.id = n.activity_id));

CREATE OR REPLACE VIEW "public"."user_priority" AS
SELECT
    pu.user_id,
    p.id,
    p.created_at,
    GREATEST (settings.updated_at, pu.updated_at, p.updated_at, COALESCE(upu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    GREATEST (pu.archived_at, p.archived_at) AS archived_at,
    p.created_by,
    p.updated_by,
    (root.root
        AND (p.id = root.id)) AS root,
    p.title,
    CASE WHEN (inherited_settings.path IS NOT NULL) THEN
        inherited_settings.path
    WHEN (user_root.path @> p.path) THEN
        p.path
    ELSE
        (user_root.path || p.path)
    END AS path,
    settings.top_order,
    inherited_settings.pomodoro,
    inherited_settings.color,
    COALESCE(upu.unread, FALSE) AS unread
FROM ((((((priority_user pu
                        JOIN priority root ON (pu.priority_id = root.id))
                    JOIN priority user_root ON (((pu.user_id = user_root.created_by)
                                AND user_root.root)))
                JOIN priority p ON (root.path @> p.path))
            LEFT JOIN priority_settings settings ON (((settings.user_id = pu.user_id)
                        AND (p.id = settings.priority_id))))
        LEFT JOIN priority_settings_inherited inherited_settings ON (((inherited_settings.user_id = pu.user_id)
                    AND (p.id = inherited_settings.priority_id))))
    LEFT JOIN user_priority_unread upu ON (((upu.user_id = pu.user_id)
                AND (upu.priority_id = p.id))))
WHERE (pu.archived_at IS NULL);

CREATE TRIGGER upsert_user_priority
    INSTEAD OF INSERT OR UPDATE ON public.user_priority
    FOR EACH ROW
    EXECUTE FUNCTION handle_user_priority_upsert ();

-- Recreate actor function for user_activity (dropped with CASCADE)
CREATE OR REPLACE FUNCTION public.actor (user_activity)
    RETURNS SETOF actor
    LANGUAGE sql
    STABLE ROWS 1
    AS $function$
    SELECT
        actor.*
    FROM
        actor
    WHERE
        actor.id = $1.author_id
$function$;

ALTER VIEW "public"."user_note" SET ( security_invoker = TRUE);
ALTER VIEW "public"."note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_twist" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_exception" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_expanded" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);
