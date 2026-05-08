-- Create "upsert_user_settings" function
CREATE FUNCTION "user"."upsert_user_settings" ("user_id" uuid, "p_enter_behavior" "public"."enter_behavior", "p_ai_enabled" boolean DEFAULT NULL::boolean, "p_onboarding_completed" boolean DEFAULT NULL::boolean) RETURNS "public"."user_settings" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
#variable_conflict use_column
DECLARE
    v_row user_settings;
BEGIN
    INSERT INTO user_settings (user_id, enter_behavior, ai_enabled, onboarding_completed)
        VALUES (upsert_user_settings.user_id, p_enter_behavior, p_ai_enabled, p_onboarding_completed)
    ON CONFLICT (user_id)
        DO UPDATE SET
            enter_behavior = EXCLUDED.enter_behavior,
            ai_enabled = EXCLUDED.ai_enabled,
            -- Once true, stay true: don't let a NULL from a device that hasn't
            -- pulled yet clobber completion set by another device.
            onboarding_completed = COALESCE(EXCLUDED.onboarding_completed, user_settings.onboarding_completed),
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Drop "upsert_user_settings" function
DROP FUNCTION "user"."upsert_user_settings" (uuid, "public"."enter_behavior", boolean);
