DROP VIEW IF EXISTS "public"."note_x";

ALTER TABLE "public"."note"
    ADD COLUMN "do_at" timestamp with time zone;

ALTER TABLE "public"."note"
    ADD COLUMN "done_at" timestamp with time zone;

ALTER TABLE "public"."note"
    ADD COLUMN "ordered_at" timestamp with time zone NOT NULL DEFAULT now();

ALTER TABLE "public"."note"
    ADD COLUMN "pinned" boolean NOT NULL DEFAULT FALSE;

CREATE OR REPLACE VIEW "public"."note_x" AS
SELECT
    note.id,
    note.created_at,
    note.updated_at,
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

ALTER VIEW note_x SET (security_invoker = TRUE);

