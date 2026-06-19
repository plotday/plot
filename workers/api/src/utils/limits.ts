import type { Kysely } from "kysely";
import { sql } from "kysely";

import type { DB } from "../db-types";
import type { Bindings } from "../env";
import { UserAiUsage } from "../state/user-ai-usage";
import { FREE_AI_LIMITS } from "./ai-limits";
export type PlanKey = "free" | "core" | "pro" | "team";

/** twist.twist_package_id for the built-in Plot twist. */
export const BUILTIN_TWIST_PACKAGE_ID = "0199b6f4-ae64-7718-8a02-44716f30358f";

/**
 * Premium connection policy per plan.
 *
 * - `blocked`: connector is gated entirely; user must upgrade to enable it.
 * - `credits`: plan includes a fixed number of premium slots (+ add-ons).
 *   Premium connections do NOT count against the regular pool.
 * - `weighted`: premium connections share the regular pool but each one
 *   consumes `weightAsRegular` slots from it.
 */
export type PremiumPolicy =
  | { type: "blocked" }
  | { type: "credits"; included: number }
  | { type: "weighted"; weightAsRegular: number };

export type PlanLimits = {
  connections: number;
  twists: number;
  syncHistoryDays: number;
  premium: PremiumPolicy;
};

export const PLAN_LIMITS: Record<PlanKey, PlanLimits> = {
  free: { connections: 2, twists: 1, syncHistoryDays: 7, premium: { type: "blocked" } },
  core: { connections: 5, twists: 2, syncHistoryDays: 30, premium: { type: "blocked" } },
  pro: { connections: Infinity, twists: Infinity, syncHistoryDays: 365, premium: { type: "credits", included: 1 } },
  team: { connections: Infinity, twists: Infinity, syncHistoryDays: 365, premium: { type: "weighted", weightAsRegular: 3 } }, // team pool handled separately
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

export type PlanLimitReason =
  | "connection_limit"
  | "premium_blocked"
  | "premium_credit_exhausted";

export class PlanLimitError extends Error {
  readonly limitType: "connection" | "twist";
  readonly reason: PlanLimitReason;
  readonly plan: string;
  readonly currentCount: number;
  readonly limit: number;
  readonly isTeam: boolean;
  readonly isAdmin: boolean;
  readonly teamId: string | null;

  constructor(opts: {
    limitType: "connection" | "twist";
    reason?: PlanLimitReason;
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
    this.reason = opts.reason ?? "connection_limit";
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
      reason: this.reason,
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
 * Count personal connections: active source twist_instances owned by the
 * user personally (team_id IS NULL) with at least one enabled channel.
 *
 * This matches what the Connections modal shows in its "Active connections"
 * list (`/sources/summary` in app/twists.ts), so the count and the list are
 * always self-consistent. Counting `twist_instance_connection` rows would
 * undercount when a source borrows auth from a private auth twist or has
 * had its connection rows pruned while channels remain enabled.
 *
 * Excludes premium connectors — those are metered separately per
 * `getPersonalPremiumConnectionCount`.
 */
export async function getPersonalConnectionCount(
  db: Kysely<DB>,
  userId: string
): Promise<number> {
  const result = await db
    .selectFrom("twist_instance as pt")
    .innerJoin("twist as tw", "tw.id", "pt.twist_id")
    .select(sql<string>`count(*)`.as("count"))
    .where("pt.owner_id", "=", userId)
    .where("pt.team_id", "is", null)
    .where("pt.archived_at", "is", null)
    .where("tw.is_source", "=", true)
    .where("tw.premium", "=", false)
    .where(({ exists, selectFrom }) =>
      exists(
        selectFrom("channel as sc")
          .whereRef("sc.twist_instance_id", "=", "pt.id")
          .where("sc.enabled", "=", true)
          .select(sql`1`.as("x"))
      )
    )
    .executeTakeFirstOrThrow();

  return Number(result.count);
}

/**
 * Count personal premium connections (where `twist.premium = true`).
 * Premium credits are independent of the regular pool — used on plans
 * with a `credits` policy (Pro).
 */
export async function getPersonalPremiumConnectionCount(
  db: Kysely<DB>,
  userId: string
): Promise<number> {
  const result = await db
    .selectFrom("twist_instance as pt")
    .innerJoin("twist as tw", "tw.id", "pt.twist_id")
    .select(sql<string>`count(*)`.as("count"))
    .where("pt.owner_id", "=", userId)
    .where("pt.team_id", "is", null)
    .where("pt.archived_at", "is", null)
    .where("tw.is_source", "=", true)
    .where("tw.premium", "=", true)
    .where(({ exists, selectFrom }) =>
      exists(
        selectFrom("channel as sc")
          .whereRef("sc.twist_instance_id", "=", "pt.id")
          .where("sc.enabled", "=", true)
          .select(sql`1`.as("x"))
      )
    )
    .executeTakeFirstOrThrow();

  return Number(result.count);
}

/**
 * Get add-on premium connection credits for a user (beyond their plan default).
 * Wired now for forward-compatibility with paid add-ons; returns 0 today.
 */
export async function getPersonalPremiumAddons(
  db: Kysely<DB>,
  userId: string
): Promise<number> {
  const sub = await db
    .selectFrom("user_subscription")
    .select("premium_connection_addons")
    .where("user_id", "=", userId)
    .executeTakeFirst();
  return sub?.premium_connection_addons ?? 0;
}

/**
 * A user's connection reduced to what the downgrade trimmer needs: the keys
 * `removeIntegrationAccount` requires plus the premium flag and connect time
 * used to decide what to keep.
 */
export type TrimmableConnection = {
  twistInstanceId: string;
  provider: string;
  actorId: string;
  premium: boolean;
  connectedAt: Date | string;
};

/**
 * Pure decision for downgrade/cancel/trial-expiry trimming: given a user's
 * connections and the new plan's budget, return the connections to remove.
 *
 * Regular and premium connections are trimmed against SEPARATE budgets,
 * mirroring how the limits are enforced at add-time (`getPersonalConnectionCount`
 * excludes premium):
 *
 *   - Regular pool: keep the newest `connections`, trim older. `Infinity`
 *     never trims.
 *   - Premium pool, per the `premium` policy:
 *       blocked  → trim ALL premium. Free/Core gate premium entirely, so a
 *                  premium (e.g. Unipile-backed LinkedIn) connection must be
 *                  removed even when it fits within the regular budget —
 *                  otherwise we keep paying its per-account upstream cost.
 *       credits  → keep the newest `included + premiumAddons`, trim older.
 *       weighted → team-only; personal plans never use it, so leave premium
 *                  intact (team trimming is handled separately).
 *
 * Newest-first by `connectedAt` so the user keeps their most recent connections.
 */
export function selectConnectionsToTrim(
  connections: TrimmableConnection[],
  budget: { connections: number; premium: PremiumPolicy; premiumAddons?: number }
): TrimmableConnection[] {
  const newestFirst = (a: TrimmableConnection, b: TrimmableConnection) =>
    new Date(b.connectedAt).getTime() - new Date(a.connectedAt).getTime();

  const regular = connections.filter((c) => !c.premium).sort(newestFirst);
  const premium = connections.filter((c) => c.premium).sort(newestFirst);

  const toTrim: TrimmableConnection[] = [];

  if (budget.connections !== Infinity) {
    toTrim.push(...regular.slice(budget.connections));
  }

  switch (budget.premium.type) {
    case "blocked":
      toTrim.push(...premium);
      break;
    case "credits": {
      const keep = budget.premium.included + (budget.premiumAddons ?? 0);
      toTrim.push(...premium.slice(keep));
      break;
    }
    case "weighted":
      // Personal plans never use weighted; team trimming is handled separately.
      break;
  }

  return toTrim;
}

/**
 * Count team connections, weighting premium connectors by their plan's
 * `weightAsRegular` factor. Mirrors the personal count above so the total
 * matches the Connections modal list, but each premium connection consumes
 * more slots from the shared pool than a regular one.
 *
 * Currently the weight is taken from `PLAN_LIMITS.team.premium` (= 3); if
 * we ever vary the team weight per-plan, thread the policy through.
 */
export async function getTeamConnectionCount(
  db: Kysely<DB>,
  teamId: string
): Promise<number> {
  const teamPolicy = PLAN_LIMITS.team.premium;
  const weight =
    teamPolicy.type === "weighted" ? teamPolicy.weightAsRegular : 1;
  const result = await db
    .selectFrom("twist_instance as pt")
    .innerJoin("twist as tw", "tw.id", "pt.twist_id")
    .select(
      sql<string>`COALESCE(SUM(CASE WHEN tw.premium THEN ${weight} ELSE 1 END), 0)`.as("count")
    )
    .where("pt.team_id", "=", teamId)
    .where("pt.archived_at", "is", null)
    .where("tw.is_source", "=", true)
    .where(({ exists, selectFrom }) =>
      exists(
        selectFrom("channel as sc")
          .whereRef("sc.twist_instance_id", "=", "pt.id")
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
 * Get team premium connection add-on credits. Wired for forward-compat.
 */
export async function getTeamPremiumAddons(
  db: Kysely<DB>,
  teamId: string
): Promise<number> {
  const sub = await db
    .selectFrom("team_subscription")
    .select("premium_connection_addons")
    .where("team_id", "=", teamId)
    .executeTakeFirst();
  return sub?.premium_connection_addons ?? 0;
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
 * Helper: look up the team_id and premium flag of a twist_instance.
 */
async function getTwistInstanceMeta(
  db: Kysely<DB>,
  twistInstanceId: string
): Promise<{ teamId: string | null; premium: boolean }> {
  const row = await db
    .selectFrom("twist_instance as pt")
    .innerJoin("twist as tw", "tw.id", "pt.twist_id")
    .select(["pt.team_id", "tw.premium"])
    .where("pt.id", "=", twistInstanceId)
    .executeTakeFirst();
  return {
    teamId: row?.team_id ? String(row.team_id) : null,
    premium: !!row?.premium,
  };
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
 * `twist_instance.team_id`. Premium connectors (twist.premium = true) are
 * metered per-plan via PremiumPolicy:
 * - blocked: rejected outright with reason="premium_blocked"
 * - credits: counted against the per-user premium credit pool
 * - weighted: counted against the regular pool with a multiplier
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

  const { teamId, premium: isPremium } = await getTwistInstanceMeta(db, twistInstanceId);

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
    const policy = PLAN_LIMITS[teamPlan].premium;

    // Premium connector on a plan that blocks premium (team free/core)
    if (isPremium && policy.type === "blocked") {
      const admin = await isTeamAdmin(db, userId, teamId);
      return {
        allowed: false,
        error: new PlanLimitError({
          limitType: "connection",
          reason: "premium_blocked",
          plan: teamPlan,
          currentCount: 0,
          limit: 0,
          isTeam: true,
          isAdmin: admin,
          teamId,
        }),
      };
    }

    // Team-Pro / Team-Core: regular pool unlimited; premium uses credits
    if (teamPlan === "pro" || teamPlan === "core") {
      if (isPremium && policy.type === "credits") {
        const addons = await getTeamPremiumAddons(db, teamId);
        const limit = policy.included + addons;
        const count = await getTeamPremiumConnectionCount(db, teamId);
        if (count >= limit) {
          const admin = await isTeamAdmin(db, userId, teamId);
          return {
            allowed: false,
            error: new PlanLimitError({
              limitType: "connection",
              reason: "premium_credit_exhausted",
              plan: teamPlan,
              currentCount: count,
              limit,
              isTeam: true,
              isAdmin: admin,
              teamId,
            }),
          };
        }
      }
      return { allowed: true };
    }

    if (teamPlan === "team") {
      const count = await getTeamConnectionCount(db, teamId);
      const limit = await getTeamConnectionLimit(db, teamId);
      const candidateWeight =
        isPremium && policy.type === "weighted" ? policy.weightAsRegular : 1;
      if (count + candidateWeight > limit) {
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

  // Premium connector enforcement
  if (isPremium) {
    if (limits.premium.type === "blocked") {
      return {
        allowed: false,
        error: new PlanLimitError({
          limitType: "connection",
          reason: "premium_blocked",
          plan,
          currentCount: 0,
          limit: 0,
          isTeam: false,
          isAdmin: false,
          teamId: null,
        }),
      };
    }
    if (limits.premium.type === "credits") {
      const addons = await getPersonalPremiumAddons(db, userId);
      const limit = limits.premium.included + addons;
      const count = await getPersonalPremiumConnectionCount(db, userId);
      if (count >= limit) {
        return {
          allowed: false,
          error: new PlanLimitError({
            limitType: "connection",
            reason: "premium_credit_exhausted",
            plan,
            currentCount: count,
            limit,
            isTeam: false,
            isAdmin: false,
            teamId: null,
          }),
        };
      }
    }
    // Premium under `credits` policy doesn't consume the regular pool.
    return { allowed: true };
  }

  // Regular connector: classic personal pool check
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
 * Count team premium connections (raw count, unweighted). Used when a team
 * plan happens to use a `credits` policy for premium (currently only when
 * the team subscription is on Pro/Core; the default `team` plan uses
 * `weighted` instead and folds premium into the regular pool count).
 */
async function getTeamPremiumConnectionCount(
  db: Kysely<DB>,
  teamId: string
): Promise<number> {
  const result = await db
    .selectFrom("twist_instance as pt")
    .innerJoin("twist as tw", "tw.id", "pt.twist_id")
    .select(sql<string>`count(*)`.as("count"))
    .where("pt.team_id", "=", teamId)
    .where("pt.archived_at", "is", null)
    .where("tw.is_source", "=", true)
    .where("tw.premium", "=", true)
    .where(({ exists, selectFrom }) =>
      exists(
        selectFrom("channel as sc")
          .whereRef("sc.twist_instance_id", "=", "pt.id")
          .where("sc.enabled", "=", true)
          .select(sql`1`.as("x"))
      )
    )
    .executeTakeFirstOrThrow();

  return Number(result.count);
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
 * Shape the premium-usage payload for a personal or team scope. The
 * discriminator (`policy`) mirrors PremiumPolicy so the client can render
 * the right UI without knowing the plan tier directly.
 */
export type PremiumUsage =
  | { policy: "blocked" }
  | { policy: "credits"; count: number; included: number; addons: number; limit: number }
  | { policy: "weighted"; count: number; weight: number };

async function personalPremiumUsage(
  db: Kysely<DB>,
  userId: string,
  plan: PlanKey
): Promise<PremiumUsage> {
  const policy = PLAN_LIMITS[plan].premium;
  if (policy.type === "blocked") return { policy: "blocked" };
  if (policy.type === "credits") {
    const count = await getPersonalPremiumConnectionCount(db, userId);
    const addons = await getPersonalPremiumAddons(db, userId);
    return {
      policy: "credits",
      count,
      included: policy.included,
      addons,
      limit: policy.included + addons,
    };
  }
  // weighted
  const count = await getPersonalPremiumConnectionCount(db, userId);
  return { policy: "weighted", count, weight: policy.weightAsRegular };
}

async function teamPremiumUsage(
  db: Kysely<DB>,
  teamId: string,
  plan: PlanKey
): Promise<PremiumUsage> {
  const policy = PLAN_LIMITS[plan].premium;
  if (policy.type === "blocked") return { policy: "blocked" };
  if (policy.type === "credits") {
    const count = await getTeamPremiumConnectionCount(db, teamId);
    const addons = await getTeamPremiumAddons(db, teamId);
    return {
      policy: "credits",
      count,
      included: policy.included,
      addons,
      limit: policy.included + addons,
    };
  }
  // weighted (default team plan)
  const count = await getTeamPremiumConnectionCount(db, teamId);
  return { policy: "weighted", count, weight: policy.weightAsRegular };
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
  const premium = await personalPremiumUsage(db, userId, plan);

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
      // Free team plans (no active subscription) reject every connection in
      // checkChannelConnectionLimit regardless of connection_group_quantity,
      // so surface limit=0 here so the client's isAtLimit check matches the
      // server policy. Without this, EditSource pre-checks would say "ok"
      // and Save would 403 with plan_limit_exceeded.
      const teamPlan = (team.team_plan as
        | "free"
        | "core"
        | "pro"
        | "team"
        | null
        | undefined) ?? "free";
      const teamConnectionLimit =
        teamPlan === "pro" || teamPlan === "core"
          ? null
          : teamPlan === "team"
            ? team.connection_group_quantity ?? TEAM_CONNECTIONS_PER_GROUP
            : 0;
      const teamPremium = await teamPremiumUsage(db, teamId, teamPlan);

      return {
        id: teamId,
        name: team.team_name,
        plan: teamPlan,
        connections: {
          count: teamConnectionCount,
          limit: teamConnectionLimit,
        },
        premium: teamPremium,
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
      premium,
      syncHistoryDays: limits.syncHistoryDays,
      ...(ai ? { ai } : {}),
    },
    teams,
  };
}
