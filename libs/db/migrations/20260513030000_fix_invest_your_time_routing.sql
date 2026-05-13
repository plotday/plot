-- Fix routing for the "Invest your time" onboarding thread so it lands in
-- every user's "Using Plot" priority (key '@plot.app'), matching the other
-- onboarding threads. The original migration set thread.topic to the
-- Everyone group id, which has no priority:{KEY} prefix — so
-- classify_thread_for_user fell through to the user's oldest root priority
-- (usually "Plot") instead of "Using Plot".
--
-- See 20260417005639_priority_key_topic_prefix.sql for the established
-- pattern: onboarding threads carry topic = 'priority:@plot.app:{key}' so
-- classify_thread_for_user's priority-prefix branch resolves them to the
-- user's @plot.app priority when no user_moved example outscores it.
--
-- This migration:
--   1. Updates thread.topic on the existing 'invest-your-time' thread.
--   2. Re-files thread_priority rows for that thread into each user's
--      "Using Plot" priority — only where user_moved = FALSE, so manual
--      moves are never clobbered.
--
-- Idempotent: re-running is a no-op once topics and filings line up.

UPDATE public.thread
SET topic = 'priority:@plot.app:invest-your-time'
WHERE key = 'invest-your-time'
  AND (topic IS NULL OR topic <> 'priority:@plot.app:invest-your-time');

UPDATE public.thread_priority tp
SET priority_id = p.id
FROM public.thread t,
     public.priority p
WHERE tp.thread_id = t.id
  AND t.key = 'invest-your-time'
  AND p.user_id = tp.user_id
  AND p.key = '@plot.app'
  AND p.archived_at IS NULL
  AND tp.user_moved = FALSE
  AND tp.priority_id <> p.id;
