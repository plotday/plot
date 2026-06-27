-- Data migration: move all legacy 'core' plan rows to 'free'.
-- The 'core' enum value is kept in the subscription_plan type (removing a
-- Postgres enum value requires recreating the type — not worth it). App code
-- no longer references 'core' as a PlanKey; this migration ensures no DB row
-- carries it going forward.
UPDATE "public"."user_subscription" SET plan = 'free' WHERE plan = 'core';
UPDATE "public"."team_subscription" SET plan = 'free' WHERE plan = 'core';
