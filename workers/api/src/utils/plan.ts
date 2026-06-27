import type { Kysely } from "kysely";

import type { DB } from "../db-types";

type PlanSource = "personal" | "team";

type EffectivePlan = {
  plan: "free" | "pro" | "team";
  source: PlanSource;
  teamId?: string;
  teamName?: string;
};

const PLAN_TIER: Record<string, number> = {
  free: 0,
  pro: 1,
  team: 2,
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

  // 'trialing' is treated exactly like 'active'. Map legacy 'core' DB value
  // to 'free' at the read boundary (Core plan is no longer active).
  const rawPersonal = personalSub?.plan as string | undefined;
  const personalPlan: "free" | "pro" | "team" =
    personalSub &&
    (personalSub.status === "active" || personalSub.status === "trialing")
      ? ((rawPersonal === "core" ? "free" : rawPersonal) as "free" | "pro" | "team")
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
    // Map legacy 'core' DB value to 'free' at the read boundary.
    const rawTeam = teamSub.plan as string;
    const teamPlan = (rawTeam === "core" ? "free" : rawTeam) as "free" | "pro" | "team";
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
