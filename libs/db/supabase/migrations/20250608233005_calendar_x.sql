CREATE OR REPLACE VIEW "public"."calendar_x" AS
SELECT
    calendar.id,
    calendar.created_at,
    calendar.updated_at,
    calendar.deleted_at,
    calendar.account_id,
    calendar.priority_id,
    calendar.provider_id,
    calendar.synced_dates,
    calendar.sequence,
    calendar.full_sync_at,
    calendar.synced_at,
    calendar.sync_error,
    calendar.full_sync_started_at,
    calendar.name,
    calendar.enabled,
    calendar.ready,
    account.user_id
FROM (calendar
    JOIN account ON (calendar.account_id = account.id));

ALTER VIEW public.calendar_x SET (security_invoker = TRUE);

