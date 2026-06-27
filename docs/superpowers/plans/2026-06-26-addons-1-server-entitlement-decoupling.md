# Add-ons Plan 1 — Server entitlement decoupling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make add-on (premium) connections stop counting toward the plan connection pool and stop requiring a paid plan, so an add-on is allowed on any plan (Free/Core/Team) and is enforced purely by purchased add-on credits.

**Architecture:** All changes are in the API worker's pure/limit layer (`workers/api/src/utils/limits.ts`) plus its three callers (`trial.ts`, `twist/management.ts`, `twist/premium-connectors.ts` comment) and a comment/test in `apple/iap.ts`. The connection-pool counts exclude `twist.premium = true`; the add-on admission check requires only a spare purchased credit; the downgrade trimmer treats add-ons as a separate budget that the pool never touches; `PlanLimits.addonsAllowed` is deleted and `usage.premium.allowed` becomes always true.

**Tech Stack:** TypeScript, Cloudflare Workers, Kysely (Postgres), Vitest. DB-backed tests run against `$DATABASE_URL` and gate on it via `describe.skipIf(!DATABASE_URL)`.

## Global Constraints

- Add-on connectors are exactly `twist.premium = true` (LinkedIn / Instagram / WhatsApp, public + private). No other connector is an add-on.
- Pricing is unchanged and not referenced in this plan ($5/mo web; Apple $6.99/$12.99/$17.99).
- No schema/migration changes in this plan (the `stripe_addon_subscription_id` column lands in Plan 2).
- Never use fire-and-forget DB calls; always `await` Kysely and let errors propagate.
- Lint + test from the worker package: `cd workers/api && pnpm lint` and `pnpm test`.
- This is part of a worktree-isolated feature branch; commit after each task.

## File structure

- `workers/api/src/utils/limits.ts` — pool counts, `selectConnectionsToTrim`, `checkChannelConnectionLimit`, `PlanLimits`/`PLAN_LIMITS`, `personalPremiumUsage`/`shapeTeamPremiumUsage`/`getUsage`. (Primary.)
- `workers/api/src/utils/limits.test.ts` — count-exclusion + trim unit tests.
- `workers/api/src/utils/trial.ts:88,98` — `selectConnectionsToTrim` caller (trial-expiry trim).
- `workers/api/src/twist/management.ts:1435,1467,1477` — `selectConnectionsToTrim` caller (downgrade trim) + its `limits` Pick type.
- `workers/api/src/twist/premium-connectors.ts:8` — doc comment referencing `addonsAllowed`.
- `workers/api/src/apple/iap.ts` — `applyAppleAddonTransactionToUser` comment + a plan-less apply test in `apple/iap.test.ts`.

---

### Task 1: Exclude add-ons from the connection-pool counts

**Files:**
- Modify: `workers/api/src/utils/limits.ts` — `getPersonalConnectionCount` (`:147`), `getTeamConnectionCount` (`:281`), `getTeamConnectionCounts` (`:780`).
- Test: `workers/api/src/utils/limits.test.ts` — extend `seedAndCount`, add exclusion cases.

**Interfaces:**
- Consumes: nothing new.
- Produces: `getPersonalConnectionCount(db, userId)` and `getTeamConnectionCount(db, teamId)` now count only `twist.premium = false` source connectors; `getTeamConnectionCounts(db, teamIds)` likewise.

- [ ] **Step 1: Make `seedAndCount` able to seed a premium connector**

In `workers/api/src/utils/limits.test.ts`, add `premium` to the options and thread it into the twist insert (it currently hardcodes `false`):

```typescript
async function seedAndCount(opts: {
  scope: "personal" | "team";
  channelEnabled: boolean;
  premium?: boolean;
}): Promise<number> {
```

and change the twist insert's `premium` value from the literal `false` to:

```typescript
        VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid,
          'LinkedIn', 'linkedin', '1.0.0', true, ${opts.premium ?? false})
```

- [ ] **Step 2: Write the failing tests**

Add inside the existing `describe.skipIf(!DATABASE_URL)("connection quota excludes stuck instances", ...)` block:

```typescript
  it("personal: an enabled ADD-ON (premium) instance does NOT count", async () => {
    expect(
      await seedAndCount({ scope: "personal", channelEnabled: true, premium: true })
    ).toBe(0);
  });

  it("team: an enabled ADD-ON (premium) instance does NOT count", async () => {
    expect(
      await seedAndCount({ scope: "team", channelEnabled: true, premium: true })
    ).toBe(0);
  });
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd workers/api && pnpm test limits -- -t "ADD-ON"`
Expected: FAIL — both return `1` (premium still counted) instead of `0`. (If `$DATABASE_URL` is unset the suite is skipped; export it first — see AGENTS.md "Worktree Database Port".)

- [ ] **Step 4: Exclude premium from the three pool-count queries**

In `getPersonalConnectionCount`, `getTeamConnectionCount`, and `getTeamConnectionCounts`, add a `premium = false` filter next to the existing `tw.is_source` filter:

```typescript
    .where("tw.is_source", "=", true)
    .where("tw.premium", "=", false)
```

Also update the doc comment above `getPersonalConnectionCount` (`:143-146`) from "Includes add-on (premium) connectors…" to:

```typescript
 * Excludes add-on (premium) connectors — they are billed separately and do not
 * consume a plan connection slot. The add-on count is tracked independently via
 * `getPersonalPremiumConnectionCount` + `premium_connection_addons`.
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd workers/api && pnpm test limits -- -t "count"`
Expected: PASS — premium instances report 0; the existing non-premium "counts" tests still report 1.

- [ ] **Step 6: Commit**

```bash
git add workers/api/src/utils/limits.ts workers/api/src/utils/limits.test.ts
git commit -m "feat(limits): exclude add-on connectors from the connection pool count"
```

---

### Task 2: `selectConnectionsToTrim` — add-ons exempt from the pool, drop `addonsAllowed`

**Files:**
- Modify: `workers/api/src/utils/limits.ts` — `selectConnectionsToTrim` (`:248`) + its `budget` type.
- Modify: `workers/api/src/utils/trial.ts:88-99` — caller.
- Modify: `workers/api/src/twist/management.ts:1435,1467-1478` — caller + its `limits` Pick type.
- Test: `workers/api/src/utils/limits.test.ts` — `describe("selectConnectionsToTrim", …)`.

**Interfaces:**
- Produces: `selectConnectionsToTrim(connections, { connections: number; addonCredits: number }): TrimmableConnection[]` — note the removed `addonsAllowed` field. Add-ons are trimmed only beyond `addonCredits` (on any plan); the pool pass operates on non-premium connections only and never trims add-ons.

- [ ] **Step 1: Rewrite the trim unit tests for the new semantics**

In `limits.test.ts`, replace the existing `selectConnectionsToTrim` cases that reference `addonsAllowed` (the "trims the lone LinkedIn…", "Free trims every connection add-on…", "connection add-ons count toward the regular pool", "trims the OLDEST excess regular…", "keeps the newest `addonCredits`…", "Infinity pool…" cases) with these:

```typescript
  it("add-ons are never trimmed by the pool (only beyond purchased credits)", () => {
    // 1 regular + 3 add-ons, pool of 1, 3 add-on credits: nothing trims —
    // add-ons don't count toward the pool and all 3 are within credits.
    const reg = conn({ twistInstanceId: "reg", premium: false, connectedAt: "2026-01-01T00:00:00Z" });
    const a1 = conn({ twistInstanceId: "a1", premium: true, connectedAt: "2026-01-02T00:00:00Z" });
    const a2 = conn({ twistInstanceId: "a2", premium: true, connectedAt: "2026-01-03T00:00:00Z" });
    const a3 = conn({ twistInstanceId: "a3", premium: true, connectedAt: "2026-01-04T00:00:00Z" });
    const trimmed = selectConnectionsToTrim([reg, a1, a2, a3], {
      connections: 1,
      addonCredits: 3,
    });
    expect(trimmed).toEqual([]);
  });

  it("trims add-ons beyond purchased credits, newest kept, on ANY plan", () => {
    // Free plan (pool 2), 1 purchased credit, 2 add-ons -> trim the older add-on.
    const old = conn({ twistInstanceId: "old", premium: true, connectedAt: "2026-01-01T00:00:00Z" });
    const newest = conn({ twistInstanceId: "newest", premium: true, connectedAt: "2026-01-02T00:00:00Z" });
    const trimmed = selectConnectionsToTrim([old, newest], {
      connections: 2,
      addonCredits: 1,
    });
    expect(trimmed.map((c) => c.twistInstanceId)).toEqual(["old"]);
  });

  it("trims the OLDEST excess regular connections, keeping the newest; add-ons untouched", () => {
    const oldest = conn({ twistInstanceId: "oldest", premium: false, connectedAt: "2026-01-01T00:00:00Z" });
    const newer = conn({ twistInstanceId: "newer", premium: false, connectedAt: "2026-01-02T00:00:00Z" });
    const newest = conn({ twistInstanceId: "newest", premium: false, connectedAt: "2026-01-03T00:00:00Z" });
    const addon = conn({ twistInstanceId: "addon", premium: true, connectedAt: "2026-01-04T00:00:00Z" });
    const trimmed = selectConnectionsToTrim([oldest, newer, newest, addon], {
      connections: 2,
      addonCredits: 1,
    });
    expect(trimmed.map((c) => c.twistInstanceId)).toEqual(["oldest"]);
  });

  it("Infinity pool + enough credits never trims", () => {
    const reg1 = conn({ twistInstanceId: "reg1", premium: false });
    const reg2 = conn({ twistInstanceId: "reg2", premium: false });
    const add = conn({ twistInstanceId: "add", premium: true });
    const trimmed = selectConnectionsToTrim([reg1, reg2, add], {
      connections: Infinity,
      addonCredits: 1,
    });
    expect(trimmed).toEqual([]);
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd workers/api && pnpm test limits -- -t "selectConnectionsToTrim"`
Expected: FAIL — a TS/shape error because the new calls omit `addonsAllowed`, or wrong trims, since the implementation still pool-trims add-ons.

- [ ] **Step 3: Rewrite `selectConnectionsToTrim`**

Replace the body (`limits.ts:248-273`) with:

```typescript
export function selectConnectionsToTrim(
  connections: TrimmableConnection[],
  budget: { connections: number; addonCredits: number }
): TrimmableConnection[] {
  const newestFirst = (a: TrimmableConnection, b: TrimmableConnection) =>
    new Date(b.connectedAt).getTime() - new Date(a.connectedAt).getTime();

  const toTrim: TrimmableConnection[] = [];

  // Pass 1: connection add-ons beyond the purchased credit. Add-ons are
  // available on any plan now, so the credit cap applies regardless of plan.
  const addons = connections.filter((c) => c.premium).sort(newestFirst);
  toTrim.push(...addons.slice(budget.addonCredits));

  // Pass 2: regular (non-add-on) connections beyond the pool. Add-ons never
  // count toward the pool, so they are excluded here and never pool-trimmed.
  if (budget.connections !== Infinity) {
    const regulars = connections.filter((c) => !c.premium).sort(newestFirst);
    toTrim.push(...regulars.slice(budget.connections));
  }

  return toTrim;
}
```

Update the doc comment above it (`:233-247`) to describe the two independent budgets (add-on credits; regular pool excluding add-ons).

- [ ] **Step 4: Update the two callers**

In `workers/api/src/utils/trial.ts` (around `:88-99`), drop `addonsAllowed` from the budget object passed to `selectConnectionsToTrim`. Remove the now-unused `addonsAllowed: PLAN_LIMITS.free.addonsAllowed` line.

In `workers/api/src/twist/management.ts`:
- `:1435` — change the `limits` parameter type from `Pick<PlanLimits, "connections" | "twists" | "addonsAllowed">` to `Pick<PlanLimits, "connections" | "twists">`.
- `:1467-1478` — drop `addonsAllowed: limits.addonsAllowed` from the budget object.

- [ ] **Step 5: Run the trim tests to verify they pass**

Run: `cd workers/api && pnpm test limits -- -t "selectConnectionsToTrim"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add workers/api/src/utils/limits.ts workers/api/src/utils/limits.test.ts \
  workers/api/src/utils/trial.ts workers/api/src/twist/management.ts
git commit -m "feat(limits): add-ons exempt from pool trim; drop addonsAllowed from trim budget"
```

---

### Task 3: `checkChannelConnectionLimit` — add-ons need only a credit, never the pool

**Files:**
- Modify: `workers/api/src/utils/limits.ts` — `checkChannelConnectionLimit` (`:459`), `PlanLimitReason` (`:55-60`).
- Test: `workers/api/src/utils/limits.test.ts` — new DB-backed `describe` for add-on admission.

**Interfaces:**
- Consumes: `getPersonalPlan`, `getPersonalPremiumAddons`, `getPersonalPremiumConnectionCount` (unchanged).
- Produces: `checkChannelConnectionLimit` allows an add-on connector when `activeAddons < purchasedAddons` regardless of plan (incl. Free), returns `PlanLimitError` with `reason: "addon_required"` otherwise, and never applies the pool check to an add-on connector. `PlanLimitReason` no longer includes `"addon_unavailable"`.

- [ ] **Step 1: Write the failing DB-backed tests**

Add a new block to `limits.test.ts`. It seeds a Free `user_subscription`, a premium twist + instance + connection + enabled channel, and a `premium_connection_addons` count, then calls `checkChannelConnectionLimit`. Add `checkChannelConnectionLimit` to the imports from `./limits`.

```typescript
describe.skipIf(!DATABASE_URL)("checkChannelConnectionLimit add-on admission", () => {
  async function seedAddonAndCheck(opts: {
    purchasedAddons: number;
  }): Promise<{ allowed: boolean; reason?: string }> {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    const userId = randomUUID();
    const twistInstanceId = randomUUID();
    let result: { allowed: boolean; reason?: string } = { allowed: false };
    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);

        await sql`INSERT INTO user_subscription
            (user_id, plan, status, premium_connection_addons)
          VALUES (${userId}::uuid, 'free', 'active', ${opts.purchasedAddons})`.execute(trx);

        const twist = await sql<{ id: string }>`
          INSERT INTO twist
            (twist_package_id, environment, user_id, name, handle, version,
             is_source, premium)
          VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid,
            'LinkedIn', 'linkedin', '1.0.0', true, true)
          RETURNING id`.execute(trx);

        await sql`INSERT INTO twist_instance
            (id, twist_id, owner_id, name, team_id)
          VALUES (${twistInstanceId}::uuid, ${twist.rows[0].id}, ${userId}::uuid,
            'LinkedIn', null)`.execute(trx);

        await sql`INSERT INTO twist_instance_connection
            (twist_instance_id, user_id, provider, actor_id)
          VALUES (${twistInstanceId}::uuid, ${userId}::uuid, 'linkedin',
            ${randomUUID()}::uuid)`.execute(trx);

        const res = await checkChannelConnectionLimit(trx, userId, twistInstanceId);
        result = res.allowed
          ? { allowed: true }
          : { allowed: false, reason: res.error.reason };

        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    }
    return result;
  }

  it("Free user WITH a spare add-on credit is allowed", async () => {
    expect(await seedAddonAndCheck({ purchasedAddons: 1 })).toEqual({ allowed: true });
  });

  it("Free user with NO add-on credit needs to buy one", async () => {
    expect(await seedAddonAndCheck({ purchasedAddons: 0 })).toEqual({
      allowed: false,
      reason: "addon_required",
    });
  });
});
```

(Note: there is no enabled channel yet for the instance under test, so `getPersonalPremiumConnectionCount` reports 0 active add-ons; with `purchasedAddons: 1` that's `0 < 1` → allowed; with `0` it's `0 >= 0` → `addon_required`.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd workers/api && pnpm test limits -- -t "add-on admission"`
Expected: FAIL — the Free user is currently rejected with `addon_unavailable` (today `PLAN_LIMITS.free.addonsAllowed === false`), so the "WITH a spare credit is allowed" case fails.

- [ ] **Step 3: Rewrite the add-on branch and remove `addon_unavailable`**

In `PlanLimitReason` (`:55-60`), delete the `| "addon_unavailable"` member and its comment.

In `checkChannelConnectionLimit`, replace the personal add-on branch (`:589-623`, the `if (isAddon) { if (!limits.addonsAllowed) {…} … }` block) with a version that drops the plan check and returns early on success so the pool check never applies to an add-on:

```typescript
  // Add-on connector: independent of the plan. Allowed when there is a spare
  // purchased add-on credit; never consumes a plan pool slot.
  if (isAddon) {
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
    return { allowed: true };
  }
```

Apply the same shape to the **team** add-on branch (`:523-544`): remove any reliance on plan being paid, keep the `addonCount >= purchased → addon_required` check, and `return { allowed: true }` immediately when within credits (so team add-ons skip the team pool check too). Leave the Free-team "no connections at all" guard (`:506-521`) for **non-add-on** connectors only — move the `if (isAddon)` add-on check above that guard so an add-on is admitted on a Free team when it has a purchased credit.

Update the function's doc comment (`:449-458`) to describe the new behavior (add-ons: credit-only, any plan, never pool; regulars: pool only).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd workers/api && pnpm test limits -- -t "add-on admission"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/utils/limits.ts workers/api/src/utils/limits.test.ts
git commit -m "feat(limits): admit add-on connectors on any plan by credit only, never the pool"
```

---

### Task 4: Delete `PlanLimits.addonsAllowed`; `usage.premium.allowed` always true

**Files:**
- Modify: `workers/api/src/utils/limits.ts` — `PlanLimits` (`:27-32`), `PLAN_LIMITS` (`:34-39`), `personalPremiumUsage` (`:768`), `shapeTeamPremiumUsage` (`:847`), `getUsage` premium-team filter (`:892-894`).
- Modify: `workers/api/src/twist/premium-connectors.ts:8` — doc comment.

**Interfaces:**
- Produces: `PlanLimits` no longer has `addonsAllowed`; `PremiumUsage.allowed` is always `true` (kept in the payload for client backwards compatibility).

- [ ] **Step 1: Remove the field from the type and table**

In `limits.ts`, delete `addonsAllowed: boolean;` from `PlanLimits` (`:31`) and delete the `addonsAllowed: …` entry from each `PLAN_LIMITS` row (`:35-38`). Update the `PlanLimits` doc comment (`:13-26`) to drop the "addonsAllowed is false only on Free" paragraph and state add-ons are independent of plans.

- [ ] **Step 2: Set `allowed` to true at the two shaping sites**

In `personalPremiumUsage` (`:768`), replace:

```typescript
  const allowed = PLAN_LIMITS[plan].addonsAllowed;
```

with:

```typescript
  // Add-ons are available on every plan now; `allowed` is retained in the
  // payload only for backwards compatibility with older clients.
  const allowed = true;
```

In `shapeTeamPremiumUsage` (`:841-851`), replace `allowed: PLAN_LIMITS[plan].addonsAllowed,` with `allowed: true,` (the `plan` parameter becomes unused — drop it from the signature and its one call site at `:916`).

- [ ] **Step 3: Always fetch team add-on counts**

In `getUsage` (`:892-894`), replace the `anyPremiumTeam` computation (which used `addonsAllowed`) with an always-on fetch when there are teams:

```typescript
  const anyPremiumTeam = teamIds.length > 0;
```

- [ ] **Step 4: Fix the premium-connectors comment**

In `workers/api/src/twist/premium-connectors.ts:8`, update the comment that references `PLAN_LIMITS[plan].addonsAllowed` to instead reference the per-credit model (active add-on connections ≤ `premium_connection_addons`), since `addonsAllowed` no longer exists.

- [ ] **Step 5: Typecheck + full worker test run**

Run: `cd workers/api && pnpm lint && pnpm test limits`
Expected: PASS, with no remaining references to `addonsAllowed` (a stray reference is now a TS error). If `pnpm lint` reports `addonsAllowed` anywhere, fix that reference.

- [ ] **Step 6: Commit**

```bash
git add workers/api/src/utils/limits.ts workers/api/src/twist/premium-connectors.ts
git commit -m "refactor(limits): delete PlanLimits.addonsAllowed; premium.allowed always true"
```

---

### Task 5: Apple add-on apply works for a plan-less user

**Files:**
- Modify: `workers/api/src/apple/iap.ts` — `applyAppleAddonTransactionToUser` comment (`:742-743`).
- Test: `workers/api/src/apple/iap.test.ts` — plan-less apply case.

**Interfaces:**
- Produces: no signature change; documents and tests that `applyAppleAddonTransactionToUser` sets `premium_connection_addons` for a user whose `user_subscription.plan = 'free'` (the row exists from account activation).

- [ ] **Step 1: Write the failing test**

In `workers/api/src/apple/iap.test.ts`, add a DB-backed case (mirroring the existing add-on apply tests' seeding) that inserts a `user_subscription` with `plan = 'free'` and asserts `applyAppleAddonTransactionToUser` returns `{ addons: 1 }` and the row's `premium_connection_addons` is `1` for product `day.plot.app.addon_1`:

```typescript
  it("applies an add-on tier to a FREE-plan user (no paid plan required)", async () => {
    // seed user_subscription(plan='free') for `userId`, then:
    const { addons } = await applyAppleAddonTransactionToUser(db, userId, {
      productId: "day.plot.app.addon_1",
      originalTransactionId: randomUUID(),
      expiresDate: Date.now() + 60_000,
      revocationDate: null,
    } as unknown as JwsTransactionPayload);
    expect(addons).toBe(1);
    const row = await db
      .selectFrom("user_subscription")
      .select("premium_connection_addons")
      .where("user_id", "=", userId)
      .executeTakeFirstOrThrow();
    expect(row.premium_connection_addons).toBe(1);
  });
```

(Follow the seeding/teardown pattern already used by the other cases in `iap.test.ts`; reuse its helpers rather than introducing new ones.)

- [ ] **Step 2: Run to verify it passes (behavior already correct) or fails (if a guard exists)**

Run: `cd workers/api && pnpm test iap -- -t "FREE-plan"`
Expected: PASS (the function does an in-place UPDATE and the Free row exists). If it FAILS because of an added plan guard, remove that guard so a Free row is updated.

- [ ] **Step 3: Update the misleading comment**

In `applyAppleAddonTransactionToUser` (`:742-743`), replace:

```typescript
  // The user must already have a subscription row (add-ons require a paid plan,
  // which created it). UPDATE in place; never touch the plan fields.
```

with:

```typescript
  // The user already has a subscription row (created at account activation,
  // even on Free — add-ons are independent of the plan). UPDATE in place;
  // never touch the plan fields.
```

- [ ] **Step 4: Commit**

```bash
git add workers/api/src/apple/iap.ts workers/api/src/apple/iap.test.ts
git commit -m "test(iap): apply Apple add-on entitlement for plan-less (Free) users"
```

---

## Self-Review

**Spec coverage (Plan 1's slice of the spec's "Server changes · limits.ts" + Apple):**
- Pool excludes add-ons → Task 1. ✅
- `selectConnectionsToTrim` never pool-trims add-ons; drop `addonsAllowed` → Task 2. ✅
- `checkChannelConnectionLimit` add-ons credit-only, any plan, no pool; remove `addon_unavailable` → Task 3. ✅
- Delete `PlanLimits.addonsAllowed`; `premium.allowed` always true → Task 4. ✅
- Apple plan-less apply → Task 5. ✅
- Deferred to Plan 2 (out of this plan's scope): `stripe_addon_subscription_id` schema column, reconciliation hook, Stripe endpoints/webhook, the front-end fulfillment of `addon_required`. The intermediate state after Plan 1 (the check returns `addon_required` with no auto-fulfillment yet) is internally consistent and is wired up in Plan 2.

**Placeholder scan:** none — every code/test step shows the exact code. The one prose-only step (Task 5 Step 1 seeding) points at an existing in-file pattern rather than inventing helpers.

**Type consistency:** `selectConnectionsToTrim`'s budget is `{ connections, addonCredits }` everywhere (definition Task 2 Step 3, callers Task 2 Step 4, tests Task 2 Step 1). `PlanLimitReason` loses `addon_unavailable` in Task 3 and no task references it afterward. `shapeTeamPremiumUsage` loses its `plan` param in Task 4 Step 2 and its caller is updated in the same step.
