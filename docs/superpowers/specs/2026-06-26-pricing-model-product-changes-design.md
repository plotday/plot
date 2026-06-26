# Pricing model — product & billing changes

Date: 2026-06-26
Status: Draft design — for handoff to an implementing agent

## Summary

The marketing pricing page is being rewritten (see Spec A,
`2026-06-26-pricing-page-rewrite-design.md`) around a simplified model:

- **Plans:** Free / Pro / Team (**Core dropped**).
- **Connections:** à-la-carte. Each plan includes a base count; every connection
  beyond it is a flat **$5/mo connection add-on**. A few connectors
  (LinkedIn / Instagram / WhatsApp) **always require** an add-on.
- **Automations (twists):** a single **weighted capacity** replaces the old twist
  count *and* separate AI/token pricing. Plans include capacity (Free 1 · Pro 10
  · Team 10 per 50-connection block); a heavier automation consumes more slots;
  **+20 slots for $10/mo**; **AI cost is bundled into the slot weight.**
- **Built-in Plot assistant:** included on every plan, **consumes 0 capacity**,
  **no usage limit** on any plan.
- **AI cleanup:** remove separate AI/token billing, bring-your-own-API-key,
  choose-your-model, and the per-feature Free AI limits.

This spec designs the **product and billing changes** required to make that real.
It is meant to be handed to another agent to break into implementation plans.

## Terminology (user-facing vs. code)

- **"Automations"** is the user-facing term; the code/SDK term is **`twist`**.
  Keep code identifiers (`twist`, `twist_package`, etc.) — only copy uses
  "automation."
- Connections that always require an add-on are **never** called "premium" or
  "pro" in copy; the user-facing label is **"Add-on required."** The internal
  `twist.premium = true` flag is **retained** (renaming it is optional cleanup,
  out of scope) and never surfaced to users.

### Relationship to the independent-usage-based-add-ons work

This builds **on top of** the add-ons work
(`2026-06-25-independent-usage-based-add-ons-design.md`), specifically:

- **Plan 1 — server entitlement decoupling** (`2026-06-26-addons-1-server-entitlement-decoupling.md`): DONE.
- **Plan 2 — Stripe usage-synced billing** (`2026-06-26-addons-2-stripe-usage-synced-billing.md`): the standalone `stripe_addon_subscription_id` add-on subscription, reconciliation, webhook routing.
- **Plan 3 — Apple billing** (the design doc's "Billing — Apple" section): tiered `addon_1/2/3`.

The implementing agent **waits for that build to finish through Plan 3**, then
applies this spec. This spec **extends and in places supersedes** that design:

- Add-ons are **no longer add-on-required-only.** The same $5/mo "connection
  add-on" mechanism now also covers **regular connections beyond a plan's
  included pool** (capacity add-ons). The usage-synced quantity generalizes from
  "active add-on-required connections" to "active billable connection add-ons"
  (see below).
- The add-ons design's **"Site changes" → pricing page** section is **superseded
  by Spec A**. Its `upgrade.tsx` (checkout/account) and `apps/plot` purchase-UX
  changes ("the rest of Plan 4") remain in scope **here**.

## Goals

- One unified **connection add-on** ($5/mo) that covers both (a) regular
  connections beyond the included pool and (b) always-required connectors —
  usage-synced on Stripe, tiered on Apple.
- A **weighted automation-capacity** entitlement with per-automation multipliers,
  a +20-slot ($10/mo) pack, and AI cost folded into the weight (no token billing).
- The **built-in assistant** included everywhere at 0 capacity and **no usage
  limit**, replacing the per-feature Free AI limits.
- Remove BYOK / model choice / separate AI pricing from product and UI.
- **Drop Core**: plan limits, plan value, Stripe prices, and a migration path for
  existing Core subscribers.
- Finish the add-ons build's **Plan 4** client work (`apps/plot` purchase UX +
  `apps/site/upgrade.tsx`).

## Non-goals

- The marketing pricing page itself (Spec A).
- Changing the $5 connection-add-on price or the plan prices.
- Re-doing Plans 1–3 (assumed complete via the add-ons build).
- Renaming the `twist.premium` code flag.

---

## Area 1 — Connections: unify capacity + add-on-required

### Model

For a scope (personal user or team):

- **Included pool** = plan base of **regular** connections (Free 2, Pro ∞, Team
  50 per block). Composite connectors count once per account (one Google = Gmail
  + Calendar + Tasks; one Outlook = mail + calendar) — already handled by the
  connector model; verify the count treats them as one.
- **Billable connection add-ons** for a scope =
  `max(0, activeRegular − includedPool) + activeAddonRequired`.
  - On **Pro** (∞ pool) the first term is 0 → only add-on-required connectors bill.
  - On **Free** both terms can bill.
  - On **Team**, the included pool is the purchased 50-blocks; the team grows by
    adding another 50-block. Single capacity add-ons are **also available** (they
    must be, for add-on-required connectors) and may technically extend capacity,
    but blocks are the featured path and the pricing self-guides (50 × $5 = $250/mo
    vs. $124/mo for a block). Don't add bespoke Team-only single-add-on logic
    unless it's the simpler path.

### Server (`workers/api/src/utils/limits.ts` and billing)

- Plan 1 made the pool **exclude** add-on-required connectors and admit them by
  credit only. Extend `checkChannelConnectionLimit` so a **regular** connector
  beyond the included pool **also** requires a connection-add-on credit (instead
  of a hard `connection_limit` block) on plans with a finite pool (Free). The
  existing `addon_required` reason is reused; the app/server then provisions
  billing headroom (Stripe bump or Apple tier) exactly as for an add-on-required
  connector.
- Generalize the usage-synced **quantity** (Plan 2's reconciliation) from "active
  add-on-required connections" to the **billable connection add-ons** formula
  above. `premium_connection_addons` continues to store the entitled quantity
  (the name is now a slight misnomer — keep the column for compatibility;
  document it as "entitled connection add-ons").
- `selectConnectionsToTrim`: when the entitlement drops, trim **add-on**
  connections beyond the entitled count; never trim within the included pool.
  Trim policy (which add-ons go first) is an open question.

### Billing

- **Stripe (web/desktop/Android):** reuse the standalone add-on subscription from
  Plan 2; its quantity is the generalized billable-add-on count. No new
  subscription type needed — capacity add-ons and add-on-required connectors are
  the same $5 line.
- **Apple:** the tiered `addon_1/2/3` model already abstracts "number of add-on
  connections"; capacity add-ons fit the same tiers. Verify tier headroom logic
  treats a regular-beyond-pool enable the same as an add-on-required enable.

### Client (`apps/plot`) — see Area 5

Enabling a regular connection beyond the pool now follows the **same**
"ensure billing headroom, then enable" path as an add-on-required connector
(Plan 4 generalizes from add-on-required-only to any-billable-connection).

---

## Area 2 — Automations: weighted capacity + packs

### Model

- Each **automation (twist)** has a **weight (multiplier)**: 1, 2, 10, … New
  field (e.g. `twist_package.capacity_weight`, default 1), settable by Plot
  and/or the automation builder. AI-intensive automations get a higher weight;
  **the weight is how AI cost is recovered** (no per-token billing).
- A scope's **automation capacity** = plan base (**Free 1 · Pro 10 · Team 10 per
  50-block**) + purchased packs × 20.
- **Active capacity rule:** sum of weights of **enabled** automations ≤ capacity.
  Enabling one that would exceed capacity is blocked until the user frees slots
  (disable something) or buys a pack. No monthly reset.
- The **built-in Plot assistant** (`BUILTIN_TWIST_PACKAGE_ID`) has weight 0 / is
  excluded — it never consumes capacity.

### Server

- Replace `PLAN_LIMITS[...].twists` (a flat count) with a **capacity** number and
  a weighted check at the twist-enable path (mirrors the connection-limit check).
  Source the per-automation weight from the new column.
- Add an entitlement field for **purchased automation packs** (e.g.
  `automation_pack_count` on `user_subscription`/`team_subscription`), analogous
  to `premium_connection_addons`.
- Decide the enforcement point(s): twist install vs. enable. Recommend **enable**
  (matches "active capacity"). Pin call sites during planning.

### Billing

- **+20 slots for $10/mo.** Options:
  1. **User-managed quantity** (buy N packs; a stepper) — simplest; matches a
     capacity purchase. Recommended default.
  2. **Usage-synced** like connections (auto-provision a pack when you exceed) —
     more "usage-based" but capacity isn't a natural per-unit meter.
  **Open question** — recommend (1): explicit pack purchase, auto-prompted when an
  enable would exceed capacity.
- Stripe: a separate price (`automation_pack_monthly`, $10) on its own line/
  subscription, routed by metadata like the connection add-on sub. Apple: a new
  consumable/auto-renewable product or tier set — **confirm Apple modeling**
  (packs may need their own subscription group). **Open question.**

### Schema

- `twist_package.capacity_weight` (int, default 1) — and how it flows through
  twist instances and the twister SDK (`public/twister`) so builders can declare
  it. SDK change ⇒ changeset (per AGENTS.md).
- Pack entitlement column(s) on the subscription tables.

---

## Area 3 — Built-in assistant entitlement

- The built-in assistant is **included on all plans, 0 capacity, no usage
  limit** (Free included). It is the general-purpose helper, distinct from
  installed automations, and never consumes automation capacity.
- This removes the last Free-tier AI limit. The per-feature `FREE_AI_LIMITS`
  patchwork (`workers/api/src/utils/ai-limits.ts`, `state/user-ai-usage.ts`) is
  removed entirely in Area 4, with **no replacement cap**.
- If any abuse/fair-use protection is still wanted, it's an **internal,
  unpublished safeguard** — a product call, not a stated limit, and not part of
  this spec's promises.

---

## Area 4 — AI cleanup (remove BYOK / model choice / token pricing / Free limits)

Sweep and remove, across product + UI:

- **Per-feature Free AI limits**: `utils/ai-limits.ts` (`FREE_AI_LIMITS`) and the
  metering in `state/user-ai-usage.ts` — removed (no replacement, per Area 3).
- **Bring-your-own-API-key**: storage, settings UI, and any runtime path that
  uses user-supplied keys (`apps/plot` settings; `workers/api` AI tool /
  `twist/tools/ai`-style code; any `*_api_key` columns/secrets).
- **Choose-your-AI-model**: model-picker UI and per-user model config.
- **Separate AI/token pricing & budgets**: usage-metering for token billing, the
  "billed at cost / set budgets" surfaces.
- Keep only: the automation weight as the AI-cost mechanism (Area 2); the
  built-in assistant is simply included (Area 3).
- **Backwards compatibility:** any removed API fields/columns follow the
  expand→contract pattern (keep, stop reading, drop later); don't break older
  `apps/plot` clients. Inventory the exact surfaces during planning.

---

## Area 5 — Drop Core (plan + migration)

- `PlanKey` / `PLAN_LIMITS` (`limits.ts`): remove `core`. Update
  `apps/site/app/lib/plans.ts` mirror (Spec A removes the card; the numeric
  mirror is updated in this PR per the file's header note).
- `user_subscription.plan` (and team) value `'core'`: **migrate existing Core
  subscribers.** Decide the policy — **grandfather** (keep paying Core price with
  Pro entitlements) vs. **migrate to Pro** (price change at renewal) vs.
  **honor until renewal then convert.** Coordinate Stripe price changes / proration
  and Apple. **Open question — product/commercial decision.**
- Retire Core Stripe price IDs and any Core-specific copy/paths. Check the trial
  flow (`workers/api/src/.../trial.ts`) for Core assumptions.
- **Ordering:** this lands **after** the add-ons build's Plans 1–3, which still
  reference `core` in tests/seeds; expect to update those when removing the value.

---

## Area 6 — Rest of the add-ons build's Plan 4 (client payment/subscription)

From the add-ons design doc's "Flutter app changes", "Site changes →
`upgrade.tsx`", and "Flutter web add-on entry" sections, **plus** the
generalizations above:

- **`apps/plot` gating**: remove the "add-ons require a paid plan" gate
  (`command/twist.dart`); `PremiumUsage.allowed` always true (defensive parse).
- **`apps/plot` purchase flow** (`command/upgrade.dart`, `api/iap_api.dart`,
  `api/upgrade_api.dart`): replace the 0–3 add-on quantity picker with the
  per-connection flow (App Store: auto-present next tier; non-App-Store: charge
  confirmation + first-card Checkout). **Generalize** so it triggers for **any**
  billable connection (regular-beyond-pool *and* add-on-required), not
  add-on-required only.
- **`apps/plot` connection enable path** (EditSource/SaveSource/sync enable):
  "ensure billing headroom, then enable" for billable connections; add the
  **automation capacity** equivalent for enabling automations (prompt to free a
  slot or buy a pack).
- **`apps/plot` usage display**: show included vs. add-on connections + monthly
  cost; show automation capacity used / available + pack cost. (No built-in
  assistant usage meter — there's no limit.)
- **Copy** per the add-ons design doc (sentence case): "doesn't count toward your
  plan's connection limit," etc., extended to the capacity-add-on framing; use
  "Add-on required," never "premium."
- **`apps/site/app/routes/upgrade.tsx`**: remove the add-on quantity stepper;
  informational add-on summary + card management; first add-on via Checkout-session
  card capture; add the automation-pack purchase surface.

---

## Affected areas (reference index)

- **Server:** `workers/api/src/utils/limits.ts` (connection + new automation
  capacity checks), `utils/ai-limits.ts` + `state/user-ai-usage.ts` (removal),
  `app/upgrade.ts` (connection add-on generalization + automation packs),
  `stripe/stripe.ts` (pack subscription routing), `apple/iap.ts` (capacity adds +
  packs), `twist/management.ts` / twist-enable path (capacity enforcement),
  `trial.ts` (Core removal), `libs/db/schema/**` + `libs/db/src/types.ts`
  (weight column, pack entitlement columns, plan-value migration).
- **SDK:** `public/twister` — per-automation `capacity_weight` declaration
  (+ changeset).
- **Flutter (`apps/plot`):** `command/twist.dart`, `command/upgrade.dart`,
  `api/iap_api.dart`, `api/upgrade_api.dart`, `widget/pro_badge.dart`, the
  connection + automation enable paths, settings (BYOK/model-choice removal),
  usage display.
- **Site (`apps/site`):** `app/routes/upgrade.tsx`, `app/lib/plans.ts` numeric
  mirror.

## Open questions (consolidated)

1. **Automation-pack billing** — user-managed quantity (recommended) vs.
   usage-synced; and Apple modeling for packs.
2. **Core migration policy** — grandfather vs. migrate-to-Pro vs.
   honor-until-renewal; Stripe/Apple proration handling.
3. **Automation weight authority** — who sets `capacity_weight` (Plot-curated vs.
   builder-declared vs. derived from declared AI usage), and how it's validated.
4. **Trim policy** when connection-add-on entitlement drops — add-on-required
   first vs. newest-first.
