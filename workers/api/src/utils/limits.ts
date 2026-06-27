import type { Kysely } from "kysely";
import { sql } from "kysely";

import type { DB } from "../db-types";
import type { Bindings } from "../env";
export type PlanKey = "free" | "pro" | "team";

/** twist.twist_package_id for the built-in Plot twist. */
export const BUILTIN_TWIST_PACKAGE_ID = "0199b6f4-ae64-7718-8a02-44716f30358f";

/**
 * Connection add-ons ("premium" connectors, e.g. Unipile-backed LinkedIn /
 * Instagram / WhatsApp) cost $5/mo each and are independent of the user's
 * plan — they are available on every plan, including Free. Admission is
 * governed solely by purchased add-on credits (`premium_connection_addons`):
 * the number of enabled connection add-ons may not exceed the number
 * purchased. Add-ons do NOT consume a plan connection-pool slot; they are
 * billed separately and independent of `connections`.
 */
export type PlanLimits = {
  connections: number;
  /**
   * Legacy flat-count limit used only by the downgrade/trial-expiry twist trim
   * (`utils/trial.ts` and `twist/management.ts`). NOT used at install/activate
   * time; `twistCapacity` is the enable-time weighted capacity.
   */
  twists: number;
  /**
   * Enable-time weighted twist-capacity limit. Σ capacity_weight of all
   * installed non-source non-built-in twists must not exceed this value plus
   * 20 × purchased twist-add-on blocks. See `checkTwistCapacity`.
   * Cross-reference: `twists` (above) is the legacy flat-count limit used only
   * by the downgrade/trial-expiry trim.
   */
  twistCapacity: number;
  syncHistoryDays: number;
};

export const PLAN_LIMITS: Record<PlanKey, PlanLimits> = {
  free: { connections: 2, twists: 1, twistCapacity: 1, syncHistoryDays: 7 },
  pro: { connections: Infinity, twists: Infinity, twistCapacity: 10, syncHistoryDays: 365 },
  team: { connections: Infinity, twists: Infinity, twistCapacity: 10, syncHistoryDays: 365 }, // 10 per 50-block; multiplied by connection_group_quantity
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
  // No spare purchased add-on credit — must buy one.
  | "addon_required"
  | "twist_addon_required";

export class PlanLimitError extends Error {
  readonly limitType: "connection" | "twist";
  readonly reason: PlanLimitReason;
  readonly plan: string;
  readonly currentCount: number;
  readonly limit: number;
  readonly isTeam: boolean;
  readonly isAdmin: boolean;
  readonly teamId: string | null;
  /**
   * The capacity_weight of the blocked candidate twist. Included only on
   * `twist_addon_required` errors so the client can echo it back to the
   * `/upgrade/twist-addons/purchase` endpoint as `candidateWeight`, which
   * threads the pending weight through `twistAddonBlocksNeeded` to compute
   * the correct target block count. Optional and absent on connection errors.
   */
  readonly candidateWeight?: number;

  constructor(opts: {
    limitType: "connection" | "twist";
    reason?: PlanLimitReason;
    plan: string;
    currentCount: number;
    limit: number;
    isTeam: boolean;
    isAdmin: boolean;
    teamId: string | null;
    candidateWeight?: number;
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
    if (opts.candidateWeight !== undefined) {
      this.candidateWeight = opts.candidateWeight;
    }
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
      ...(this.candidateWeight !== undefined ? { candidate_weight: this.candidateWeight } : {}),
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
 * Excludes add-on (premium) connectors — they are billed separately and do not
 * consume a plan connection slot. The add-on count is tracked independently via
 * `getPersonalPremiumConnectionCount` + `premium_connection_addons`.
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
 * Count personal connection add-ons (where `twist.premium = true`). The number
 * of enabled connection add-ons may not exceed the user's purchased add-on
 * credits (`getPersonalPremiumAddons`). Add-ons do NOT count toward the regular
 * connection pool.
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
 * Billable connection add-ons for a scope: regular connections beyond the
 * included pool PLUS active add-on-required (premium) connectors. This is the
 * usage-synced quantity for the standalone connection add-on subscription
 * (Stripe). On Pro/Team-unlimited the first term is 0 (∞ pool).
 */
export async function getBillableConnectionAddonCount(
  db: Kysely<DB>,
  scope: { userId: string } | { teamId: string }
): Promise<number> {
  if ("teamId" in scope) {
    const { teamId } = scope;
    const regular = await getTeamConnectionCount(db, teamId);
    // NOTE: getTeamConnectionLimit is NOT status-gated (it returns the purchased
    // block pool, defaulting to one 50-block when no sub exists — not 0 for a
    // free/lapsed team). This is safe here only because a free team is
    // hard-blocked from accruing regular connections upstream in
    // checkChannelConnectionLimit (the `teamPlan === "free"` branch), so
    // `regular` is ~0 for such teams and the first term is 0 regardless.
    const pool = await getTeamConnectionLimit(db, teamId);
    const addonRequired = await getTeamPremiumConnectionCount(db, teamId);
    return Math.max(0, regular - pool) + addonRequired;
  }
  const { userId } = scope;
  const { plan, trialActive } = await getPersonalConnectionContext(db, userId);
  // During an active 30-day trial the connection pool is unlimited (∞), so
  // no regular connection is "over pool" and the over-pool term is always 0.
  const pool = trialActive ? Infinity : PLAN_LIMITS[plan].connections;
  const regular = await getPersonalConnectionCount(db, userId);
  const addonRequired = await getPersonalPremiumConnectionCount(db, userId);
  const overPool = pool === Infinity ? 0 : Math.max(0, regular - pool);
  return overPool + addonRequired;
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

/** Purchased twist-add-on blocks for a personal scope (each = +20 capacity). */
export async function getPersonalTwistAddonCount(
  db: Kysely<DB>,
  userId: string
): Promise<number> {
  const sub = await db
    .selectFrom("user_subscription")
    .select("twist_addon_count")
    .where("user_id", "=", userId)
    .executeTakeFirst();
  return sub?.twist_addon_count ?? 0;
}

/**
 * Pure: how many twist-add-on blocks are needed to cover `weightSum` given
 * a plan base capacity. Each block adds 20 capacity units.
 *
 * `ceil(max(0, weightSum + pendingWeight − base) / 20)`
 *
 * `pendingWeight` (default 0) is the capacity_weight of a not-yet-installed
 * candidate twist whose weight must be included in the overflow calculation.
 * Pass it when the blocked candidate's weight is known (e.g. from the
 * `twist_addon_required` error payload) so the purchase computes the correct
 * target block count rather than under-counting installed-only weight.
 */
export function computeTwistBlocksNeeded(weightSum: number, base: number, pendingWeight = 0): number {
  return Math.ceil(Math.max(0, weightSum + pendingWeight - base) / 20);
}

/**
 * How many twist-add-on blocks the given scope needs to cover its installed
 * twist-weight sum (plus any pending candidate weight) at its current plan.
 *
 * - Personal: `base = PLAN_LIMITS[plan].twistCapacity`; plan via
 *   `getPersonalPlan` (lapsed → "free").
 * - Team: `base = PLAN_LIMITS.team.twistCapacity × connection_group_quantity`
 *   when the team sub is active, else 0 (free team has no capacity).
 *
 * `pendingWeight` (default 0) is the capacity_weight of a not-yet-installed
 * candidate twist (draft=true or not yet inserted) that is blocked and needs
 * add-on coverage. Pass it from the `candidate_weight` field on the
 * `twist_addon_required` error so the purchase endpoint charges for the right
 * number of blocks rather than under-counting installed-only weight.
 *
 * Returns the number of blocks that must be purchased (0 when already within
 * capacity). Used by the twist-add-on purchase endpoint and the reconcile-down
 * path.
 */
export async function twistAddonBlocksNeeded(
  db: Kysely<DB>,
  scope: { userId: string } | { teamId: string },
  pendingWeight = 0
): Promise<number> {
  if ("teamId" in scope) {
    const teamId = (scope as { teamId: string }).teamId;
    const teamSub = await db
      .selectFrom("team_subscription")
      .select(["plan", "status", "connection_group_quantity"])
      .where("team_id", "=", teamId)
      .executeTakeFirst();
    const rawPlan = (teamSub?.plan as string) ?? "free";
    const plan: PlanKey =
      teamSub && teamSub.status === "active"
        ? ((rawPlan === "core" ? "free" : rawPlan) as PlanKey)
        : "free";
    const blocks = teamSub?.connection_group_quantity ?? 1;
    const base = plan === "free" ? 0 : PLAN_LIMITS.team.twistCapacity * blocks;
    const weightSum = await getTeamTwistWeightSum(db, teamId);
    return computeTwistBlocksNeeded(weightSum, base, pendingWeight);
  }
  const userId = (scope as { userId: string }).userId;
  const plan = await getPersonalPlan(db, userId);
  const base = PLAN_LIMITS[plan].twistCapacity;
  const weightSum = await getPersonalTwistWeightSum(db, userId);
  return computeTwistBlocksNeeded(weightSum, base, pendingWeight);
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
 * Credits are consumed by premium (add-on-required) connectors first; any
 * leftover credits extend the regular pool. Oldest-first ordering ensures the
 * user keeps their most foundational/oldest connections on downgrade.
 *
 *   1. Add-on credits: keep the oldest `addonCredits` connection add-ons.
 *      Trim the newest excess — preserves foundational installs on downgrade.
 *   2. Regular pool: keep the oldest `connections + creditsForRegular` non-add-on
 *      connections, where `creditsForRegular = max(0, addonCredits − premiumCount)`.
 *      Credits not consumed by premium connectors spill over to cover over-pool
 *      regulars, so a user who paid for 3 credits but only has 1 premium connector
 *      keeps 2 extra regulars. `Infinity` never trims.
 */
export function selectConnectionsToTrim(
  connections: TrimmableConnection[],
  budget: { connections: number; addonCredits: number }
): TrimmableConnection[] {
  const oldestFirst = (a: TrimmableConnection, b: TrimmableConnection) =>
    new Date(a.connectedAt).getTime() - new Date(b.connectedAt).getTime();

  const toTrim: TrimmableConnection[] = [];

  // Pass 1: connection add-ons beyond the purchased credit — keep the OLDEST,
  // trim the newest excess (preserve foundational installs).
  const addons = connections.filter((c) => c.premium).sort(oldestFirst);
  toTrim.push(...addons.slice(budget.addonCredits));

  // Pass 2: regular (non-add-on) connections beyond the pool — keep the OLDEST,
  // trim the newest. Credits not fully consumed by premium connectors spill over
  // and extend the regular pool.
  if (budget.connections !== Infinity) {
    const regulars = connections.filter((c) => !c.premium).sort(oldestFirst);
    const creditsForRegular = Math.max(0, budget.addonCredits - addons.length);
    toTrim.push(...regulars.slice(budget.connections + creditsForRegular));
  }

  return toTrim;
}

/**
 * Count team connections (non-premium only). Add-on connectors (`premium =
 * true`) are excluded from the pool and never pool-trimmed; they require a
 * purchased add-on credit. Mirrors the personal count so the total matches the
 * Connections modal list.
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
 * Σ capacity_weight over a user's installed twists: non-archived,
 * non-draft, non-source twist instances, excluding the built-in assistant
 * (which is excluded from capacity sums). Drives the weighted twist-capacity check.
 */
export async function getPersonalTwistWeightSum(
  db: Kysely<DB>,
  userId: string
): Promise<number> {
  const row = await db
    .selectFrom("twist_instance as pt")
    .innerJoin("twist as t", "t.id", "pt.twist_id")
    .select(sql<string>`sum(t.capacity_weight)`.as("weight"))
    .where("pt.owner_id", "=", userId)
    .where("pt.team_id", "is", null)
    .where("pt.archived_at", "is", null)
    .where("t.is_source", "=", false)
    .where("pt.draft", "=", false)
    .where("t.twist_package_id", "!=", BUILTIN_TWIST_PACKAGE_ID)
    .executeTakeFirst();
  return Number(row?.weight ?? 0);
}

/** Team equivalent of {@link getPersonalTwistWeightSum}. */
export async function getTeamTwistWeightSum(
  db: Kysely<DB>,
  teamId: string
): Promise<number> {
  const row = await db
    .selectFrom("twist_instance as pt")
    .innerJoin("twist as t", "t.id", "pt.twist_id")
    .select(sql<string>`sum(t.capacity_weight)`.as("weight"))
    .where("pt.team_id", "=", teamId)
    .where("pt.archived_at", "is", null)
    .where("t.is_source", "=", false)
    .where("pt.draft", "=", false)
    .where("t.twist_package_id", "!=", BUILTIN_TWIST_PACKAGE_ID)
    .executeTakeFirst();
  return Number(row?.weight ?? 0);
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

  if (sub && (sub.status === "active" || sub.status === "trialing")) {
    // Map legacy 'core' DB value → 'free' at the read boundary.
    const raw = sub.plan as string;
    return (raw === "core" ? "free" : raw) as PlanKey;
  }
  return "free";
}

/**
 * Fetch the user's personal plan + trial status in one query, for use by
 * connection-pool checks that need to know whether the 30-day connections trial
 * is active. `trialActive = trial_ends_at > now()`.
 *
 * The plan follows the same status-gating as `getPersonalPlan` (lapsed/absent
 * subscription → "free"). Legacy "core" DB values are mapped to "free" at
 * the read boundary (B5 Task 3).
 */
export async function getPersonalConnectionContext(
  db: Kysely<DB>,
  userId: string
): Promise<{ plan: PlanKey; trialActive: boolean }> {
  const sub = await db
    .selectFrom("user_subscription")
    .select(["plan", "status", "trial_ends_at"])
    .where("user_id", "=", userId)
    .executeTakeFirst();

  const rawPlan = sub?.plan as string | undefined;
  const plan: PlanKey =
    sub && (sub.status === "active" || sub.status === "trialing")
      ? ((rawPlan === "core" ? "free" : rawPlan) as PlanKey)
      : "free";

  const trialActive =
    sub?.trial_ends_at != null && new Date(sub.trial_ends_at) > new Date();

  return { plan, trialActive };
}


/**
 * Check if enabling a channel would exceed connection limits.
 * Routes to the team-level or personal quota based on `twist_instance.team_id`.
 *
 * Add-on connectors (twist.premium = true) are independent of the plan pool:
 * - Allowed on ANY plan (including Free) when there is a spare purchased
 *   add-on credit (`premium_connection_addons`). Resolves immediately on
 *   success — never falls through to the pool check.
 * - Rejected with reason="addon_required" when no spare credit exists.
 *
 * Regular connectors (twist.premium = false) are checked against the plan's
 * connection pool only; add-on credits are irrelevant to them.
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

    const rawTeamPlan = teamSub?.plan as string | undefined;
    const teamPlan: PlanKey =
      teamSub && teamSub.status === "active"
        ? ((rawTeamPlan === "core" ? "free" : rawTeamPlan) as PlanKey)
        : "free";

    // Add-on connector: independent of the team plan. Allowed when there is a
    // spare purchased add-on credit; never consumes a plan pool slot.
    // Gate on the BILLABLE formula (overPool regulars + premium) so credits
    // consumed by over-pool regulars are correctly counted here.
    if (isAddon) {
      const purchased = await getTeamPremiumAddons(db, teamId);
      const addonCount = await getTeamPremiumConnectionCount(db, teamId);
      const pendingBillable = (await getBillableConnectionAddonCount(db, { teamId })) + 1;
      if (pendingBillable > purchased) {
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
      return { allowed: true };
    }

    // Free team plan: no regular connections allowed at all.
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

    // Regular pool: only the `team` plan is pooled (per-50 groups). Team-Pro
    // has unlimited regular connections. Beyond the pool, regular
    // connectors require connection-add-on headroom → addon_required.
    if (teamPlan === "team") {
      const count = await getTeamConnectionCount(db, teamId);
      const limit = await getTeamConnectionLimit(db, teamId);
      const pendingBillable =
        Math.max(0, count + 1 - limit) +
        (await getTeamPremiumConnectionCount(db, teamId));
      const purchased = await getTeamPremiumAddons(db, teamId);
      if (pendingBillable > purchased) {
        const admin = await isTeamAdmin(db, userId, teamId);
        return {
          allowed: false,
          error: new PlanLimitError({
            limitType: "connection",
            reason: "addon_required",
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

  const { plan, trialActive } = await getPersonalConnectionContext(db, userId);
  const limits = PLAN_LIMITS[plan];

  // Add-on connector: independent of the plan. Allowed when there is a spare
  // purchased add-on credit; never consumes a plan pool slot.
  // Gate on the BILLABLE formula (overPool regulars + premium) so credits
  // consumed by over-pool regulars are correctly counted here.
  if (isAddon) {
    const purchased = await getPersonalPremiumAddons(db, userId);
    const addonCount = await getPersonalPremiumConnectionCount(db, userId);
    const pendingBillable = (await getBillableConnectionAddonCount(db, { userId })) + 1;
    if (pendingBillable > purchased) {
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
    return { allowed: true };
  }

  // Regular connector. Within the effective pool it's free; beyond the pool it
  // requires connection-add-on headroom (same $5 credit as an add-on-required
  // connector). The client offers "add-on or upgrade" (web) / "upgrade" (App
  // Store); the server is platform-agnostic and returns addon_required.
  //
  // During an active 30-day trial the effective pool is unlimited (∞) so every
  // regular connection is allowed without any add-on credit. The trial only
  // unlocks connections — twistCapacity and syncHistoryDays are unchanged.
  const effectivePool = trialActive ? Infinity : limits.connections;
  if (effectivePool === Infinity) {
    return { allowed: true };
  }
  // getBillableConnectionAddonCount counts CURRENTLY-enabled connections; the
  // one under test is not yet enabled, so adding it pushes regular by 1 when it
  // is beyond the pool. Recompute with the pending regular connection included:
  const regularNow = await getPersonalConnectionCount(db, userId);
  const pendingBillable =
    Math.max(0, regularNow + 1 - effectivePool) +
    (await getPersonalPremiumConnectionCount(db, userId));
  const purchased = await getPersonalPremiumAddons(db, userId);
  if (pendingBillable > purchased) {
    return {
      allowed: false,
      error: new PlanLimitError({
        limitType: "connection",
        reason: "addon_required",
        plan,
        currentCount: regularNow,
        limit: effectivePool,
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
export async function getTeamPremiumConnectionCount(
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
 * Weighted twist-capacity check. Allowed when the scope's installed twist
 * weight plus the candidate's weight is within capacity. Capacity = plan base
 * (Free 1 · Pro 10 · Team 10 per 50-block) + 20 × purchased twist-add-on blocks.
 * Over capacity returns reason "twist_addon_required" (buy a block or upgrade).
 */
export async function checkTwistCapacity(
  db: Kysely<DB>,
  userId: string,
  teamId: string | null,
  candidateWeight: number
): Promise<{ allowed: true } | { allowed: false; error: PlanLimitError }> {
  if (teamId) {
    const teamSub = await db
      .selectFrom("team_subscription")
      .select(["plan", "status", "connection_group_quantity", "twist_addon_count"])
      .where("team_id", "=", teamId)
      .executeTakeFirst();
    const rawTeamPlan = (teamSub?.plan as string) ?? "free";
    const plan: PlanKey =
      teamSub && teamSub.status === "active"
        ? ((rawTeamPlan === "core" ? "free" : rawTeamPlan) as PlanKey)
        : "free";
    const blocks = teamSub?.connection_group_quantity ?? 1;
    const addons = teamSub?.twist_addon_count ?? 0;
    const capacity =
      plan === "free"
        ? 0
        : PLAN_LIMITS.team.twistCapacity * blocks + 20 * addons;
    const used = await getTeamTwistWeightSum(db, teamId);
    if (used + candidateWeight <= capacity) return { allowed: true };
    return {
      allowed: false,
      error: new PlanLimitError({
        limitType: "twist",
        reason: "twist_addon_required",
        plan,
        currentCount: used,
        limit: capacity,
        isTeam: true,
        isAdmin: false,
        teamId,
        candidateWeight,
      }),
    };
  }

  const plan = await getPersonalPlan(db, userId);
  const addons = await getPersonalTwistAddonCount(db, userId);
  const capacity = PLAN_LIMITS[plan].twistCapacity + 20 * addons;
  const used = await getPersonalTwistWeightSum(db, userId);
  if (used + candidateWeight <= capacity) return { allowed: true };
  return {
    allowed: false,
    error: new PlanLimitError({
      limitType: "twist",
      reason: "twist_addon_required",
      plan,
      currentCount: used,
      limit: capacity,
      isTeam: false,
      isAdmin: false,
      teamId: null,
      candidateWeight,
    }),
  };
}

/**
 * Connection add-on usage for a personal or team scope.
 *
 * - `allowed`: always true — add-ons are available on every plan, including
 *   Free. Retained for backwards compatibility with older clients.
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
  userId: string
): Promise<PremiumUsage> {
  // Add-ons are available on every plan now; `allowed` is retained in the
  // payload only for backwards compatibility with older clients.
  // `count` is the BILLABLE quantity (overPool regulars + premium) so the
  // client's "spare credit" check (count >= purchased) is consistent with the
  // enable gate in checkChannelConnectionLimit.
  const allowed = true;
  const count = await getBillableConnectionAddonCount(db, { userId });
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
    .where("tw.premium", "=", false)
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
 *
 * `billableCount` is the BILLABLE quantity (overPool regulars + premium) so the
 * client's "spare credit" check (count >= purchased) matches the enable gate.
 */
function shapeTeamPremiumUsage(billableCount: number, purchased: number): PremiumUsage {
  return {
    // Add-ons are available on every plan now; `allowed` is retained in the
    // payload only for backwards compatibility with older clients.
    allowed: true,
    count: billableCount,
    purchased,
  };
}

/**
 * Get usage data for a user (for the usage endpoint).
 */
export async function getUsage(
  db: Kysely<DB>,
  userId: string,
  _env?: Bindings
) {
  const { plan, trialActive } = await getPersonalConnectionContext(db, userId);
  const limits = PLAN_LIMITS[plan];

  const connectionCount = await getPersonalConnectionCount(db, userId);
  const twistWeightSum = await getPersonalTwistWeightSum(db, userId);
  const twistAddonCount = await getPersonalTwistAddonCount(db, userId);
  const twistCapacity = limits.twistCapacity + 20 * twistAddonCount;
  const premium = await personalPremiumUsage(db, userId);

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
  // rather than two queries per team. The add-on aggregate is fetched whenever
  // the user has any team, since add-ons are available on every plan.
  const teamIds = teamMemberships.map((team) => String(team.team_id));
  // Map legacy 'core' DB value to 'free' at the read boundary.
  const teamPlanOf = (team: (typeof teamMemberships)[number]): PlanKey => {
    const raw = (team.team_plan as string | null | undefined) ?? "free";
    return (raw === "core" ? "free" : raw) as PlanKey;
  };
  const anyPremiumTeam = teamIds.length > 0;
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
      teamPlan === "pro"
        ? null
        : teamPlan === "team"
          ? team.connection_group_quantity ?? TEAM_CONNECTIONS_PER_GROUP
          : 0;

    // Compute billable count for the team: overPool regulars + premium connections.
    // Mirrors getBillableConnectionAddonCount but uses the pre-fetched batched counts.
    const teamRegCount = teamConnectionCounts.get(teamId) ?? 0;
    const teamPremCount = teamPremiumCounts.get(teamId) ?? 0;
    const teamPool =
      teamPlan === "pro"
        ? Infinity
        : teamPlan === "team"
          ? (team.connection_group_quantity ?? TEAM_CONNECTIONS_PER_GROUP)
          : 0; // free teams reject all connections, so regular count is ~0
    const teamBillableCount =
      (teamPool === Infinity ? 0 : Math.max(0, teamRegCount - teamPool)) + teamPremCount;
    const teamPremium = shapeTeamPremiumUsage(teamBillableCount, team.premium_connection_addons ?? 0);

    return {
      id: teamId,
      name: team.team_name,
      plan: teamPlan,
      connections: {
        count: teamRegCount,
        limit: teamConnectionLimit,
      },
      premium: teamPremium,
      is_admin: team.role === "admin",
    };
  });

  return {
    personal: {
      connections: {
        count: connectionCount,
        // Report null (unlimited) when the user has an active 30-day trial OR
        // is on a plan with an inherently unlimited connection pool (Pro/Team).
        limit: trialActive || limits.connections === Infinity ? null : limits.connections,
      },
      twists: {
        count: twistWeightSum,
        limit: twistCapacity,
      },
      premium,
      twistAddonCount,
      syncHistoryDays: limits.syncHistoryDays,
    },
    teams,
  };
}
