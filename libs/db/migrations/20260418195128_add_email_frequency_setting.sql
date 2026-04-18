-- Create enum type "email_frequency"
CREATE TYPE "public"."email_frequency" AS ENUM ('daily', 'weekly', 'never');
-- Modify "user_settings" table
ALTER TABLE "public"."user_settings" ADD COLUMN "email_frequency" "public"."email_frequency" NULL;
