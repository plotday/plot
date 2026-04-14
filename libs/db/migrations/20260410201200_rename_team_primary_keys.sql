-- Rename a constraint from "organization_pkey" to "team_pkey"
ALTER TABLE "public"."team" RENAME CONSTRAINT "organization_pkey" TO "team_pkey";
-- Rename a constraint from "organization_invitation_pkey" to "team_invitation_pkey"
ALTER TABLE "public"."team_invitation" RENAME CONSTRAINT "organization_invitation_pkey" TO "team_invitation_pkey";
-- Rename a constraint from "organization_subscription_pkey" to "team_subscription_pkey"
ALTER TABLE "public"."team_subscription" RENAME CONSTRAINT "organization_subscription_pkey" TO "team_subscription_pkey";
-- Rename a constraint from "organization_member_pkey" to "team_user_pkey"
ALTER TABLE "public"."team_user" RENAME CONSTRAINT "organization_member_pkey" TO "team_user_pkey";
