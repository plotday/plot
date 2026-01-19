SET check_function_bodies = OFF;

-- Fix typo in user_activity_unread view (upt -> upe)
CREATE OR REPLACE VIEW "public"."user_activity_unread" WITH ( security_invoker = TRUE
) AS
SELECT
    upe.user_id,
    a.id AS activity_id,
    ar.read_at IS NULL AS unread,
    GREATEST (
        COALESCE(
            ar.updated_at, 'epoch'
), CASE WHEN a.created_by = upe.user_id THEN
            COALESCE(
                a.last_note_created_at, 'epoch'
)
        ELSE
            COALESCE(
                a.last_note_created_at, a.created_at
)
        END
) AS updated_at
FROM
    -- All the user's priorities
    user_priority_expanded upe
    -- All non-archived activities in those priorities created after user joined
    JOIN activity a ON a.priority_id = upe.priority_id
        AND a.archived_at IS NULL
        -- For self-created activities: only include if there are notes
        -- For others: use standard logic
        AND ((
                a.created_by = upe.user_id
                AND a.last_note_created_at IS NOT NULL
                AND a.last_note_created_at > upe.joined_at)
            OR ((a.created_by IS NULL
                    OR a.created_by != upe.user_id)
                AND COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at))
    LEFT JOIN activity_read ar ON ar.user_id = upe.user_id
        AND ar.activity_id = a.id
        AND ar.read_at >= CASE WHEN a.created_by = upe.user_id THEN
            a.last_note_created_at
        ELSE
            COALESCE(a.last_note_created_at, a.created_at)
        END;

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

ALTER VIEW "public"."priority_twist_activity_update" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_twist_note_create" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_twist_note_update" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_expanded" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_settings_inherited" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_twist_activity_tag_change" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child_twist" SET (security_invoker = TRUE);

