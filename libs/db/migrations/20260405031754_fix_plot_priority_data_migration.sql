-- Fix: Data migration from 20260404033440 was not applied.
-- Re-run the DML steps to archive old @plot sub-priorities and reparent @plot.twist-dev.

-- 1. Archive @plot.whats-new
UPDATE priority SET archived_at = now()
WHERE key = '@plot.whats-new' AND archived_at IS NULL;

-- 2. Archive @plot.help-feedback and all children
UPDATE priority SET archived_at = now()
WHERE (key = '@plot.help-feedback' OR key LIKE '@plot.help-feedback-%')
AND archived_at IS NULL;

-- 3. Archive @plot.getting-started
UPDATE priority SET archived_at = now()
WHERE key = '@plot.getting-started' AND archived_at IS NULL;

-- 4. Reparent @plot.twist-dev to top-level: INSERT path override per user
-- The original migration used UPDATE but no priority_setting rows existed.
-- priority_setting_inherited propagates this to all descendants automatically.
INSERT INTO priority_setting (user_id, priority_id, key, value)
SELECT
    pu.user_id,
    pr.id,
    'path',
    to_jsonb(ltree2text(generate_path((
        SELECT p.path FROM priority_user pu2
        JOIN priority p ON pu2.priority_id = p.id
        WHERE pu2.user_id = pu.user_id AND pu2.personal = TRUE LIMIT 1
    ))))
FROM priority pr
CROSS JOIN (
    SELECT DISTINCT user_id FROM priority_user WHERE personal = TRUE
) pu
WHERE pr.key = '@plot.twist-dev'
ON CONFLICT DO NOTHING;

-- 5. Make @plot.twist-dev viewer-only: set inherit_members=false and add viewer priority_user rows
UPDATE priority SET inherit_members = FALSE
WHERE key = '@plot.twist-dev' AND inherit_members = TRUE;

INSERT INTO priority_user (user_id, priority_id, role, personal)
SELECT
    pu.user_id,
    pr.id,
    'viewer',
    FALSE
FROM priority pr
CROSS JOIN (
    SELECT DISTINCT user_id FROM priority_user WHERE personal = TRUE
) pu
WHERE pr.key = '@plot.twist-dev'
ON CONFLICT DO NOTHING;

-- 6. Archive @plot priorities
UPDATE priority SET archived_at = now()
WHERE key = '@plot' AND archived_at IS NULL;

-- 6. Set up Using Plot for all existing users who don't have it yet
DO $$
DECLARE
    v_user record;
BEGIN
    FOR v_user IN SELECT DISTINCT
        u.id
    FROM
        "user" u
    WHERE
        NOT EXISTS (
            SELECT 1
            FROM priority_user pu
            JOIN priority p ON pu.priority_id = p.id
            WHERE pu.user_id = u.id AND p.key = '@plot.app'
        )
    LOOP
        PERFORM setup_plot_app_priority(v_user.id);
    END LOOP;
END;
$$;
