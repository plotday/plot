# Add-on consent + charge-on-enable — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a connection add-on's charge a consequence of the connection actually enabling (web/Stripe), with explicit consent captured before authorization — so abandoning the flow never charges.

**Architecture:** Add a consent-gated **reconcile-up on enable** symmetric with the existing reconcile-down on disable. The connection-enable handlers accept a `consentAddon` flag; when enabling a billable connection with consent + a card on file, the server provisions the add-on credit (the charge) and enables; with consent but no card it returns `needs_card` (client captures a card via a $0 Stripe **setup** session, then retries); without consent it returns today's `addon_required`. The Flutter client shows one consent gate before the auth CTA for both premium and regular-beyond-pool connectors.

**Tech Stack:** Cloudflare Workers (Hono, Kysely, Stripe), Flutter (Bloc, forui), Vitest (DB-backed), React Router (apps/site).

## Global Constraints

- **Naming:** "connection add-on" ($5/mo). NEVER "automation" in code/UI.
- **Platform split:** web/DMG/Android (Stripe) = charge-on-enable; App Store (StoreKit) = purchase sheet before auth, charge at purchase (Apple constraint — unchanged here).
- **No schema migration:** all columns exist (`premium_connection_addons`, `stripe_addon_subscription_id`).
- **Back-compat:** `consentAddon` is a new OPTIONAL request field; absent → server returns `addon_required` exactly as today. The legacy `POST /upgrade/addons/purchase` and `POST /upgrade/addons` endpoints are unchanged.
- **DB:** worktree DB only. `bash scripts/worktree-db` first (no migration, but the Stripe/upgrade/limits tests are DB-backed). Use the explicit `DATABASE_URL` from `.worktree-db` on every DB/test command.
- **Verify HEAD directly:** server `npx tsc --noEmit` (covers tests); Flutter `flutter analyze` (whole project incl. `test/`, faking `app.env` like CI). Harness diagnostics fire stale mid-edit — trust only the committed HEAD.
- **No `c.var.db` in `waitUntil`.** Errors in new catch blocks → `captureException`.

## File structure / responsibilities

- `workers/api/src/stripe/addons.ts` — billing primitives. **Add** `createAddonCardSetupSession` (setup-mode, $0). `reconcileAddonQuantityDown` is already down-only (verify).
- `workers/api/src/app/upgrade.ts` — `purchaseAddonCreditForScope` (existing; reused). **Add** `provisionAddonForConsentedEnable` (card-on-file → charge via `provisionAddonCredit` + DB write; no card → setup checkout URL).
- `workers/api/src/app/twist-integrations.ts` — the two enable handlers (`:1182` channel-enable, `:1423` activateDraft). **Modify** to read `consentAddon` and call the charge-on-enable helper when the gate returns `addon_required`.
- `workers/api/src/utils/limits.ts` — `checkChannelConnectionLimit` stays a pure gate (no change to its return contract).
- `apps/plot/lib/api/upgrade_api.dart`, `iap_api.dart`, `api/twist_api.dart` — thread `consentAddon` into the enable/activate calls; parse a `needs_card` response.
- `apps/plot/lib/command/upgrade.dart` — `ConnectionCapacityOffer` / `BuyAddonCommand` become consent + (setup) card capture, NOT an upfront charge.
- `apps/plot/lib/command/twist.dart` — unify at-limit entry points; gate the premium auth CTA; thread `consentAddon` through the enable/activate call sites.
- `apps/site/app/routes/upgrade.tsx` — handle `?addon=card_saved` return.

---

## Task 1: `createAddonCardSetupSession` — $0 setup-mode card capture (server)

**Files:**
- Modify: `workers/api/src/stripe/addons.ts`
- Test: `workers/api/src/stripe/addons.test.ts` (or the existing addons test file)

**Interfaces:**
- Produces: `createAddonCardSetupSession({ stripe, customerId, siteRoot, scopeMetadata }): Promise<string>` — a Stripe Checkout session in `mode: "setup"` that saves a card without charging; `success_url = ${siteRoot}/upgrade?addon=card_saved`, `cancel_url = ${siteRoot}/upgrade?addon=canceled`. Returns the session URL.

- [ ] **Step 1: Write the failing test** — assert a setup-mode session is created with the card_saved return URL and no line_items/charge.

```ts
it("createAddonCardSetupSession creates a $0 setup session with card_saved return", async () => {
  const created: any[] = [];
  const stripe = { checkout: { sessions: { create: async (a: any) => { created.push(a); return { url: "https://stripe/setup" }; } } } } as any;
  const url = await createAddonCardSetupSession({
    stripe, customerId: "cus_1", siteRoot: "https://plot.day", scopeMetadata: { user_id: "u1" },
  });
  expect(url).toBe("https://stripe/setup");
  expect(created[0].mode).toBe("setup");
  expect(created[0].line_items).toBeUndefined();
  expect(created[0].success_url).toBe("https://plot.day/upgrade?addon=card_saved");
});
```

- [ ] **Step 2: Run it, verify it fails** (`createAddonCardSetupSession is not a function`).
  Run: `cd workers/api && DATABASE_URL="$WT_DB" npx vitest run src/stripe/addons.test.ts -t "setup session"`
- [ ] **Step 3: Implement** in `addons.ts`:

```ts
export async function createAddonCardSetupSession(args: {
  stripe: Stripe; customerId: string; siteRoot: string; scopeMetadata: Record<string, string>;
}): Promise<string> {
  const { stripe, customerId, siteRoot, scopeMetadata } = args;
  const session = await stripe.checkout.sessions.create({
    customer: customerId,
    mode: "setup",
    success_url: `${siteRoot}/upgrade?addon=card_saved`,
    cancel_url: `${siteRoot}/upgrade?addon=canceled`,
    setup_intent_data: { metadata: { type: "addon_card", ...scopeMetadata } },
  });
  if (!session.url) throw new Error("Setup session has no url");
  return session.url;
}
```

- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Add a down-only regression test** for `reconcileAddonQuantityDown` (already down-only — lock it):

```ts
it("reconcileAddonQuantityDown never raises quantity above current", async () => {
  const stripe = stripeWithItemQuantity(1); // helper returning a sub whose item.quantity = 1
  const r = await reconcileAddonQuantityDown({ stripe, addonSubscriptionId: "sub_1", activeCount: 5 });
  expect(r.quantity).toBe(1); // unchanged, not raised to 5
});
```

- [ ] **Step 6: Commit** — `feat(addons): $0 setup-mode card-capture session + down-only reconcile lock`.

---

## Task 2: `provisionAddonForConsentedEnable` — charge-on-enable helper (server)

**Files:**
- Modify: `workers/api/src/app/upgrade.ts`
- Test: `workers/api/src/app/upgrade.test.ts`

**Interfaces:**
- Consumes: `provisionAddonCredit`, `customerHasPaymentMethod`, `createAddonCardSetupSession` (Task 1).
- Produces: `provisionAddonForConsentedEnable(args): Promise<{ ok: true; addons: number } | { ok: false; needsCard: true; checkout_url: string }>` where `args` mirrors `purchaseAddonCreditForScope`'s (`stripe, db, customerId, addonSubscriptionId, scopeMetadata, siteRoot, table, idVal, captureException`). Card on file → `provisionAddonCredit` (+1, the charge) + writes `premium_connection_addons`/`stripe_addon_subscription_id` to the scope row → `{ok:true, addons}`. No card → `{ok:false, needsCard:true, checkout_url}` from `createAddonCardSetupSession` (NO charge).

- [ ] **Step 1: Write failing tests** (two): card-on-file charges + writes DB; no-card returns needsCard + setup URL + does NOT call `provisionAddonCredit`.

```ts
it("consented enable with card on file provisions a credit and writes the row", async () => {
  // seed user_subscription with a customer + card-on-file stub; assert quantity 1 + DB updated
  const r = await provisionAddonForConsentedEnable({ ...cardOnFileArgs });
  expect(r).toEqual({ ok: true, addons: 1 });
  const row = await db.selectFrom("user_subscription").select(["premium_connection_addons","stripe_addon_subscription_id"]).where("user_id","=",U).executeTakeFirst();
  expect(row?.premium_connection_addons).toBe(1);
});
it("consented enable with no card returns needsCard + setup url and does not charge", async () => {
  const r = await provisionAddonForConsentedEnable({ ...noCardArgs });
  expect(r).toEqual({ ok: false, needsCard: true, checkout_url: expect.stringContaining("addon=card_saved") });
  expect(provisionCalled).toBe(false);
});
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** (mirror `purchaseAddonCreditForScope` lines 899–933, but the no-card branch uses the setup session):

```ts
export async function provisionAddonForConsentedEnable(args: {
  stripe: Stripe; db: Kysely<DB>; customerId: string; addonSubscriptionId: string | null;
  scopeMetadata: Record<string, string>; siteRoot: string;
  table: "user_subscription" | "team_subscription"; idVal: string;
  captureException: (e: unknown) => void;
}): Promise<{ ok: true; addons: number } | { ok: false; needsCard: true; checkout_url: string }> {
  const { stripe, db, customerId, addonSubscriptionId, scopeMetadata, siteRoot, table, idVal, captureException } = args;
  if (await customerHasPaymentMethod(stripe, customerId)) {
    const { subscriptionId, quantity } = await provisionAddonCredit({ stripe, customerId, addonSubscriptionId, scopeMetadata });
    try {
      const col = { premium_connection_addons: quantity, stripe_addon_subscription_id: subscriptionId };
      if (table === "team_subscription") await db.updateTable("team_subscription").set(col).where("team_id","=",idVal).execute();
      else await db.updateTable("user_subscription").set(col).where("user_id","=",idVal).execute();
    } catch (e) { captureException(e); }
    return { ok: true, addons: quantity };
  }
  const checkout_url = await createAddonCardSetupSession({ stripe, customerId, siteRoot, scopeMetadata });
  return { ok: false, needsCard: true, checkout_url };
}
```

- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** — `feat(upgrade): provisionAddonForConsentedEnable (charge on enable, setup-card fallback)`.

---

## Task 3: Charge-on-enable in the two enable handlers (server)

**Files:**
- Modify: `workers/api/src/app/twist-integrations.ts` (channel-enable `~:1182`, activateDraft `~:1423`)
- Test: `workers/api/src/app/twist-integrations.test.ts` (or a new `twist-integrations-consent.test.ts`)

**Interfaces:**
- Consumes: `checkChannelConnectionLimit` (gate), `provisionAddonForConsentedEnable` (Task 2). Reads `consentAddon?: boolean` from the request body.
- Behavior at each handler, after `const limitCheck = await checkChannelConnectionLimit(...)`:
  - `limitCheck.allowed` → proceed (unchanged).
  - `!allowed` and `error.reason === "addon_required"` and `consentAddon === true` → resolve scope (personal vs team) + `customerId` + `addonSubscriptionId` from the subscription row, call `provisionAddonForConsentedEnable`; `ok` → proceed to enable; `needsCard` → `return c.json({ reason: "needs_card", checkout_url }, 402)`.
  - otherwise → `return c.json(limitCheck.error.toJSON(), 403)` (unchanged: `addon_required` without consent, or `plan_limit_exceeded`).

- [ ] **Step 1: Write failing DB-backed tests** (channel-enable handler), four cases:

```ts
// (a) consent + card on file → 200 enabled + premium_connection_addons incremented
// (b) consent + no card → 402 { reason:"needs_card", checkout_url }
// (c) no consent, billable → 403 addon_required, quantity unchanged
// (d) abandon == case (c): never enabled, premium_connection_addons unchanged (no charge)
```

(Seed a Free user at/over pool, or a premium connector; stub Stripe `customerHasPaymentMethod` + `subscriptions`.)

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** — read `consentAddon` from the parsed body at both handlers and insert the branch between the gate and the enable call:

```ts
if (!limitCheck.allowed) {
  if (limitCheck.error.reason === "addon_required" && body.consentAddon === true) {
    const scope = await resolveAddonScope(c.var.db, c.var.user.id, twistInstanceId); // {customerId, addonSubscriptionId, table, idVal, scopeMetadata}
    if (!scope.customerId) return c.json(limitCheck.error.toJSON(), 403);
    const res = await provisionAddonForConsentedEnable({
      stripe: createStripeClient(c.env.STRIPE_SECRET_KEY), db: c.var.db,
      customerId: scope.customerId, addonSubscriptionId: scope.addonSubscriptionId,
      scopeMetadata: scope.scopeMetadata, siteRoot: c.env.SITE_ROOT || "https://plot.day",
      table: scope.table, idVal: scope.idVal, captureException: (e) => c.var.tracker.captureException(e),
    });
    if (!res.ok) return c.json({ reason: "needs_card", checkout_url: res.checkout_url }, 402);
    // fall through to enable
  } else {
    return c.json(limitCheck.error.toJSON(), 403);
  }
}
```

(Factor `resolveAddonScope` as a small local helper; for personal it reads `user_subscription` (`stripe_customer_id`, `stripe_addon_subscription_id`) with `scopeMetadata = { user_id }`, `table="user_subscription"`, `idVal=userId`; team mirrors with admin-gating already enforced upstream.)

- [ ] **Step 4: Run, verify pass; `npx tsc --noEmit` clean.**
- [ ] **Step 5: Apply the identical branch to the activateDraft handler (`~:1423`)** and add one test that the premium/hosted-auth activate path charges on consent. Run.
- [ ] **Step 6: Commit** — `feat(connections): charge connection add-on on consented enable; needs_card when no card`.

---

## Task 4: Flutter API plumbing — `consentAddon` + `needs_card` (client)

**Files:**
- Modify: `apps/plot/lib/api/twist_api.dart` (enable channel + activateDraft calls), `apps/plot/lib/api/api_exception.dart` (parse `needs_card` + `checkout_url`), `apps/plot/lib/api/upgrade_api.dart` (card-setup launch helper if needed)
- Test: `apps/plot/test/api/api_exception_test.dart`

**Interfaces:**
- Produces: `TwistApi.enableChannel(..., {bool consentAddon = false})` and `TwistApi.activateDraft(..., {bool consentAddon = false})` — add `consentAddon` to the request body when true. `ApiException` gains `bool get needsCard` (status 402 + `reason == "needs_card"`) and `String? get checkoutUrl`.

- [ ] **Step 1: Failing test** — `ApiException` from a 402 `{reason:"needs_card", checkout_url:"..."}` exposes `needsCard == true` and `checkoutUrl`.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** the `consentAddon` body field on both API calls + the `needsCard`/`checkoutUrl` getters (mirror the existing `isAddonRequired`/`candidateWeight` parsing in `api_exception.dart`).
- [ ] **Step 4: Run; `flutter analyze` (the two files) clean.**
- [ ] **Step 5: Commit** — `feat(app): plumb consentAddon + needs_card through the connection-enable API`.

---

## Task 5: Consent before authorization — unify the gate (client)

**Files:**
- Modify: `apps/plot/lib/command/upgrade.dart` (`ConnectionCapacityOffer`, `BuyAddonCommand`), `apps/plot/lib/command/twist.dart` (`_connectionAtLimitCommand` callers `~:1474/2164/2266/2411/2515/3378/4341`, the premium gate, the activate/enable call sites)
- Test: `flutter analyze` (behavioral verify is run-app / device — note in plan; no widget test for the redirect flow).

**Interfaces:**
- `BuyAddonCommand` becomes **consent + ensure-card**, not an upfront charge: show the disclosure consent; then trigger the connection enable with `consentAddon: true`. On `needsCard` → launch `checkoutUrl` (setup session) and tell the user "card saved — connect to finish"; the actual charge happens on the next enable. It no longer calls `purchaseAddon` (the prepaid endpoint) on the primary path.
- `ConnectionCapacityOffer` (regular-beyond-pool, web) keeps the add-on **OR** Pro choice; the add-on branch routes to the consent path above.
- Premium connectors: run the consent gate **before** the "Continue with X" auth CTA (gate the CTA), not after `activateDraft`.
- Replace `_connectionAtLimitCommand()` (upgrade-only) at the **billable** proactive sites with the consent gate (`ConnectionCapacityOffer` for regular; the premium consent for premium). Keep `_connectionAtLimitCommand` only for the genuine plan-limit (App Store regular-beyond-pool → Pro-only) case.

- [ ] **Step 1:** Reorder the premium add-source flow so the consent gate precedes the auth CTA (gate `_ActivateNoProviderSource`'s "Continue with LinkedIn" behind the premium consent when `usage` shows it's billable). Thread `consentAddon: true` into the `activateDraft`/`enableChannel` call that follows consent.
- [ ] **Step 2:** Point the billable proactive `_connectionAtLimitCommand` call sites at `ConnectionCapacityOffer(isPremium:…)` instead; keep the reactive `addon_required` 403 handlers (`:3845/:4332`) routing to the same gate (safety net) and add `needsCard` handling there (launch `checkoutUrl`, then "connect again").
- [ ] **Step 3:** `BuyAddonCommand`: drop the upfront `purchaseAddon` charge on the primary path; instead confirm consent (keep the 3.1.2 disclosure for App Store) and let the subsequent enable carry `consentAddon`. App Store path unchanged (StoreKit purchase before auth).
- [ ] **Step 4:** `flutter analyze` whole project (fake `app.env`) → clean.
- [ ] **Step 5: Commit** — `feat(app): consent before authorization; charge on enable for connection add-ons`.

---

## Task 6: Site — `?addon=card_saved` return (apps/site)

**Files:**
- Modify: `apps/site/app/routes/upgrade.tsx`

- [ ] **Step 1:** Add a green alert for `addonReturn === "card_saved"`: "Card saved — return to Plot and connect to finish." (Parallel to the existing `addon=success` handling.)
- [ ] **Step 2:** `cd apps/site && pnpm lint` → clean.
- [ ] **Step 3: Commit** — `feat(site): handle ?addon=card_saved return on the upgrade page`.

---

## Task 7: Finalize

- [ ] `/finalize`: `pnpm lint` (workers/api, apps/site), `flutter analyze` whole project, backwards-compat (consentAddon optional; legacy endpoints intact), `captureException` on new catches, `docs/updates.d/` fragment ("You now see and approve a connection add-on's cost before connecting, and you're only billed once the connection is actually added"), `docs/features.md` add-on line tweak if needed.
- [ ] Full server suite **serially** (`npx vitest run --no-file-parallelism`) green; `flutter analyze` clean.
- [ ] Opus whole-branch review over the branch; fix findings.
- [ ] Open PR (base main). Body: the consent-before-auth + charge-on-enable model, the Apple constraint, back-compat (optional `consentAddon`, legacy endpoints kept). Standard attribution.

## Self-review notes

- **Spec coverage:** consent-before-auth (Task 5), charge-on-enable (Tasks 2–3), $0 setup card capture (Task 1), down-only reconcile (Task 1 — already true, locked by test), unify entry points (Task 5), site return (Task 6), Apple unchanged (Global Constraints). ✓
- **Type consistency:** `provisionAddonForConsentedEnable` return `{ok:true,addons} | {ok:false,needsCard:true,checkout_url}` used identically in Task 3; client `needsCard`/`checkoutUrl` (Task 4) consumed in Task 5. ✓
- **Ambiguity pinned:** the client billability check is a pre-flight estimate; the **server** gate (`checkChannelConnectionLimit` + `getBillableConnectionAddonCount`) is the source of truth and the reactive 403 is the safety net.
