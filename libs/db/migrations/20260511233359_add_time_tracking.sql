-- Drop "upsert_priority_block" function first: its return type is the
-- "user"."priority_block" row type, so the view cannot be dropped while
-- the function exists.
DROP FUNCTION "user"."upsert_priority_block" (uuid, jsonb);
-- Drop "priority_block" view (recreated below with the new "duration" column)
DROP VIEW "user"."priority_block";
-- Modify "priority_block" table
ALTER TABLE "public"."priority_block" ADD COLUMN "duration" interval NULL;
-- Modify "user_settings" table
ALTER TABLE "public"."user_settings" ADD COLUMN "tracking_paused_at" timestamptz NULL;
-- (upsert_priority_block recreated after the view is restored below)
-- Create "upsert_user_settings" function
CREATE FUNCTION "user"."upsert_user_settings" ("user_id" uuid, "p_enter_behavior" "public"."enter_behavior", "p_ai_enabled" boolean DEFAULT NULL::boolean, "p_onboarding_completed" boolean DEFAULT NULL::boolean, "p_tracking_paused_at" timestamptz DEFAULT NULL::timestamp with time zone) RETURNS "public"."user_settings" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
#variable_conflict use_column
DECLARE
    v_row user_settings;
BEGIN
    INSERT INTO user_settings (user_id, enter_behavior, ai_enabled, onboarding_completed, tracking_paused_at)
        VALUES (
            upsert_user_settings.user_id,
            p_enter_behavior,
            p_ai_enabled,
            p_onboarding_completed,
            CASE
                WHEN p_tracking_paused_at = '1970-01-01T00:00:00Z'::timestamptz THEN NULL
                ELSE p_tracking_paused_at
            END
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
-- Modify "session" table
ALTER TABLE "public"."session" ADD CONSTRAINT "session_source_check" CHECK (source = ANY (ARRAY['active'::text, 'event'::text, 'manual'::text])), ADD COLUMN "source" text NOT NULL DEFAULT 'active', ADD COLUMN "schedule_id" uuid NULL, ADD COLUMN "occurrence_at" timestamptz NULL, ADD CONSTRAINT "session_schedule_id_fkey" FOREIGN KEY ("schedule_id") REFERENCES "public"."schedule" ("id") ON UPDATE NO ACTION ON DELETE SET NULL;
-- Create index "idx_session_schedule_occurrence" to table: "session"
CREATE UNIQUE INDEX "idx_session_schedule_occurrence" ON "public"."session" ("user_id", "schedule_id", "occurrence_at") WHERE ((schedule_id IS NOT NULL) AND (archived_at IS NULL));
-- Create "priority_block" view
CREATE VIEW "user"."priority_block" (
  "id",
  "user_id",
  "priority_id",
  "order_value",
  "effective_at",
  "duration",
  "archived_at",
  "created_at",
  "updated_at",
  "created_by",
  "updated_by",
  "seq"
) AS SELECT id,
    user_id,
    priority_id,
    order_value,
    effective_at,
    duration,
    archived_at,
    created_at,
    updated_at,
    created_by,
    updated_by,
    seq
   FROM public.priority_block pb;
-- Recreate "upsert_priority_block" function with the new "duration" column.
-- Lives after the CREATE VIEW so the RETURNS "user"."priority_block" row
-- type resolves against the new view.
CREATE OR REPLACE FUNCTION "user"."upsert_priority_block" ("user_id" uuid, "p_block" jsonb) RETURNS "user"."priority_block" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
#variable_conflict use_column
DECLARE
    _input "user"."priority_block";
    _new_id uuid;
    v_row "user"."priority_block";
BEGIN
    _input := jsonb_populate_record(NULL::"user"."priority_block", p_block || jsonb_build_object('user_id', upsert_priority_block.user_id));

    PERFORM "user".assert_priority_access(upsert_priority_block.user_id, _input.priority_id);

    INSERT INTO priority_block (id, priority_id, user_id, order_value, effective_at, duration, archived_at, created_by, updated_by)
        VALUES (
            COALESCE(_input.id, uuidv7()),
            _input.priority_id,
            upsert_priority_block.user_id,
            _input.order_value,
            _input.effective_at,
            _input.duration,
            _input.archived_at,
            _input.created_by,
            COALESCE(_input.updated_by, 0)
        )
    ON CONFLICT (priority_id, effective_at)
        DO UPDATE SET
            order_value = EXCLUDED.order_value,
            duration = EXCLUDED.duration,
            archived_at = EXCLUDED.archived_at,
            updated_by = EXCLUDED.updated_by
        RETURNING id INTO _new_id;

    SELECT * INTO v_row
    FROM "user".priority_block
    WHERE id = _new_id AND user_id = upsert_priority_block.user_id;

    RETURN v_row;
END;
$$;
-- Drop "upsert_user_settings" function
DROP FUNCTION "user"."upsert_user_settings" (uuid, "public"."enter_behavior", boolean, boolean);
