DROP TRIGGER IF EXISTS "handle_event_changes" ON "public"."event";

DROP TRIGGER IF EXISTS "set_event_updated_at" ON "public"."event";

DROP TRIGGER IF EXISTS "upsert_event_x" ON "public"."event_x";

DROP TRIGGER IF EXISTS "on_invitee_created" ON "public"."invitee";

DROP TRIGGER IF EXISTS "set_invitee_updated_at" ON "public"."invitee";

DROP POLICY "Users can edit their own events" ON "public"."event";

DROP POLICY "Users can read all embeddings" ON "public"."event";

DROP POLICY "Users can edit their invitees for their events" ON "public"."invitee";

ALTER TABLE "public"."event"
    DROP CONSTRAINT "event_calendar_id_fkey";

ALTER TABLE "public"."event"
    DROP CONSTRAINT "event_calendar_provider_id_unique";

ALTER TABLE "public"."event"
    DROP CONSTRAINT "event_provider_id_only_with_calendar";

ALTER TABLE "public"."event"
    DROP CONSTRAINT "event_user_id_fkey";

ALTER TABLE "public"."event"
    DROP CONSTRAINT "event_user_or_calendar";

ALTER TABLE "public"."invitee"
    DROP CONSTRAINT "invitee_email_check";

ALTER TABLE "public"."invitee"
    DROP CONSTRAINT "invitee_event_email_unique";

ALTER TABLE "public"."invitee"
    DROP CONSTRAINT "invitee_event_id_fkey";

DROP FUNCTION IF EXISTS "public"."account" (calendar);

DROP VIEW IF EXISTS "public"."balance";

DROP VIEW IF EXISTS "public"."balance_without_children";

DROP FUNCTION IF EXISTS "public"."calc_internal" (invitee_count integer, user_domain bigint, domains bigint[]);

DROP FUNCTION IF EXISTS "public"."calendar" (event_x);

DROP FUNCTION IF EXISTS "public"."cancel_events" (_events event_ids[]);

DROP FUNCTION IF EXISTS "public"."contact" (invitee);

DROP TYPE "public"."event_ids";

DROP VIEW IF EXISTS "public"."gap_daily";

DROP VIEW IF EXISTS "public"."gap_monthly";

DROP FUNCTION IF EXISTS "public"."handle_event_x_upsert" ();

DROP VIEW IF EXISTS "public"."insight";

DROP FUNCTION IF EXISTS "public"."invitee" (event_x);

DROP FUNCTION IF EXISTS "public"."is_week" (p_week daterange);

DROP FUNCTION IF EXISTS "public"."notify_user_for_event" ();

DROP FUNCTION IF EXISTS "public"."upsert_invitees" (_event_ids uuid[], _invitees invitee_upsert[]);

DROP TYPE "public"."invitee_upsert";

DROP VIEW IF EXISTS "public"."gap";

DROP FUNCTION IF EXISTS "public"."work_day_end" ();

DROP FUNCTION IF EXISTS "public"."work_day_start" ();

DROP VIEW IF EXISTS "public"."event_x";

DROP FUNCTION IF EXISTS "public"."calc_all_day" (at tstzrange);

DROP FUNCTION IF EXISTS "public"."calc_event_type" (at tstzrange, availability event_availability, response event_response, has_invitees boolean);

DROP FUNCTION IF EXISTS "public"."calc_notice" (created_at timestamp with time zone, at tstzrange);

DROP FUNCTION IF EXISTS "public"."calc_rounded_length" (at tstzrange);

DROP FUNCTION IF EXISTS "public"."calc_seconds" (r tstzrange);

DROP FUNCTION IF EXISTS "public"."calc_speedy" (at tstzrange);

DROP VIEW IF EXISTS "public"."event_invitees";

DROP FUNCTION IF EXISTS "public"."calc_meeting_size" (invitee_count integer);

ALTER TABLE "public"."event"
    DROP CONSTRAINT "event_pkey";

DROP INDEX IF EXISTS "public"."event_at_idx";

DROP INDEX IF EXISTS "public"."event_calendar_provider_id_unique";

DROP INDEX IF EXISTS "public"."event_pkey";

DROP INDEX IF EXISTS "public"."invitee_event_email_unique";

DROP INDEX IF EXISTS "public"."invitee_event_id_idx";

DROP TABLE "public"."event" CASCADE;

DROP TABLE "public"."invitee";

DROP TYPE "public"."event_availability";

DROP TYPE "public"."event_internal";

DROP TYPE "public"."event_response";

DROP TYPE "public"."event_status";

DROP TYPE "public"."event_type";

DROP TYPE "public"."event_visibility";

DROP TYPE "public"."location_type";

DROP TYPE "public"."meeting_size";

DROP TYPE "public"."provider";

ALTER VIEW "public"."activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_children" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_exception" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "admin"."invitation" SET (security_invoker = FALSE);

ALTER VIEW public.calendar_x SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority" SET (security_invoker = TRUE);

ALTER VIEW "public"."agent_x" SET (security_invoker = TRUE);

