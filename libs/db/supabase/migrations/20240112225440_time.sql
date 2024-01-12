ALTER TABLE "public"."time"
    DROP CONSTRAINT "time_activity_id_fkey";

ALTER TABLE "public"."activity"
    ADD COLUMN "pomodoro" integer NOT NULL DEFAULT 25;

ALTER TABLE "public"."time"
    ADD COLUMN "event_id" bigint;

ALTER TABLE "public"."time"
    ADD COLUMN "planned" interval NOT NULL;

ALTER TABLE "public"."time"
    ADD COLUMN "remaining" interval NOT NULL DEFAULT '00:00:00'::interval;

ALTER TABLE "public"."time"
    ADD COLUMN "series_id" bigint;

-- CREATE INDEX time_user_id_at_excl ON public."time" USING gist (user_id, at);
ALTER TABLE "public"."time"
    ADD CONSTRAINT "time_check" CHECK (((remaining >= '00:00:00'::interval) AND (remaining <= planned))) NOT valid;

ALTER TABLE "public"."time" validate CONSTRAINT "time_check";

ALTER TABLE "public"."time"
    ADD CONSTRAINT "time_event_id_fkey" FOREIGN KEY (event_id) REFERENCES event (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."time" validate CONSTRAINT "time_event_id_fkey";

ALTER TABLE "public"."time"
    ADD CONSTRAINT "time_planned_check" CHECK ((planned >= '00:00:00'::interval)) NOT valid;

ALTER TABLE "public"."time" validate CONSTRAINT "time_planned_check";

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

