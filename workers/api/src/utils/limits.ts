import type { Kysely } from "kysely";
import { sql } from "kysely";

import type { DB } from "../db-types";
import type { Bindings } from "../env";
import { UserAiUsage } from "../state/user-ai-usage";
import { FREE_AI_LIMITS } from "./ai-limits";
export type PlanKey = "free" | "core" | "pro" | "team";

/** twist.twist_package_id for the built-in Plot twist. */
export const BUILTIN_TWIST_PACKAGE_ID = "0199b6f4-ae64-7718-8a02-44716f30358f";

export const PLAN_LIMITS = {
  free: { connections: 2, twists: 1, syncHistoryDays: 7 },
  core: { connections: 5, twists: 2, syncHistoryDays: 30 },
  pro: { connections: Infinity, twists: Infinity, syncHistoryDays: 365 },
  team: { connections: Infinity, twists: Infinity, syncHistoryDays: 365 }, // team pool handled separately
};

export const TEAM_CONNECTIONS_PER_GROUP = 50;

/**
 * Returns the earliest date that should be included in initial sync,
 * based on the user's plan. Items older than this date (excluding
 * recurring events) should not be imported during initial sync.
 */
export function getSyncHistoryMinDate(plan: PlanKey): Date {
  const days = PLAN_LIMITS[plan].syncHistoryDays;
  const cutoff = new Date();
  cutoff.setDate(cutoff.getDate() - days);
  return cutoff;
}

export class PlanLimitError extends Error {
  readonly limitType: "connection" | "twist";
  readonly plan: string;
  readonly currentCount: number;
  readonly limit: number;
  readonly isTeam: boolean;
  readonly isAdmin: boolean;
  readonly teamId: string | null;

  constructor(opts: {
    limitType: "connection" | "twist";
    plan: string;
    currentCount: number;
    limit: number;
    isTeam: boolean;
    isAdmin: boolean;
    teamId: string | null;
  }) {
    const noun = opts.limitType === "connection" ? "connection" : "twist";
    super(`You've reached your ${noun} limit.`);
    this.name = "PlanLimitError";
    this.limitType = opts.limitType;
    this.plan = opts.plan;
    this.currentCount = opts.currentCount;
    this.limit = opts.limit;
    this.isTeam = opts.isTeam;
    this.isAdmin = opts.isAdmin;
    this.teamId = opts.teamId;
  }

  toJSON() {
    return {
      message: this.message,
      code: "plan_limit_exceeded",
      limit_type: this.limitType,
      plan: this.plan,
      current_count: this.currentCount,
      limit: this.limit,
      is_team: this.isTeam,
      is_admin: this.isAdmin,
      team_id: this.teamId,
    };
  }
}

export class SingleInstanceError extends Error {
  readonly scope: "personal" | "team";

  constructor(scope: "personal" | "team") {
    super(
      scope === "team"
        ? "This twist is already active for this team."
        : "This twist is already active in your personal workspace."
    );
    this.name = "SingleInstanceError";
    this.scope = scope;
  }

  toJSON() {
    return {
      message: this.message,
      code: "single_instance_conflict",
      scope: this.scope,
    };
  }
}

/**
 * Count personal connections: DISTINCT (twist_instance_id, provider, actor_id)
 * tuples where the connection belongs to a twist_instance owned by this
 * user personally (team_id IS NULL) and has at least one enabled channel.
 */
export async function getPersonalConnectionCount(
  db: Kysely<DB>,
  userId: string
): Promise<number> {
  const result = await db
    .selectFrom("twist_instance_connection as ptc")
    .innerJoin("twist_instance as pt", "pt.id", "ptc.twist_instance_id")
    .select(sql<string>`count(DISTINCT (ptc.twist_instance_id, ptc.provider, ptc.actor_id))`.as("count"))
    .where("ptc.user_id", "=", userId)
    .where("pt.team_id", "is", null)
    .where("pt.archived_at", "is", null)
    .where(({ exists, selectFrom }) =>
      exists(
        selectFrom("channel as sc")
          .whereRef("sc.twist_instance_id", "=", "ptc.twist_instance_id")
          .where("sc.enabled", "=", true)
          .select(sql`1`.as("x"))
      )
    )
    .executeTakeFirstOrThrow();

  return Number(result.count);
}

/**
 * Count team connections: DISTINCT (twist_instance_id, provider, actor_id)
 * tuples for twists owned by the given team with at least one enabled channel.
 */
export async function getTeamConnectionCount(
  db: Kysely<DB>,
  teamId: string
): Promise<number> {
  const result = await db
    .selectFrom("twist_instance_connection as ptc")
    .innerJoin("twist_instance as pt", "pt.id", "ptc.twist_instance_id")
    .select(sql<string>`count(DISTINCT (ptc.twist_instance_id, ptc.provider, ptc.actor_id))`.as("count"))
    .where("pt.team_id", "=", teamId)
    .where("pt.archived_at", "is", null)
    .where(({ exists, selectFrom }) =>
      exists(
        selectFrom("channel as sc")
          .whereRef("sc.twist_instance_id", "=", "ptc.twist_instance_id")
          .where("sc.enabled", "=", true)
          .select(sql`1`.as("x"))
      )
    )
    .executeTakeFirstOrThrow();

  return Number(result.count);
}

/**
 * Get the connection limit for a team based on connection_group_quantity.
 */
export async function getTeamConnectionLimit(
  db: Kysely<DB>,
  teamId: string
): Promise<number> {
  const sub = await db
    .selectFrom("team_subscription")
    .select("connection_group_quantity")
    .where("team_id", "=", teamId)
    .executeTakeFirst();

  if (!sub) return TEAM_CONNECTIONS_PER_GROUP; // default 1 group
  return sub.connection_group_quantity;
}

/**
 * Count personal non-source twists: non-archived twist_instance where
 * is_source = false, owner_id = userId, team_id IS NULL.
 */
export async function getPersonalTwistCount(
  db: Kysely<DB>,
  userId: string
): Promise<number> {
  const result = await db
    .selectFrom("twist_instance as pt")
    .innerJoin("twist as t", "t.id", "pt.twist_id")
    .select(sql<string>`count(DISTINCT pt.id)`.as("count"))
    .where("pt.owner_id", "=", userId)
    .where("pt.team_id", "is", null)
    .where("pt.archived_at", "is", null)
    .where("t.is_source", "=", false)
    .where("pt.draft", "=", false)
    .where("t.twist_package_id", "!=", BUILTIN_TWIST_PACKAGE_ID)
    .executeTakeFirstOrThrow();

  return Number(result.count);
}

/**
 * Count team non-source twists.
 */
export async function getTeamTwistCount(
  db: Kysely<DB>,
  teamId: string
): Promise<number> {
  const result = await db
    .selectFrom("twist_instance as pt")
    .innerJoin("twist as t", "t.id", "pt.twist_id")
    .select(sql<string>`count(DISTINCT pt.id)`.as("count"))
    .where("pt.team_id", "=", teamId)
    .where("pt.archived_at", "is", null)
    .where("t.is_source", "=", false)
    .where("pt.draft", "=", false)
    .where("t.twist_package_id", "!=", BUILTIN_TWIST_PACKAGE_ID)
    .executeTakeFirstOrThrow();

  return Number(result.count);
}

/**
 * Helper: look up the team_id of a twist_instance (null = personal).
 */
async function getTwistTeamId(
  db: Kysely<DB>,
  twistInstanceId: string
): Promise<string | null> {
  const row = await db
    .selectFrom("twist_instance")
    .select("team_id")
    .where("id", "=", twistInstanceId)
    .executeTakeFirst();
  return row?.team_id ? String(row.team_id) : null;
}

async function isTeamAdmin(
  db: Kysely<DB>,
  userId: string,
  teamId: string
): Promise<boolean> {
  const member = await db
    .selectFrom("team_user")
    .select("role")
    .where("team_id", "=", teamId)
    .where("user_id", "=", userId)
    .executeTakeFirst();
  return member?.role === "admin";
}

/**
 * Check if a user is a member of any team.
 */
export async function isUserInAnyTeam(
  db: Kysely<DB>,
  userId: string
): Promise<boolean> {
  const member = await db
    .selectFrom("team_user")
    .select("id")
    .where("user_id", "=", userId)
    .executeTakeFirst();
  return !!member;
}

/**
 * Get the user's personal plan.
 */
export async function getPersonalPlan(
  db: Kysely<DB>,
  userId: string
): Promise<PlanKey> {
  const sub = await db
    .selectFrom("user_subscription")
    .select(["plan", "status"])
    .where("user_id", "=", userId)
    .executeTakeFirst();

  return sub && (sub.status === "active" || sub.status === "trialing")
    ? (sub.plan as "free" | "core" | "pro" | "team")
    : "free";
}


/**
 * Check if enabling a channel would exceed connection limits.
 * Routes to the team-level or personal quota based on
 * `twist_instance.team_id`.
 */
export async function checkChannelConnectionLimit(
  db: Kysely<DB>,
  userId: string,
  twistInstanceId: string
): Promise<{ allowed: true } | { allowed: false; error: PlanLimitError }> {
  const connection = await db
    .selectFrom("twist_instance_connection")
    .select(["provider", "actor_id"])
    .where("twist_instance_id", "=", twistInstanceId)
    .where("user_id", "=", userId)
    .executeTakeFirst();

  // No connection record — source doesn't require auth, no limit applies
  if (!connection) {
    return { allowed: true };
  }

  const teamId = await getTwistTeamId(db, twistInstanceId);

  // Team-owned twist: team quota applies
  if (teamId) {
    const existingTeamChannel = await db
      .selectFrom("channel as sc")
      .innerJoin("twist_instance as pt", "pt.id", "sc.twist_instance_id")
      .where("sc.twist_instance_id", "=", twistInstanceId)
      .where("sc.enabled", "=", true)
      .where("pt.archived_at", "is", null)
      .where("pt.team_id", "=", teamId)
      .select(sql`1`.as("x"))
      .executeTakeFirst();

    if (existingTeamChannel) {
      return { allowed: true };
    }

    const teamSub = await db
      .selectFrom("team_subscription")
      .select(["plan", "status"])
      .where("team_id", "=", teamId)
      .executeTakeFirst();

    const teamPlan =
      teamSub && teamSub.status === "active"
        ? (teamSub.plan as "free" | "core" | "pro" | "team")
        : "free";

    if (teamPlan === "pro" || teamPlan === "core") {
      return { allowed: true };
    }

    if (teamPlan === "team") {
      const count = await getTeamConnectionCount(db, teamId);
      const limit = await getTeamConnectionLimit(db, teamId);
      if (count >= limit) {
        const admin = await isTeamAdmin(db, userId, teamId);
        return {
          allowed: false,
          error: new PlanLimitError({
            limitType: "connection",
            plan: teamPlan,
            currentCount: count,
            limit,
            isTeam: true,
            isAdmin: admin,
            teamId,
          }),
        };
      }
      return { allowed: true };
    }

    // Free team plan: no connections allowed
    const count = await getTeamConnectionCount(db, teamId);
    const admin = await isTeamAdmin(db, userId, teamId);
    return {
      allowed: false,
      error: new PlanLimitError({
        limitType: "connection",
        plan: teamPlan,
        currentCount: count,
        limit: 0,
        isTeam: true,
        isAdmin: admin,
        teamId,
      }),
    };
  }

  // Personal channel — check if this connector already has an enabled channel
  const existingPersonalChannel = await db
    .selectFrom("channel as sc")
    .innerJoin("twist_instance as pt", "pt.id", "sc.twist_instance_id")
    .where("sc.twist_instance_id", "=", twistInstanceId)
    .where("sc.enabled", "=", true)
    .where("pt.team_id", "is", null)
    .where("pt.archived_at", "is", null)
    .select(sql`1`.as("x"))
    .executeTakeFirst();

  if (existingPersonalChannel) {
    return { allowed: true };
  }

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
        isTeam: false,
        isAdmin: false,
        teamId: null,
      }),
    };
  }

  return { allowed: true };
}

/**
 * Check if adding a non-source twist is allowed. When `teamId` is provided
 * the twist counts against that team's quota; otherwise it counts against
 * the user's personal quota.
 */
export async function checkTwistLimit(
  db: Kysely<DB>,
  userId: string,
  teamId?: string | null
): Promise<{ allowed: true } | { allowed: false; error: PlanLimitError }> {
  if (teamId) {
    const teamSub = await db
      .selectFrom("team_subscription")
      .select(["plan", "status"])
      .where("team_id", "=", teamId)
      .executeTakeFirst();

    const teamPlan =
      teamSub && teamSub.status === "active"
        ? (teamSub.plan as "free" | "core" | "pro" | "team")
        : "free";

    // Paid team plans have unlimited twists
    if (teamPlan !== "free") return { allowed: true };

    const count = await getTeamTwistCount(db, teamId);
    const admin = await isTeamAdmin(db, userId, teamId);
    return {
      allowed: false,
      error: new PlanLimitError({
        limitType: "twist",
        plan: teamPlan,
        currentCount: count,
        limit: 0,
        isTeam: true,
        isAdmin: admin,
        teamId,
      }),
    };
  }

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
        isTeam: false,
        isAdmin: false,
        teamId: null,
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

  // Get team memberships with connection counts
  const teamMemberships = await db
    .selectFrom("team_user as tu")
    .innerJoin("team as t", "t.id", "tu.team_id")
    .leftJoin("team_subscription as ts", "ts.team_id", "tu.team_id")
    .select([
      "t.id as team_id",
      "t.name as team_name",
      "tu.role",
      "ts.plan as team_plan",
      "ts.connection_group_quantity",
    ])
    .where("tu.user_id", "=", userId)
    .execute();

  const teams = await Promise.all(
    teamMemberships.map(async (team) => {
      const teamId = String(team.team_id);
      const teamConnectionCount = await getTeamConnectionCount(db, teamId);
      const teamConnectionLimit =
        team.connection_group_quantity ?? TEAM_CONNECTIONS_PER_GROUP;

      return {
        id: teamId,
        name: team.team_name,
        connections: {
          count: teamConnectionCount,
          limit: teamConnectionLimit,
        },
        is_admin: team.role === "admin",
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
      syncHistoryDays: limits.syncHistoryDays,
      ...(ai ? { ai } : {}),
    },
    teams,
  };
}
