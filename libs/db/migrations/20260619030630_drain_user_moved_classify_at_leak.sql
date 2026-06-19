-- Data migration: drain the user_moved classify_at leak.
--
-- A thread_priority row with user_moved = TRUE is sticky -- the classify worker
-- never re-files it. But if a reclassify/channel/topic marker raced the user's
-- move, the row can carry a non-NULL classify_at that nothing ever clears: the
-- worker skips it (user_moved) and the hourly sweep re-enqueues it every hour
-- forever. Prod (2026-06-19) held 1428 such rows for the mega-user, the oldest
-- stranded since 2026-05-19, monopolizing the global 1000-row sweep budget.
--
-- The worker now clears classify_at on this skip (workers/classify handler), and
-- the markers never touch user_moved rows -- so no new leaks form. This one-shot
-- backfill drains the existing strands immediately instead of waiting for the
-- bounded sweep to chew through them.
--
-- classify_at is internal (no user.* view surfaces it), and this runs after the
-- quiet-classify_at triggers (thread_priority_seq_and_updated_at /
-- sync_user_for_thread_priority_update, earlier migrations) so it neither bumps
-- seq nor the user_sync singleton: no client re-sync, no sync storm.
UPDATE public.thread_priority
   SET classify_at = NULL
 WHERE user_moved = TRUE
   AND classify_at IS NOT NULL;
