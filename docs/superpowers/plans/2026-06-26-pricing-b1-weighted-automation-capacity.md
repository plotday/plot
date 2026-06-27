# Pricing B1 — Weighted automation capacity (server foundation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the flat per-plan twist *count* limit with a **weighted automation-capacity** entitlement — each twist has a `capacity_weight` (default 1); a scope's capacity = plan base (Free 1 · Pro 10 · Team 10 per 50-block) + 20 × purchased twist-add-on blocks; installing a twist is blocked when the sum of installed twists' weights would exceed capacity; the built-in assistant has weight 0.

**Architecture:** All changes are in the API worker (`workers/api`) plus one schema migration. Add `twist.capacity_weight` (the `twist` table — there is no `twist_package` table; `twist_package_id` is only a grouping UUID) and `twist_addon_count` on `user_subscription`/`team_subscription`. In `utils/limits.ts`, `PLAN_LIMITS[*].twists` (a flat count) becomes `automationCapacity`; `checkTwistLimit` becomes the weighted `checkTwistCapacity(db, userId, teamId, candidateWeight)`. Its three call sites in `twist/management.ts` pass the candidate twist's weight. Mirrors the add-ons build's connection-limit shape.

**Tech Stack:** TypeScript, Cloudflare Workers, Kysely (Postgres), Vitest, Atlas migrations. DB-backed tests run against `$DATABASE_URL` and gate via `describe.skipIf(!DATABASE_URL)`.

## Global Constraints

- **Base branch:** this plan builds on `independent-usage-based-addons` (the add-ons build, Plans 1–3). Create a worktree off that branch (not `main`) — see `superpowers:using-git-worktrees`. The add-ons billing infra (`stripe/addons.ts`, generalized `limits.ts`) must be present.
- **Worktree DB:** schema work needs the worktree's isolated Postgres. **Never hardcode `54322`.** Before any migration verify the port: `psql "$DATABASE_URL" -tAc "show port;"` must print the worktree's port (from `.worktree-db`), not `54322`. If `$DATABASE_URL` is stale, `source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"`.
- **Capacity numbers (verbatim):** Free **1** · Pro **10** · Team **10 per 50-connection block**; **+20 slots per twist-add-on block**. Built-in assistant (`BUILTIN_TWIST_PACKAGE_ID`) weight **0**.
- **Behavior change to flag:** Pro and Team twists were `Infinity` (unlimited); they are now finite capacity (Pro 10; Team 10×blocks). The check only blocks *new* installs over capacity — it never retroactively uninstalls. Existing scopes already over the new cap keep their twists but can't add more until under capacity or they buy a twist-add-on (B2).
- **Schema workflow (AGENTS.md):** edit `libs/db/schema/` only → `pnpm gen-migration -- <name>` → `pnpm apply-migrations` (auto-runs `pnpm types`) → commit the regenerated `libs/db/src/types.ts` + migration + `atlas.sum`. Never hand-edit applied migrations.
- **Out of scope (later plans):** the `twist_addon` Stripe/Apple billing + `stripe_twist_addon_subscription_id`/`apple_twist_addon_*` columns (B2); SDK `capacity_weight` declaration that feeds the column (B6) — B1 ships the column with default 1; dropping `core` (B5); AI/BYOK cleanup including the `if (effective.plan === "free") { … "Add an API key…" }` gate above each call site (B4).
- Never use fire-and-forget DB calls; `await` Kysely and let errors propagate. Lint + test from the worker: `cd workers/api && pnpm lint && pnpm test`.
- Commit after each task.

## File structure

- `libs/db/schema/50-tables/90-twist.sql` — add `capacity_weight`.
- `libs/db/schema/50-tables/20-user_subscription.sql` — add `twist_addon_count`.
- `libs/db/schema/50-tables/13-team_subscription.sql` — add `twist_addon_count`.
- `libs/db/migrations/*` + `libs/db/src/types.ts` — generated; commit.
- `workers/api/src/utils/limits.ts` — `PlanLimits`/`PLAN_LIMITS`, `PlanLimitReason`, new entitlement + weight-sum + capacity helpers, `checkTwistCapacity` (replaces `checkTwistLimit`), `getUsage` twists shape.
- `workers/api/src/utils/limits.test.ts` — weighted-capacity tests.
- `workers/api/src/twist/management.ts` — three call sites (`add` :193, `update` :596, `activateDraft` :913).

---

### Task 1: Schema — `capacity_weight` + `twist_addon_count`

**Files:**
- Modify: `libs/db/schema/50-tables/90-twist.sql` (column near `execution_limit`, line 51).
- Modify: `libs/db/schema/50-tables/20-user_subscription.sql` (near `premium_connection_addons`, line 40).
- Modify: `libs/db/schema/50-tables/13-team_subscription.sql` (near `premium_connection_addons`, line 22).
- Generated: `libs/db/migrations/*`, `libs/db/src/types.ts`.

**Interfaces:**
- Produces: `twist.capacity_weight` (`integer NOT NULL DEFAULT 1`); `user_subscription.twist_addon_count` and `team_subscription.twist_addon_count` (`integer NOT NULL DEFAULT 0`). These appear in `libs/db/src/types.ts` as `Generated<number>`.

- [ ] **Step 1: Add the `twist` column**

In `libs/db/schema/50-tables/90-twist.sql`, add directly after the `"execution_limit" integer,` line:

```sql
    -- Automation-capacity weight: how many capacity slots this twist consumes
    -- when installed (Σ weights of a scope's installed twists ≤ its capacity).
    -- Plot-curated; the SDK may declare it (B6). Built-in assistant uses 0.
    "capacity_weight" integer NOT NULL DEFAULT 1,
```

- [ ] **Step 2: Add the subscription columns**

In `libs/db/schema/50-tables/20-user_subscription.sql`, add after `"premium_connection_addons" integer NOT NULL DEFAULT 0,`:

```sql
    -- Purchased twist-add-on blocks (each grants +20 automation-capacity slots).
    -- Driven by the standalone twist-add-on subscription (Stripe) / tier (Apple) in B2.
    "twist_addon_count" integer NOT NULL DEFAULT 0,
```

Add the identical column (same comment) to `libs/db/schema/50-tables/13-team_subscription.sql` after its `"premium_connection_addons" integer NOT NULL DEFAULT 0,`.

- [ ] **Step 3: Generate + apply the migration**

```bash
psql "$DATABASE_URL" -tAc "show port;"   # MUST be the worktree port, not 54322
cd <repo-root> && pnpm gen-migration -- add_capacity_weight_and_twist_addon_count
pnpm apply-migrations
```

Expected: a new file in `libs/db/migrations/`, applied cleanly, and `libs/db/src/types.ts` regenerated (it runs `pnpm types` automatically). `Twist` gains `capacity_weight: Generated<number>`; `UserSubscription` and `TeamSubscription` gain `twist_addon_count: Generated<number>`.

- [ ] **Step 4: Verify schema/migration sync + types**

```bash
pnpm diff-schema-migrations   # expect: no differences
pnpm --filter @plotday/db run lint   # expect: types in sync
```

- [ ] **Step 5: Commit**

```bash
git add libs/db/schema libs/db/migrations libs/db/src/types.ts
git commit -m "feat(db): add twist.capacity_weight and subscription twist_addon_count"
```

---

### Task 2: `PLAN_LIMITS` capacity + entitlement/weight-sum reads

**Files:**
- Modify: `workers/api/src/utils/limits.ts` — `PlanLimits` (:22-26), `PLAN_LIMITS` (:28-33), `PlanLimitReason` (:49-52); add reader/helper functions near `getPersonalTwistCount` (:333) and `getPersonalPremiumAddons` (:199-211).
- Test: `workers/api/src/utils/limits.test.ts`.

**Interfaces:**
- Produces:
  - `PlanLimits.automationCapacity: number` (replaces `twists`).
  - `PlanLimitReason` includes `"twist_addon_required"`.
  - `getPersonalTwistAddonCount(db, userId): Promise<number>` and `getTeamTwistAddonCount(db, teamId): Promise<number>`.
  - `getPersonalTwistWeightSum(db, userId): Promise<number>` and `getTeamTwistWeightSum(db, teamId): Promise<number>` — Σ `twist.capacity_weight` over installed (non-source, non-draft, non-archived, non-built-in) twist instances for the scope.

- [ ] **Step 1: Rename the plan field and add the reason**

In `workers/api/src/utils/limits.ts`, change `PlanLimits` (:22-26) so `twists: number;` becomes `automationCapacity: number;`, and set `PLAN_LIMITS` (:28-33) to:

```typescript
export const PLAN_LIMITS: Record<PlanKey, PlanLimits> = {
  free: { connections: 2, automationCapacity: 1, syncHistoryDays: 7 },
  core: { connections: 5, automationCapacity: 2, syncHistoryDays: 30 },
  pro: { connections: Infinity, automationCapacity: 10, syncHistoryDays: 365 },
  team: { connections: Infinity, automationCapacity: 10, syncHistoryDays: 365 }, // 10 per 50-block; multiplied by connection_group_quantity
};
```

In `PlanLimitReason` (:49-52) add the new member:

```typescript
export type PlanLimitReason =
  | "connection_limit"
  | "addon_required"
  | "twist_addon_required";
```

- [ ] **Step 2: Add the twist-add-on entitlement readers**

Immediately after `getPersonalPremiumAddons` (ends ~:211), add (mirroring its shape):

```typescript
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

/** Purchased twist-add-on blocks for a team scope (each = +20 capacity). */
export async function getTeamTwistAddonCount(
  db: Kysely<DB>,
  teamId: string
): Promise<number> {
  const sub = await db
    .selectFrom("team_subscription")
    .select("twist_addon_count")
    .where("team_id", "=", teamId)
    .executeTakeFirst();
  return sub?.twist_addon_count ?? 0;
}
```

- [ ] **Step 3: Add the weight-sum functions**

Replace `getPersonalTwistCount` (:333-350) and `getTeamTwistCount` (:355-371) with weight-summing versions (same filters; `sum(t.capacity_weight)` instead of `count`):

```typescript
/**
 * Σ capacity_weight over a user's installed automations: non-archived,
 * non-draft, non-source twist instances, excluding the built-in assistant
 * (which is weight 0 anyway). Drives the weighted automation-capacity check.
 */
export async function getPersonalTwistWeightSum(
  db: Kysely<DB>,
  userId: string
): Promise<number> {
  const row = await db
    .selectFrom("twist_instance as pt")
    .innerJoin("twist as t", "t.id", "pt.twist_id")
    .select((eb) => eb.fn.sum("t.capacity_weight").as("weight"))
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
    .select((eb) => eb.fn.sum("t.capacity_weight").as("weight"))
    .where("pt.team_id", "=", teamId)
    .where("pt.archived_at", "is", null)
    .where("t.is_source", "=", false)
    .where("pt.draft", "=", false)
    .where("t.twist_package_id", "!=", BUILTIN_TWIST_PACKAGE_ID)
    .executeTakeFirst();
  return Number(row?.weight ?? 0);
}
```

(If `getPersonalTwistCount`/`getTeamTwistCount` have any other importers, a TS error in Step 5 will surface them — repoint those to the weight-sum functions. Per exploration the only callers are `checkTwistLimit` and `getUsage`, both rewritten in Tasks 3–4.)

- [ ] **Step 4: Write failing tests for the readers + weight sum**

In `workers/api/src/utils/limits.test.ts`, extend the existing DB-backed seeding helper so a seeded twist can carry a weight, and add a block. Add these imports to the `./limits` import: `getPersonalTwistWeightSum`, `checkTwistCapacity`, `getPersonalTwistAddonCount`. Then:

```typescript
describe.skipIf(!DATABASE_URL)("weighted automation capacity", () => {
  // Seeds a non-source twist + instance with the given capacity_weight for a
  // personal user and returns getPersonalTwistWeightSum. Mirrors the existing
  // seedAndCount pattern (session_replication_role=replica + Rollback).
  async function seedWeightSum(opts: { weight: number; builtin?: boolean }): Promise<number> {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    const userId = randomUUID();
    const twistInstanceId = randomUUID();
    let sum = -1;
    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);
        const pkgId = opts.builtin
          ? "0199b6f4-ae64-7718-8a02-44716f30358f"
          : randomUUID();
        const twist = await sql<{ id: string }>`
          INSERT INTO twist (twist_package_id, environment, user_id, name, handle,
            version, is_source, premium, capacity_weight)
          VALUES (${pkgId}::uuid, 'personal', ${userId}::uuid, 'W', 'w', '1.0.0',
            false, false, ${opts.weight})
          RETURNING id`.execute(trx);
        await sql`INSERT INTO twist_instance (id, twist_id, owner_id, name, team_id)
          VALUES (${twistInstanceId}::uuid, ${twist.rows[0].id}, ${userId}::uuid, 'W', null)`.execute(trx);
        sum = await getPersonalTwistWeightSum(trx, userId);
        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    }
    return sum;
  }

  it("sums capacity_weight of installed automations", async () => {
    expect(await seedWeightSum({ weight: 3 })).toBe(3);
  });

  it("excludes the built-in assistant (weight 0 / excluded)", async () => {
    expect(await seedWeightSum({ weight: 5, builtin: true })).toBe(0);
  });
});
```

- [ ] **Step 5: Typecheck + run**

```bash
cd workers/api && pnpm lint && pnpm test limits -- -t "weighted automation capacity"
```
Expected: PASS (weight sum 3; built-in 0). Fix any `twists`/`getPersonalTwistCount` references the typechecker flags (they belong to Tasks 3–4 but the rename surfaces them now).

- [ ] **Step 6: Commit**

```bash
git add workers/api/src/utils/limits.ts workers/api/src/utils/limits.test.ts
git commit -m "feat(limits): automation-capacity plan field + twist weight-sum/add-on readers"
```

---

### Task 3: `checkTwistCapacity` — weighted check (replaces `checkTwistLimit`)

**Files:**
- Modify: `workers/api/src/utils/limits.ts` — replace `checkTwistLimit` (:666-726) with `checkTwistCapacity`.
- Test: `workers/api/src/utils/limits.test.ts`.

**Interfaces:**
- Consumes: `getPersonalPlan` (existing), `getPersonalTwistAddonCount`, `getTeamTwistAddonCount`, `getPersonalTwistWeightSum`, `getTeamTwistWeightSum` (Task 2).
- Produces: `checkTwistCapacity(db, userId, teamId, candidateWeight): Promise<{allowed:true}|{allowed:false;error:PlanLimitError}>`. Allowed when `weightSum + candidateWeight ≤ capacity`; otherwise a `PlanLimitError` with `limitType:"twist"`, `reason:"twist_addon_required"`. Personal capacity = `PLAN_LIMITS[plan].automationCapacity + 20×addons`. Team capacity = `0` on a free team, else `PLAN_LIMITS.team.automationCapacity × connection_group_quantity + 20×addons`.

- [ ] **Step 1: Write failing tests**

Add to the `"weighted automation capacity"` describe block. This seeds a Free `user_subscription`, a non-source twist of `installedWeight`, an instance, and then checks a candidate of `candidateWeight`:

```typescript
async function seedAndCheckCapacity(opts: {
  installedWeight: number;
  candidateWeight: number;
  twistAddonCount?: number;
}): Promise<{ allowed: boolean; reason?: string }> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const userId = randomUUID();
  let result: { allowed: boolean; reason?: string } = { allowed: false };
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);
      await sql`INSERT INTO user_subscription (user_id, plan, status, twist_addon_count)
        VALUES (${userId}::uuid, 'free', 'active', ${opts.twistAddonCount ?? 0})`.execute(trx);
      if (opts.installedWeight > 0) {
        const twist = await sql<{ id: string }>`
          INSERT INTO twist (twist_package_id, environment, user_id, name, handle,
            version, is_source, premium, capacity_weight)
          VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid, 'I', 'i', '1.0.0',
            false, false, ${opts.installedWeight})
          RETURNING id`.execute(trx);
        await sql`INSERT INTO twist_instance (id, twist_id, owner_id, name, team_id)
          VALUES (${randomUUID()}::uuid, ${twist.rows[0].id}, ${userId}::uuid, 'I', null)`.execute(trx);
      }
      const res = await checkTwistCapacity(trx, userId, null, opts.candidateWeight);
      result = res.allowed ? { allowed: true } : { allowed: false, reason: res.error.reason };
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  }
  return result;
}

it("Free: first automation (weight 1) fits capacity 1", async () => {
  expect(await seedAndCheckCapacity({ installedWeight: 0, candidateWeight: 1 })).toEqual({ allowed: true });
});

it("Free: a second automation exceeds capacity 1 → twist_addon_required", async () => {
  expect(await seedAndCheckCapacity({ installedWeight: 1, candidateWeight: 1 })).toEqual({
    allowed: false,
    reason: "twist_addon_required",
  });
});

it("Free: a weight-2 automation alone exceeds capacity 1", async () => {
  expect(await seedAndCheckCapacity({ installedWeight: 0, candidateWeight: 2 })).toEqual({
    allowed: false,
    reason: "twist_addon_required",
  });
});

it("a purchased twist-add-on block (+20) lets it fit", async () => {
  expect(
    await seedAndCheckCapacity({ installedWeight: 1, candidateWeight: 1, twistAddonCount: 1 })
  ).toEqual({ allowed: true });
});
```

- [ ] **Step 2: Run to verify they fail**

```bash
cd workers/api && pnpm test limits -- -t "weighted automation capacity"
```
Expected: FAIL — `checkTwistCapacity` is not defined / `checkTwistLimit` still exists.

- [ ] **Step 3: Replace `checkTwistLimit` with `checkTwistCapacity`**

Replace the whole `checkTwistLimit` function (:666-726) with:

```typescript
/**
 * Weighted automation-capacity check. Allowed when the scope's installed twist
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
      .select(["plan", "connection_group_quantity", "twist_addon_count"])
      .where("team_id", "=", teamId)
      .executeTakeFirst();
    const plan = teamSub?.plan ?? "free";
    const blocks = teamSub?.connection_group_quantity ?? 1;
    const addons = teamSub?.twist_addon_count ?? 0;
    const capacity =
      plan === "free"
        ? 0
        : PLAN_LIMITS.team.automationCapacity * blocks + 20 * addons;
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
      }),
    };
  }

  const plan = await getPersonalPlan(db, userId);
  const addons = await getPersonalTwistAddonCount(db, userId);
  const capacity = PLAN_LIMITS[plan].automationCapacity + 20 * addons;
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
    }),
  };
}
```

- [ ] **Step 4: Run to verify they pass**

```bash
cd workers/api && pnpm test limits -- -t "weighted automation capacity"
```
Expected: PASS (all four capacity cases).

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/utils/limits.ts workers/api/src/utils/limits.test.ts
git commit -m "feat(limits): weighted checkTwistCapacity replaces flat checkTwistLimit"
```

---

### Task 4: Wire call sites + `getUsage` shape

**Files:**
- Modify: `workers/api/src/twist/management.ts` — import + three call sites (:193, :596, :913); ensure each candidate twist record selects `capacity_weight`.
- Modify: `workers/api/src/utils/limits.ts` — `getUsage` personal `twists` shape (:925-940) to use weight-sum + capacity.
- Test: `workers/api/src/utils/limits.test.ts` (covered by Task 3); plus a typecheck/full run.

**Interfaces:**
- Consumes: `checkTwistCapacity` (Task 3).
- Produces: twist installs/activations/moves enforce weighted capacity; `getUsage().personal.twists` = `{ count: <weight sum>, limit: <capacity> }` (same JSON shape; `count` now means weight used, `limit` the capacity number — never `null` now that capacity is finite).

- [ ] **Step 1: Update the import in `management.ts`**

Change the `import { … checkTwistLimit … } from "../utils/limits"` to import `checkTwistCapacity` instead.

- [ ] **Step 2: Update the `add` call site (:191-197)**

Replace:

```typescript
    // Check plan limits before inserting (sources check limits at channel-enable time)
    if (twistRecord?.is_source !== true) {
      const limitCheck = await checkTwistLimit(db, userId, team_id ?? null);
      if (!limitCheck.allowed) {
        throw limitCheck.error;
      }
    }
```

with:

```typescript
    // Check automation capacity before inserting (sources check at channel-enable time)
    if (twistRecord?.is_source !== true) {
      const limitCheck = await checkTwistCapacity(
        db,
        userId,
        team_id ?? null,
        twistRecord?.capacity_weight ?? 1
      );
      if (!limitCheck.allowed) {
        throw limitCheck.error;
      }
    }
```

Verify `twistRecord` is fetched with `capacity_weight` available (it selects from `twist`). If the query uses an explicit column list rather than `selectAll`, add `"capacity_weight"` to it; if `capacity_weight` is absent, the `?? 1` keeps behavior safe but the weight would be wrong — prefer selecting it.

- [ ] **Step 3: Update the `update` call site (:594-603)**

Replace the `checkTwistLimit(db, currentTwist.owner_id, twist.teamId)` call with:

```typescript
        const limitCheck = await checkTwistCapacity(
          db,
          currentTwist.owner_id,
          twist.teamId ?? null,
          currentTwist?.capacity_weight ?? 1
        );
```

Ensure `currentTwist` selects `capacity_weight` (add to its select list if explicit).

- [ ] **Step 4: Update the `activateDraft` call site (:911-917)**

Replace `checkTwistLimit(db, draft.owner_id, teamId)` with:

```typescript
    const limitCheck = await checkTwistCapacity(
      db,
      draft.owner_id,
      teamId ?? null,
      twistRecord?.capacity_weight ?? 1
    );
```

Ensure the `twistRecord` in scope selects `capacity_weight`.

- [ ] **Step 5: Update `getUsage` twists shape**

In `getUsage` (`limits.ts`), where it currently computes `twistCount` via the old count function and returns `twists: { count: twistCount, limit: limits.twists === Infinity ? null : limits.twists }`, change to use the weight sum and capacity:

```typescript
  const twistWeightSum = await getPersonalTwistWeightSum(db, userId);
  const twistAddonCount = await getPersonalTwistAddonCount(db, userId);
  const automationCapacity =
    limits.automationCapacity + 20 * twistAddonCount;
```

and the returned `twists` object:

```typescript
    twists: {
      count: twistWeightSum,
      limit: automationCapacity,
    },
```

(Keep the `{ count, limit }` keys so older Flutter clients still parse; B7 updates the display to "capacity used / available".)

- [ ] **Step 6: Typecheck + full worker test run**

```bash
cd workers/api && pnpm lint && pnpm test limits
```
Expected: PASS, no remaining references to `checkTwistLimit`, `getPersonalTwistCount`, `getTeamTwistCount`, or `PlanLimits.twists` (any stray reference is now a TS error — fix it).

- [ ] **Step 7: Commit**

```bash
git add workers/api/src/twist/management.ts workers/api/src/utils/limits.ts
git commit -m "feat(twist): enforce weighted automation capacity at install/activate/move; usage shows capacity"
```

---

## Self-Review

**Spec coverage (B1's slice of Spec B "Area 2 — server"):**
- `twist_package.capacity_weight` (here on `twist`, since no `twist_package` table) default 1 → Task 1. ✅
- Replace `PLAN_LIMITS.twists` flat count with a capacity number (Free 1 · Pro 10 · Team 10/block) → Task 2. ✅
- Weighted check at the twist-enable (install/activate/move) path → Tasks 3–4. ✅
- Built-in assistant weight 0 / excluded → weight-sum filter (Task 2) + test (Task 2 Step 4). ✅
- Entitlement field for purchased automation packs (`twist_addon_count`) feeding capacity → Tasks 1–3. ✅
- Deferred (later plans): twist-add-on billing wiring + `stripe_twist_addon_subscription_id`/`apple_twist_addon_*` (B2); SDK `capacity_weight` declaration (B6); `core` removal (B5). The intermediate state — `twist_addon_count` always 0 until B2 makes it purchasable — is internally consistent (capacity = plan base).

**Placeholder scan:** every code step shows exact code. The only prose-only guidance is "ensure the record selects `capacity_weight`" in Task 4 (Steps 2–4), which is a verification with a safe `?? 1` fallback shown — not a missing implementation.

**Type consistency:** `automationCapacity` replaces `twists` in `PlanLimits`/`PLAN_LIMITS` (Task 2) and is read in `checkTwistCapacity` (Task 3) and `getUsage` (Task 4). `checkTwistCapacity(db, userId, teamId, candidateWeight)` signature is identical at its definition (Task 3) and all three call sites (Task 4). `getPersonalTwistWeightSum`/`getTeamTwistWeightSum`/`getPersonalTwistAddonCount`/`getTeamTwistAddonCount` are defined in Task 2 and consumed in Tasks 3–4. `PlanLimitReason` gains `"twist_addon_required"` (Task 2) used in Task 3.
