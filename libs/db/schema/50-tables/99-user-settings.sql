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
    "email_token" uuid
);

CREATE UNIQUE INDEX idx_user_settings_email_token ON "public"."user_settings" ("email_token")
    WHERE "email_token" IS NOT NULL;

-- Index for user-based settings lookups
CREATE INDEX idx_user_settings_user_id ON "public"."user_settings" ("user_id");

CREATE TRIGGER set_user_settings_updated_at
    BEFORE INSERT OR UPDATE ON "public"."user_settings"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();
