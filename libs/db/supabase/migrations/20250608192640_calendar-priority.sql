ALTER TABLE "public"."calendar"
    ADD COLUMN "priority_id" uuid;

ALTER TABLE "public"."calendar"
    ADD CONSTRAINT "calendar_priority_id_fkey" FOREIGN KEY (priority_id) REFERENCES priority (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."calendar" validate CONSTRAINT "calendar_priority_id_fkey";

ALTER TABLE "public"."calendar"
    ADD CONSTRAINT "calendar_priority_required_when_enabled" CHECK (((NOT enabled) OR (priority_id IS NOT NULL))) NOT valid;

ALTER TABLE "public"."calendar" validate CONSTRAINT "calendar_priority_required_when_enabled";

