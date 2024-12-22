DROP VIEW IF EXISTS "public"."note_x";

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.handle_note_x_upsert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    INSERT INTO note (user_id, id, draft, archived_at, activity_id, topic_id, body, root, pinned, "order", ordered_at, private, do_at, done_at)
        VALUES (auth.uid (), NEW.id, NEW.draft, NEW.archived_at, NEW.activity_id, NEW.topic_id, NEW.body, NEW.root, NEW.pinned, NEW."order", NEW.ordered_at, NEW.private, NEW.do_at, NEW.done_at)
    ON CONFLICT (id)
        DO UPDATE SET
            draft = NEW.draft, archived_at = NEW.archived_at, activity_id = NEW.activity_id, topic_id = NEW.topic_id, body = NEW.body, root = NEW.root, pinned = NEW.pinned, "order" = NEW."order", ordered_at = NEW.ordered_at, private = NEW.private, do_at = NEW.do_at, done_at = NEW.done_at;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE VIEW "public"."note_x" AS
SELECT
    note.id,
    note.created_at,
    note.updated_at,
    note.draft,
    note.archived_at,
    note.user_id,
    note.activity_id,
    note.topic_id,
    note.body,
    note.root,
    note.pinned,
    note."order",
    note.ordered_at,
    note.private,
    note.do_at,
    note.done_at,
    activity.path AS activity_path,
    CASE WHEN (note.pinned = TRUE) THEN
        note."order"
    WHEN (note.do_at <= now()) THEN
        ((('100000000000000'::numeric + (EXTRACT(epoch FROM note.do_at) * '1000'::numeric)))::double precision + (note."order" / ('10000000'::numeric)::double precision))
    ELSE
        (('200000000000000'::numeric)::double precision + note."order")
    END AS order_x,
    COALESCE(jsonb_object_agg(tag_users.emoji, tag_users.user_ids) FILTER (WHERE (tag_users.emoji IS NOT NULL)), '{}'::jsonb) AS tags
FROM ((note
    LEFT JOIN activity ON (note.activity_id = activity.id))
    LEFT JOIN (
        SELECT
            tag.note_id,
            tag.emoji,
            array_agg(tag.user_id ORDER BY tag.user_id) AS user_ids
        FROM
            tag
        GROUP BY
            tag.note_id,
            tag.emoji) tag_users ON (note.id = tag_users.note_id))
GROUP BY
    note.id,
    activity.path;

CREATE TRIGGER upsert_note_x
    INSTEAD OF INSERT OR UPDATE ON public.note_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_note_x_upsert ();

ALTER VIEW note_x SET ( security_invoker = TRUE);
ALTER VIEW gap SET ( security_invoker = TRUE);
ALTER VIEW gap_monthly SET ( security_invoker = TRUE);
ALTER VIEW gap_daily SET ( security_invoker = TRUE);
ALTER VIEW insight SET ( security_invoker = TRUE);
-- ALTER VIEW insight_weekly SET ( security_invoker = TRUE);
ALTER VIEW "public"."invitation_admin" SET ( security_invoker = FALSE);
ALTER VIEW "public"."event_invitees" SET ( security_invoker = TRUE);
ALTER VIEW "public"."event_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."waitlist_admin" SET ( security_invoker = FALSE);
ALTER VIEW "public"."activity_x" SET ( security_invoker = TRUE);
ALTER VIEW balance SET ( security_invoker = TRUE);
ALTER VIEW "public"."sync_admin" SET ( security_invoker = FALSE);
