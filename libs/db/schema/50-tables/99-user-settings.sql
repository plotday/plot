-- Global user settings
CREATE TABLE "public"."user_settings" (
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid PRIMARY KEY REFERENCES auth.users ON DELETE CASCADE,
    -- All fields added below must be nullable to support partial updates
    "enter_behavior" enter_behavior
);

-- Index for user-based settings lookups
CREATE INDEX idx_user_settings_user_id ON "public"."user_settings" ("user_id");

ALTER TABLE "public"."user_settings" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_user_settings_updated_at
    BEFORE UPDATE ON "public"."user_settings"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();
