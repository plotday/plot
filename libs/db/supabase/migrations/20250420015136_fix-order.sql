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
        (('400000000000000'::numeric)::double precision - activity."order")
    WHEN (activity.do_at <= now()) THEN
        ((('200000000000000'::numeric - (EXTRACT(epoch FROM activity.do_at) * '1000'::numeric)))::double precision - (activity."order" / ('10000000'::numeric)::double precision))
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
