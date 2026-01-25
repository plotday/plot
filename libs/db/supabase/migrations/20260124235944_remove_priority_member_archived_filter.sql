CREATE OR REPLACE VIEW "public"."priority_member" AS
SELECT
    pc.contact_id,
    pc.priority_id,
    pc.created_at,
    GREATEST (pc.created_at, COALESCE(pu.updated_at, pc.created_at)) AS updated_at,
    COALESCE(pc.archived_at, pu.archived_at) AS archived_at,
    CASE WHEN ((c.user_id IS NOT NULL)
        AND (pu.user_id IS NOT NULL)) THEN
        'accepted'::text
    ELSE
        'invited'::text
    END AS status,
    pc.invited_by,
    COALESCE(pu.personal, FALSE) AS personal
FROM ((priority_contact pc
        JOIN contact c ON (c.id = pc.contact_id))
    LEFT JOIN priority_user pu ON (((pu.user_id = c.user_id)
                AND (pu.priority_id = pc.priority_id)
                AND (pu.archived_at IS NULL))))
WHERE ((pu.user_id IS NOT NULL)
    OR (pc.invited_by IS NOT NULL));

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
ALTER VIEW public.priority_member SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);
