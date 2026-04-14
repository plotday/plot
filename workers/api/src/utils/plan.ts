import type { Kysely } from "kysely";

import type { DB } from "../db-types";

type PlanSource = "personal" | "team";

type EffectivePlan = {
  plan: "free" | "core" | "pro" | "team";
  source: PlanSource;
  teamId?: string;
  teamName?: string;
};

const PLAN_TIER: Record<string, number> = {
  free: 0,
  core: 1,
  pro: 2,
  team: 3,
};

/**
 * Resolve a user's effective plan by checking both personal subscription
 * and team memberships. Returns the highest-tier plan.
 */
export async function getEffectivePlan(
  db: Kysely<DB>,
  userId: string
): Promise<EffectivePlan> {
  // Get personal plan
  const personalSub = await db
    .selectFrom("user_subscription")
    .select(["plan", "status"])
    .where("user_id", "=", userId)
    .executeTakeFirst();

  const personalPlan =
    personalSub && personalSub.status === "active"
      ? (personalSub.plan as "free" | "core" | "pro" | "team")
      : "free";

  let result: EffectivePlan = { plan: personalPlan, source: "personal" };

  // Check team memberships with active subscriptions
  const teamSubs = await db
    .selectFrom("team_user as tu")
    .innerJoin("team_subscription as ts", "ts.team_id", "tu.team_id")
    .innerJoin("team as t", "t.id", "tu.team_id")
    .select([
      "t.id as team_id",
      "t.name as team_name",
      "ts.plan",
      "ts.status",
    ])
    .where("tu.user_id", "=", userId)
    .where("ts.status", "=", "active")
    .execute();

  for (const teamSub of teamSubs) {
    const teamPlan = teamSub.plan as "free" | "core" | "pro" | "team";
    if ((PLAN_TIER[teamPlan] ?? 0) > (PLAN_TIER[result.plan] ?? 0)) {
      result = {
        plan: teamPlan,
        source: "team",
        teamId: String(teamSub.team_id),
        teamName: teamSub.team_name,
      };
    }
  }

  return result;
}
