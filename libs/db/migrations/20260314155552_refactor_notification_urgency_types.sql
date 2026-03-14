-- Drop old constraint first so we can update values
ALTER TABLE "public"."thread_unread" DROP CONSTRAINT "thread_unread_urgency_check";

-- Migrate existing urgency values
UPDATE thread_unread SET urgency = 'inform-requests' WHERE urgency = 'inform-fast';
UPDATE thread_unread SET urgency = 'inform-updates' WHERE urgency = 'inform-slow';

-- Add new constraint
ALTER TABLE "public"."thread_unread" ADD CONSTRAINT "thread_unread_urgency_check" CHECK (urgency = ANY (ARRAY['interrupt'::text, 'inform-requests'::text, 'inform-updates'::text, 'passive'::text]));
