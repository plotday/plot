-- Global user settings
CREATE TABLE "public"."user_settings" (
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid PRIMARY KEY REFERENCES public."user" ON DELETE CASCADE,
    -- All fields added below must be nullable to support partial updates
    "enter_behavior" enter_behavior,
    "ai_enabled" boolean,
    "email_frequency" email_frequency,
    -- Random token issued in notification emails so a recipient can update
    -- their email_frequency preference without signing in. Generated lazily
    -- the first time a notification email is sent.
    "email_token" uuid,
    "onboarding_completed" boolean,
    -- When non-null, the user has paused time tracking since this instant.
    -- Drives:
    --   * the client's foreground tracker (skip Session.resume while paused),
    --   * the server's event finalizer (skip occurrences whose `end` falls
    --     inside the paused window),
    --   * the retroactive reconciler (archive `source='event'` rows whose
    --     `at.start >= tracking_paused_at` when the flag is set or moved earlier).
    "tracking_paused_at" timestamp with time zone,
    -- Watermark for the event-session finalizer cron. NULL means this user
    -- has never been finalized; the cron will pick them up in a bounded
    -- backfill phase (90-day lookback) and then set this column. Once set,
    -- the steady-state phase uses GREATEST(this, now() - 30 min) as the
    -- per-user lookback start, which self-heals against missed ticks.
    "event_sessions_finalized_through" timestamp with time zone,
    "seq" xid8 NOT NULL DEFAULT pg_current_xact_id()
);

CREATE INDEX idx_user_settings_seq ON "public"."user_settings" ("seq");

-- Partial index for the event-session finalizer's per-tick Phase B
-- selection (users needing backfill).
CREATE INDEX idx_user_settings_event_finalize_backfill
    ON "public"."user_settings" ("user_id")
    WHERE "event_sessions_finalized_through" IS NULL;

CREATE UNIQUE INDEX idx_user_settings_email_token ON "public"."user_settings" ("email_token")
    WHERE "email_token" IS NOT NULL;

-- Index for user-based settings lookups
CREATE INDEX idx_user_settings_user_id ON "public"."user_settings" ("user_id");

CREATE TRIGGER set_user_settings_updated_at
    BEFORE INSERT OR UPDATE ON "public"."user_settings"
    FOR EACH ROW
    EXECUTE FUNCTION update_seq_and_updated_at ();
