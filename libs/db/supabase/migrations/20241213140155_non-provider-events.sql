ALTER TABLE "public"."event"
    DROP CONSTRAINT "event_calendar_provider_id_unique";

CREATE UNIQUE INDEX event_calendar_provider_id_unique ON public.event USING btree (calendar_id, provider_id);

ALTER TABLE "public"."event"
    ADD CONSTRAINT "event_calendar_provider_id_unique" UNIQUE USING INDEX "event_calendar_provider_id_unique";

