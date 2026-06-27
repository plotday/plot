# Independent, usage-based connection add-ons

Date: 2026-06-25
Status: Approved design — ready for implementation plan

## Summary

Connection add-ons today are coupled to plans in two ways: an add-on connection
**counts toward the plan's connection pool** *and* it **requires a paid plan**
(`addonsAllowed` is false on Free). That coupling produces inconsistencies and
purchase-clarity problems (e.g. buying an add-on during a Core free trial, then
being surprised a plan is needed when the trial ends).

This change makes connection add-ons **completely independent of plans** and
**usage-based**:

- An add-on provides its connection, and that connection **does not count toward
  the plan's connection limit** on any plan (Free / Core / Team).
- **No plan includes add-ons.** They can be purchased on any plan, including
  Free. There is nothing to gate and nothing to explain.
- The amount billed tracks **actual active add-on connections** — users do not
  manage a count. Enabling an add-on connector is the purchase; disabling it
  stops the charge.

Pricing is unchanged: **$5/mo per add-on on web; Apple tiers $6.99 / $12.99 /
$17.99 for 1 / 2 / 3**.

## Goals

- Add-on connections never consume a plan connection slot, on any plan.
- Add-ons are purchasable regardless of plan (including Free) with no gating.
- Billing follows usage: you pay only for add-on connections that are currently
  active; no pre-purchased credits to manage.
- On platforms we control (web, desktop DMG, Android via Stripe), once a payment
  method is on file, enabling/disabling add-on connections adjusts billing
  automatically with **no trip to the web** to "bump a count."
- On the App Store, get as close to usage-based as Apple allows; where Apple
  forbids server-driven changes, the user makes the change themselves.

## Non-goals

- Changing add-on pricing.
- Changing which connectors are add-ons (`twist.premium = true`:
  LinkedIn / Instagram / WhatsApp, both the public connectors in `public/` and
  the private connectors in `connectors/`).
- Changing plan pricing, plan connection limits, or twist limits.
- Grandfathering existing add-on buyers (there are no paying add-on users yet —
  only comped accounts).

## Background: how add-ons work today (for reference)

- `twist.premium = true` marks add-on connectors.
- `user_subscription` / `team_subscription` hold `premium_connection_addons`
  (purchased credits), populated by Stripe / Apple billing
  (`libs/db/migrations/20260602133006_add_premium_connection_columns.sql`).
- **Pool counting includes add-ons** today: `getPersonalConnectionCount`
  (`workers/api/src/utils/limits.ts:147`) counts every enabled source connector,
  add-on or not.
- **Plan gating**: `PLAN_LIMITS[...].addonsAllowed` is false on Free
  (`limits.ts:34-39`); `checkChannelConnectionLimit` (`limits.ts:459`) rejects
  add-ons on Free with reason `addon_unavailable`, and rejects a paid user with
  no spare credit with `addon_required`, then *also* applies the pool check.
- **Web billing** rides the plan subscription: `POST /upgrade/addons`
  (`workers/api/src/app/upgrade.ts:600`) adds/updates an add-on **line item on
  the plan's Stripe subscription** (`buildAddonItemUpdate`,
  `ADDON_PRORATION_BEHAVIOR = "always_invoice"`). It requires a non-free plan and
  an existing `stripe_subscription_id`; a Free user (no plan sub) cannot buy.
- **Apple billing** already uses a **separate subscription group**
  (`addon_1/2/3`) and writes `premium_connection_addons` via
  `applyAppleAddonTransactionToUser` (`workers/api/src/apple/iap.ts`), using the
  `apple_addon_*` columns.
- **Flutter** gates in `command/twist.dart` (`_evaluatePremium`,
  `_premiumGateCommand`, `_addonNeedsPaidPlanCommand`) and manages a 0–3 quantity
  picker in `command/upgrade.dart` (`BuyAddonCommand`). `api/upgrade_api.dart`
  models `PremiumUsage { allowed, count, purchased }`.
- **Site** shows add-ons as a per-plan feature line and a quantity stepper
  (`apps/site/app/lib/plans.ts` `ADDON_PRICE`, `apps/site/app/routes/upgrade.tsx`).

## Core model

### Entitlement invariant (unchanged in shape, decoupled in meaning)

`active add-on connections ≤ entitled add-on count (premium_connection_addons)`.

What changes is **how the entitled count grows**, and that add-ons no longer
touch the plan pool:

- **Stripe (web / desktop DMG / Android):** the entitled count = the standalone
  add-on subscription's quantity, which the server keeps equal to the number of
  active add-on connections (usage-synced). Headroom is created **just in time**
  when a connection is enabled.
- **Apple (App Store):** the entitled count = the purchased tier (`addon_1/2/3`).
  Headroom is created by the **user** buying/upgrading a tier via StoreKit.

### Add-ons never count toward the plan pool

The connection pool (Free = 2, Core = 5, Pro/Team = ∞) counts **only
non-premium** connectors. An active add-on connection consumes **zero** plan
slots on every plan.

## Billing — Stripe (web, desktop DMG, Android): usage-synced

A **standalone monthly add-on subscription**, separate from the plan
subscription, scoped per user (personal) or per team.

- New nullable column **`stripe_addon_subscription_id`** on `user_subscription`
  and `team_subscription` stores its id. `premium_connection_addons` continues to
  hold the current quantity.
- The add-on subscription carries metadata `{ addon: true }` (or
  `metadata.type = "addon"`) so the webhook can route it independently of the
  plan subscription.
- `quantity` = number of **active add-on connections**, kept in lockstep by the
  server (see Reconciliation).
- Retire `addon_annual`; the standalone add-on subscription is always **monthly**
  (the only reason annual existed was to match an annual plan's interval, and we
  no longer ride the plan sub; we do not discount add-ons).

### Enable flow (non-App-Store)

1. User enables an add-on connector (`twist.premium = true`).
2. **Payment method on file** (from a prior plan purchase or a prior add-on):
   in-app confirmation ("This is a connection add-on — $5/mo, billed to your card
   on file, prorated"), then the server bumps the add-on subscription quantity by
   1 (off-session, prorated charge) and the connection is enabled. **No web
   trip.**
3. **No payment method** (e.g. a Free user who never paid): open a one-time
   Stripe Checkout (mode `subscription`, price `addon_monthly`, metadata
   `{ addon: true }`) to capture a card and create the add-on subscription at
   quantity 1. On success the connection is enabled. This is the only
   payment/web touch.

Ordering: ensure billing headroom **before** enabling. If the charge fails (incl.
SCA decline), do not enable; surface a retry/auth path.

### Disable / remove flow (non-App-Store)

- Disabling or removing an active add-on connection drops the add-on subscription
  quantity by 1, **immediately** (prorated credit to the customer balance). The
  user stops paying for what is no longer active.
- Removing the last add-on **cancels** the standalone add-on subscription.
- A small prorated credit may remain on the customer balance for a card-only user
  with no other subscription; this is acceptable and applies to any future
  invoice on that customer.

### Teams

Teams get their own standalone team add-on subscription on the team's Stripe
customer, usage-synced the same way. Because enabling an add-on connection
incurs **team** billing, enabling/creating team add-on connections is restricted
to **team admins** (this is a billing-authority gate, not a plan gate). Exact
member-vs-admin behavior is a plan-time detail; default to admin-gated to match
today's admin-managed team billing.

## Billing — Apple (App Store iOS / macOS): manual, friction-minimized

Mechanism is unchanged: tiered auto-renewable subscriptions `addon_1/2/3` in a
separate subscription group, one active at a time, cap 3. Apple does not allow
server-driven quantity changes or metered billing, so the user must initiate
every change.

- **Enable** an add-on connector: if there is a spare tier slot
  (`active < purchased`), enable immediately; otherwise **auto-present the
  StoreKit purchase for the next tier** (`addon_{active+1}`), and enable on
  success.
- **Disable**: the connection turns off, but the purchased tier remains (the user
  may briefly pay for an add-on they are not using). Prompt: "You're paying for a
  connection add-on you're not using — reduce it in App Store settings." The user
  downgrades the tier themselves (Apple defers downgrades to renewal anyway).
- `premium_connection_addons` continues to be driven by Apple add-on transactions
  via `applyAppleAddonTransactionToUser` and the `apple_addon_*` columns.

## Server changes (`workers/api`)

### `utils/limits.ts`

- `getPersonalConnectionCount` (`:147`) and `getTeamConnectionCount` (`:281`):
  **exclude** premium connectors (`tw.premium = false` / `is not true`) so the
  pool counts non-add-on connections only.
- Delete `PlanLimits.addonsAllowed` and remove it from `PLAN_LIMITS` (`:27-39`).
- Remove `PlanLimitReason` value `addon_unavailable` (`:55-60`); keep
  `addon_required` (used to signal "need more add-on headroom").
- `checkChannelConnectionLimit` (`:459`): for an add-on connector
  (`premium = true`), check **only** `active < premium_connection_addons`
  (entitled). Do **not** apply the plan pool check and do **not** require a paid
  plan. Return `addon_required` when headroom must be created (the app/server then
  fulfills: Stripe bump or Apple tier purchase). For non-premium connectors, the
  pool check applies as before, now against the add-on-free count.
- `selectConnectionsToTrim` (`:248`): add-ons are **never** trimmed to satisfy the
  pool. Trim add-ons **only** when the entitled count drops (add-on subscription
  cancel/downgrade). The pool pass runs over **non-premium** survivors only.
  Remove the `addonsAllowed` input.

### Billing reconciliation (new)

A server function that, for a Stripe-billed scope, sets the standalone add-on
subscription quantity to the current count of active add-on connections
(`getPersonalPremiumConnectionCount` / team equivalent) and updates
`premium_connection_addons`. Invoked from the **channel enable/disable path**
(the same flow that runs `checkChannelConnectionLimit` and `enableSync` /
`enableSyncBatch`, and on archive/delete of a premium connection). The exact call
sites are pinned during planning. No-op for Apple-billed scopes (Apple drives the
count via StoreKit).

### API endpoints (`app/upgrade.ts`)

- Replace the manual `POST /upgrade/addons` (`:600`) with:
  - **Create-add-on-checkout**: create a Checkout session to capture a card and
    create the standalone add-on subscription (first add-on for a card-less
    scope).
  - **Internal quantity sync**: called by the enable/disable path (not a
    user-facing "set the number" endpoint).
  - **Cancel-at-zero**: cancel the standalone add-on subscription when the last
    add-on connection is removed.
- Keep `buildAddonItemUpdate` semantics for quantity changes but apply them to the
  **standalone** add-on subscription rather than a line item on the plan sub.

### Stripe webhook (`stripe/stripe.ts`)

- `handleSubscriptionUpdate` (`:222`) and `parseSubscriptionItemQuantities`
  (`:205`): route by subscription metadata. An **add-on** subscription updates
  `premium_connection_addons` + `stripe_addon_subscription_id` + status, and must
  **not** touch plan fields; a **plan** subscription updates plan fields and must
  **not** clobber the add-on count.
- `handleSubscriptionDeleted`: an add-on subscription deletion sets
  `premium_connection_addons = 0` and clears `stripe_addon_subscription_id`
  (and triggers add-on trim).
- Preserve a cross-origin guard so a Stripe webhook never overwrites an
  Apple-driven add-on entitlement and vice versa (mirror the existing App Store
  guard at `stripe.ts:236-242`).

### Apple (`apple/iap.ts`)

- `applyAppleAddonTransactionToUser`: drop the "add-ons require a paid plan, which
  created the row" assumption from comments and behavior. A Free user already has
  a `user_subscription` row (created at account activation), so the in-place
  UPDATE works; confirm it does not depend on plan state.

### Schema (`libs/db/schema/`)

- Add nullable `stripe_addon_subscription_id` (text) to `user_subscription` and
  `team_subscription`. Generate the migration via `pnpm gen-migration` and commit
  the regenerated `libs/db/src/types.ts`.
- No change to `premium_connection_addons` or `apple_addon_*`.

## Flutter app changes (`apps/plot`)

- **Remove gating**: delete `_addonNeedsPaidPlanCommand` and the `blocked` branch
  in `_evaluatePremium` / `_premiumGateCommand` (`lib/command/twist.dart`).
  `PremiumUsage.allowed` / `isBlocked` (`lib/api/upgrade_api.dart`) become always
  allowed (keep the JSON field for backwards compatibility, parsed defensively).
- **Reframe `BuyAddonCommand`** (`lib/command/upgrade.dart`) from a 0–3 count
  picker to a per-connection flow:
  - **App Store**: enabling an add-on connector auto-presents the next tier when
    there's no spare slot; "manage/reduce" routes to App Store settings; surface
    the over-provisioned prompt.
  - **Non-App-Store**: enabling shows the charge confirmation and, if no card is
    on file, opens the one-time card-capture Checkout; the billed count follows
    the connections. Remove the manual quantity picker.
- **Copy** (sentence case, project convention):
  - `lib/widget/pro_badge.dart` doc/description: "counts as a regular connection"
    → "doesn't count toward your plan's connection limit."
  - `lib/command/upgrade.dart` disclosure (`:271`): "Each also counts as one of
    your plan connections." → "Each is billed separately and doesn't count toward
    your plan's connection limit."
  - Remove "Connection add-ons require a paid plan. Subscribe first…"
    (`twist.dart:907-909`).
- **Usage display**: the regular "X of N" count excludes add-ons (driven by the
  server count, which now excludes them); show active add-ons + monthly cost
  separately (`_usageSuffix` "Add-ons: …"); surface the Apple over-provisioned
  prompt.
- **Connection enable path** (EditSource / SaveSource / the sync enable flow):
  integrate the "ensure add-on billing headroom, then enable" step described
  above.

## Site changes (`apps/site`)

- `app/lib/plans.ts`: remove the per-plan "Connection add-ons $5/mo each" feature
  line; keep `ADDON_PRICE` for the dedicated section.
- `app/routes/pricing.tsx`:
  - Add a dedicated **Connection add-ons** section explaining they are
    independent, $5/mo each, billed separately, and **don't count toward your
    plan's connection limit**.
  - Add a **footnote on each plan's connection level** (e.g. "Up to 5
    connections"): *"A few connections require a separate connection add-on,
    billed separately."* — so it's clear that add-on connectors (LinkedIn,
    Instagram, WhatsApp) aren't part of the included pool.
- `app/routes/upgrade.tsx`: remove the add-on quantity stepper; replace with an
  informational add-on summary (active add-ons + monthly cost) and card
  management. The first add-on uses the Checkout-session card capture.

## Flutter web add-on entry (`openWebUpgrade`)

`lib/command/upgrade.dart` `openWebUpgrade` currently routes all non-App-Store
add-on management to `${Env.siteRoot}/upgrade`. Under this design, non-App-Store
add-on quantity changes happen **in-app via the API** when a card is on file;
only the first card capture opens the web (Checkout). Update the command flow
accordingly.

## Migration / rollout

- **Low risk**: comped-only today. Excluding add-ons from the pool can only
  *reduce* counts, so no user is pushed over a limit and no forced trim results
  from the semantic flip.
- **Entitlement recompute is automatic** (query-logic change); no backfill of
  `premium_connection_addons` is required.
- **`addon_annual` retirement**: no annual add-on line items are expected in
  production; handle any that exist gracefully (treat as monthly-equivalent or
  drain).
- **Existing Stripe add-on line-items-on-plan-subs**: migrate to standalone
  add-on subscriptions, or drain (likely none in production beyond test data).
- **Apple** add-on entitlements are unaffected.

## Backwards compatibility

- `PremiumUsage` JSON keeps the `allowed` field (defensive parse, effectively
  always true) so older Flutter clients don't break.
- Server `/upgrade/usage` shape is preserved; `premium.allowed` may be reported
  as always true.
- The `premium_connection_addons` column and `apple_addon_*` columns are
  unchanged.

## Testing strategy

- `workers/api` `limits.test.ts`: pool count excludes add-ons; add-on enable
  allowed on Free; `selectConnectionsToTrim` never trims add-ons for the pool and
  trims them when entitlement drops; `addon_unavailable` removed.
- Stripe: standalone add-on subscription create / quantity sync / cancel-at-zero;
  webhook routing by metadata (add-on vs plan, no cross-clobber); first-card
  Checkout.
- Apple `apple/iap.test.ts`: `applyAppleAddonTransactionToUser` works for a
  plan-less user; tier-present-on-enable behavior.
- Flutter: gating removed; enable confirmation + card-capture path; copy strings;
  usage display excludes add-ons.
- Site: pricing page add-on section + plan footnote; upgrade page has no stepper.

## Risks & open questions

- **Off-session SCA**: a quantity-bump charge may require re-authentication for
  some cards; provide a fallback auth path and don't enable on failure.
- **Atomicity**: "ensure billing headroom, then enable" must not enable an
  unpaid connection if the charge fails.
- **Apple over-provisioning**: users can pay for a tier above their active count
  until they downgrade; mitigated by prompts, not eliminated (Apple constraint).
- **Anti-steering**: the in-app card-capture / API quantity path is for
  non-App-Store builds only; App Store builds must use StoreKit.
- **Team add-on authority**: default to admin-gated enabling of team add-on
  connections; confirm during planning.

## Affected files (reference index)

- Server: `workers/api/src/utils/limits.ts`, `workers/api/src/app/upgrade.ts`,
  `workers/api/src/stripe/stripe.ts`, `workers/api/src/apple/iap.ts`,
  `libs/db/schema/**`, `libs/db/src/types.ts`.
- Flutter: `apps/plot/lib/command/twist.dart`,
  `apps/plot/lib/command/upgrade.dart`, `apps/plot/lib/api/upgrade_api.dart`,
  `apps/plot/lib/api/iap_api.dart`, `apps/plot/lib/widget/pro_badge.dart`, and the
  connection enable path (EditSource / SaveSource / sync enable).
- Site: `apps/site/app/lib/plans.ts`, `apps/site/app/routes/pricing.tsx`,
  `apps/site/app/routes/upgrade.tsx`.
