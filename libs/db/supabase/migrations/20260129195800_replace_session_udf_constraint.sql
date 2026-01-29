ALTER TABLE "public"."session"
    DROP CONSTRAINT "session_at_check";

ALTER TABLE "public"."session"
    ADD CONSTRAINT "session_at_check" CHECK ((NOT (lower_inf(at) OR upper_inf(at)))) NOT valid;

ALTER TABLE "public"."session" validate CONSTRAINT "session_at_check";
