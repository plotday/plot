import type { Kysely } from "kysely";

import type { DB } from "../db-types";

type PlanSource = "personal" | "organization";

type EffectivePlan = {
  plan: "free" | "pro" | "business";
  source: PlanSource;
  organizationId?: string;
  organizationName?: string;
};

const PLAN_TIER: Record<string, number> = {
  free: 0,
  pro: 1,
  business: 2,
};

/**
 * Resolve a user's effective plan by checking both personal subscription
 * and organization memberships. Returns the highest-tier plan.
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
      ? (personalSub.plan as "free" | "pro" | "business")
      : "free";

  let result: EffectivePlan = { plan: personalPlan, source: "personal" };

  // Check org memberships with active subscriptions
  const orgSubs = await db
    .selectFrom("organization_member as om")
    .innerJoin(
      "organization_subscription as os",
      "os.organization_id",
      "om.organization_id"
    )
    .innerJoin("organization as o", "o.id", "om.organization_id")
    .select([
      "o.id as organization_id",
      "o.name as organization_name",
      "os.plan",
      "os.status",
    ])
    .where("om.user_id", "=", userId)
    .where("os.status", "=", "active")
    .execute();

  for (const orgSub of orgSubs) {
    const orgPlan = orgSub.plan as "free" | "pro" | "business";
    if ((PLAN_TIER[orgPlan] ?? 0) > (PLAN_TIER[result.plan] ?? 0)) {
      result = {
        plan: orgPlan,
        source: "organization",
        organizationId: String(orgSub.organization_id),
        organizationName: orgSub.organization_name,
      };
    }
  }

  return result;
}
