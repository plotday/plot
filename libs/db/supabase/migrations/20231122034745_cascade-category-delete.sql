ALTER TABLE "public"."event_rule"
    DROP CONSTRAINT "event_rule_calendar_id_fkey";

ALTER TABLE "public"."event_rule"
    DROP CONSTRAINT "event_rule_category_id_fkey";

ALTER TABLE "public"."event_rule"
    ADD CONSTRAINT "event_rule_calendar_id_fkey" FOREIGN KEY (calendar_id) REFERENCES calendar (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."event_rule" validate CONSTRAINT "event_rule_calendar_id_fkey";

ALTER TABLE "public"."event_rule"
    ADD CONSTRAINT "event_rule_category_id_fkey" FOREIGN KEY (category_id) REFERENCES category (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."event_rule" validate CONSTRAINT "event_rule_category_id_fkey";

