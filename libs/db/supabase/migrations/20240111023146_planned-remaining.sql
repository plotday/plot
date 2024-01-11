ALTER TABLE "public"."time"
    ALTER COLUMN "status" DROP DEFAULT;

ALTER TYPE "public"."time_status" RENAME TO "time_status__old_version_to_be_dropped";

CREATE TYPE "public"."time_status" AS enum (
    'started',
    'skipped',
    'stopped'
);

ALTER TABLE "public"."time"
    ALTER COLUMN status TYPE "public"."time_status"
    USING status::text::"public"."time_status";

ALTER TABLE "public"."time"
    ALTER COLUMN "status" SET DEFAULT 'started'::time_status;

DROP TYPE "public"."time_status__old_version_to_be_dropped";

ALTER TABLE "public"."activity"
    ADD COLUMN "pomodoro" integer NOT NULL DEFAULT 25;

ALTER TABLE "public"."time"
    ADD COLUMN "planned" integer NOT NULL;

ALTER TABLE "public"."time"
    ADD COLUMN "remaining" integer NOT NULL DEFAULT 0;

ALTER TABLE "public"."time"
    ADD CONSTRAINT "time_planned_check" CHECK ((planned >= 0)) NOT valid;

ALTER TABLE "public"."time" validate CONSTRAINT "time_planned_check";

ALTER TABLE "public"."time"
    ADD CONSTRAINT "time_remaining_check" CHECK ((remaining >= 0)) NOT valid;

ALTER TABLE "public"."time" validate CONSTRAINT "time_remaining_check";

ALTER VIEW gap SET ( security_invoker = TRUE);
ALTER VIEW gap_monthly SET ( security_invoker = TRUE);
ALTER VIEW gap_daily SET ( security_invoker = TRUE);
ALTER VIEW insight SET ( security_invoker = TRUE);
ALTER VIEW insight_weekly SET ( security_invoker = TRUE);
ALTER VIEW "public"."invitation_admin" SET ( security_invoker = FALSE);
ALTER VIEW "public"."event_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."waitlist_admin" SET ( security_invoker = FALSE);
ALTER VIEW "public"."sync_admin" SET ( security_invoker = FALSE);
