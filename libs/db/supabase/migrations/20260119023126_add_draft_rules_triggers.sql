SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.enforce_draft_rules ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    -- Prevent unpublishing: draft cannot go from false to true
    IF OLD.draft = FALSE AND NEW.draft = TRUE THEN
        RAISE EXCEPTION 'Cannot change draft from false to true';
    END IF;
    -- Update created_at when publishing (draft: true -> false)
    IF OLD.draft = TRUE AND NEW.draft = FALSE THEN
        NEW.created_at = now();
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE VIEW "public"."priority_twist_activity_create" AS
SELECT
    ax.created_by AS priority_twist_id,
    ax.id,
    ax.created_at,
    ax.updated_at,
    ax.source_created_at,
    ax.author_id,
    ax.created_by,
    ax.assignee_id,
    ax.updated_by,
    ax.sync_depth,
    ax.archived_at,
    ax.priority_id,
    ax.type,
    ax."order",
    ax.draft,
    ax.private,
    ax.title,
    ax.preview,
    ax.at,
    ax."on",
    ax.duration,
    ax.done_at,
    ax.recurrence_rule,
    ax.recurrence_exdates,
    ax.source,
    ax.meta,
    ax.mentions,
    author.name AS author_name,
    author.type AS author_type,
    p.title AS priority_title,
    at.tags
FROM ((((priority_child_twist pct
                JOIN activity_x ax ON (ax.priority_id = pct.priority_child_id))
            LEFT JOIN actor author ON (author.id = ax.author_id))
        LEFT JOIN priority p ON (p.id = ax.priority_id))
    LEFT JOIN activity_tags at ON (((at.activity_id = ax.id)
                AND (at.occurrence IS NULL))))
WHERE ((ax.draft = FALSE)
    AND (pct.id <> ax.created_by)
    AND (ax.archived_at IS NULL)
    AND (pct.archived_at IS NULL)
    AND (ax.created_at > pct.created_at))
ORDER BY
    ax.created_at;

CREATE OR REPLACE FUNCTION public.updated_by_uuid (id uuid)
    RETURNS numeric
    LANGUAGE sql
    IMMUTABLE
    AS $function$
    SELECT
        CASE WHEN ('x' ||
        RIGHT (REPLACE(id::text, '-', ''),
            16))::bit(64)::bigint < 0 THEN
            (('x' ||
                RIGHT (REPLACE(id::text, '-', ''),
                    16))::bit(64)::bigint::numeric + 18446744073709551616::numeric) % 2147483647
        ELSE
            ('x' ||
            RIGHT (REPLACE(id::text, '-', ''),
                16))::bit(64)::bigint::numeric % 2147483647
        END
$function$;

CREATE OR REPLACE VIEW "public"."priority_twist_activity_update" AS
SELECT
    ax.created_by AS priority_twist_id,
    ax.id,
    ax.created_at,
    GREATEST (ax.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    ax.source_created_at,
    ax.author_id,
    ax.created_by,
    ax.assignee_id,
    ax.updated_by,
    ax.sync_depth,
    ax.archived_at,
    ax.priority_id,
    ax.type,
    ax."order",
    ax.draft,
    ax.private,
    ax.title,
    ax.preview,
    ax.at,
    ax."on",
    ax.duration,
    ax.done_at,
    ax.recurrence_rule,
    ax.recurrence_exdates,
    ax.source,
    ax.meta,
    ax.mentions,
    author.name AS author_name,
    author.type AS author_type,
    p.title AS priority_title,
    at.tags
FROM ((((priority_child_twist pct
                JOIN activity_x ax ON (ax.priority_id = pct.priority_child_id))
            LEFT JOIN actor author ON (author.id = ax.author_id))
        LEFT JOIN priority p ON (p.id = ax.priority_id))
    LEFT JOIN activity_tags at ON (((at.activity_id = ax.id)
                AND (at.occurrence IS NULL))))
WHERE ((ax.draft = FALSE)
    AND (updated_by_uuid (pct.id) <> (ax.updated_by)::numeric)
    AND (pct.archived_at IS NULL)
    AND (ax.updated_at > pct.created_at))
ORDER BY
    ax.updated_at;

CREATE OR REPLACE VIEW "public"."priority_twist_note_create" AS
SELECT
    pct.id AS priority_twist_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.sync_depth,
    n.archived_at,
    n.activity_id,
    n.draft,
    n.private,
    n.content,
    n.links,
    n.key,
    n.mentions,
    ax.priority_id,
    ax.title AS activity_title,
    ax.created_by AS activity_created_by,
    ax.meta AS activity_meta,
    ax.mentions AS activity_mentions,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags,
    fm.first_mentioned_at
FROM (((((priority_child_twist pct
                    JOIN activity_x ax ON (ax.priority_id = pct.priority_child_id))
                JOIN note n ON (n.activity_id = ax.id))
            LEFT JOIN actor author ON (author.id = n.author_id))
        LEFT JOIN note_tags nt ON (nt.note_id = n.id))
    LEFT JOIN LATERAL (
        SELECT
            min(note.created_at) AS first_mentioned_at
        FROM
            note
        WHERE ((note.activity_id = ax.id)
            AND (pct.id = ANY (note.mentions))
            AND (note.archived_at IS NULL))) fm ON (TRUE))
WHERE ((n.draft = FALSE)
    AND (updated_by_uuid (pct.id) <> (n.updated_by)::numeric)
    AND (ax.archived_at IS NULL)
    AND (pct.archived_at IS NULL)
    AND (n.created_at > pct.created_at)
    AND ((ax.created_by = pct.id)
        OR ((fm.first_mentioned_at IS NOT NULL)
            AND (n.created_at >= fm.first_mentioned_at))))
ORDER BY
    n.created_at;

CREATE OR REPLACE VIEW "public"."priority_twist_note_update" AS
SELECT
    n.created_by AS priority_twist_id,
    n.id,
    n.created_at,
    GREATEST (n.updated_at, COALESCE(nt.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.sync_depth,
    n.archived_at,
    n.activity_id,
    n.draft,
    n.private,
    n.content,
    n.links,
    n.key,
    n.mentions,
    ax.priority_id,
    ax.title AS activity_title,
    ax.created_by AS activity_created_by,
    ax.meta AS activity_meta,
    ax.mentions AS activity_mentions,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
FROM ((((priority_child_twist pct
                JOIN activity_x ax ON (ax.priority_id = pct.priority_child_id))
            JOIN note n ON (ax.id = n.activity_id))
        LEFT JOIN actor author ON (author.id = n.author_id))
    LEFT JOIN note_tags nt ON (nt.note_id = n.id))
WHERE ((n.draft = FALSE)
    AND (updated_by_uuid (pct.id) <> (n.updated_by)::numeric)
    AND (ax.archived_at IS NULL)
    AND (pct.archived_at IS NULL)
    AND (n.updated_at > pct.created_at))
ORDER BY
    n.updated_at;

CREATE TRIGGER enforce_activity_draft_rules_trigger
    BEFORE UPDATE ON public.activity
    FOR EACH ROW
    WHEN ((old.draft IS DISTINCT FROM new.draft))
    EXECUTE FUNCTION enforce_draft_rules ();

CREATE TRIGGER enforce_note_draft_rules_trigger
    BEFORE UPDATE ON public.note
    FOR EACH ROW
    WHEN ((old.draft IS DISTINCT FROM new.draft))
    EXECUTE FUNCTION enforce_draft_rules ();

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
ALTER VIEW "public"."priority_twist_activity_update" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_note_create" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_activity_create" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_note_update" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_expanded" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_activity_tag_change" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);
