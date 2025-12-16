CREATE OR REPLACE FUNCTION public.sync_priority_contact_on_update ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    v_contact_id uuid;
BEGIN
    -- Only proceed if archived_at changed
    IF OLD.archived_at IS DISTINCT FROM NEW.archived_at THEN
        -- Get the contact_id for this user
        SELECT
            id INTO v_contact_id
        FROM
            contact
        WHERE
            user_id = NEW.user_id;
        -- Update the corresponding priority_contact if it exists
        IF v_contact_id IS NOT NULL THEN
            UPDATE
                priority_contact
            SET
                archived_at = NEW.archived_at
            WHERE
                priority_id = NEW.priority_id
                AND contact_id = v_contact_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_priority_contact_on_delete ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    v_contact_id uuid;
BEGIN
    -- Get the contact_id for this user
    SELECT
        id INTO v_contact_id
    FROM
        contact
    WHERE
        user_id = OLD.user_id;
    -- Delete the corresponding priority_contact if it exists
    IF v_contact_id IS NOT NULL THEN
        DELETE FROM priority_contact
        WHERE priority_id = OLD.priority_id
            AND contact_id = v_contact_id;
    END IF;
    RETURN OLD;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_priority_contact_on_insert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    v_contact_id uuid;
BEGIN
    -- Get the contact_id for this user
    SELECT
        id INTO v_contact_id
    FROM
        contact
    WHERE
        user_id = NEW.user_id;
    -- Only create priority_contact if the user has a contact record
    IF v_contact_id IS NOT NULL THEN
        INSERT INTO priority_contact (priority_id, contact_id, created_at, archived_at)
            VALUES (NEW.priority_id, v_contact_id, NEW.created_at, NEW.archived_at)
        ON CONFLICT (priority_id, contact_id)
            DO NOTHING;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_priority_contact_on_update ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    v_contact_id uuid;
BEGIN
    -- Only proceed if archived_at changed
    IF OLD.archived_at IS DISTINCT FROM NEW.archived_at THEN
        -- Get the contact_id for this user
        SELECT
            id INTO v_contact_id
        FROM
            contact
        WHERE
            user_id = NEW.user_id;
        -- Update the corresponding priority_contact if it exists
        IF v_contact_id IS NOT NULL THEN
            UPDATE
                priority_contact
            SET
                archived_at = NEW.archived_at
            WHERE
                priority_id = NEW.priority_id
                AND contact_id = v_contact_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER sync_priority_contact_delete
    AFTER DELETE ON public.priority_user
    FOR EACH ROW
    EXECUTE FUNCTION sync_priority_contact_on_delete ();

CREATE TRIGGER sync_priority_contact_insert
    AFTER INSERT ON public.priority_user
    FOR EACH ROW
    EXECUTE FUNCTION sync_priority_contact_on_insert ();

CREATE TRIGGER sync_priority_contact_update
    AFTER UPDATE OF archived_at ON public.priority_user
    FOR EACH ROW
    EXECUTE FUNCTION sync_priority_contact_on_update ();

INSERT INTO priority_contact (priority_id, contact_id, created_at, archived_at)
SELECT
    pu.priority_id,
    c.id AS contact_id,
    pu.created_at,
    pu.archived_at
FROM
    priority_user pu
    JOIN contact c ON c.user_id = pu.user_id
ON CONFLICT (priority_id,
    contact_id)
    DO NOTHING;

CREATE OR REPLACE VIEW "public"."user_activity_unread" AS SELECT DISTINCT ON (up.user_id, a.id)
    up.user_id,
    a.id AS activity_id,
    (unread.updated_at IS NOT NULL) AS unread,
    GREATEST (ar.updated_at, unread.updated_at) AS updated_at
FROM (((((user_priority up
                    JOIN contact c ON (c.user_id = up.user_id))
                JOIN activity a ON (a.priority_id = up.id))
            LEFT JOIN activity_read ar ON (((ar.user_id = up.user_id)
                        AND (ar.activity_id = a.id))))
        LEFT JOIN LATERAL (
            SELECT
                pu.created_at
            FROM ((priority_user pu
                    JOIN priority p ON (p.id = pu.priority_id))
                JOIN priority ap ON (ap.id = a.priority_id))
        WHERE ((pu.user_id = up.user_id)
            AND (p.path @> ap.path))
    ORDER BY
        (nlevel (p.path))
    LIMIT 1) member ON (TRUE))
    LEFT JOIN LATERAL (
        SELECT
            max(GREATEST (a.updated_at, n.updated_at)) AS updated_at
        FROM
            note n
        WHERE ((n.activity_id = a.id)
            AND (n.archived_at IS NULL)
            AND (n.author_id <> c.id)
            AND ((member.created_at IS NULL)
                OR (n.created_at >= member.created_at))
            AND ((ar.read_at IS NULL)
                OR (n.created_at > ar.read_at)))
    UNION ALL
    SELECT
        a.updated_at
    WHERE ((a.author_id <> c.id)
        AND ((member.created_at IS NULL)
            OR (a.created_at >= member.created_at))
        AND (ar.read_at IS NULL))) unread ON (TRUE))
WHERE (up.archived_at IS NULL)
ORDER BY
    up.user_id,
    a.id,
    unread.updated_at DESC NULLS LAST;

ALTER VIEW "public"."user_note" SET (security_invoker = TRUE);

ALTER VIEW "public"."note_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_note_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_twist" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_exception" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_settings_inherited" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_base" SET (security_invoker = TRUE);

ALTER VIEW "public"."actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child_twist" SET (security_invoker = TRUE);

