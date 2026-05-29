-- Create "upsert_priority_attention" function
CREATE FUNCTION "user"."upsert_priority_attention" ("p_user_id" uuid, "p_priority_id" uuid, "p_early_notifications_enabled" boolean DEFAULT NULL::boolean, "p_set_early_notifications_enabled" boolean DEFAULT false, "p_notify_window" jsonb DEFAULT NULL::jsonb, "p_set_notify_window" boolean DEFAULT false, "p_see_within" jsonb DEFAULT NULL::jsonb, "p_set_see_within" boolean DEFAULT false) RETURNS void LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
BEGIN
    PERFORM "user".assert_priority_access(p_user_id, p_priority_id);

    IF p_set_early_notifications_enabled THEN
        IF p_early_notifications_enabled IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (p_user_id, p_priority_id, 'early_notifications_enabled', to_jsonb(p_early_notifications_enabled))
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE priority_setting.user_id = p_user_id
              AND priority_setting.priority_id = p_priority_id AND key = 'early_notifications_enabled';
        END IF;
    END IF;

    IF p_set_notify_window THEN
        IF p_notify_window IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (p_user_id, p_priority_id, 'notify_window', p_notify_window)
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE priority_setting.user_id = p_user_id
              AND priority_setting.priority_id = p_priority_id AND key = 'notify_window';
        END IF;
    END IF;

    IF p_set_see_within THEN
        IF p_see_within IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (p_user_id, p_priority_id, 'see_within', p_see_within)
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE priority_setting.user_id = p_user_id
              AND priority_setting.priority_id = p_priority_id AND key = 'see_within';
        END IF;
    END IF;

    -- Bump the priority's seq so the user view re-emits with the new
    -- inherited values (the seq protocol is driven off priority.updated_at).
    UPDATE priority SET updated_at = now() WHERE id = p_priority_id;
END;
$$;
-- Drop "upsert_priority_attention" function
DROP FUNCTION "user"."upsert_priority_attention" (uuid, uuid, boolean, boolean, jsonb, boolean, jsonb, boolean, boolean, boolean, jsonb, boolean, jsonb, boolean);

-- Data: drop orphan respond_* setting rows now that the feature is gone.
-- priority_setting isn't synced row-by-row to clients (the user.priority
-- view projects from it), so a plain DELETE is safe.
DELETE FROM priority_setting
WHERE key IN ('respond_schedule_enabled', 'respond_window', 'respond_within');
