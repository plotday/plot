-- Modify "user_settings" table
ALTER TABLE "public"."user_settings" ADD COLUMN "dismissed_focus_suggestions" jsonb NULL DEFAULT '[]';
-- Drop "upsert_user_settings" function
DROP FUNCTION "user"."upsert_user_settings" (uuid, "public"."enter_behavior", boolean, boolean, timestamptz);
-- Create "upsert_user_settings" function
CREATE FUNCTION "user"."upsert_user_settings" ("user_id" uuid, "p_enter_behavior" "public"."enter_behavior", "p_ai_enabled" boolean DEFAULT NULL::boolean, "p_onboarding_completed" boolean DEFAULT NULL::boolean, "p_tracking_paused_at" timestamptz DEFAULT NULL::timestamp with time zone, "p_dismissed_focus_suggestions" jsonb DEFAULT NULL::jsonb) RETURNS "public"."user_settings" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
#variable_conflict use_column
DECLARE
    v_row user_settings;
BEGIN
    INSERT INTO user_settings (user_id, enter_behavior, ai_enabled, onboarding_completed, tracking_paused_at, dismissed_focus_suggestions)
        VALUES (
            upsert_user_settings.user_id,
            p_enter_behavior,
            p_ai_enabled,
            p_onboarding_completed,
            CASE
                WHEN p_tracking_paused_at = '1970-01-01T00:00:00Z'::timestamptz THEN NULL
                ELSE p_tracking_paused_at
            END,
            COALESCE(p_dismissed_focus_suggestions, '[]'::jsonb)
        )
    ON CONFLICT (user_id)
        DO UPDATE SET
            enter_behavior = EXCLUDED.enter_behavior,
            ai_enabled = EXCLUDED.ai_enabled,
            -- Once true, stay true: don't let a NULL from a device that hasn't
            -- pulled yet clobber completion set by another device.
            onboarding_completed = COALESCE(EXCLUDED.onboarding_completed, user_settings.onboarding_completed),
            tracking_paused_at = CASE
                -- Sentinel epoch means "explicit clear" (resume).
                WHEN p_tracking_paused_at = '1970-01-01T00:00:00Z'::timestamptz THEN NULL
                -- NULL from the client means "no change", preserve existing.
                WHEN p_tracking_paused_at IS NULL THEN user_settings.tracking_paused_at
                ELSE p_tracking_paused_at
            END,
            -- Union-merge: existing keys ∪ newly dismissed keys, deduped.
            -- NULL/empty incoming leaves the set unchanged. Never removes keys.
            dismissed_focus_suggestions = (
                SELECT COALESCE(jsonb_agg(DISTINCT e), '[]'::jsonb)
                FROM jsonb_array_elements_text(
                    COALESCE(user_settings.dismissed_focus_suggestions, '[]'::jsonb)
                    || COALESCE(EXCLUDED.dismissed_focus_suggestions, '[]'::jsonb)
                ) AS e
            ),
            updated_at = now()
    RETURNING * INTO v_row;

    -- Retroactive pause reconciliation: when pause was just set (or moved
    -- earlier), archive any non-archived 'event' session rows for this user
    -- whose recorded interval starts at or after the paused instant. Sessions
    -- of source='active' or 'manual' are user-authored and not touched.
    IF v_row.tracking_paused_at IS NOT NULL THEN
        UPDATE public.session
        SET archived_at = now()
        WHERE user_id = upsert_user_settings.user_id
            AND source = 'event'
            AND archived_at IS NULL
            AND lower(at) >= v_row.tracking_paused_at;
    END IF;

    RETURN v_row;
END;
$$;
