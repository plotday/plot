# Pricing Model Adjustments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Adjust the #487 pricing model: twist add-ons become packs of 5 (was 20), Pro includes 3 twist automations (was 10), Team gets one interchangeable 50-slot-per-block pool (connections + twists), connection/twist add-ons are individual-only (premium-connector exception), update site copy, and put all pricing numbers in a single shared source.

**Architecture:** A new `@plotday/pricing` workspace package holds the numeric constants; `workers/api` and `apps/site` both import it. Server capacity logic in `workers/api/src/utils/limits.ts` is rewritten so Team uses a combined slot pool (`TEAM_SLOTS_PER_GROUP × connection_group_quantity`) shared by regular connections and weighted twist capacity; over-capacity on Team returns a new `team_block_required` reason. Flutter derives capacity from server `/upgrade/usage` responses (already does) and gets the two web add-on prices from that payload.

**Tech Stack:** TypeScript (Cloudflare Workers / Hono / Kysely), Vitest (DB-backed, transaction-rollback), React Router + Mantine (apps/site), Flutter/Dart (apps/plot).

## Global Constraints

- **Worktree DB:** `worktree-db` ran mid-session; ambient `$DATABASE_URL` is STALE (54322). Source the real port for every DB command: `source .worktree-db && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres" <cmd>` (PORT=54335). Sanity-check with `psql "$DATABASE_URL" -tAc "show port;"` → must print 54335.
- **Naming/copy:** user-facing term is **"twist automations"** on pricing + upgrade surfaces (not bare "automations"). Twist add-on web price stays **$10/pack**; connection add-on **$5/mo**. Twist add-on pack size = **5**. Pro included twists = **3**; Free = **1**. Team = **50 slots per 50-block**, interchangeable between connections and twists.
- **Add-ons individual-only** except always-required premium connectors (LinkedIn/Instagram/WhatsApp), which keep their **$5/mo connection add-on on every plan including Team**, billed separately, not consuming a Team slot.
- **No DB migration** (greenfield; Team `twist_addon_count` column kept vestigial). **No Stripe object changes** (verify-only).
- **Error capture:** any new catch for unexpected errors calls `tracker.captureException` (TS) / `Tracker.captureException` (Dart). Use `safeQuery`/awaited Kysely; never fire-and-forget.
- **Lint per package** = `tsc && eslint` (eslint excludes tests; tsc covers tests). Verify committed HEAD with `npx tsc --noEmit`, not harness diagnostics.
- Spec: `docs/superpowers/specs/2026-06-27-pricing-model-adjustments-design.md`.

---

### Task 1: `@plotday/pricing` shared constants package

**Files:**
- Create: `libs/pricing/package.json`
- Create: `libs/pricing/tsconfig.json`
- Create: `libs/pricing/src/index.ts`
- Create: `libs/pricing/src/index.test.ts`
- Modify: `pnpm-workspace.yaml` (add `libs/pricing` if packages are listed individually; if it uses a glob like `libs/*` no change needed — verify)
- Modify: `workers/api/package.json` (add `"@plotday/pricing": "workspace:*"` to dependencies)
- Modify: `apps/site/package.json` (add `"@plotday/pricing": "workspace:*"` to dependencies)

**Interfaces:**
- Produces:
  - `PLAN: { free: {connections:number; twistCapacity:number; syncHistoryDays:number}; pro: {...}; team: {syncHistoryDays:number} }`
  - `TEAM_SLOTS_PER_GROUP: number` (50)
  - `TWIST_ADDON_BLOCK_SIZE: number` (5)
  - `CONNECTION_ADDON_PRICE: number` (5)
  - `TWIST_ADDON_PRICE: number` (10)
  - `PLAN_PRICES: { pro:{monthly:number;annual:number}; team:{monthly:number;annual:number} }`

- [ ] **Step 1: Inspect an existing libs/* package to mirror its layout**

Run: `cat libs/tsconfig/package.json; echo ---; cat libs/db/package.json | head -30; echo ---; sed -n '1,40p' pnpm-workspace.yaml`
Note the `name` convention (`@plotday/<x>`), the build script, `main`/`types`/`exports`, and whether `pnpm-workspace.yaml` lists packages by glob (`libs/*`, `packages/*`) or individually. Match it.

- [ ] **Step 2: Write the constants + a value test**

Create `libs/pricing/src/index.ts`:

```ts
/**
 * Single source of truth for Plot pricing numbers. Consumed by the API worker
 * (workers/api) and the marketing site (apps/site). Flutter (Dart) cannot import
 * this; it derives capacity from server responses and reads the two web add-on
 * prices from the /upgrade/usage payload. Pure constants only — no logic/deps.
 */

/** Per-plan included capacity. Team has no fixed twistCapacity/connections — it
 *  uses an interchangeable slot pool of TEAM_SLOTS_PER_GROUP × purchased blocks. */
export const PLAN = {
  free: { connections: 2, twistCapacity: 1, syncHistoryDays: 7 },
  pro: { connections: Infinity, twistCapacity: 3, syncHistoryDays: 365 },
  team: { syncHistoryDays: 365 },
} as const;

/** Interchangeable Team slots granted per purchased 50-block (connection_group_quantity). */
export const TEAM_SLOTS_PER_GROUP = 50;

/** Twist automations granted per twist add-on pack. */
export const TWIST_ADDON_BLOCK_SIZE = 5;

/** Connection add-on price, USD/month (web/Stripe). */
export const CONNECTION_ADDON_PRICE = 5;

/** Twist add-on price, USD/month (web/Stripe). */
export const TWIST_ADDON_PRICE = 10;

/** Plan prices, USD/month. */
export const PLAN_PRICES = {
  pro: { monthly: 25, annual: 20 },
  team: { monthly: 124, annual: 99 },
} as const;
```

Create `libs/pricing/src/index.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import {
  PLAN,
  PLAN_PRICES,
  TEAM_SLOTS_PER_GROUP,
  TWIST_ADDON_BLOCK_SIZE,
  CONNECTION_ADDON_PRICE,
  TWIST_ADDON_PRICE,
} from "./index";

describe("pricing constants", () => {
  it("has the adjusted values", () => {
    expect(PLAN.free.twistCapacity).toBe(1);
    expect(PLAN.pro.twistCapacity).toBe(3);
    expect(PLAN.free.connections).toBe(2);
    expect(PLAN.pro.connections).toBe(Infinity);
    expect(TEAM_SLOTS_PER_GROUP).toBe(50);
    expect(TWIST_ADDON_BLOCK_SIZE).toBe(5);
    expect(CONNECTION_ADDON_PRICE).toBe(5);
    expect(TWIST_ADDON_PRICE).toBe(10);
    expect(PLAN_PRICES.pro).toEqual({ monthly: 25, annual: 20 });
    expect(PLAN_PRICES.team).toEqual({ monthly: 124, annual: 99 });
  });
});
```

Create `libs/pricing/package.json` and `libs/pricing/tsconfig.json` mirroring the layout found in Step 1 (name `@plotday/pricing`, ESM, `exports`/`main`/`types` pointing at the built output or `src` per the convention; extend `@plotday/tsconfig`). If sibling libs build with `tsc -b`, add the same `build` script and a `lint`/`test` script (`vitest run`).

- [ ] **Step 3: Wire workspace + install**

Add `"@plotday/pricing": "workspace:*"` to `workers/api/package.json` and `apps/site/package.json` dependencies. If `pnpm-workspace.yaml` lists packages individually, add `libs/pricing`. Then:
Run: `pnpm install`
Expected: resolves `@plotday/pricing` as a workspace link in both consumers (no registry fetch error).

- [ ] **Step 4: Build + test the package**

Run: `pnpm --filter @plotday/pricing build` (skip if the convention is source-only/no build) then `pnpm --filter @plotday/pricing test` (or `npx vitest run libs/pricing/src/index.test.ts`).
Expected: build clean; test PASS.

- [ ] **Step 5: Commit**

```bash
git add libs/pricing pnpm-workspace.yaml workers/api/package.json apps/site/package.json pnpm-lock.yaml
git commit -m "feat(pricing): add @plotday/pricing single-source constants package"
```

---

### Task 2: limits.ts — shared constants, Pro=3, twist pack=5 (personal paths)

**Files:**
- Modify: `workers/api/src/utils/limits.ts` (imports, `PLAN_LIMITS` ~39–45, `computeTwistBlocksNeeded` ~296–298, personal capacity ~906, usage display ~1051, doc comments ~30–31/286–288/860)
- Test: `workers/api/src/utils/limits.test.ts`

**Interfaces:**
- Consumes: `@plotday/pricing` (`PLAN`, `TEAM_SLOTS_PER_GROUP`, `TWIST_ADDON_BLOCK_SIZE`).
- Produces: `PLAN_LIMITS` (unchanged shape; `pro.twistCapacity = 3`), `computeTwistBlocksNeeded(weightSum, base, pendingWeight?)` now divides by `TWIST_ADDON_BLOCK_SIZE`. `TEAM_CONNECTIONS_PER_GROUP` retained as an alias of `TEAM_SLOTS_PER_GROUP`.

- [ ] **Step 1: Write/extend failing tests**

Add to `workers/api/src/utils/limits.test.ts` (a non-DB `describe` for the pure function; mirror existing imports):

```ts
import { computeTwistBlocksNeeded, PLAN_LIMITS } from "./limits";

describe("pricing constants wired", () => {
  it("Pro includes 3 twist automations", () => {
    expect(PLAN_LIMITS.pro.twistCapacity).toBe(3);
    expect(PLAN_LIMITS.free.twistCapacity).toBe(1);
  });
  it("twist add-on blocks are packs of 5", () => {
    // base 3 (Pro), weightSum 8 → overflow 5 → 1 block of 5
    expect(computeTwistBlocksNeeded(8, 3)).toBe(1);
    // overflow 6 → 2 blocks
    expect(computeTwistBlocksNeeded(9, 3)).toBe(2);
    // within capacity → 0
    expect(computeTwistBlocksNeeded(3, 3)).toBe(0);
    // pendingWeight included
    expect(computeTwistBlocksNeeded(3, 3, 5)).toBe(1);
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd workers/api && source ../../.worktree-db && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres" npx vitest run src/utils/limits.test.ts -t "pricing constants wired"`
Expected: FAIL (`pro.twistCapacity` is 10; `computeTwistBlocksNeeded(8,3)` returns 1 only after the ÷5 change — currently `ceil(5/20)=1` too, so assert the ÷5-specific case `computeTwistBlocksNeeded(9,3)` → currently `ceil(6/20)=1`, must become 2). The `9,3 → 2` assertion fails now.

- [ ] **Step 3: Implement**

In `limits.ts` add the import near the top:

```ts
import { PLAN, TEAM_SLOTS_PER_GROUP, TWIST_ADDON_BLOCK_SIZE } from "@plotday/pricing";
```

Replace the `PLAN_LIMITS` block (lines ~39–45) with:

```ts
export const PLAN_LIMITS: Record<PlanKey, PlanLimits> = {
  free: { connections: PLAN.free.connections, twists: 1, twistCapacity: PLAN.free.twistCapacity, syncHistoryDays: PLAN.free.syncHistoryDays },
  pro: { connections: PLAN.pro.connections, twists: Infinity, twistCapacity: PLAN.pro.twistCapacity, syncHistoryDays: PLAN.pro.syncHistoryDays },
  // team.twistCapacity is vestigial: Team now uses the interchangeable slot pool
  // (TEAM_SLOTS_PER_GROUP × connection_group_quantity), not a fixed per-block twist cap.
  team: { connections: Infinity, twists: Infinity, twistCapacity: 10, syncHistoryDays: PLAN.team.syncHistoryDays },
};

// Retained name (was a literal 50); now sourced from @plotday/pricing.
export const TEAM_CONNECTIONS_PER_GROUP = TEAM_SLOTS_PER_GROUP;
```

In `computeTwistBlocksNeeded` (line ~297) replace `/ 20` with `/ TWIST_ADDON_BLOCK_SIZE`. In personal `checkTwistCapacity` (line ~906) replace `+ 20 * addons` with `+ TWIST_ADDON_BLOCK_SIZE * addons`. In `getUsage` (line ~1051) replace `+ 20 * twistAddonCount` with `+ TWIST_ADDON_BLOCK_SIZE * twistAddonCount`. Update the `+20`/"20 ×"/"per 50-block" doc comments at ~30–31, ~286–288, ~306, ~860 to reflect 5 and the slot pool (Team comment updated fully in Task 3).

- [ ] **Step 4: Run tests**

Run: `cd workers/api && source ../../.worktree-db && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres" npx vitest run src/utils/limits.test.ts -t "pricing constants wired"`
Expected: PASS. Then `npx tsc --noEmit` in `workers/api` → 0 errors.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/utils/limits.ts workers/api/src/utils/limits.test.ts
git commit -m "feat(limits): source plan numbers from @plotday/pricing; Pro=3, twist pack=5 (personal)"
```

---

### Task 3: Team interchangeable slot pool + `team_block_required`

**Files:**
- Modify: `workers/api/src/utils/limits.ts` — add `getTeamCapacityContext`, `getTeamUsedSlots`, `getTeamTwistWeightSums` (batched); rewrite `checkTwistCapacity` team branch (~869–902), `checkChannelConnectionLimit` team branch (~642–743), `getBillableConnectionAddonCount` team branch (~231–243), `getUsage` team section (~1089–1129); add `"team_block_required"` to `PlanLimitReason` (~59–63); remove now-unused `getTeamConnectionLimit` (~437–449) and `twistAddonBlocksNeeded` team branch usage of `twist_addon_count` (team has none — Task 4 removes team twist add-on entirely; here just stop using it for capacity).
- Test: `workers/api/src/utils/limits.test.ts` (update lapsed-team test ~443–472; add interchangeable-pool tests).

**Interfaces:**
- Consumes: `TEAM_SLOTS_PER_GROUP`, `getTeamConnectionCount`, `getTeamTwistWeightSum`, `getTeamPremiumConnectionCount`, `isTeamAdmin`.
- Produces:
  - `getTeamCapacityContext(db, teamId): Promise<{ plan: PlanKey; blocks: number; pool: number }>` (pool = 0 if free, Infinity if pro, `TEAM_SLOTS_PER_GROUP × blocks` if team)
  - `getTeamUsedSlots(db, teamId): Promise<number>` (regular connection count + twist weight sum)
  - `PlanLimitReason` gains `"team_block_required"`.

- [ ] **Step 1: Add `"team_block_required"` to `PlanLimitReason`**

Edit lines ~59–63:

```ts
export type PlanLimitReason =
  | "connection_limit"
  // No spare purchased add-on credit — must buy one (personal scope only now).
  | "addon_required"
  | "twist_addon_required"
  // Team interchangeable slot pool is full — an admin must add a 50-block
  // (raise connection_group_quantity), or start a Team plan if the team is free.
  | "team_block_required";
```

- [ ] **Step 2: Write failing tests for the interchangeable pool**

Add a DB-backed `describe` (mirror the seeding style at `limits.test.ts:443–472`, using `session_replication_role = replica` + `Rollback`). Seed a team_subscription `plan='team', status='active', connection_group_quantity=1` (pool = 50). Cases:
1. Regular connections + twist weight share the 50 pool: seed 49 regular team connections + a twist weight 1 (used=50); a candidate twist weight 1 → `checkTwistCapacity` rejects with `reason: "team_block_required"`.
2. Same team, used=49, candidate weight 1 → allowed.
3. `checkChannelConnectionLimit` for a regular team connector when used=50 → `team_block_required`.
4. Update the existing lapsed-team test (line ~471) expectation from `"twist_addon_required"` to `"team_block_required"`.

(Write the seeds explicitly with `INSERT INTO twist_instance/twist/channel` like the existing helpers; seed twist weight via `twist.capacity_weight`.)

- [ ] **Step 3: Run to verify failure**

Run: `cd workers/api && source ../../.worktree-db && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres" npx vitest run src/utils/limits.test.ts -t "team"`
Expected: FAIL (old team logic returns `twist_addon_required` / wrong allow-deny around the combined pool).

- [ ] **Step 4: Implement the helpers**

Add after `getTeamPremiumAddons`:

```ts
/**
 * Resolve a team's plan, purchased 50-blocks, and interchangeable slot pool.
 * pool = 0 (free/lapsed), Infinity (legacy team-pro), or TEAM_SLOTS_PER_GROUP ×
 * connection_group_quantity (Team plan). Single source for team capacity.
 */
export async function getTeamCapacityContext(
  db: Kysely<DB>,
  teamId: string
): Promise<{ plan: PlanKey; blocks: number; pool: number }> {
  const sub = await db
    .selectFrom("team_subscription")
    .select(["plan", "status", "connection_group_quantity"])
    .where("team_id", "=", teamId)
    .executeTakeFirst();
  const rawPlan = (sub?.plan as string) ?? "free";
  const plan: PlanKey =
    sub && sub.status === "active"
      ? ((rawPlan === "core" ? "free" : rawPlan) as PlanKey)
      : "free";
  const blocks = sub?.connection_group_quantity ?? 1;
  const pool =
    plan === "free" ? 0 : plan === "pro" ? Infinity : TEAM_SLOTS_PER_GROUP * blocks;
  return { plan, blocks, pool };
}

/**
 * Used interchangeable slots for a team: regular (non-premium) connections +
 * Σ twist capacity_weight. Premium connectors are billed as add-ons and do NOT
 * consume a slot. The built-in assistant (weight 0) is already excluded.
 */
export async function getTeamUsedSlots(
  db: Kysely<DB>,
  teamId: string
): Promise<number> {
  const connections = await getTeamConnectionCount(db, teamId);
  const twistWeight = await getTeamTwistWeightSum(db, teamId);
  return connections + twistWeight;
}
```

- [ ] **Step 5: Rewrite `checkTwistCapacity` team branch**

Replace lines ~869–902 (the `if (teamId) { ... }` block) with:

```ts
  if (teamId) {
    const { plan, pool } = await getTeamCapacityContext(db, teamId);
    if (pool === Infinity) return { allowed: true };
    const used = await getTeamUsedSlots(db, teamId);
    if (used + candidateWeight <= pool) return { allowed: true };
    const admin = await isTeamAdmin(db, userId, teamId);
    return {
      allowed: false,
      error: new PlanLimitError({
        limitType: "twist",
        reason: "team_block_required",
        plan,
        currentCount: used,
        limit: pool,
        isTeam: true,
        isAdmin: admin,
        teamId,
      }),
    };
  }
```

- [ ] **Step 6: Rewrite `checkChannelConnectionLimit` team branch**

Within the `if (teamId) { ... }` block (lines ~642–743): keep the `existingTeamChannel` short-circuit (re-enable) and the `isAddon` premium-credit gate UNCHANGED (premium connectors keep their add-on on Team). Replace everything from the `teamSub`/`teamPlan` resolution through the `teamPlan === "free"` and `teamPlan === "team"` branches and the trailing `return { allowed: true }` with:

```ts
    // Regular (non-premium) connector: consumes one interchangeable Team slot.
    const { plan: teamPlan, pool } = await getTeamCapacityContext(db, teamId);
    if (pool === Infinity) return { allowed: true }; // legacy team-pro: unlimited
    const used = await getTeamUsedSlots(db, teamId);
    if (used + 1 <= pool) return { allowed: true };
    const admin = await isTeamAdmin(db, userId, teamId);
    return {
      allowed: false,
      error: new PlanLimitError({
        limitType: "connection",
        reason: "team_block_required",
        plan: teamPlan,
        currentCount: used,
        limit: pool,
        isTeam: true,
        isAdmin: admin,
        teamId,
      }),
    };
```

(The `isAddon` branch stays above this, still calling `getTeamPremiumAddons` + the billable gate. Confirm the `isAddon` branch precedes the regular-connector code so premium connectors never reach the slot check.)

- [ ] **Step 7: `getBillableConnectionAddonCount` team branch + remove `getTeamConnectionLimit`**

Replace the team branch (lines ~231–243) with:

```ts
  if ("teamId" in scope) {
    // On Team, the only billable connection add-ons are the always-required
    // premium connectors. Regular connections beyond the slot pool are covered
    // by buying another 50-block (team_block_required), NOT a connection add-on.
    return getTeamPremiumConnectionCount(db, scope.teamId);
  }
```

Then `grep -rn "getTeamConnectionLimit" workers/` — if only its definition remains, delete the `getTeamConnectionLimit` function (~437–449).

- [ ] **Step 8: `getUsage` team section — report the combined pool**

Add a batched twist-weight helper near `getTeamConnectionCounts`:

```ts
async function getTeamTwistWeightSums(
  db: Kysely<DB>,
  teamIds: string[]
): Promise<Map<string, number>> {
  if (teamIds.length === 0) return new Map();
  const rows = await db
    .selectFrom("twist_instance as pt")
    .innerJoin("twist as t", "t.id", "pt.twist_id")
    .select(["pt.team_id", sql<string>`coalesce(sum(t.capacity_weight),0)`.as("weight")])
    .where("pt.team_id", "in", teamIds)
    .where("pt.archived_at", "is", null)
    .where("t.is_source", "=", false)
    .where("pt.draft", "=", false)
    .where("t.twist_package_id", "!=", BUILTIN_TWIST_PACKAGE_ID)
    .groupBy("pt.team_id")
    .execute();
  return new Map(rows.map((r) => [String(r.team_id), Number(r.weight)]));
}
```

Call it in the `Promise.all` batch, then in the `teams.map`: compute `teamPool` via `plan === 'pro' ? Infinity : plan === 'team' ? TEAM_SLOTS_PER_GROUP * (connection_group_quantity ?? 1) : 0`, `teamTwistWeight = teamTwistWeightSums.get(teamId) ?? 0`, `usedSlots = teamRegCount + teamTwistWeight`, `teamBillableCount = teamPremCount` (premium-only now). Return per team:

```ts
    return {
      id: teamId,
      name: team.team_name,
      plan: teamPlan,
      connections: { count: teamRegCount, limit: teamPool === Infinity ? null : teamPool },
      twists: { count: teamTwistWeight, limit: teamPool === Infinity ? null : teamPool },
      slots: { used: usedSlots, limit: teamPool === Infinity ? null : teamPool },
      premium: shapeTeamPremiumUsage(teamBillableCount, team.premium_connection_addons ?? 0),
      is_admin: team.role === "admin",
    };
```

Note `connection_group_quantity` is the block count: `teamPool = 50 × quantity` (fixes the prior raw-quantity bug). Remove the old `teamConnectionLimit`/`teamBillableCount` overPool computation.

- [ ] **Step 9: Run tests + typecheck**

Run: `cd workers/api && source ../../.worktree-db && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres" npx vitest run src/utils/limits.test.ts`
Expected: PASS (all, including updated lapsed-team + new interchangeable cases). Then `npx tsc --noEmit` → 0.

- [ ] **Step 10: Commit**

```bash
git add workers/api/src/utils/limits.ts workers/api/src/utils/limits.test.ts
git commit -m "feat(limits): Team interchangeable 50-slot pool + team_block_required"
```

---

### Task 4: Remove team twist/connection add-on paths (individual-only)

**Files:**
- Modify: `workers/api/src/app/upgrade.ts` — the `/upgrade/twist-addons/purchase` handler: reject/remove the team branch (twist add-ons are personal-only).
- Modify: `workers/api/src/app/twists.ts` — remove team `reconcileScopeTwistAddonBillingDown` calls (twist removal on a team no longer reconciles a twist add-on sub).
- Modify: `workers/api/src/stripe/stripe.ts` — webhook routing for `metadata.type === "twist_addon"`: stop writing `team_subscription.twist_addon_count` (personal only). Connection add-on (`metadata.type === "addon"`) team routing stays (premium connectors).
- Modify: `workers/api/src/utils/limits.ts` — `twistAddonBlocksNeeded` team branch: it referenced `twist_addon_count` and team twist capacity; since teams have no twist add-on, make the team branch return `0` (or remove team support and have callers not pass a team scope). Keep personal branch.
- Test: relevant `*.test.ts` (upgrade/stripe) — assert team twist-addon purchase is rejected and webhook never writes team `twist_addon_count`.

**Interfaces:**
- Consumes: Task 3's `team_block_required` (the client path that replaces team twist add-on purchase).
- Produces: `/upgrade/twist-addons/purchase` returns a 400/403 (not-supported) for team scope; team twist-addon billing code removed.

- [ ] **Step 1: Read the current code**

Run: `grep -rn "twist_addon\|twistAddon\|reconcileScopeTwistAddon\|twist-addons" workers/api/src/app/upgrade.ts workers/api/src/app/twists.ts workers/api/src/stripe/stripe.ts`
Read each hit and the enclosing function. Identify every team-scope twist-addon branch.

- [ ] **Step 2: Write failing test**

In the upgrade test (find it: `ls workers/api/src/app/*upgrade*test* 2>/dev/null` or `grep -rln "twist-addons/purchase" workers/api/src`), add a case: POSTing `/upgrade/twist-addons/purchase` with a `teamId` returns a 4xx error (team twist add-ons unsupported) and does not change `team_subscription.twist_addon_count`.

- [ ] **Step 3: Run to verify failure**

Run: `cd workers/api && source ../../.worktree-db && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres" npx vitest run <the upgrade test path> -t "team twist add-on"`
Expected: FAIL (currently the team branch attempts a purchase).

- [ ] **Step 4: Implement removals**

- `upgrade.ts`: in `/upgrade/twist-addons/purchase`, if the request targets a team (`body.teamId`), return an error response (e.g. `c.json({ error: "twist_add_ons_personal_only" }, 400)`), removing the admin-gated team purchase branch. Personal flow unchanged.
- `twists.ts`: delete the team-scope `reconcileScopeTwistAddonBillingDown({ teamId })` invocations (keep personal `{ userId }`).
- `stripe.ts`: in the `twist_addon` webhook branch, remove the `team_subscription` update path; only `user_subscription.twist_addon_count` is written. Leave the connection add-on (`addon`) team path intact.
- `limits.ts`: `twistAddonBlocksNeeded` team branch → `return 0;` (teams never buy twist add-ons). Add a comment. Personal branch unchanged.

For any new catch of unexpected errors, call `tracker.captureException`.

- [ ] **Step 5: Run tests + typecheck**

Run: `cd workers/api && source ../../.worktree-db && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres" npx vitest run src/app src/stripe src/utils/limits.test.ts`
Expected: PASS. `npx tsc --noEmit` → 0.

- [ ] **Step 6: Commit**

```bash
git add workers/api/src
git commit -m "feat(billing): twist add-ons are personal-only; teams scale via 50-blocks"
```

---

### Task 5: Expose web add-on prices in `/upgrade/usage`

**Files:**
- Modify: `workers/api/src/utils/limits.ts` `getUsage` return (the top-level object) — add `pricing: { connectionAddonPrice, twistAddonPrice }` sourced from `@plotday/pricing`.
- Test: `workers/api/src/utils/limits.test.ts` getUsage test — assert the new field.

**Interfaces:**
- Consumes: `CONNECTION_ADDON_PRICE`, `TWIST_ADDON_PRICE` from `@plotday/pricing`.
- Produces: `/upgrade/usage` JSON gains `pricing: { connectionAddonPrice: number; twistAddonPrice: number }` (Flutter reads these for web confirm/summary copy).

- [ ] **Step 1: Failing test** — extend a getUsage test to assert `result.pricing.twistAddonPrice === 10` and `connectionAddonPrice === 5`.
- [ ] **Step 2: Run → FAIL** (`pricing` undefined). Command as in Task 3 Step 9 filtered to the getUsage test.
- [ ] **Step 3: Implement** — import `CONNECTION_ADDON_PRICE, TWIST_ADDON_PRICE`; add to the `getUsage` return object: `pricing: { connectionAddonPrice: CONNECTION_ADDON_PRICE, twistAddonPrice: TWIST_ADDON_PRICE }`. Verify the route handler returns the whole object verbatim (grep the `/usage` route in `app/upgrade.ts`); no shape filtering.
- [ ] **Step 4: Run → PASS** + `npx tsc --noEmit`.
- [ ] **Step 5: Commit** — `git commit -m "feat(usage): expose web add-on prices for clients"`.

---

### Task 6: Flutter — team_block_required, /usage prices, "twist automations" copy

**Files (read first, then edit):**
- `apps/plot/lib/api/upgrade_api.dart` — `/usage` parsing: add `connectionAddonPrice`/`twistAddonPrice` and per-team `slots`.
- `apps/plot/lib/api/api_exception.dart` (or wherever `ApiException.reason`/`isTwistAddonRequired` live) — add `isTeamBlockRequired`.
- `apps/plot/lib/command/upgrade.dart` / `command/twist.dart` — `TwistCapacityOffer`/`ConnectionCapacityOffer`/`BuyTwistAddonCommand`: route `team_block_required` to a team-capacity offer (admin → "add 50 connections/automations" i.e. raise blocks; member → "ask your admin"). Replace `+20 twists` strings with `+5 twist automations`. Use `/usage` `pricing` for web `$5`/`$10` strings.
- Twist/connection capacity display widgets — show team combined slots ("X of 50 used") from the `slots` field; "twist automations" wording.

**Interfaces:**
- Consumes: server `team_block_required` reason; `/usage` `pricing` + per-team `slots`.
- Produces: client handles the new reason without falling through to a twist-add-on purchase for teams.

- [ ] **Step 1: Codegen + baseline analyze**

Run: `cd apps/plot && flutter pub get && flutter pub run build_runner build --delete-conflicting-outputs && flutter analyze lib`
Expected: clean (establish baseline before edits).

- [ ] **Step 2: Read the current Flutter capacity/offer code**

Run: `grep -rn "twist_addon_required\|isTwistAddonRequired\|addon_required\|TwistCapacityOffer\|ConnectionCapacityOffer\|BuyTwistAddonCommand\|+20\|twistAddonCount\|candidateWeight" apps/plot/lib`
Read each file. Map where the 403 reasons are handled and where the "+20"/price strings render.

- [ ] **Step 3: Implement (no separate unit test; verified by analyze + Task 9 manual run)**

- Parse `pricing.connectionAddonPrice`/`twistAddonPrice` and per-team `slots {used, limit}` in `upgrade_api.dart`.
- Add `bool get isTeamBlockRequired => reason == "team_block_required";` to the ApiException helper.
- In the capacity-offer handlers: when `isTeamBlockRequired`, show a team offer: admins → CTA to add capacity (raise the team's 50-block count — wire to whatever the team-quantity flow is, confirmed in Task 9 Step 1); members → informational "ask your team admin to add capacity". Do NOT present the twist add-on purchase for teams.
- Replace `+20 twists` → `+5 twist automations`; bare "automations" → "twist automations" on these surfaces. Use the `/usage` `pricing` values for `$5`/`$10` web confirm strings (keep live StoreKit price for App Store).
- For team capacity display, show `slots.used`/`slots.limit` ("X of 50 used").
- Any new catch of unexpected errors → `Tracker.captureException(error, stackTrace)`.

- [ ] **Step 4: Analyze**

Run: `cd apps/plot && flutter analyze lib`
Expected: "No issues found!"

- [ ] **Step 5: Commit** — `git add apps/plot/lib && git commit -m "feat(app): handle team_block_required; +5 twist automations; prices from /usage"`.

---

### Task 7: apps/site — copy, "twist automations", heading, centring

**Files:**
- `apps/site/app/lib/plans.ts` — import numbers from `@plotday/pricing`; derive feature strings; Pro "3 twist automations"; Free "1 twist automation"; Team interchangeable line; add-on availability note. Replace local `ADDON_PRICE`/`TWIST_ADDON_PRICE`/`PRICES` literals with re-exports of the shared constants (keep the export names other files import).
- `apps/site/app/routes/pricing.tsx` — FAQ "1 on Free, 10 on Pro" → "1 on Free, 3 on Pro"; "add 20 slots for $10" / "add 20 more for $10/mo" → "add 5 ... for $10" (lines ~58, ~344); Team interchangeable framing; "automations" → "twist automations" on capacity/add-on lines.
- `apps/site/app/routes/upgrade.tsx` — heading "Do more with Plot"; sub "Add connections and twist automations to bring all your work together."; centre the plan-card grid (only Pro+Team now render); "+20 twists each" → "+5 twist automations each" (lines ~447, ~659–660).
- `apps/site/app/routes/pricing.module.css` / upgrade layout CSS — grid centring.

**Interfaces:**
- Consumes: `@plotday/pricing`.
- Produces: site copy matching the new model; no behavior change beyond display.

- [ ] **Step 1: Read the files** — `pricing.tsx`, `upgrade.tsx`, `plans.ts`, the relevant `*.module.css`. Note exact current strings (the exploration line numbers are approximate; confirm).

- [ ] **Step 2: plans.ts → shared constants + copy**

Replace the local numeric literals with imports:

```ts
import { PLAN, PLAN_PRICES, CONNECTION_ADDON_PRICE, TWIST_ADDON_PRICE } from "@plotday/pricing";

export const ADDON_PRICE = CONNECTION_ADDON_PRICE; // keep name for existing importers
export { TWIST_ADDON_PRICE };
export const PRICES = PLAN_PRICES;
```

Update feature strings: Pro `` `${PLAN.pro.twistCapacity} twist automations` `` ("3 twist automations"); Free "1 twist automation"; Team line "50 connections or twist automations, shared across your team (add 50 more anytime)" replacing the two separate lines; add-on availability note: "Connection and twist add-ons are available on individual plans; LinkedIn, Instagram, and WhatsApp always need a connection add-on on any plan." Keep "No-code automation builder" verbatim (user-confirmed).

- [ ] **Step 3: pricing.tsx copy** — apply the FAQ/body edits above; "twist automations" wording; Team interchangeable framing. Keep the existing "On Team, add another block of 50 connections anytime" answer (now also covers automations — reword to "another block of 50 connections or automations").

- [ ] **Step 4: upgrade.tsx heading + centring + copy** — set heading/sub-heading; reword add-on summary to "+5 twist automations each"; centre the cards. For centring, prefer `justify-content: center` / `place-content: center` on the grid/flex container (or `grid-template-columns: repeat(auto-fit, minmax(<cardwidth>, max-content))` centered) so 1/2/3 cards all center. Do not hardcode two columns.

- [ ] **Step 5: Lint + visual check**

Run: `cd apps/site && pnpm lint` (tsc + eslint) → 0. Then build/preview if quick (`pnpm build`) to confirm no broken imports.
Visual centring confirmed in Task 9 (run the site or screenshot).

- [ ] **Step 6: Commit** — `git add apps/site && git commit -m "feat(site): twist automations copy, upgrade heading + centred cards, shared pricing"`.

---

### Task 8: Docs — features.md + updates fragment

**Files:**
- Modify: `docs/features.md` (plans/automations sections: Pro 3 twist automations, Team interchangeable 50 slots, twist add-on +5/$10, add-ons individual-only + premium exception).
- Create: `docs/updates.d/<slug>-<id>.md` via `pnpm updates:new "..."`.

- [ ] **Step 1:** Run `pnpm updates:new "Twist add-ons now come in packs of 5; Team plans share 50 connections and automations interchangeably"` (or hand-write the fragment). Put feature bullets under an existing `### Plans`/`### Pricing`-style section if present; plain user language.
- [ ] **Step 2:** Edit `docs/features.md` plan/automation sections to match the new model.
- [ ] **Step 3: Commit** — `git add docs && git commit -m "docs: pricing model adjustments (packs of 5, Team interchangeable slots)"`.

---

### Task 9: Stripe verify + finalize

- [ ] **Step 1: Confirm the Team block-quantity flow** (resolves the spec's open item). `grep -rn "connection_group_quantity\|setQuantity\|plan.*quantity\|createCheckoutSession" workers/api/src/app/upgrade.ts apps/plot/lib apps/site/app/routes/upgrade.tsx` to find how a team raises its block count (in-app endpoint vs billing portal vs Checkout). Ensure the `team_block_required` offer (Task 6) points at the real flow. If only a billing-portal path exists, the admin CTA opens the portal.
- [ ] **Step 2: Stripe verify (MCP, both modes)** — confirm the "Twist Add-on" price is $10/mo and the "Connection Add-on" price is $5/mo, and neither product description names a pack size, in **Sandbox and Production**. No object changes expected. Report findings; only edit a description if it names "20".
- [ ] **Step 3: Full server suite (serial)** — `cd workers/api && source ../../.worktree-db && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres" CI=true npx vitest run --no-file-parallelism`. Expected: green (parallel DB-isolation flakes are pre-existing; serial must pass).
- [ ] **Step 4: Cross-package lint + type sync** — `pnpm --filter @plotday/pricing lint`, `cd workers/api && npx tsc --noEmit && pnpm lint`, `cd apps/site && pnpm lint`, `cd apps/plot && flutter analyze lib`. `pnpm diff-schema-migrations` (clean — no schema change). Confirm `libs/db/src/types.ts` + `workers/api/src/db-types.ts` unchanged.
- [ ] **Step 5: /finalize** — run the finalization checklist (lint, backwards-compat for `/usage` shape additions are additive/safe, error capture in new catches, docs fragment present, no `public/` submodule changes so no changeset).
- [ ] **Step 6: Commit any finalize fixes.**

---

## Self-Review

**Spec coverage:**
- Area 0 (single source) → Task 1 (package) + Tasks 2/3/5 (server consumes) + Task 7 (site consumes) + Task 5/6 (Flutter via /usage). ✓
- Area 1 (pack 5) → Task 2 (computeTwistBlocksNeeded ÷ TWIST_ADDON_BLOCK_SIZE, personal capacity, usage display) + Apple map unchanged (×5 via the calc). ✓
- Area 2 (Pro 3) → Task 1 (`PLAN.pro.twistCapacity=3`) + Task 2 (PLAN_LIMITS). ✓
- Area 3 (Team interchangeable) → Task 3. ✓
- Area 4 (add-ons individual-only + premium exception) → Task 3 (billable team = premium-only; checks) + Task 4 (remove team twist-addon paths). ✓
- Area 5 (site copy) → Task 7. ✓
- Area 6 (Stripe verify) → Task 9 Step 2. ✓
- Flutter (team_block_required + prices + copy) → Tasks 5 (server price) + 6. ✓
- Docs → Task 8. ✓

**Placeholder scan:** Flutter/site tasks instruct "read first" because exact line numbers are approximate and those files weren't fully read during planning; the behavioral contract, exact copy strings, and test/verify commands are concrete. No "TBD"/"handle edge cases".

**Type consistency:** `getTeamCapacityContext` returns `{plan, blocks, pool}` used by `checkTwistCapacity`, `checkChannelConnectionLimit`, and `getUsage`. `getTeamUsedSlots` (connections + twist weight) used by both checks. `team_block_required` added to `PlanLimitReason` (Task 3 Step 1) before use. `/usage` gains additive `pricing` + per-team `slots`/`twists` — backwards compatible (older clients ignore new fields).
