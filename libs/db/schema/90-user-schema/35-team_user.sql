-- Per-user team membership view. Sync cursor reads tu.seq.
CREATE OR REPLACE VIEW "user"."team_user" AS
SELECT
    tu.id,
    tu.user_id,
    tu.team_id,
    tu.role,
    tu.archived_at,
    tu.seq,
    t.name AS team_name
FROM public.team_user tu
JOIN public.team t ON t.id = tu.team_id;
