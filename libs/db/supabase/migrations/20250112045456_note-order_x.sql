DROP TRIGGER IF EXISTS "upsert_note_x" ON "public"."note_x";

DROP VIEW IF EXISTS "public"."note_x";

ALTER TABLE "public"."note"
    ALTER COLUMN "activity_id" SET NOT NULL;

CREATE OR REPLACE VIEW "public"."note_x" AS
SELECT
    note.id,
    note.created_at,
    note.updated_at,
    note.deleted_at,
    note.draft,
    note.user_id,
    note.activity_id,
    note.body,
    note.pinned,
    note."order",
    note.ordered_at,
    note.private,
    CASE WHEN (note.pinned = TRUE) THEN
        (('100000000000000'::numeric)::double precision + note."order")
    ELSE
        note."order"
    END AS order_x,
    COALESCE(jsonb_object_agg(tag_users.emoji, tag_users.user_ids) FILTER (WHERE (tag_users.emoji IS NOT NULL)), '{}'::jsonb) AS tags
FROM (note
    LEFT JOIN (
        SELECT
            tag.item_id,
            tag.emoji,
            array_agg(tag.user_id ORDER BY tag.user_id) AS user_ids
        FROM
            tag
        WHERE (tag.item_type = 'note'::item_type)
    GROUP BY
        tag.item_id,
        tag.emoji) tag_users ON (note.id = tag_users.item_id))
GROUP BY
    note.id;

CREATE TRIGGER upsert_note_x
    INSTEAD OF INSERT OR UPDATE ON public.note_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_note_x_upsert ();

ALTER VIEW note_x SET ( security_invoker = TRUE);
ALTER VIEW gap SET ( security_invoker = TRUE);
ALTER VIEW gap_monthly SET ( security_invoker = TRUE);
ALTER VIEW gap_daily SET ( security_invoker = TRUE);
ALTER VIEW insight SET ( security_invoker = TRUE);
ALTER VIEW "admin"."sync" SET ( security_invoker = FALSE);
ALTER VIEW "admin"."invitation" SET ( security_invoker = FALSE);
ALTER VIEW activity_x SET ( security_invoker = TRUE);
ALTER VIEW "public"."event_invitees" SET ( security_invoker = TRUE);
ALTER VIEW "public"."event_x" SET ( security_invoker = TRUE);
ALTER VIEW "admin"."user" SET ( security_invoker = FALSE);
ALTER VIEW balance_without_children SET ( security_invoker = TRUE);
ALTER VIEW balance SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_children" SET ( security_invoker = TRUE);
