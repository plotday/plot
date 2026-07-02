-- user.role — per-user view of the user's roles, for /sync/roles (Plan 2).
DROP VIEW IF EXISTS "user"."role" CASCADE;
CREATE OR REPLACE VIEW "user"."role" -- for formatting
AS
SELECT
    r.user_id,
    r.id,
    r.created_at,
    r.updated_at,
    r.seq,
    r.archived_at,
    r.created_by,
    r.name,
    r.color,
    r."order",
    r.early_notifications_enabled,
    r.notify_window,
    r.see_within,
    r.send_window
FROM role r;
