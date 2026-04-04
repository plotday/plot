-- Set comment to function: "setup_plot_app_priority"
COMMENT ON FUNCTION "public"."setup_plot_app_priority" IS 'Creates the global @plot.app priority and onboarding threads. Replaces retired @plot.getting-started and @plot.help-feedback priorities.';

-- Data migration: Move Help+Feedback user threads to Using Plot, archive old onboarding

-- 1. Move threads from per-user Help & Feedback priorities into @plot.app as private threads.
--    The thread's created_by remains the original user, so visibility rule
--    (a.created_by = upe.user_id) ensures only they can see their private threads.
--    Key is nulled to avoid thread_priority_key_unique constraint conflicts.
UPDATE thread t
SET
    priority_id = plot_app.id,
    private = true,
    key = NULL
FROM
    priority hf,
    priority plot_app
WHERE
    t.priority_id = hf.id
    AND hf.key LIKE '@plot.help-feedback-%'
    AND plot_app.key = '@plot.app'
    AND t.archived_at IS NULL;

-- 2. Archive all remaining threads in Getting Started and Help & Feedback priorities
UPDATE thread t
SET archived_at = now()
FROM priority p
WHERE t.priority_id = p.id
    AND (p.key = '@plot.getting-started'
         OR p.key = '@plot.help-feedback'
         OR p.key LIKE '@plot.help-feedback-%')
    AND t.archived_at IS NULL;

-- 3. Archive priority_user memberships for old priorities
UPDATE priority_user pu
SET archived_at = now()
FROM priority p
WHERE pu.priority_id = p.id
    AND (p.key = '@plot.getting-started'
         OR p.key = '@plot.help-feedback'
         OR p.key LIKE '@plot.help-feedback-%')
    AND pu.archived_at IS NULL;
