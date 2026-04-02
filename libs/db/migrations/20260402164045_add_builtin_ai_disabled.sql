-- Modify "ai_preference" table
ALTER TABLE "public"."ai_preference" ADD COLUMN "builtin_ai_disabled" boolean NOT NULL DEFAULT false;
