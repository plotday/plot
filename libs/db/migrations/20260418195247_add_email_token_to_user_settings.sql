-- Modify "user_settings" table
ALTER TABLE "public"."user_settings" ADD COLUMN "email_token" uuid NULL;
-- Create index "idx_user_settings_email_token" to table: "user_settings"
CREATE UNIQUE INDEX "idx_user_settings_email_token" ON "public"."user_settings" ("email_token") WHERE (email_token IS NOT NULL);
