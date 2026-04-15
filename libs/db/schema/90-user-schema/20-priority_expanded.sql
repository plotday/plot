-- user.priority_expanded — one row per priority, scoped by its single owner.
--
-- In the per-user model a priority belongs to exactly one user, so the
-- old priority_user / priority_child aggregation collapses to a simple
-- SELECT from priority.
--
-- role is always 'member' for now — viewer is gone with the old access
-- model and may be reintroduced later via group contacts.
CREATE OR REPLACE VIEW "user"."priority_expanded" --
AS
SELECT
    p.user_id,
    p.id AS priority_id,
    p.created_at AS joined_at,
    p.archived_at,
    'member'::text AS role,
    p.path
FROM
    priority p;
