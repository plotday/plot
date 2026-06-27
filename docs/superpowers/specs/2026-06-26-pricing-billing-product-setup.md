# Billing product setup — manual ops for the new pricing model

Date: 2026-06-26
Status: Front-loaded ops checklist (do these in the Stripe + App Store Connect
dashboards before the product/billing code lands)

Companion to the design specs:
- `2026-06-26-pricing-model-product-changes-design.md` (Spec B — product/billing)
- `2026-06-25-independent-usage-based-add-ons-design.md` (the add-ons build, Plans 1–3)
- `apps/plot/docs/storekit-testing.md` (the StoreKit / App Store Connect testing
  + pre-submission checklist — extend it with the new products below)

These are the **manual dashboard tasks only an account holder can do**. They have
real lead time (App Store products need *Ready to Submit* status, localized
metadata, and a review screenshot each), so they're pulled ahead of the code.

## Decisions locked (2026-06-26, rev 2)

- **Two billable add-on types, same usage-synced mechanism per platform:**
  **connection add-ons** ($5/mo) and **twist add-ons** (+20 twists,
  $10/mo). On **web/Stripe** both are usage-synced — enabling something over the
  limit prompts a charge confirmation and bumps a standalone subscription's
  quantity; dropping back below the level auto-credits and lowers the quantity.
  On **Apple** both are tiered auto-renewables (mutually exclusive, manual via
  StoreKit), each in its own subscription group.
- **Connection headroom — offer BOTH an add-on and a plan upgrade (web).** A Free
  user adding a *regular* connection beyond the included 2 gets **either a $5/mo
  connection add-on OR upgrade to Pro**. Team's 51st offers **a $5 add-on OR a
  50-block**. Always-required connectors (LinkedIn/IG/WhatsApp) always take a
  connection add-on. **On Apple, regular-beyond-pool offers Pro only** — Apple's
  `addon_1/2/3` tiers are reserved for the always-required connectors (exactly 3,
  so 3 tiers is right); Apple has no connection *capacity* add-on. ⇒ The
  generalized "billable = regular-beyond-pool + add-on-required" quantity is
  **web/Stripe only**; this reinstates spec Area 1's generalization for web.
- **Twist headroom — symmetric.** Over twist capacity, offer **a +20 twist add-on
  OR a plan upgrade** (Free→Pro raises base 1→10; Team adds 10 per 50-block). On
  Pro (web) a solo user just buys the +20 twist add-on.
- **Naming (decided 2026-06-26):** the paid add-on is **always a "twist add-on"**
  in product, code, and UI — never "automation slots/pack/capacity" (confusing).
  Code: `twist_addon` (Stripe/Apple/columns) and `twistCapacity` (the entitlement).
  The +20 unit is described to users as **"+20 twists."** "Automation" language is
  reserved for the **marketing pricing page only** (Spec A), used before users
  learn the word "twist." Apple/Stripe product display names must say "Twist
  add-on," not "automation."
- **Core is dropped with no subscriber migration** — no paying Core users exist,
  only Core 30-day trials, which become **30 days of unlimited connections on
  Free**. Retire the Core products once the trial rework ships.

---

## Stripe (web / desktop DMG / Android) — prices are matched by **lookup key**

The code resolves prices by `lookup_key` (e.g. `stripe.prices.list({ lookup_keys })`),
not hardcoded IDs. Create a **Product** + a recurring monthly **Price** and set the
Price's **lookup key** exactly as below. The code sets subscription `metadata` at
creation — you don't set it by hand.

### Create / verify

- [ ] **`addon_monthly`** — Connection add-on, **$5.00/mo**, recurring monthly,
      USD. *(Prerequisite for the add-ons build — Plan 2 throws "addon_monthly
      price not configured" without it. Verify it exists; create if not.)*
      Standalone subscription, `metadata.type = "addon"`, **usage-synced**
      `quantity` = active add-on-required connections **+ regular connections
      beyond the plan pool** (the generalized billable-connection-add-on count —
      web only).
- [ ] **`twist_addon_monthly`** — Twist add-on (+20 twists),
      **$10.00/mo**, recurring monthly, USD. **NEW.** Standalone subscription,
      `metadata.type = "twist_addon"` (set by code), **usage-synced** `quantity` =
      number of +20 blocks currently needed
      (`ceil((activeWeightSum − planBaseCapacity) / 20)`). Same enable-prompts-a-
      charge / disable-auto-credits flow as connection add-ons — **not** a
      user-managed stepper.

### Already exist (no action)

- `free_monthly` (usage tracker), `pro_monthly` / `pro_annual`,
  `team_monthly` / `team_annual`. Plan prices are unchanged ($25/$20, $124/$99).

### Retire (AFTER the trial rework ships — see Core below)

- [ ] **`core_monthly`** — stop offering for new purchases (archive the Price /
      Product). No paying subscribers to migrate. **Do not archive until** the
      trial flow no longer references `core_monthly` (today
      `createInitialTrialSubscription` in `workers/api/src/stripe/utils.ts` builds
      the new-user trial on `core_monthly`).
- [ ] `addon_annual` — retired by the add-ons build (add-ons are monthly-only).
      Archive if a Price exists.

### Trial rework note (decide in implementation, not a paid product)

The new-user trial becomes **Free + 30 days of unlimited connections**. Options
(no new *paid* product either way): reuse `free_monthly` + a `trial_ends_at`
grant, **or** a distinct **$0** `trial_monthly` price for clean reporting. The
welcome thread copy must be updated to match.

---

## App Store Connect (iOS / macOS) — product IDs must match the code **exactly**

Prefix is `day.plot.app.`. **Team is Stripe-only** — no Apple Team product. Each
Apple subscription needs: auto-renewable, **1-month** duration, a localized
display name + description, a **review screenshot**, and status ≥ *Ready to
Submit*; the **group** needs a localized display name.

### Apple price basis (all US base prices below)

Each Apple **add-on** US base price is the **cleanest `.99` point at or above a
15% markup over the web price** (`web × 1.15`). Tiers are a **flat per-unit `.99`**
(1×/2×/3× of the single-unit price), so per-unit is effectively flat — `.99`
rounding can nudge a larger tier up by a fraction of a cent, which we accept for
clean prices. The ~16–20% gross markup nets roughly **even with web**: Apple takes
15% (Small Business Program) on the Apple side, while web carries ~2.3% processing
fees, so the two land at about the same net. The app reads the live storefront
price from StoreKit, so these only anchor the US base; set them via ASC's
**"See Additional Prices"** picker.

**Plan exception:** `pro_monthly` is **not** marked up — it stays at **$24.99**
(see below). Pro's real price target is the annual rate, which Apple doesn't
offer, and $24.99 monthly already clears it.

### Already specced by the add-ons build — create now (prerequisite)

- [ ] **`day.plot.app.addon_1`** — 1 connection add-on, **$5.99/mo** (US base)
- [ ] **`day.plot.app.addon_2`** — 2 connection add-ons, **$11.99/mo**
- [ ] **`day.plot.app.addon_3`** — 3 connection add-ons, **$17.99/mo**
- [ ] All three in **one dedicated subscription group** (e.g. "Connection
      add-ons"), **mutually exclusive** (one active at a time — models "N
      add-ons" as tiers since auto-renewables can't be bought in quantity).
      Cap of 3 is intentional and final: there are exactly 3 add-on-required
      connectors. Code map: `IAP_ADDON_PRODUCT_TO_COUNT` (1/2/3).
      *(Flat $5.99/connection: $5.99 / $11.99 / $17.99.)*

### NEW — twist add-ons (create now)

- [ ] **`day.plot.app.twist_addon_1`** — +20 twists, **$11.99/mo** (US base)
- [ ] **`day.plot.app.twist_addon_2`** — +40 twists, **$23.99/mo**
- [ ] **`day.plot.app.twist_addon_3`** — +60 twists, **$35.99/mo**
- [ ] All three in a **new dedicated subscription group** (e.g. "Twist add-ons"),
      **mutually exclusive**. Code map (to add):
      `IAP_TWIST_ADDON_PRODUCT_TO_COUNT` → `twist_addon_N` grants `N` blocks
      (`N × 20` twists), written to the new `twist_addon_count` entitlement column.
      Same shape as the connection-add-on tiers (auto-present next tier on
      over-capacity enable; tier persists on disable → prompt to reduce in App
      Store settings).

Flat $11.99/block (web $10/block × 1.15 floor = $11.50; cleanest `.99` at/above):

| Tier | Twists | US base | per-block | markup vs. web |
|---|---|---|---|---|
| `twist_addon_1` | +20 | $11.99 | $11.99 | +19.9% |
| `twist_addon_2` | +40 | $23.99 | $11.995 | +19.95% |
| `twist_addon_3` | +60 | $35.99 | $11.997 | +19.97% |

You're open to fewer tiers / different quantities — if you'd rather ship
`twist_addon_1` only for v1 and add `_2/_3` later, that's a clean subset (the
code map just lists fewer entries).

### Existing Apple plan price — unchanged

- [ ] **`day.plot.app.pro_monthly`** stays at **$24.99/mo** (no change). Pro's real
      price target is the **annual** rate ($20/mo billed yearly), which Apple
      doesn't offer; $24.99 monthly already clears that target, so we don't mark it
      up and avoid a price-increase consent flow for existing iOS Pro buyers.

### Retire (AFTER the trial rework + Core removal ships)

- [ ] **`day.plot.app.core_monthly`** — remove from sale (App Store can't delete a
      live subscription, but you can clear availability / stop new purchases).

### Not-a-product prerequisites (already in storekit-testing.md)

- App Store Server Notifications V2 → `https://<api-root>/hook/appstore`
  (Production + Sandbox).
- App Privacy labels include Purchases; EULA + Privacy Policy URL set.
- One review screenshot per new IAP.

---

## Suggested ordering

1. **Now (front-load, independent of code):** create `addon_monthly` +
   `twist_addon_monthly` (Stripe) and `addon_1/2/3` + `twist_addon_1/2/3` (Apple)
   with metadata/screenshots so they reach *Ready to Submit*.
2. **When the add-ons build merges:** verify `addon_monthly` / `addon_1/2/3` end
   to end (the add-ons spec's testing strategy + storekit-testing.md levels B/C).
3. **When Spec B's capacity + twist-add-on code lands:** wire
   `twist_addon_monthly` / `twist_addon_1/2/3` and verify purchase →
   `twist_addon_count` entitlement; verify the generalized `addon_monthly`
   quantity now also covers regular-beyond-pool connections (web).
4. **When the trial rework + Core removal lands:** archive `core_monthly`
   (Stripe) and remove `day.plot.app.core_monthly` from sale.
