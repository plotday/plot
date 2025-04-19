DROP VIEW IF EXISTS "public"."activity_x";

DROP VIEW IF EXISTS "public"."balance";

DROP VIEW IF EXISTS "public"."balance_without_children";

ALTER TABLE "public"."activity" RENAME COLUMN "body" TO "title";

ALTER TABLE "public"."priority"
    ALTER COLUMN "created_by" SET NOT NULL;

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.add_default_priority ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $function$
DECLARE
    _priority_id uuid;
BEGIN
    RAISE LOG 'Inserting into priority table for user_id: %', NEW.id;
    INSERT INTO public.priority (created_by, name, path)
        VALUES (NEW.id, 'Personal', public.generate_path (NULL))
    RETURNING
        id INTO _priority_id;
    RAISE LOG 'Inserted priority_id: %', _priority_id;
    INSERT INTO public.priority_settings (user_id, priority_id, "order", is_default)
        VALUES (NEW.id, _priority_id, public.order_first (), TRUE);
    RAISE LOG 'Inserted priority_settings for priority_id: %', _priority_id;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.order_first ()
    RETURNS double precision
    LANGUAGE plpgsql
    AS $function$
DECLARE
    millis_since_epoch double precision;
BEGIN
    millis_since_epoch := EXTRACT(epoch FROM CURRENT_TIMESTAMP) * 1000;
    RETURN millis_since_epoch;
END;
$function$;

CREATE OR REPLACE VIEW "public"."activity_x" AS
SELECT
    activity.id,
    activity.created_at,
    activity.updated_at,
    activity.deleted_at,
    activity.draft,
    activity.user_id,
    activity.priority_id,
    activity.title,
    activity.pinned,
    activity."order",
    activity.ordered_at,
    activity.private,
    activity.do_at,
    activity.done_at,
    priority.path AS priority_path,
    CASE WHEN (activity.pinned = TRUE) THEN
        (('200000000000000'::numeric)::double precision + activity."order")
    WHEN (activity.do_at <= now()) THEN
        ((('100000000000000'::numeric + (EXTRACT(epoch FROM activity.do_at) * '1000'::numeric)))::double precision + (activity."order" / ('10000000'::numeric)::double precision))
    ELSE
        activity."order"
    END AS order_x,
    COALESCE(jsonb_object_agg(tag_users.emoji, tag_users.user_ids) FILTER (WHERE (tag_users.emoji IS NOT NULL)), '{}'::jsonb) AS tags
FROM ((activity
    LEFT JOIN priority ON (activity.priority_id = priority.id))
    LEFT JOIN (
        SELECT
            tag.item_id,
            tag.emoji,
            array_agg(tag.user_id ORDER BY tag.user_id) AS user_ids
        FROM
            tag
        WHERE (tag.item_type = 'activity'::item_type)
    GROUP BY
        tag.item_id,
        tag.emoji) tag_users ON (activity.id = tag_users.item_id))
GROUP BY
    activity.id,
    priority.path;

CREATE OR REPLACE VIEW "public"."balance_without_children" AS
SELECT
    event_x.user_id,
    event_x.day,
    event_x.priority_id,
    CASE WHEN (event_x.response IS NULL) THEN
        'tentative'::text
    ELSE
        (event_x.response)::text
    END AS type,
    count(*) AS count,
    sum(event_x.seconds) AS seconds,
    max(event_x.updated_at) AS updated_at
FROM
    event_x
WHERE ((event_x.status <> 'cancelled'::event_status)
    AND (event_x.all_day = FALSE))
GROUP BY
    event_x.user_id,
    event_x.day,
    event_x.priority_id,
    event_x.response
UNION ALL
SELECT
    session.user_id,
    ((lower(session.at) AT TIME ZONE user_timezone ()))::date AS day,
    session.priority_id,
    'session'::text AS type,
    count(*) AS count,
    (sum(EXTRACT(epoch FROM (upper(session.at) - lower(session.at)))))::integer AS seconds,
    max(session.updated_at) AS updated_at
FROM
    session
GROUP BY
    session.user_id,
    (((lower(session.at) AT TIME ZONE user_timezone ()))::date),
    session.priority_id
UNION ALL
SELECT
    activity.user_id,
    ((COALESCE(activity.done_at, activity.do_at) AT TIME ZONE user_timezone ()))::date AS day,
    activity.priority_id,
    CASE WHEN (activity.done_at IS NULL) THEN
        'todo'::text
    ELSE
        'done'::text
    END AS type,
    count(*) AS count,
    0 AS seconds,
    max(activity.updated_at) AS updated_at
FROM
    activity
WHERE ((activity.draft = FALSE)
    AND (activity.do_at IS NOT NULL)
    AND (activity.done_at IS NULL))
GROUP BY
    activity.user_id,
    (((COALESCE(activity.done_at, activity.do_at) AT TIME ZONE user_timezone ()))::date),
    activity.priority_id,
    CASE WHEN (activity.done_at IS NULL) THEN
        'todo'::text
    ELSE
        'done'::text
    END;

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
                name = NEW.name,
                path = NEW.path,
                draft = NEW.draft,
                deleted_at = NEW.deleted_at
            RETURNING
                id INTO _priority_id;
    END IF;
    IF (OLD IS NULL AND (NEW.order IS NOT NULL OR NEW.pomodoro IS NOT NULL OR NEW.color IS NOT NULL OR NEW.is_default IS NOT NULL)) OR (OLD IS NOT NULL AND (NEW."order" IS DISTINCT FROM OLD."order" OR NEW.pomodoro IS DISTINCT FROM OLD.pomodoro OR NEW.color IS DISTINCT FROM OLD.color OR NEW.is_default IS DISTINCT FROM OLD.is_default)) THEN
        INSERT INTO priority_settings (user_id, priority_id, "order", pomodoro, color, is_default)
            VALUES (auth.uid (), _priority_id, NEW.order, COALESCE(NEW.pomodoro, 25 * 60), COALESCE(NEW.color, 0), COALESCE(NEW.is_default, FALSE))
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET
                "order" = COALESCE(NEW.order, priority_settings."order"),
                pomodoro = COALESCE(NEW.pomodoro, priority_settings.pomodoro),
                color = COALESCE(NEW.color, priority_settings.color),
                is_default = COALESCE(NEW.is_default, priority_settings.is_default);
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.insert_priority_user ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
BEGIN
    -- Only create entry for new, top-level priorities.
    IF extensions.nlevel (NEW.path) = 1 AND NEW.created_by IS NOT NULL THEN
        INSERT INTO public.priority_user (created_at, updated_at, user_id, priority_id)
            VALUES (now(), now(), NEW.created_by, NEW.id);
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_created_by ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    NEW.created_by = COALESCE(auth.uid (), NEW.created_by);
    RETURN NEW;
END;
$function$;

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

