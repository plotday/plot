-- Fix missing @plot.app priority for users who were previously sharing one.
-- The previous migration 20260405031754 had a buggy WHERE clause that skipped
-- users who already had a priority_user entry for @plot.app, even if it was
-- owned by someone else. In the per-user model, everyone needs their own.

DO $$
DECLARE
    v_user record;
BEGIN
    FOR v_user IN
        SELECT id
        FROM "user" u
        WHERE NOT EXISTS (
            SELECT 1
            FROM priority p
            WHERE p.user_id = u.id AND p.key = '@plot.app'
        )
    LOOP
        PERFORM setup_plot_app_priority(v_user.id);
    END LOOP;
END $$;
