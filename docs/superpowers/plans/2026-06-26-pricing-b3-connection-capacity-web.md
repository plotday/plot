# Pricing B3 — Connection capacity add-on (web) + trim flip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make a **regular** connection beyond a plan's included pool (Free 2, Team 50/block) a **billable connection add-on** instead of a hard block — reusing the existing `$5/mo` connection-add-on machinery — so the client can offer "$5 connection add-on **or** upgrade to Pro." Generalize the billable-connection quantity to `max(0, activeRegular − includedPool) + activeAddonRequired`, and flip the downgrade trimmer to **keep the oldest / trim the newest** connections.

**Architecture:** Server-only, all in `workers/api`. `checkChannelConnectionLimit` (in `utils/limits.ts`) stops returning a hard `connection_limit` for a regular connection over a finite pool and instead checks **connection-add-on headroom** (returns `addon_required` when none) — exactly as it already does for add-on-required (`premium`) connectors. A new `getBillableConnectionAddonCount(db, scope)` = `max(0, regularCount − pool) + addonRequiredCount` replaces the "active add-on-required connections" quantity used by the Stripe reconcile + purchase target. `selectConnectionsToTrim` flips its sort comparator to oldest-first. The server stays platform-agnostic; the client (B7) gates the *offer* (web: add-on **or** Pro; App Store: Pro only).

**Tech Stack:** TypeScript, Cloudflare Workers, Kysely (Postgres), Vitest. DB-backed tests gate on `$DATABASE_URL` via `describe.skipIf(!DATABASE_URL)`.

## Global Constraints

- **Base:** branch `pricing-model-product-changes` (B2 done @ `e8d978cf`). Continue on it.
- **Worktree DB on 54333** (ambient `$DATABASE_URL` stale 54322). Before any test: `export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54333/postgres"`. No schema change in B3 → no migration / type regen.
- **Verify each commit with `npx tsc --noEmit` (exit 0)** — harness new-diagnostics fire stale mid-edit; the committed HEAD is the source of truth. `pnpm lint` = `tsc && eslint` but eslint excludes tests; `tsc --noEmit` covers tests.
- **Billable formula (verbatim):** `billableConnectionAddons(scope) = max(0, activeRegular − includedPool) + activeAddonRequired`. `includedPool` = `PLAN_LIMITS[plan].connections` (personal; `Infinity` on Pro → first term 0) or the team's purchased 50-block pool (`getTeamConnectionLimit`). `activeRegular` = `getPersonalConnectionCount`/`getTeamConnectionCount` (already exclude `premium`). `activeAddonRequired` = `getPersonalPremiumConnectionCount`/`getTeamPremiumConnectionCount`.
- **Trim policy (verbatim, user-directed):** on a downgrade/entitlement drop, **keep the OLDEST connections, trim the NEWEST excess** — both the add-on pass and the regular-pool pass. (Flip the current `newestFirst` comparator to `oldestFirst`.)
- **Platform-agnostic server:** `checkChannelConnectionLimit` returns `addon_required` for a regular-beyond-pool connection on a finite-pool plan; it does NOT branch on web-vs-Apple. The client decides the fulfilment offer (B7). Reconcile/purchase are Stripe-only (they already no-op when there's no Stripe add-on subscription).
- Never fire-and-forget DB; `captureException` new catch blocks. Lint+test from `workers/api`. Commit per task.

## File structure

- `workers/api/src/utils/limits.ts` — `getBillableConnectionAddonCount` (new); `checkChannelConnectionLimit` regular-pool branches (personal + team); `selectConnectionsToTrim` comparator + its callers' budget (already `{connections, addonCredits}`).
- `workers/api/src/utils/limits.test.ts` — billable-count + admission + trim tests.
- `workers/api/src/app/upgrade.ts` — the connection add-on **purchase target** + the connection **reconcile** quantity (currently `getPersonalPremiumConnectionCount`/team) generalize to `getBillableConnectionAddonCount`.
- `workers/api/src/app/twist-integrations.ts` — `reconcileScopeAddonBillingDown` (connection reconcile) uses the generalized count.

---

### Task 1: `getBillableConnectionAddonCount` + flip the trim comparator

**Files:**
- Modify: `workers/api/src/utils/limits.ts` — add `getBillableConnectionAddonCount`; flip `selectConnectionsToTrim` comparator (`:319`).
- Test: `workers/api/src/utils/limits.test.ts`.

**Interfaces — Produces:**
- `getBillableConnectionAddonCount(db, scope: { userId: string } | { teamId: string }): Promise<number>` = `max(0, activeRegular − includedPool) + activeAddonRequired`. Personal: `includedPool = PLAN_LIMITS[getPersonalPlan].connections` (status-gated; `Infinity` → first term 0). Team: `includedPool = getTeamConnectionLimit(db, teamId)` (status-gated free team → pool 0).
- `selectConnectionsToTrim` unchanged signature; comparator now keeps oldest, trims newest.

- [ ] **Step 1: Flip the trim comparator + write the trim test**

In `selectConnectionsToTrim` (`limits.ts:319`), replace the `newestFirst` comparator with `oldestFirst` (so `.slice(budget)` keeps the oldest `budget` and trims the newer excess), and rename the local for clarity:

```typescript
  const oldestFirst = (a: TrimmableConnection, b: TrimmableConnection) =>
    new Date(a.connectedAt).getTime() - new Date(b.connectedAt).getTime();

  const toTrim: TrimmableConnection[] = [];

  // Pass 1: connection add-ons beyond the purchased credit — keep the OLDEST,
  // trim the newest excess (preserve foundational installs).
  const addons = connections.filter((c) => c.premium).sort(oldestFirst);
  toTrim.push(...addons.slice(budget.addonCredits));

  // Pass 2: regular (non-add-on) connections beyond the pool — keep the OLDEST,
  // trim the newest. Add-ons never count toward the pool.
  if (budget.connections !== Infinity) {
    const regulars = connections.filter((c) => !c.premium).sort(oldestFirst);
    toTrim.push(...regulars.slice(budget.connections));
  }

  return toTrim;
```

In `limits.test.ts`, update the existing `selectConnectionsToTrim` tests that assert which connection is trimmed: the "trims the OLDEST excess regular… keeping the newest" case must become **"trims the NEWEST excess regular, keeping the oldest"** (flip the expected ids), and the add-on "newest kept" case becomes **"oldest kept"**. Add an explicit case:

```typescript
  it("trims the NEWEST excess regular connections, keeping the oldest; add-ons untouched", () => {
    const oldest = conn({ twistInstanceId: "oldest", premium: false, connectedAt: "2026-01-01T00:00:00Z" });
    const newer = conn({ twistInstanceId: "newer", premium: false, connectedAt: "2026-01-02T00:00:00Z" });
    const newest = conn({ twistInstanceId: "newest", premium: false, connectedAt: "2026-01-03T00:00:00Z" });
    const trimmed = selectConnectionsToTrim([oldest, newer, newest], {
      connections: 1,
      addonCredits: 0,
    });
    // pool of 1 keeps the oldest; newer + newest are trimmed.
    expect(trimmed.map((c) => c.twistInstanceId).sort()).toEqual(["newer", "newest"]);
  });

  it("trims the NEWEST add-on beyond credits, keeping the oldest", () => {
    const old = conn({ twistInstanceId: "old", premium: true, connectedAt: "2026-01-01T00:00:00Z" });
    const newest = conn({ twistInstanceId: "newest", premium: true, connectedAt: "2026-01-02T00:00:00Z" });
    const trimmed = selectConnectionsToTrim([old, newest], { connections: 2, addonCredits: 1 });
    expect(trimmed.map((c) => c.twistInstanceId)).toEqual(["newest"]);
  });
```

- [ ] **Step 2: Run the trim tests — verify they pass**

`cd workers/api && pnpm test limits -- -t "selectConnectionsToTrim"` → PASS (new oldest-keeping semantics). Fix any other existing trim case whose expectation still assumes newest-kept.

- [ ] **Step 3: Write the failing billable-count test**

Add a DB-backed block to `limits.test.ts` (mirror the existing connection-count seeding). Add `getBillableConnectionAddonCount` to the `./limits` import. Seed a Free personal user with N regular enabled connections and M add-on-required (premium) ones, and assert:

```typescript
describe.skipIf(!DATABASE_URL)("getBillableConnectionAddonCount", () => {
  it("Free: 3 regular + 1 add-on-required → (3−2) + 1 = 2 billable", async () => {
    expect(await seedAndBillable({ plan: "free", regular: 3, addonRequired: 1 })).toBe(2);
  });
  it("Free: 2 regular (at pool) + 0 add-on → 0 billable", async () => {
    expect(await seedAndBillable({ plan: "free", regular: 2, addonRequired: 0 })).toBe(0);
  });
  it("Pro: 5 regular + 2 add-on-required → 0 + 2 = 2 billable (∞ pool)", async () => {
    expect(await seedAndBillable({ plan: "pro", regular: 5, addonRequired: 2 })).toBe(2);
  });
});
```

(Write the `seedAndBillable` helper following the existing connection-count seeding helper in the file — seed a `user_subscription` of `plan`, then `regular` non-premium + `addonRequired` premium source twists each with an enabled channel, then call `getBillableConnectionAddonCount(trx, { userId })` inside a rolled-back transaction.)

- [ ] **Step 4: Run — verify it fails** (`getBillableConnectionAddonCount` undefined): `cd workers/api && pnpm test limits -- -t "getBillableConnectionAddonCount"` → FAIL.

- [ ] **Step 5: Implement `getBillableConnectionAddonCount`**

Add near `getPersonalPremiumConnectionCount`:

```typescript
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
    const pool = await getTeamConnectionLimit(db, teamId); // status-gated; free team → 0
    const addonRequired = await getTeamPremiumConnectionCount(db, teamId);
    return Math.max(0, regular - pool) + addonRequired;
  }
  const { userId } = scope;
  const plan = await getPersonalPlan(db, userId);
  const pool = PLAN_LIMITS[plan].connections;
  const regular = await getPersonalConnectionCount(db, userId);
  const addonRequired = await getPersonalPremiumConnectionCount(db, userId);
  const overPool = pool === Infinity ? 0 : Math.max(0, regular - pool);
  return overPool + addonRequired;
}
```

- [ ] **Step 6: Run — verify pass.** `cd workers/api && pnpm test limits -- -t "getBillableConnectionAddonCount"` → PASS. Then `npx tsc --noEmit` → 0.

- [ ] **Step 7: Commit.** `git add workers/api/src/utils/limits.ts workers/api/src/utils/limits.test.ts && git commit -m "feat(limits): billable-connection-add-on count + trim newest-first on downgrade"`

---

### Task 2: `checkChannelConnectionLimit` — regular-beyond-pool needs add-on headroom

**Files:**
- Modify: `workers/api/src/utils/limits.ts` — `checkChannelConnectionLimit` personal regular-pool branch (`:704-724`) + team `team` plan branch (`:~620`).
- Test: `workers/api/src/utils/limits.test.ts`.

**Interfaces:**
- Consumes: `getBillableConnectionAddonCount`, `getPersonalPremiumAddons`/`getTeamPremiumAddons` (entitlement = `premium_connection_addons`).
- Produces: for a **regular** connector on a finite-pool plan, `checkChannelConnectionLimit` returns `allowed:true` while `billableAfterAdding ≤ premium_connection_addons`, else `addon_required` (NOT `connection_limit`). The add-on-required (`premium`) branch is unchanged. Pro (∞ pool) regular connectors stay `allowed:true`.

- [ ] **Step 1: Write failing admission tests**

Add to `limits.test.ts` (mirror the existing add-on admission DB block). For a Free personal user:

```typescript
describe.skipIf(!DATABASE_URL)("checkChannelConnectionLimit regular-beyond-pool", () => {
  it("Free: 3rd regular connection with NO add-on credit → addon_required", async () => {
    // seed 2 enabled regular connections (at pool) + premium_connection_addons=0,
    // then check a NEW regular connection instance → adding it makes billable 1 > 0.
    expect(await seedRegularAndCheck({ existingRegular: 2, purchasedAddons: 0 }))
      .toEqual({ allowed: false, reason: "addon_required" });
  });
  it("Free: 3rd regular connection WITH 1 add-on credit → allowed", async () => {
    expect(await seedRegularAndCheck({ existingRegular: 2, purchasedAddons: 1 }))
      .toEqual({ allowed: true });
  });
  it("Free: 2nd regular connection (within pool) → allowed, no add-on needed", async () => {
    expect(await seedRegularAndCheck({ existingRegular: 1, purchasedAddons: 0 }))
      .toEqual({ allowed: true });
  });
});
```

(`seedRegularAndCheck` seeds a Free `user_subscription` with `premium_connection_addons`, `existingRegular` enabled non-premium connections, and a NEW non-premium twist instance under test, then calls `checkChannelConnectionLimit(trx, userId, newTwistInstanceId)`. Adding the new one makes `regular = existingRegular + 1`; billable = `max(0, (existingRegular+1) − 2) + 0`. Follow the file's existing add-on admission seeding.)

- [ ] **Step 2: Run — verify fail** (today the Free 3rd regular returns plain `connection_limit`, so the WITH-credit case is rejected and the reason differs): `pnpm test limits -- -t "regular-beyond-pool"` → FAIL.

- [ ] **Step 3: Rewrite the personal regular-pool branch**

Replace the personal regular-pool check (`limits.ts:704-724`, the `if (limits.connections === Infinity) {...}` + `count >= limits.connections → connection_limit` block) with an add-on-headroom check:

```typescript
  // Regular connector. Within the included pool it's free; beyond the pool it
  // requires connection-add-on headroom (same $5 credit as an add-on-required
  // connector). The client offers "add-on or upgrade" (web) / "upgrade" (App
  // Store); the server is platform-agnostic and returns addon_required.
  if (limits.connections === Infinity) {
    return { allowed: true };
  }
  const billableAfter = await getBillableConnectionAddonCount(db, { userId });
  // getBillableConnectionAddonCount counts CURRENTLY-enabled connections; the
  // one under test is not yet enabled, so adding it pushes regular by 1 when it
  // is beyond the pool. Recompute with the pending regular connection included:
  const regularNow = await getPersonalConnectionCount(db, userId);
  const pendingBillable =
    Math.max(0, regularNow + 1 - limits.connections) +
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
        limit: limits.connections,
        isTeam: false,
        isAdmin: false,
        teamId: null,
      }),
    };
  }
  return { allowed: true };
```

(Drop the now-unused `count >= limits.connections` block. Keep `billableAfter`/`pendingBillable` as one clear computation — if `getBillableConnectionAddonCount` already returns the "currently enabled" billable, `pendingBillable` is the with-candidate value; collapse to a single helper call plus the `+1` adjustment for the pending regular connection. Do not double-count.)

- [ ] **Step 4: Mirror the team `team`-plan branch**

In the team branch's `if (teamPlan === "team")` block (`:~620`, currently `count + 1 > limit → connection_limit`), apply the same generalization: beyond the team pool, require add-on headroom → `addon_required` (admin flag preserved) instead of `connection_limit`. Use `getBillableConnectionAddonCount(db, { teamId })` + `getTeamPremiumAddons`. Leave the Free-team "no regular connections at all" guard and the add-on-required branch unchanged.

- [ ] **Step 5: Run — verify pass.** `pnpm test limits -- -t "regular-beyond-pool"` → PASS. Then `pnpm test limits` (whole file) + `npx tsc --noEmit` → all green/0. Fix any existing `connection_limit` expectation that should now be `addon_required`.

- [ ] **Step 6: Commit.** `git commit -am "feat(limits): regular connection beyond pool requires add-on headroom (addon_required)"`

---

### Task 3: Generalize the Stripe reconcile + purchase quantity to billable connections

**Files:**
- Modify: `workers/api/src/app/twist-integrations.ts` — `reconcileScopeAddonBillingDown` (`:300`) quantity source.
- Modify: `workers/api/src/app/upgrade.ts` — the connection add-on **purchase target** in `purchaseAddonCreditForScope` (`:868`) / `POST /upgrade/addons/purchase`.
- Test: `workers/api/src/app/upgrade.test.ts`.

**Interfaces:**
- Produces: the connection add-on subscription quantity (Stripe) tracks `getBillableConnectionAddonCount(scope)` rather than `getPersonalPremiumConnectionCount`/team (add-on-required-only). Reconcile-down and the purchase target both use the generalized count. (Apple unaffected — reconcile no-ops without a Stripe add-on sub.)

- [ ] **Step 1: Failing tests.** In `upgrade.test.ts` (mirror existing connection add-on reconcile/purchase tests): after enabling a regular-beyond-pool connection on a Free Stripe scope, `reconcileScopeAddonBillingDown` sets the add-on sub quantity to the billable count (incl. the regular-beyond-pool term); the purchase target equals `getBillableConnectionAddonCount`. Run → FAIL.

- [ ] **Step 2: Swap the quantity source.** In `reconcileScopeAddonBillingDown` (`twist-integrations.ts:300`) replace the `getPersonalPremiumConnectionCount`/`getTeamPremiumConnectionCount` active-count with `getBillableConnectionAddonCount(db, scope)`. In `purchaseAddonCreditForScope` / the `/upgrade/addons/purchase` handler, set the target to `getBillableConnectionAddonCount` (the connection add-on provisioning becomes "set to billable count" — keep `provisionAddonCredit`'s create path but ensure the resulting quantity equals billable; if `provisionAddonCredit` is strictly +1, add a `setConnectionAddonQuantity`-style absolute setter mirroring `setTwistAddonQuantity`, or compute the delta). Keep behavior identical for pure add-on-required scopes (billable == add-on-required count when regular ≤ pool).

- [ ] **Step 3: Run — verify pass.** `pnpm test upgrade` + `npx tsc --noEmit` → green/0.

- [ ] **Step 4: Commit.** `git commit -am "feat(upgrade): connection add-on quantity tracks billable connections (regular-beyond-pool + add-on-required)"`

---

### Task 4: Full-suite guard + docs fragment

**Files:**
- Test: full `workers/api` suite.
- Modify: `docs/updates.d/<slug>.md` (user-facing fragment, optional per AGENTS.md).

- [ ] **Step 1:** `cd workers/api && DATABASE_URL=…54333 pnpm test` → all green (note any pre-existing parallel-isolation flake in `link*.test.ts`; re-run that file in isolation to confirm unrelated). `npx tsc --noEmit` → 0. `pnpm lint` → 0.
- [ ] **Step 2:** Add a `docs/updates.d/` fragment in plain language: extra connections beyond your plan are a $5/mo add-on (or upgrade to Pro). Use "twist add-on"/"connection add-on" wording, never "automation slots". Skip if judged too internal.
- [ ] **Step 3: Commit.** `git commit -am "test(limits): full-suite guard for connection capacity; docs fragment"`

---

## Self-Review

**Spec coverage (Area 1 + the rev2 decision + trim policy):**
- Regular-beyond-pool → `addon_required` not a hard block, finite-pool plans (Free, Team-pool) → Task 2. ✅
- Generalized billable quantity `max(0, regular−pool)+addonRequired`, web/Stripe reconcile + purchase → Tasks 1, 3. ✅
- Server platform-agnostic; client offers add-on-or-Pro (web) / Pro-only (App Store) → server returns `addon_required`; offer UX is B7. ✅ (noted)
- Trim keep-oldest/trim-newest, both passes → Task 1. ✅
- Apple reconcile unaffected (no Stripe sub → no-op) → Task 3. ✅

**Deferred:** the client offer UI + the App-Store-vs-web gating of the connection-add-on-vs-Pro choice (B7); no Apple connection-capacity product (by design).

**Open nuance for B7 (flag, not B3):** whether an App-Store user's regular-beyond-pool may be fulfilled by an Apple add-on tier (mechanically possible since tiers drive `premium_connection_addons`) or is strictly Pro-only. B3's server returns `addon_required` either way; B7 decides the offer. Confirm with the user during B7.
