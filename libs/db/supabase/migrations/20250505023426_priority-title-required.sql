ALTER TABLE "public"."priority"
    ADD CONSTRAINT "priority_check" CHECK (((draft = FALSE) OR (title IS NOT NULL))) NOT valid;

ALTER TABLE "public"."priority" validate CONSTRAINT "priority_check";

