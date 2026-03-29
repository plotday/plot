import type { Kysely } from "kysely";
import { sql } from "kysely";

import type { DB } from "../db-types";
import type { Bindings } from "../env";
import { UserAiUsage } from "../state/user-ai-usage";
import { FREE_AI_LIMITS } from "./ai-limits";
export const PLAN_LIMITS = {
  free: { connections: 2, twists: 1 },
  core: { connections: 5, twists: 2 },
  pro: { connections: Infinity, twists: Infinity },
  team: { connections: Infinity, twists: Infinity }, // org pool handled separately
};

export const TEAM_CONNECTIONS_PER_GROUP = 50;

export class PlanLimitError extends Error {
  readonly limitType: "connection" | "twist";
  readonly plan: string;
  readonly currentCount: number;
  readonly limit: number;
  readonly isOrg: boolean;
  readonly isAdmin: boolean;
  readonly organizationId: string | null;

  constructor(opts: {
    limitType: "connection" | "twist";
    plan: string;
    currentCount: number;
    limit: number;
    isOrg: boolean;
    isAdmin: boolean;
    organizationId: string | null;
  }) {
    const noun = opts.limitType === "connection" ? "connection" : "twist";
    super(`You've reached your ${noun} limit.`);
    this.name = "PlanLimitError";
    this.limitType = opts.limitType;
    this.plan = opts.plan;
    this.currentCount = opts.currentCount;
    this.limit = opts.limit;
    this.isOrg = opts.isOrg;
    this.isAdmin = opts.isAdmin;
    this.organizationId = opts.organizationId;
  }

  toJSON() {
    return {
      message: this.message,
      code: "plan_limit_exceeded",
      limit_type: this.limitType,
      plan: this.plan,
      current_count: this.currentCount,
      limit: this.limit,
      is_org: this.isOrg,
      is_admin: this.isAdmin,
      organization_id: this.organizationId,
    };
  }
}

/**
 * Count personal connections: DISTINCT (provider, actor_id) pairs where the
 * connection has at least one enabled channel on a personal priority.
 */
export async function getPersonalConnectionCount(
  db: Kysely<DB>,
  userId: string
): Promise<number> {
  const result = await db
    .selectFrom("priority_twist_connection as ptc")
    .select(sql<string>`count(DISTINCT (ptc.provider, ptc.actor_id))`.as("count"))
    .where("ptc.user_id", "=", userId)
    .where(({ exists, selectFrom }) =>
      exists(
        selectFrom("source_channel as sc")
          .leftJoin("priority as p", "p.id", "sc.priority_id")
          .whereRef("sc.priority_twist_id", "=", "ptc.priority_twist_id")
          .where("sc.enabled", "=", true)
          .where((eb) =>
            eb.or([
              eb("sc.priority_id", "is", null),
              eb("p.organization_id", "is", null),
            ])
          )
          .select(sql`1`.as("x"))
      )
    )
    .executeTakeFirstOrThrow();

  return Number(result.count);
}

/**
 * Count org connections: DISTINCT (provider, actor_id) pairs where the
 * connection has at least one enabled channel on a priority in this org.
 */
export async function getOrgConnectionCount(
  db: Kysely<DB>,
  organizationId: string
): Promise<number> {
  const result = await db
    .selectFrom("priority_twist_connection as ptc")
    .select(sql<string>`count(DISTINCT (ptc.provider, ptc.actor_id))`.as("count"))
    .where(({ exists, selectFrom }) =>
      exists(
        selectFrom("source_channel as sc")
          .innerJoin("priority as p", "p.id", "sc.priority_id")
          .whereRef("sc.priority_twist_id", "=", "ptc.priority_twist_id")
          .where("sc.enabled", "=", true)
          .where("p.organization_id", "=", organizationId)
          .select(sql`1`.as("x"))
      )
    )
    .executeTakeFirstOrThrow();

  return Number(result.count);
}

/**
 * Get the connection limit for an org based on connection_group_quantity.
 */
export async function getOrgConnectionLimit(
  db: Kysely<DB>,
  organizationId: string
): Promise<number> {
  const sub = await db
    .selectFrom("organization_subscription")
    .select("connection_group_quantity")
    .where("organization_id", "=", organizationId)
    .executeTakeFirst();

  if (!sub) return TEAM_CONNECTIONS_PER_GROUP; // default 1 group
  return sub.connection_group_quantity;
}

/**
 * Count personal non-source twists: non-archived priority_twist where
 * is_source = false, owner_id = userId, priority's organization_id IS NULL.
 */
export async function getPersonalTwistCount(
  db: Kysely<DB>,
  userId: string
): Promise<number> {
  const result = await db
    .selectFrom("priority_twist as pt")
    .innerJoin("twist as t", "t.id", "pt.twist_id")
    .leftJoin("priority as p", "p.id", "pt.priority_id")
    .select(sql<string>`count(DISTINCT (pt.twist_id, COALESCE(pt.priority_id::text, '')))`.as("count"))
    .where("pt.owner_id", "=", userId)
    .where("pt.archived_at", "is", null)
    .where("t.is_source", "=", false)
    .where((eb) =>
      eb.or([
        eb("pt.priority_id", "is", null),
        eb("p.organization_id", "is", null),
      ])
    )
    .executeTakeFirstOrThrow();

  return Number(result.count);
}

/**
 * Get the user's personal plan.
 */
export async function getPersonalPlan(
  db: Kysely<DB>,
  userId: string
): Promise<"free" | "core" | "pro" | "team"> {
  const sub = await db
    .selectFrom("user_subscription")
    .select(["plan", "status"])
    .where("user_id", "=", userId)
    .executeTakeFirst();

  return sub && sub.status === "active"
    ? (sub.plan as "free" | "core" | "pro" | "team")
    : "free";
}

/**
 * Check if a user is an admin of an org.
 */
async function isOrgAdmin(
  db: Kysely<DB>,
  userId: string,
  organizationId: string
): Promise<boolean> {
  const member = await db
    .selectFrom("organization_member")
    .select("role")
    .where("organization_id", "=", organizationId)
    .where("user_id", "=", userId)
    .executeTakeFirst();

  return member?.role === "admin";
}

/**
 * Check if enabling a channel would exceed connection limits.
 * A connection slot is consumed the first time a (provider, actor_id) pair
 * has an enabled channel of a given type (personal or org).
 */
export async function checkChannelConnectionLimit(
  db: Kysely<DB>,
  userId: string,
  priorityTwistId: string,
  channelPriorityId: string | null
): Promise<{ allowed: true } | { allowed: false; error: PlanLimitError }> {
  // Determine if the channel's target priority is personal or org
  let organizationId: string | null = null;
  if (channelPriorityId) {
    const priority = await db
      .selectFrom("priority")
      .select("organization_id")
      .where("id", "=", channelPriorityId)
      .executeTakeFirst();
    organizationId = priority?.organization_id
      ? String(priority.organization_id)
      : null;
  }

  // Look up the connection's (provider, actor_id) for this user on this twist
  const connection = await db
    .selectFrom("priority_twist_connection")
    .select(["provider", "actor_id"])
    .where("priority_twist_id", "=", priorityTwistId)
    .where("user_id", "=", userId)
    .executeTakeFirst();

  // No connection record — source doesn't require auth, no limit applies
  if (!connection) {
    return { allowed: true };
  }

  // Check if this (provider, actor_id) already has an enabled channel of the same type
  // across any of the user's priority_twists. If so, no new slot is consumed.
  if (organizationId) {
    const existingOrgChannel = await db
      .selectFrom("priority_twist_connection as ptc")
      .innerJoin("source_channel as sc", "sc.priority_twist_id", "ptc.priority_twist_id")
      .innerJoin("priority as p", "p.id", "sc.priority_id")
      .where("ptc.user_id", "=", userId)
      .where("ptc.provider", "=", connection.provider)
      .where("ptc.actor_id", "=", connection.actor_id)
      .where("sc.enabled", "=", true)
      .where("p.organization_id", "=", organizationId)
      .select(sql`1`.as("x"))
      .executeTakeFirst();

    if (existingOrgChannel) {
      return { allowed: true };
    }

    // First channel of this type for this connection — check org limit
    const orgSub = await db
      .selectFrom("organization_subscription")
      .select(["plan", "status"])
      .where("organization_id", "=", organizationId)
      .executeTakeFirst();

    const orgPlan =
      orgSub && orgSub.status === "active"
        ? (orgSub.plan as "free" | "core" | "pro" | "team")
        : "free";

    if (orgPlan === "team") {
      const count = await getOrgConnectionCount(db, organizationId);
      const limit = await getOrgConnectionLimit(db, organizationId);
      if (count >= limit) {
        const admin = await isOrgAdmin(db, userId, organizationId);
        return {
          allowed: false,
          error: new PlanLimitError({
            limitType: "connection",
            plan: orgPlan,
            currentCount: count,
            limit,
            isOrg: true,
            isAdmin: admin,
            organizationId,
          }),
        };
      }
    }

    if (orgPlan === "free") {
      const count = await getOrgConnectionCount(db, organizationId);
      const admin = await isOrgAdmin(db, userId, organizationId);
      return {
        allowed: false,
        error: new PlanLimitError({
          limitType: "connection",
          plan: orgPlan,
          currentCount: count,
          limit: 0,
          isOrg: true,
          isAdmin: admin,
          organizationId,
        }),
      };
    }

    // Pro orgs: unlimited
    return { allowed: true };
  }

  // Personal channel — check if this connection already has a personal channel
  const existingPersonalChannel = await db
    .selectFrom("priority_twist_connection as ptc")
    .innerJoin("source_channel as sc", "sc.priority_twist_id", "ptc.priority_twist_id")
    .leftJoin("priority as p", "p.id", "sc.priority_id")
    .where("ptc.user_id", "=", userId)
    .where("ptc.provider", "=", connection.provider)
    .where("ptc.actor_id", "=", connection.actor_id)
    .where("sc.enabled", "=", true)
    .where((eb) =>
      eb.or([
        eb("sc.priority_id", "is", null),
        eb("p.organization_id", "is", null),
      ])
    )
    .select(sql`1`.as("x"))
    .executeTakeFirst();

  if (existingPersonalChannel) {
    return { allowed: true };
  }

  // First personal channel for this connection — check personal limit
  const plan = await getPersonalPlan(db, userId);
  const limits = PLAN_LIMITS[plan];

  if (limits.connections === Infinity) {
    return { allowed: true };
  }

  const count = await getPersonalConnectionCount(db, userId);
  if (count >= limits.connections) {
    return {
      allowed: false,
      error: new PlanLimitError({
        limitType: "connection",
        plan,
        currentCount: count,
        limit: limits.connections,
        isOrg: false,
        isAdmin: false,
        organizationId: null,
      }),
    };
  }

  return { allowed: true };
}

/**
 * Check if adding a non-source twist is allowed.
 */
export async function checkTwistLimit(
  db: Kysely<DB>,
  userId: string,
  targetPriorityId: string | null
): Promise<{ allowed: true } | { allowed: false; error: PlanLimitError }> {
  // Org priorities: twists are unlimited for any paid plan
  if (targetPriorityId) {
    const priority = await db
      .selectFrom("priority")
      .select("organization_id")
      .where("id", "=", targetPriorityId)
      .executeTakeFirst();

    if (priority?.organization_id) {
      // Org twists are always unlimited
      return { allowed: true };
    }
  }

  // Personal twist check
  const plan = await getPersonalPlan(db, userId);
  const limits = PLAN_LIMITS[plan];

  if (limits.twists === Infinity) {
    return { allowed: true };
  }

  const count = await getPersonalTwistCount(db, userId);
  if (count >= limits.twists) {
    return {
      allowed: false,
      error: new PlanLimitError({
        limitType: "twist",
        plan,
        currentCount: count,
        limit: limits.twists,
        isOrg: false,
        isAdmin: false,
        organizationId: null,
      }),
    };
  }

  return { allowed: true };
}

/**
 * Get usage data for a user (for the usage endpoint).
 */
export async function getUsage(
  db: Kysely<DB>,
  userId: string,
  env?: Bindings
) {
  const plan = await getPersonalPlan(db, userId);
  const limits = PLAN_LIMITS[plan];

  const connectionCount = await getPersonalConnectionCount(db, userId);
  const twistCount = await getPersonalTwistCount(db, userId);

  // Get org memberships with connection counts
  const orgMemberships = await db
    .selectFrom("organization_member as om")
    .innerJoin("organization as o", "o.id", "om.organization_id")
    .leftJoin(
      "organization_subscription as os",
      "os.organization_id",
      "om.organization_id"
    )
    .select([
      "o.id as organization_id",
      "o.name as organization_name",
      "om.role",
      "os.plan as org_plan",
      "os.connection_group_quantity",
    ])
    .where("om.user_id", "=", userId)
    .execute();

  const organizations = await Promise.all(
    orgMemberships.map(async (org) => {
      const orgId = String(org.organization_id);
      const orgConnectionCount = await getOrgConnectionCount(db, orgId);
      const orgConnectionLimit = org.connection_group_quantity ?? TEAM_CONNECTIONS_PER_GROUP;

      return {
        id: orgId,
        name: org.organization_name,
        connections: {
          count: orgConnectionCount,
          limit: orgConnectionLimit,
        },
        is_admin: org.role === "admin",
      };
    })
  );

  // Get AI usage for free plan users
  let ai = undefined;
  if (plan === "free" && env) {
    const aiUsage = await UserAiUsage.Get(env, userId).getUsage();
    ai = {
      note_processing: {
        count: aiUsage.note_processing ?? 0,
        limit: FREE_AI_LIMITS.note_processing,
      },
    };
  }

  return {
    personal: {
      connections: {
        count: connectionCount,
        limit: limits.connections === Infinity ? null : limits.connections,
      },
      twists: {
        count: twistCount,
        limit: limits.twists === Infinity ? null : limits.twists,
      },
      ...(ai ? { ai } : {}),
    },
    organizations,
  };
}
