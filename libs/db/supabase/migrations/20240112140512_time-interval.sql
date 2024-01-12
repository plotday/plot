ALTER TABLE "public"."time"
    DROP CONSTRAINT "time_planned_check";

ALTER TABLE "public"."time"
    DROP CONSTRAINT "time_remaining_check";

ALTER TABLE "public"."time"
    DROP COLUMN "status";

ALTER TABLE "public"."time"
    ALTER COLUMN "planned" SET data TYPE interval USING "planned"::interval;

ALTER TABLE "public"."time"
    ALTER COLUMN "remaining" SET DEFAULT '00:00:00'::interval;

ALTER TABLE "public"."time"
    ALTER COLUMN "remaining" SET data TYPE interval USING "remaining"::interval;

DROP TYPE "public"."time_status";

ALTER TABLE "public"."time"
    ADD CONSTRAINT "time_planned_check" CHECK ((planned >= '00:00:00'::interval)) NOT valid;

ALTER TABLE "public"."time" validate CONSTRAINT "time_planned_check";

ALTER TABLE "public"."time"
    ADD CONSTRAINT "time_remaining_check" CHECK ((remaining >= '00:00:00'::interval)) NOT valid;

ALTER TABLE "public"."time" validate CONSTRAINT "time_remaining_check";

