-- user.priority_block — per-user view of priority_block rows. The
-- public.priority_block table already carries user_id (denormalized from
-- priority.user_id), so the view is a simple filter. Mirrors the
-- conventions of user.priority: project the same columns the sync GET
-- endpoint reads, including seq for cursor-based pagination.
DROP VIEW IF EXISTS "user"."priority_block" CASCADE;
CREATE OR REPLACE VIEW "user"."priority_block" -- for formatting
AS
SELECT
    pb.id,
    pb.user_id,
    pb.priority_id,
    pb.order_value,
    pb.effective_at,
    pb.duration,
    pb.archived_at,
    pb.created_at,
    pb.updated_at,
    pb.created_by,
    pb.updated_by,
    pb.seq
FROM
    public.priority_block pb;
