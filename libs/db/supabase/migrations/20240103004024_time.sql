CREATE TYPE "public"."time_status" AS enum (
    'started',
    'paused',
    'skipped',
    'stopped'
);

ALTER TABLE "public"."time"
    DROP CONSTRAINT "time_activity_id_fkey";

ALTER TABLE "public"."time"
    ADD COLUMN "event_id" bigint;

ALTER TABLE "public"."time"
    ADD COLUMN "series_id" bigint;

ALTER TABLE "public"."time"
    ADD COLUMN "status" time_status NOT NULL DEFAULT 'started'::time_status;

SELECT
    1;

-- CREATE INDEX time_user_id_at_excl ON public."time" USING gist (user_id, at);
ALTER TABLE "public"."time"
    ADD CONSTRAINT "time_event_id_fkey" FOREIGN KEY (event_id) REFERENCES event (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."time" validate CONSTRAINT "time_event_id_fkey";

ALTER TABLE "public"."time"
    ADD CONSTRAINT "time_series_id_fkey" FOREIGN KEY (series_id) REFERENCES "time" (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."time" validate CONSTRAINT "time_series_id_fkey";

ALTER TABLE "public"."time"
    ADD CONSTRAINT "time_user_id_at_excl"
    EXCLUDE USING gist (user_id WITH =, at WITH &&);

ALTER TABLE "public"."time"
    ADD CONSTRAINT "time_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES activity (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."time" validate CONSTRAINT "time_activity_id_fkey";

CREATE POLICY "Users can edit their time" ON "public"."time" AS permissive
    FOR ALL TO authenticated
        USING ((user_id = auth.uid ()));

ALTER VIEW gap SET ( security_invoker = TRUE);
ALTER VIEW gap_monthly SET ( security_invoker = TRUE);
ALTER VIEW gap_daily SET ( security_invoker = TRUE);
ALTER VIEW insight SET ( security_invoker = TRUE);
ALTER VIEW insight_weekly SET ( security_invoker = TRUE);
ALTER VIEW "public"."invitation_admin" SET ( security_invoker = FALSE);
ALTER VIEW "public"."event_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."waitlist_admin" SET ( security_invoker = FALSE);
ALTER VIEW "public"."sync_admin" SET ( security_invoker = FALSE);
