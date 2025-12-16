DROP TRIGGER IF EXISTS "activity_propagate_mentions_to_parent" ON "public"."activity";

DROP TRIGGER IF EXISTS "upsert_user_priority" ON "public"."user_priority";

ALTER TABLE "public"."activity_read"
    DROP CONSTRAINT "activity_read_single_level";

ALTER TABLE "public"."activity_tag"
    DROP CONSTRAINT "activity_tag_actor_id_activity_id_occurrence_tag_id_key";

ALTER TABLE "public"."activity_read"
    DROP CONSTRAINT "activity_read_unique";

DROP VIEW IF EXISTS "public"."activity_children";

DROP FUNCTION IF EXISTS "public"."activity_thread" (p_activity_id uuid);

DROP FUNCTION IF EXISTS "public"."propagate_mentions_to_parent" ();

DROP FUNCTION IF EXISTS "public"."upsert_activity" (p_id uuid, p_user_id uuid, p_updated_by integer, p_archived_at timestamp with time zone, p_priority_id uuid, p_path ltree, p_draft boolean, p_private boolean, p_do_on date, p_at tstzrange, p_on daterange, p_duration interval, p_done_at timestamp with time zone, p_title text, p_note text, p_order double precision, p_recurrence_rule text, p_recurrence_exdates timestamp with time zone[], p_recurrence_dates timestamp with time zone[], p_series uuid, p_occurrence_start timestamp with time zone);

DROP VIEW IF EXISTS "public"."priority_tags";

DROP VIEW IF EXISTS "public"."user_activity_exception";

DROP VIEW IF EXISTS "public"."user_activity_tags";

DROP VIEW IF EXISTS "public"."activity_tags";

DROP INDEX IF EXISTS "public"."activity_tag_activity_id_tag_id_idx";

DROP INDEX IF EXISTS "public"."activity_tag_actor_id_activity_id_occurrence_tag_id_key";

DROP INDEX IF EXISTS "public"."idx_activity_path";

DROP INDEX IF EXISTS "public"."idx_activity_read_user_path";

DROP INDEX IF EXISTS "public"."activity_read_unique";

DROP VIEW IF EXISTS "public"."user_activity_unread" CASCADE;

DROP VIEW IF EXISTS "public"."user_priority";

DROP VIEW IF EXISTS "public"."user_activity";

CREATE TABLE "public"."note" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid_v7 (),
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "author_id" uuid NOT NULL,
    "created_by" uuid NOT NULL,
    "updated_by" integer NOT NULL DEFAULT 0,
    "archived_at" timestamp with time zone,
    "activity_id" uuid NOT NULL,
    "draft" boolean NOT NULL DEFAULT FALSE,
    "private" boolean NOT NULL DEFAULT FALSE,
    "note" text,
    "links" jsonb,
    "mentions" uuid[]
);

ALTER TABLE "public"."note" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."activity"
    ADD CONSTRAINT activity_action_assignee CHECK (TYPE != 'action' OR assignee_id IS NOT NULL);

ALTER TABLE "public"."activity"
    DROP COLUMN "links";

ALTER TABLE "public"."activity"
    DROP COLUMN "note";

ALTER TABLE "public"."activity"
    DROP COLUMN "path";

ALTER TABLE "public"."activity"
    ADD COLUMN "preview" text;

ALTER TABLE "public"."activity_read"
    DROP COLUMN "activity_path";

ALTER TABLE "public"."activity_read"
    ADD COLUMN "activity_id" uuid NOT NULL;

ALTER TABLE "public"."activity_tag"
    ADD COLUMN "note_id" uuid;

ALTER TABLE "public"."activity_tag"
    ALTER COLUMN "activity_id" DROP NOT NULL;

CREATE UNIQUE INDEX note_pkey ON public.note USING btree (id);

CREATE UNIQUE INDEX activity_read_unique ON public.activity_read USING btree (user_id, activity_id);

CREATE UNIQUE INDEX activity_tag_actor_id_activity_id_note_id_occurrence_tag_id_key ON public.activity_tag USING btree (actor_id, activity_id, note_id, occurrence, tag_id) NULLS NOT DISTINCT;

CREATE INDEX idx_note_activity_id ON public.note USING btree (activity_id);

CREATE INDEX idx_note_created_at ON public.note USING btree (activity_id, created_at);

CREATE INDEX idx_activity_read_user_activity ON public.activity_read USING btree (user_id, activity_id);

CREATE INDEX idx_activity_tag_activity_id ON public.activity_tag USING btree (activity_id, tag_id)
WHERE ((archived_at IS NULL) AND (activity_id IS NOT NULL));

CREATE INDEX idx_activity_tag_note_id ON public.activity_tag USING btree (note_id, tag_id)
WHERE ((archived_at IS NULL) AND (note_id IS NOT NULL));

ALTER TABLE "public"."note"
    ADD CONSTRAINT "note_pkey" PRIMARY KEY USING INDEX "note_pkey";

ALTER TABLE "public"."note"
    ADD CONSTRAINT "note_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES activity (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."note" validate CONSTRAINT "note_activity_id_fkey";

ALTER TABLE "public"."activity_read"
    ADD CONSTRAINT "activity_read_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES activity (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."activity_read" validate CONSTRAINT "activity_read_activity_id_fkey";

ALTER TABLE "public"."activity_read"
    ADD CONSTRAINT "activity_read_unique" UNIQUE USING INDEX "activity_read_unique";

ALTER TABLE "public"."activity_tag"
    ADD CONSTRAINT "activity_tag_note_id_fkey" FOREIGN KEY (note_id) REFERENCES note (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."activity_tag" validate CONSTRAINT "activity_tag_note_id_fkey";

ALTER TABLE "public"."activity_tag"
    ADD CONSTRAINT "activity_tag_actor_id_activity_id_note_id_occurrence_tag_id_key" UNIQUE USING INDEX "activity_tag_actor_id_activity_id_note_id_occurrence_tag_id_key";

ALTER TABLE "public"."activity_tag"
    ADD CONSTRAINT "activity_tag_check" CHECK ((((activity_id IS NOT NULL) AND (note_id IS NULL)) OR ((activity_id IS NULL) AND (note_id IS NOT NULL)))) NOT valid;

ALTER TABLE "public"."activity_tag" validate CONSTRAINT "activity_tag_check";

SET check_function_bodies = OFF;

CREATE OR REPLACE VIEW "public"."notes" AS
SELECT
    a.id AS activity_id,
    n.id AS note_id
FROM (activity a
    JOIN note n ON (n.activity_id = a.id));

CREATE OR REPLACE FUNCTION public.notes (p_activity_id uuid)
    RETURNS SETOF note
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN QUERY
    SELECT
        n.*
    FROM
        note n
    WHERE
        n.activity_id = p_activity_id
    ORDER BY
        n.created_at;
END;
$function$;

CREATE OR REPLACE VIEW "public"."activity_tags" AS
SELECT
    activity_id,
    note_id,
    occurrence,
    jsonb_object_agg(tag_id, actor_ids) FILTER (WHERE ((actor_ids IS NOT NULL)
    AND (jsonb_array_length(actor_ids) > 0))) AS tags,
max(updated_at) AS updated_at,
(array_agg(updated_by ORDER BY sq.updated_at DESC))[1] AS updated_by
FROM (
    SELECT
        at.activity_id,
        at.note_id,
        at.occurrence,
        at.tag_id,
        jsonb_agg(at.actor_id) FILTER (WHERE (at.archived_at IS NULL)) AS actor_ids,
    max(COALESCE(at.archived_at, at.updated_at)) AS updated_at,
    (array_agg(at.updated_by ORDER BY at.updated_at DESC))[1] AS updated_by
FROM
    activity_tag at
GROUP BY
    at.activity_id,
    at.note_id,
    at.occurrence,
    at.tag_id) sq
GROUP BY
    activity_id,
    note_id,
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

CREATE OR REPLACE FUNCTION public.propagate_note_mentions_to_activity ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    -- Skip if no mentions
    IF NEW.mentions IS NULL OR array_length(NEW.mentions, 1) IS NULL THEN
        RETURN NEW;
    END IF;
    -- Update parent activity with deduplicated mentions
    -- Silently skips if parent not found (UPDATE affects 0 rows)
    UPDATE
        public.activity
    SET
        mentions = ARRAY ( SELECT DISTINCT
                unnest(COALESCE(mentions, ARRAY[]::uuid[]) || NEW.mentions))
    WHERE
        id = NEW.activity_id
        AND archived_at IS NULL;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.upsert_activity (p_id uuid, p_user_id uuid, p_updated_by integer, p_archived_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_priority_id uuid DEFAULT NULL::uuid, p_draft boolean DEFAULT NULL::boolean, p_private boolean DEFAULT NULL::boolean, p_at tstzrange DEFAULT NULL::tstzrange, p_on daterange DEFAULT NULL::dateRANGE, p_duration interval DEFAULT NULL::interval, p_done_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_title text DEFAULT NULL::text, p_preview text DEFAULT NULL::text, p_order double precision DEFAULT NULL::double precision, p_recurrence_rule text DEFAULT NULL::text, p_recurrence_exdates timestamp with time zone[] DEFAULT NULL::timestamp with time zone[], p_recurrence_dates timestamp with time zone[] DEFAULT NULL::timestamp with time zone[], p_series uuid DEFAULT NULL::uuid, p_occurrence_start timestamp with time zone DEFAULT NULL::timestamp with time zone)
    RETURNS uuid
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    _activity_id uuid;
    _occurrence_root_id uuid;
    _occurrence_original_start timestamptz;
BEGIN
    -- Convert series field to occurrence_root_id
    _occurrence_root_id := p_series;
    _occurrence_original_start := p_occurrence_start;
    -- Check if this is an update to an existing activity
    IF p_id IS NOT NULL THEN
        SELECT
            id INTO _activity_id
        FROM
            activity
        WHERE
            id = p_id;
    END IF;
    -- If updating a synthetic recurrence instance (generated ID), create a new exception record
    IF _activity_id IS NULL AND _occurrence_root_id IS NOT NULL AND _occurrence_original_start IS NOT NULL THEN
        -- This is a new exception for a recurring activity
        _activity_id := gen_random_uuid_v7 ();
        -- Insert new exception activity
        INSERT INTO activity (id, updated_by, archived_at, priority_id, draft, private, at, "on", duration, done_at, title, preview, "order", recurrence_rule, recurrence_exdates, recurrence_dates, occurrence_root_id, occurrence_original_start)
            VALUES (_activity_id, p_updated_by, p_archived_at, COALESCE(p_priority_id, (
                        SELECT
                            priority_id
                        FROM activity
                        WHERE
                            id = _occurrence_root_id)),
                COALESCE(p_draft, FALSE),
                COALESCE(p_private, FALSE),
                p_at,
                p_on,
                p_duration,
                p_done_at,
                p_title,
                p_preview,
                p_order,
                NULL, -- Exceptions don't have their own recurrence rules
                NULL,
                NULL,
                _occurrence_root_id,
                _occurrence_original_start);
        RETURN _activity_id;
    END IF;
    -- Standard upsert for regular activities or existing exception records
    INSERT INTO activity (id, updated_by, archived_at, priority_id, draft, private, at, "on", duration, done_at, title, preview, "order", recurrence_rule, recurrence_exdates, recurrence_dates, occurrence_root_id, occurrence_original_start)
        VALUES (COALESCE(p_id, gen_random_uuid_v7 ()), p_updated_by, p_archived_at, p_priority_id, COALESCE(p_draft, FALSE), COALESCE(p_private, FALSE), p_at, p_on, p_duration, p_done_at, p_title, p_preview, COALESCE(p_order, public.order_first ()), p_recurrence_rule, p_recurrence_exdates, p_recurrence_dates, _occurrence_root_id, _occurrence_original_start)
    ON CONFLICT (id)
        DO UPDATE SET
            updated_by = EXCLUDED.updated_by,
            updated_at = now(),
            archived_at = COALESCE(EXCLUDED.archived_at, activity.archived_at),
            priority_id = COALESCE(EXCLUDED.priority_id, activity.priority_id),
            draft = COALESCE(EXCLUDED.draft, activity.draft),
            private = COALESCE(EXCLUDED.private, activity.private),
            at = COALESCE(EXCLUDED.at, activity.at),
            "on" = COALESCE(EXCLUDED.on, activity.on),
            duration = COALESCE(EXCLUDED.duration, activity.duration),
            done_at = COALESCE(EXCLUDED.done_at, activity.done_at),
            title = COALESCE(EXCLUDED.title, activity.title),
            preview = COALESCE(EXCLUDED.preview, activity.preview),
            "order" = COALESCE(EXCLUDED."order", activity."order"),
            recurrence_rule = COALESCE(EXCLUDED.recurrence_rule, activity.recurrence_rule),
            recurrence_exdates = COALESCE(EXCLUDED.recurrence_exdates, activity.recurrence_exdates),
            recurrence_dates = COALESCE(EXCLUDED.recurrence_dates, activity.recurrence_dates)
        RETURNING
            id INTO _activity_id;
    RETURN _activity_id;
END;
$function$;

CREATE OR REPLACE VIEW "public"."user_priority_base" AS
SELECT
    pu.user_id,
    p.id,
    p.created_at,
    GREATEST (settings.updated_at, pu.updated_at, p.updated_at, COALESCE(activity_max.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone), COALESCE(ar_max.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
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
    inherited_settings.color
FROM (((((((priority_user pu
                            JOIN priority root ON (pu.priority_id = root.id))
                        JOIN priority user_root ON (((pu.user_id = user_root.created_by)
                                    AND user_root.root)))
                    JOIN priority p ON (root.path @> p.path))
                LEFT JOIN priority_settings settings ON (((settings.user_id = pu.user_id)
                            AND (p.id = settings.priority_id))))
            LEFT JOIN priority_settings_inherited inherited_settings ON (((inherited_settings.user_id = pu.user_id)
                        AND (p.id = inherited_settings.priority_id))))
        LEFT JOIN LATERAL (
            SELECT
                max(a.updated_at) AS updated_at
            FROM (activity a
                JOIN priority ap ON (ap.id = a.priority_id))
        WHERE ((ap.path <@ p.path)
            AND (a.archived_at IS NULL))) activity_max ON (TRUE))
    LEFT JOIN LATERAL (
        SELECT
            max(ar.updated_at) AS updated_at
        FROM (activity_read ar
            JOIN priority ap ON (ap.id = ar.activity_id))
    WHERE ((ar.user_id = pu.user_id)
        AND (ap.path <@ p.path))) ar_max ON (TRUE))
WHERE (pu.archived_at IS NULL);

CREATE OR REPLACE VIEW "public"."priority_active_actions" AS
SELECT
    upb.user_id,
    upb.id AS priority_id,
    COALESCE(active_check.active, FALSE) AS active_actions,
    next_action.next_at,
    next_action.next_on
FROM ((user_priority_base upb
    LEFT JOIN LATERAL (
        SELECT
            TRUE AS active
        FROM
            activity a
        WHERE ((a.priority_id = upb.id)
            AND (a.archived_at IS NULL)
            AND (a.type = 'action'::activity_type)
            AND (a.done_at IS NULL)
            AND (((a.at IS NOT NULL)
                    AND (lower(a.at) < now()))
                OR ((a."on" IS NOT NULL)
                    AND (lower(a."on") < CURRENT_DATE))))
    LIMIT 1) active_check ON (TRUE))
    LEFT JOIN LATERAL (
        SELECT
            min(lower(a.at)) FILTER (WHERE ((a.at IS NOT NULL)
                AND (lower(a.at) >= now()))) AS next_at,
    min(lower(a."on")) FILTER (WHERE ((a."on" IS NOT NULL)
    AND (lower(a."on") >= CURRENT_DATE))) AS next_on
FROM
    activity a
WHERE ((a.priority_id = upb.id)
    AND (a.archived_at IS NULL)
    AND (a.type = 'action'::activity_type)
    AND (a.done_at IS NULL))) next_action ON (TRUE));

CREATE OR REPLACE VIEW "public"."priority_unread" AS
SELECT
    upb.user_id,
    upb.id AS priority_id,
    COALESCE(unread_check.unread, FALSE) AS unread
FROM ((user_priority_base upb
    LEFT JOIN contact c ON (c.user_id = upb.user_id))
    LEFT JOIN LATERAL (
        SELECT
            TRUE AS unread
        FROM (activity a
            LEFT JOIN activity_read ar ON (((ar.user_id = upb.user_id)
                        AND (ar.activity_id = a.id))))
    WHERE ((a.priority_id = upb.id)
        AND (a.archived_at IS NULL)
        AND (a.draft = FALSE)
        AND (((a.author_id <> c.id)
                AND (ar.read_at IS NULL))
            OR (EXISTS (
                    SELECT
                        1
                    FROM
                        note n
                    WHERE ((n.activity_id = a.id)
                        AND (n.archived_at IS NULL)
                        AND (n.author_id <> c.id)
                        AND ((ar.read_at IS NULL)
                            OR (n.created_at > ar.read_at)))))))
LIMIT 1) unread_check ON (TRUE));

CREATE OR REPLACE VIEW "public"."user_priority" AS
SELECT
    upb.user_id,
    upb.id,
    upb.created_at,
    upb.updated_at,
    upb.archived_at,
    upb.created_by,
    upb.updated_by,
    upb.root,
    upb.title,
    upb.path,
    upb.top_order,
    upb.pomodoro,
    upb.color,
    COALESCE(pu.unread, FALSE) AS unread,
    COALESCE(paa.active_actions, FALSE) AS active_actions,
    paa.next_at AS next_action_at,
    paa.next_on AS next_action_on
FROM ((user_priority_base upb
    LEFT JOIN priority_unread pu ON (((pu.user_id = upb.user_id)
                AND (pu.priority_id = upb.id))))
    LEFT JOIN priority_active_actions paa ON (((paa.user_id = upb.user_id)
                AND (paa.priority_id = upb.id))));

CREATE OR REPLACE VIEW "public"."user_activity_unread" AS
SELECT
    up.user_id,
    a.id AS activity_id,
    (unread.updated_at IS NOT NULL) AS unread,
    COALESCE(ar.updated_at, unread.updated_at) AS updated_at
FROM ((((user_priority up
                JOIN contact c ON (c.user_id = up.user_id))
            JOIN activity a ON (a.priority_id = up.id))
        LEFT JOIN activity_read ar ON (((ar.user_id = up.user_id)
                    AND (ar.activity_id = a.id))))
    LEFT JOIN LATERAL (
        SELECT
            max(GREATEST (a.updated_at, n.updated_at)) AS updated_at
        FROM
            note n
        WHERE ((n.activity_id = a.id)
            AND (n.archived_at IS NULL)
            AND (n.author_id <> c.id)
            AND ((ar.read_at IS NULL)
                OR (n.created_at > ar.read_at)))) unread ON (TRUE))
WHERE (up.archived_at IS NULL);

CREATE OR REPLACE VIEW "public"."user_activity" AS
SELECT
    up.user_id,
    a.id,
    a.created_at,
    COALESCE(uau.updated_at, a.updated_at) AS updated_at,
    a.author_id,
    a.updated_by,
    a.archived_at,
    a.priority_id,
    p.path AS priority_path,
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
    a.mentions,
    CASE WHEN (a.done_at IS NOT NULL) THEN
        tstzrange(a.done_at, a.done_at, '[]'::text)
    WHEN (a.at IS NOT NULL) THEN
        a.at
    WHEN (a."on" IS NOT NULL) THEN
        NULL::tstzrange
    ELSE
        tstzrange(a.created_at, a.created_at, '[]'::text)
    END AS range_at,
    CASE WHEN (a.done_at IS NOT NULL) THEN
        NULL::daterange
    WHEN (a.at IS NOT NULL) THEN
        NULL::daterange
    WHEN (a."on" IS NOT NULL) THEN
        a."on"
    ELSE
        NULL::daterange
    END AS range_on,
    COALESCE(uau.unread, FALSE) AS unread
FROM (((activity a
            JOIN priority p ON (p.id = a.priority_id))
        JOIN user_priority up ON (a.priority_id = up.id))
    LEFT JOIN user_activity_unread uau ON (((uau.user_id = up.user_id)
                AND (uau.activity_id = a.id))))
WHERE (up.archived_at IS NULL);

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

CREATE OR REPLACE VIEW "public"."user_activity_exception" AS
SELECT
    ua.user_id,
    ua.id,
    ae.occurrence,
    ae.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    CASE WHEN (ae.archived_at IS NULL) THEN
        ae.at
    ELSE
        NULL::tstzrange
    END AS at,
    CASE WHEN (ae.archived_at IS NULL) THEN
        ae."on"
    ELSE
        NULL::daterange
    END AS "on",
    CASE WHEN (ae.archived_at IS NULL) THEN
        ae.title
    ELSE
        NULL::text
    END AS title,
    CASE WHEN (ae.archived_at IS NULL) THEN
        ae.note
    ELSE
        NULL::text
    END AS note
FROM (activity_exception ae
    JOIN user_activity ua ON (ua.id = ae.activity_id));

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

CREATE TRIGGER note_propagate_mentions_to_activity
    AFTER INSERT OR UPDATE OF mentions ON public.note
    FOR EACH ROW
    EXECUTE FUNCTION propagate_note_mentions_to_activity ();

CREATE TRIGGER set_note_author_and_created_by
    BEFORE INSERT ON public.note
    FOR EACH ROW
    EXECUTE FUNCTION update_author_and_created_by ();

CREATE TRIGGER set_note_updated_at
    BEFORE UPDATE ON public.note
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER upsert_user_priority
    INSTEAD OF INSERT OR UPDATE ON public.user_priority
    FOR EACH ROW
    EXECUTE FUNCTION handle_user_priority_upsert ();

CREATE OR REPLACE FUNCTION public.actor (note)
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

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_note ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    event_type text;
    twists_data jsonb;
    users_data jsonb;
    enriched_item jsonb;
    previous_enriched_item jsonb;
    current_tags jsonb;
    previous_tags jsonb;
    payload jsonb;
    api_url text;
    hmac_secret text;
    signature text;
    current_item record;
    previous_item record;
    parent_priority_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        event_type := 'created';
        current_item := NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        event_type := 'updated';
        current_item := NEW;
        previous_item := OLD;
    ELSIF TG_OP = 'DELETE' THEN
        event_type := 'deleted';
        current_item := OLD;
    END IF;
    -- Get the parent activity's priority_id
    SELECT
        priority_id INTO parent_priority_id
    FROM
        activity
    WHERE
        id = current_item.activity_id;
    -- Exit early if parent activity not found
    IF parent_priority_id IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    -- Extract twists query into a variable
    SELECT
        jsonb_agg(jsonb_build_object('id', twist_id, 'environment', twist_environment, 'version', version, 'priority_twist_id', id, 'config', config)) INTO twists_data
    FROM
        priority_child_twist
    WHERE
        priority_child_id = parent_priority_id
        AND id != current_item.author_id
        AND archived_at IS NULL;
    -- Get users who have access to this priority
    SELECT
        jsonb_agg(jsonb_build_object('user_id', user_id)) INTO users_data
    FROM
        public.get_users_with_priority_access (parent_priority_id);
    -- Exit early if no twists or users found
    IF (twists_data IS NULL OR jsonb_array_length(twists_data) = 0) AND (users_data IS NULL OR jsonb_array_length(users_data) = 0) THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    -- Build enriched item with author and activity information
    SELECT
        jsonb_build_object('id', current_item.id, 'created_at', current_item.created_at, 'updated_at', current_item.updated_at, 'author_id', current_item.author_id, 'created_by', current_item.created_by, 'updated_by', current_item.updated_by, 'archived_at', current_item.archived_at, 'activity_id', current_item.activity_id, 'draft', current_item.draft, 'private', current_item.private, 'note', current_item.note, 'links', current_item.links, 'mentions', current_item.mentions,
            -- Enriched data from JOINs
            'author_name', a.name, 'author_type', a.type, 'activity_title', act.title) INTO enriched_item
    FROM
        actor a,
        activity act
    WHERE
        a.id = current_item.author_id
        AND act.id = current_item.activity_id;
    -- Get tags for current note
    SELECT
        tags INTO current_tags
    FROM
        activity_tags
    WHERE
        note_id = current_item.id;
    -- Add tags to enriched item
    enriched_item := enriched_item || jsonb_build_object('tags', current_tags);
    -- Build previous enriched item for updates
    IF TG_OP = 'UPDATE' THEN
        SELECT
            jsonb_build_object('id', previous_item.id, 'created_at', previous_item.created_at, 'updated_at', previous_item.updated_at, 'author_id', previous_item.author_id, 'created_by', previous_item.created_by, 'updated_by', previous_item.updated_by, 'archived_at', previous_item.archived_at, 'activity_id', previous_item.activity_id, 'draft', previous_item.draft, 'private', previous_item.private, 'note', previous_item.note, 'links', previous_item.links, 'mentions', previous_item.mentions,
                -- Enriched data from JOINs
                'author_name', a.name, 'author_type', a.type, 'activity_title', act.title) INTO previous_enriched_item
        FROM
            actor a,
            activity act
        WHERE
            a.id = previous_item.author_id
            AND act.id = previous_item.activity_id;
        -- Get tags for previous note state
        SELECT
            tags INTO previous_tags
        FROM
            activity_tags
        WHERE
            note_id = previous_item.id;
        -- Add tags to previous enriched item
        previous_enriched_item := previous_enriched_item || jsonb_build_object('tags', previous_tags);
    END IF;
    -- Build the payload
    IF TG_OP = 'UPDATE' THEN
        payload := jsonb_build_object('type', 'note', 'event', event_type, 'item', enriched_item, 'previous', previous_enriched_item, 'twists', COALESCE(twists_data, '[]'::jsonb), 'users', COALESCE(users_data, '[]'::jsonb), 'timestamp', extract(epoch FROM now()), 'table', 'note');
    ELSE
        payload := jsonb_build_object('type', 'note', 'event', event_type, 'item', enriched_item, 'twists', COALESCE(twists_data, '[]'::jsonb), 'users', COALESCE(users_data, '[]'::jsonb), 'timestamp', extract(epoch FROM now()), 'table', 'note');
    END IF;
    api_url := get_api_root () || '/update';
    hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
    signature := encode(extensions.hmac(convert_to(payload::text, 'UTF8'), hmac_secret::bytea, 'sha256'), 'hex');
    PERFORM
        net.http_post (url := api_url, body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_activity ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    event_type text;
    twists_data jsonb;
    users_data jsonb;
    enriched_item jsonb;
    previous_enriched_item jsonb;
    current_tags jsonb;
    previous_tags jsonb;
    payload jsonb;
    api_url text;
    hmac_secret text;
    signature text;
    current_item record;
    previous_item record;
BEGIN
    IF TG_OP = 'INSERT' THEN
        event_type := 'created';
        current_item := NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        event_type := 'updated';
        current_item := NEW;
        previous_item := OLD;
    ELSIF TG_OP = 'DELETE' THEN
        event_type := 'deleted';
        current_item := OLD;
    END IF;
    -- Extract twists query into a variable
    SELECT
        jsonb_agg(jsonb_build_object('id', twist_id, 'environment', twist_environment, 'version', version, 'priority_twist_id', id, 'config', config)) INTO twists_data
    FROM
        priority_child_twist
    WHERE
        priority_child_id = current_item.priority_id
        AND id != current_item.author_id
        AND archived_at IS NULL;
    -- Get users who have access to this priority
    SELECT
        jsonb_agg(jsonb_build_object('user_id', user_id)) INTO users_data
    FROM
        public.get_users_with_priority_access (current_item.priority_id);
    -- Exit early if no twists or users found
    IF (twists_data IS NULL OR jsonb_array_length(twists_data) = 0) AND (users_data IS NULL OR jsonb_array_length(users_data) = 0) THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    -- Build enriched item with author and priority information
    SELECT
        jsonb_build_object('id', current_item.id, 'created_at', current_item.created_at, 'updated_at', current_item.updated_at, 'author_id', current_item.author_id, 'created_by', current_item.created_by, 'assignee_id', current_item.assignee_id, 'updated_by', current_item.updated_by, 'archived_at', current_item.archived_at, 'priority_id', current_item.priority_id, 'type', current_item.type, 'order', current_item.order, 'draft', current_item.draft, 'private', current_item.private, 'title', current_item.title, 'preview', current_item.preview, 'at', current_item.at, 'on', current_item.on, 'duration', current_item.duration, 'done_at', current_item.done_at, 'recurrence_rule', current_item.recurrence_rule, 'recurrence_exdates', current_item.recurrence_exdates, 'recurrence_dates', current_item.recurrence_dates, 'meta', current_item.meta, 'mentions', current_item.mentions,
            -- Enriched data from JOINs
            'author_name', a.name, 'author_type', a.type, 'priority_title', p.title) INTO enriched_item
    FROM
        actor a,
        priority p
    WHERE
        a.id = current_item.author_id
        AND p.id = current_item.priority_id;
    -- Get tags for current activity
    SELECT
        tags INTO current_tags
    FROM
        activity_tags
    WHERE
        activity_id = current_item.id;
    -- Add tags to enriched item
    enriched_item := enriched_item || jsonb_build_object('tags', current_tags);
    -- Build previous enriched item for updates
    IF TG_OP = 'UPDATE' THEN
        SELECT
            jsonb_build_object('id', previous_item.id, 'created_at', previous_item.created_at, 'updated_at', previous_item.updated_at, 'author_id', previous_item.author_id, 'created_by', previous_item.created_by, 'assignee_id', previous_item.assignee_id, 'updated_by', previous_item.updated_by, 'archived_at', previous_item.archived_at, 'priority_id', previous_item.priority_id, 'type', previous_item.type, 'order', previous_item.order, 'draft', previous_item.draft, 'private', previous_item.private, 'title', previous_item.title, 'preview', previous_item.preview, 'at', previous_item.at, 'on', previous_item.on, 'duration', previous_item.duration, 'done_at', previous_item.done_at, 'recurrence_rule', previous_item.recurrence_rule, 'recurrence_exdates', previous_item.recurrence_exdates, 'recurrence_dates', previous_item.recurrence_dates, 'meta', previous_item.meta, 'mentions', previous_item.mentions,
                -- Enriched data from JOINs
                'author_name', a.name, 'author_type', a.type, 'priority_title', p.title) INTO previous_enriched_item
        FROM
            actor a,
            priority p
        WHERE
            a.id = previous_item.author_id
            AND p.id = previous_item.priority_id;
        -- Get tags for previous activity state
        SELECT
            tags INTO previous_tags
        FROM
            activity_tags
        WHERE
            activity_id = previous_item.id;
        -- Add tags to previous enriched item
        previous_enriched_item := previous_enriched_item || jsonb_build_object('tags', previous_tags);
    END IF;
    -- Build the payload
    IF TG_OP = 'UPDATE' THEN
        payload := jsonb_build_object('type', 'activity', 'event', event_type, 'item', enriched_item, 'previous', previous_enriched_item, 'twists', COALESCE(twists_data, '[]'::jsonb), 'users', COALESCE(users_data, '[]'::jsonb), 'timestamp', extract(epoch FROM now()), 'table', 'activity');
    ELSE
        payload := jsonb_build_object('type', 'activity', 'event', event_type, 'item', enriched_item, 'twists', COALESCE(twists_data, '[]'::jsonb), 'users', COALESCE(users_data, '[]'::jsonb), 'timestamp', extract(epoch FROM now()), 'table', 'activity');
    END IF;
    api_url := get_api_root () || '/update';
    hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
    signature := encode(extensions.hmac(convert_to(payload::text, 'UTF8'), hmac_secret::bytea, 'sha256'), 'hex');
    PERFORM
        net.http_post (url := api_url, body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE TRIGGER note_change_api_call
    AFTER INSERT OR UPDATE ON public.note
    FOR EACH ROW
    EXECUTE FUNCTION notify_internal_api_for_note ();

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

