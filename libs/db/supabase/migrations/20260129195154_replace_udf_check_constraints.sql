ALTER TABLE "public"."contact"
    DROP CONSTRAINT "contact_email_check";

ALTER TABLE "public"."domain"
    DROP CONSTRAINT "domain_name_check";

ALTER TABLE "public"."contact"
    ADD CONSTRAINT "contact_email_check" CHECK ((email = lower(email))) NOT valid;

ALTER TABLE "public"."contact" validate CONSTRAINT "contact_email_check";

ALTER TABLE "public"."domain"
    ADD CONSTRAINT "domain_name_check" CHECK ((name = lower(name))) NOT valid;

ALTER TABLE "public"."domain" validate CONSTRAINT "domain_name_check";
