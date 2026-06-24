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
 * Connection add-ons ("premium" connectors, e.g. Unipile-backed LinkedIn /
 * Instagram / WhatsApp) cost $5/mo each and can be enabled on any PAID plan.
 *
 * An add-on does two things at once:
 *  1. It still counts as a regular connection against `connections` — the
 *     plan's connection pool (e.g. 2 regular + 3 add-on = 5 of a Core plan).
 *  2. It additionally requires a purchased add-on credit
 *     (`premium_connection_addons`); the number of enabled connection add-ons
 *     may not exceed the number purchased.
 *
 * `addonsAllowed` is false only on Free (which cannot purchase add-ons), so
 * add-on connectors are effectively blocked there.
 */
export type PlanLimits = {
  connections: number;
  twists: number;
  syncHistoryDays: number;
  addonsAllowed: boolean;
};

export const PLAN_LIMITS: Record<PlanKey, PlanLimits> = {
  free: { connections: 2, twists: 1, syncHistoryDays: 7, addonsAllowed: false },
  core: { connections: 5, twists: 2, syncHistoryDays: 30, addonsAllowed: true },
  pro: { connections: Infinity, twists: Infinity, syncHistoryDays: 365, addonsAllowed: true },
  team: { connections: Infinity, twists: Infinity, syncHistoryDays: 365, addonsAllowed: true }, // team pool handled separately
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
  // Add-on connector on a plan that can't purchase add-ons (Free).
  | "addon_unavailable"
  // Paid plan, but no spare purchased add-on credit — must buy one.
  | "addon_required";

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
 * Includes add-on (premium) connectors — they consume a regular connection
 * slot like any other connection. (They ALSO require a purchased add-on
 * credit, tracked separately via `getPersonalPremiumConnectionCount`.)
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
 * Count personal connection add-ons (where `twist.premium = true`). The number
 * of enabled connection add-ons may not exceed the user's purchased add-on
 * credits (`getPersonalPremiumAddons`). These connections ALSO count toward the
 * regular pool (see `getPersonalConnectionCount`).
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
 * Get the number of purchased connection add-on credits for a user (the
 * `premium_connection_addons` count, populated by Stripe / App Store billing).
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
 * Connection add-ons count toward the regular pool AND require a purchased
 * add-on credit, so trimming happens in two passes (newest-first, so the user
 * keeps their most recent connections):
 *
 *   1. Add-on credits: keep the newest `addonCredits` connection add-ons (0
 *      when `addonsAllowed` is false, e.g. Free — it can't pay for any). Trim
 *      the rest, even when they'd fit the regular pool, otherwise we keep
 *      paying their per-account upstream cost.
 *   2. Regular pool: of the survivors (regulars + kept add-ons), keep the
 *      newest `connections` and trim the rest. `Infinity` never trims.
 */
export function selectConnectionsToTrim(
  connections: TrimmableConnection[],
  budget: { connections: number; addonsAllowed: boolean; addonCredits: number }
): TrimmableConnection[] {
  const newestFirst = (a: TrimmableConnection, b: TrimmableConnection) =>
    new Date(b.connectedAt).getTime() - new Date(a.connectedAt).getTime();

  const toTrim: TrimmableConnection[] = [];

  // Pass 1: connection add-ons beyond the purchased credit.
  const addons = connections.filter((c) => c.premium).sort(newestFirst);
  const addonKeep = budget.addonsAllowed ? budget.addonCredits : 0;
  const trimmedAddon = addons.slice(addonKeep);
  toTrim.push(...trimmedAddon);

  // Pass 2: of the survivors (everything not already trimmed), enforce the pool.
  if (budget.connections !== Infinity) {
    const trimmedIds = new Set(trimmedAddon.map((c) => c.twistInstanceId));
    const survivors = connections
      .filter((c) => !trimmedIds.has(c.twistInstanceId))
      .sort(newestFirst);
    toTrim.push(...survivors.slice(budget.connections));
  }

  return toTrim;
}

/**
 * Count team connections. Every connection — regular or add-on — consumes a
 * single slot from the shared pool; add-on connectors are no longer weighted
 * (they instead require a purchased add-on credit, like personal plans).
 * Mirrors the personal count so the total matches the Connections modal list.
 */
export async function getTeamConnectionCount(
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
 * Get the number of purchased connection add-on credits for a team (the
 * `premium_connection_addons` count, populated by Stripe billing).
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
 * `twist_instance.team_id`. Add-on connectors (twist.premium = true) require a
 * purchased add-on credit (`premium_connection_addons`) AND consume a regular
 * connection slot like any other connection:
 * - Free: add-ons can't be purchased → rejected with reason="addon_unavailable"
 * - Paid plan, no spare add-on credit → reason="addon_required"
 * - Every connector (add-on or not) is then checked against the pool limit.
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

  const { teamId, premium: isAddon } = await getTwistInstanceMeta(db, twistInstanceId);

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

    // Free team plan: no connections allowed at all.
    if (teamPlan === "free") {
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

    // Add-on connector: needs a spare purchased add-on credit (paid team plans
    // can all buy add-ons).
    if (isAddon) {
      const purchased = await getTeamPremiumAddons(db, teamId);
      const addonCount = await getTeamPremiumConnectionCount(db, teamId);
      if (addonCount >= purchased) {
        const admin = await isTeamAdmin(db, userId, teamId);
        return {
          allowed: false,
          error: new PlanLimitError({
            limitType: "connection",
            reason: "addon_required",
            plan: teamPlan,
            currentCount: addonCount,
            limit: purchased,
            isTeam: true,
            isAdmin: admin,
            teamId,
          }),
        };
      }
    }

    // Regular pool: only the `team` plan is pooled (per-50 groups). Team-Core /
    // Team-Pro have unlimited regular connections.
    if (teamPlan === "team") {
      const count = await getTeamConnectionCount(db, teamId);
      const limit = await getTeamConnectionLimit(db, teamId);
      if (count + 1 > limit) {
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
    }

    return { allowed: true };
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

  // Add-on connector enforcement: paid plan + a spare purchased add-on credit.
  if (isAddon) {
    if (!limits.addonsAllowed) {
      return {
        allowed: false,
        error: new PlanLimitError({
          limitType: "connection",
          reason: "addon_unavailable",
          plan,
          currentCount: 0,
          limit: 0,
          isTeam: false,
          isAdmin: false,
          teamId: null,
        }),
      };
    }
    const purchased = await getPersonalPremiumAddons(db, userId);
    const addonCount = await getPersonalPremiumConnectionCount(db, userId);
    if (addonCount >= purchased) {
      return {
        allowed: false,
        error: new PlanLimitError({
          limitType: "connection",
          reason: "addon_required",
          plan,
          currentCount: addonCount,
          limit: purchased,
          isTeam: false,
          isAdmin: false,
          teamId: null,
        }),
      };
    }
  }

  // Regular pool check — applies to every connector, add-on included (an add-on
  // consumes a regular slot too).
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
 * Count team connection add-ons (raw count). Used to enforce the team's
 * purchased add-on credits — the number of enabled connection add-ons may not
 * exceed `team_subscription.premium_connection_addons`.
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
 * Connection add-on usage for a personal or team scope.
 *
 * - `allowed`: whether the scope's plan can have connection add-ons (true on
 *   any paid plan; false on Free).
 * - `count`: connection add-ons currently enabled.
 * - `purchased`: add-on credits purchased (`premium_connection_addons`).
 *
 * The client needs a new add-on when `allowed && count >= purchased`.
 */
export type PremiumUsage = {
  allowed: boolean;
  count: number;
  purchased: number;
};

async function personalPremiumUsage(
  db: Kysely<DB>,
  userId: string,
  plan: PlanKey
): Promise<PremiumUsage> {
  const allowed = PLAN_LIMITS[plan].addonsAllowed;
  const count = await getPersonalPremiumConnectionCount(db, userId);
  const purchased = await getPersonalPremiumAddons(db, userId);
  return { allowed, count, purchased };
}

/**
 * Batched form of {@link getTeamConnectionCount} for many teams at once. Returns
 * a map keyed by team id; teams with no qualifying connections are absent
 * (treat as 0). Used by getUsage so the Connections modal issues a single
 * grouped query instead of one per team.
 */
async function getTeamConnectionCounts(
  db: Kysely<DB>,
  teamIds: string[]
): Promise<Map<string, number>> {
  if (teamIds.length === 0) return new Map();
  const rows = await db
    .selectFrom("twist_instance as pt")
    .innerJoin("twist as tw", "tw.id", "pt.twist_id")
    .select(["pt.team_id", sql<string>`count(*)`.as("count")])
    .where("pt.team_id", "in", teamIds)
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
    .groupBy("pt.team_id")
    .execute();
  return new Map(rows.map((r) => [String(r.team_id), Number(r.count)]));
}

/**
 * Batched form of {@link getTeamPremiumConnectionCount} for many teams at once.
 * Returns a map keyed by team id; teams with no premium connections are absent
 * (treat as 0).
 */
async function getTeamPremiumConnectionCounts(
  db: Kysely<DB>,
  teamIds: string[]
): Promise<Map<string, number>> {
  if (teamIds.length === 0) return new Map();
  const rows = await db
    .selectFrom("twist_instance as pt")
    .innerJoin("twist as tw", "tw.id", "pt.twist_id")
    .select(["pt.team_id", sql<string>`count(*)`.as("count")])
    .where("pt.team_id", "in", teamIds)
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
    .groupBy("pt.team_id")
    .execute();
  return new Map(rows.map((r) => [String(r.team_id), Number(r.count)]));
}

/**
 * Shape a team's add-on usage payload from pre-fetched counts (no DB access),
 * mirroring {@link personalPremiumUsage}, so getUsage can resolve every team
 * from batched aggregates instead of per-team queries.
 */
function shapeTeamPremiumUsage(
  plan: PlanKey,
  premiumCount: number,
  purchased: number
): PremiumUsage {
  return {
    allowed: PLAN_LIMITS[plan].addonsAllowed,
    count: premiumCount,
    purchased,
  };
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

  // Get team memberships with connection counts. `premium_connection_addons`
  // is pulled in via the existing subscription join so the per-team add-on
  // lookup is free.
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
      "ts.premium_connection_addons",
    ])
    .where("tu.user_id", "=", userId)
    .execute();

  // Resolve every team's connection/add-on counts in batched grouped queries
  // rather than two queries per team. The add-on aggregate is only needed when
  // at least one team is on a plan that can have add-ons (i.e. a paid plan).
  const teamIds = teamMemberships.map((team) => String(team.team_id));
  const teamPlanOf = (team: (typeof teamMemberships)[number]): PlanKey =>
    (team.team_plan as PlanKey | null | undefined) ?? "free";
  const anyPremiumTeam = teamMemberships.some(
    (team) => PLAN_LIMITS[teamPlanOf(team)].addonsAllowed
  );
  const [teamConnectionCounts, teamPremiumCounts] = await Promise.all([
    getTeamConnectionCounts(db, teamIds),
    anyPremiumTeam
      ? getTeamPremiumConnectionCounts(db, teamIds)
      : Promise.resolve(new Map<string, number>()),
  ]);

  const teams = teamMemberships.map((team) => {
    const teamId = String(team.team_id);
    // Free team plans (no active subscription) reject every connection in
    // checkChannelConnectionLimit regardless of connection_group_quantity,
    // so surface limit=0 here so the client's isAtLimit check matches the
    // server policy. Without this, EditSource pre-checks would say "ok"
    // and Save would 403 with plan_limit_exceeded.
    const teamPlan = teamPlanOf(team);
    const teamConnectionLimit =
      teamPlan === "pro" || teamPlan === "core"
        ? null
        : teamPlan === "team"
          ? team.connection_group_quantity ?? TEAM_CONNECTIONS_PER_GROUP
          : 0;
    const teamPremium = shapeTeamPremiumUsage(
      teamPlan,
      teamPremiumCounts.get(teamId) ?? 0,
      team.premium_connection_addons ?? 0
    );

    return {
      id: teamId,
      name: team.team_name,
      plan: teamPlan,
      connections: {
        count: teamConnectionCounts.get(teamId) ?? 0,
        limit: teamConnectionLimit,
      },
      premium: teamPremium,
      is_admin: team.role === "admin",
    };
  });

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
