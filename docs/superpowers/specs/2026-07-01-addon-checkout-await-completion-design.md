# Connection add-on checkout: wait for completion + fix coupon field

**Date:** 2026-07-01
**Status:** Design approved, ready for implementation plan
**Scope:** Flutter app (`apps/plot`) + one small API worker fix (`workers/api`)

## Problem

A comped Team user (100%-off coupon on the Team plan, personal Stripe customer
has no card) tried to add a premium **LinkedIn** connection add-on and hit two
problems:

1. **No coupon field.** The Stripe Checkout page opened for the add-on had no
   place to enter a promo code, so the user couldn't redeem a coupon.
2. **Confusing hand-off.** After tapping the "$5/month" CTA, the app returned to
   the "Set up LinkedIn" modal with no indication of what was happening, and
   *then* a browser tab opened separately. There was no in-app signal that
   checkout was in progress or that the user should finish it in the browser.

## Issue #1 — root cause: a skipped deploy, not a bug (no code change)

The coupon-checkout code is correct and merged. `createAddonCheckoutSession`
(`workers/api/src/stripe/addons.ts:117`) already sets `allow_promotion_codes:
true`, and Stripe's hosted Checkout renders a promo-code box when that flag is
set. Adaptive Pricing (the CAD/USD toggle on the page) is **not** incompatible
with promotion codes — Stripe's official Adaptive Pricing "Restrictions" list
excludes only prices whose local currency is already in `currency_options` and
`capture_method: manual`; it says nothing about coupons or
`allow_promotion_codes`.

Why the field was missing: **#531's "Deploy Production" run failed at the
`terraform apply` gate, which caused the "Deploy workers" job to be *skipped*.**
No worker-touching commit has deployed since, so the production `api` worker is
still running a pre-#531 build without `allow_promotion_codes`. Verified from CI:

- #531 (`da5c7d356`) merged 2026-06-30.
- Its Deploy Production run (`28492485532`) shows `failure Apply infrastructure /
  terraform apply` and `skipped Deploy workers`.
- The next successful Deploy Production run (`c80b3ab01`, 13:24 UTC 2026-07-01)
  shows `skipped Deploy workers` (that job only runs on worker changes).

Terraform now applies cleanly (the later run's terraform step passed), so this
was a one-off gate failure.

**Resolution (operational, not code):** re-run a production worker deploy on
`main` (e.g. re-run the **Deploy Production** workflow with the Deploy workers
option, or `gh workflow run "Deploy Production" --ref main`). Once the `api`
worker redeploys, `allow_promotion_codes` goes live and the promo-code box
renders; the comped user can enter their coupon there. **Verify** by re-opening
the add-on checkout and confirming the "Add promotion code" affordance appears.

No app or server code changes are required for issue #1. It is documented here
only so the fix isn't mistaken for a code change.

## Issue #2 — wait for checkout completion (the code work)

### Current behaviour

For a user **with** a card on file the add-on is charged inline and the flow
proceeds — no browser. Only the **no-card** path detours to Stripe Checkout, and
today every add-on checkout-launch site does the same thing: launch the browser,
show a one-shot toast, and return `CommandSkipped` — which dismisses back to the
setup modal *before/while* the browser opens. Nothing in the app reflects that a
checkout is in progress, and nothing auto-continues when it completes.

### Desired behaviour

After the user confirms and we launch Stripe Checkout, the app **stays in an
in-app "waiting" state** ("Complete checkout in your browser to add the
connection." + spinner) until either:

- **Completion is detected** → dismiss the waiting state and continue the
  original action (connect the LinkedIn account / install the twist), or
- **The user backs out** (the modal's built-in back/Esc/tap-scrim) → dismiss and
  cancel, equivalent to abandoning today.

There is **no explicit Cancel button** — the `Modal` framework's back/Esc/scrim
dismissal is the cancel affordance.

### Detecting completion via the subscription sync (no polling)

Completion is detected from **subscription state**, driven by the existing
websocket push, **not** by timed polling.

`SubscriptionService` already:
- refreshes when `Store.onSubscriptionChanged` fires (a `subscription` table
  broadcast over the sync websocket), exposing state via a `ValueNotifier`
  (`SubscriptionSnapshot`), and
- refreshes on `AppLifecycleState.resumed`
  (`subscription_service.dart:150-159`) — which fires when the user switches
  back from the browser to the app.

**Gap to close (server):** when an add-on subscription is provisioned, the API
does **not** currently emit the `subscription` broadcast. In
`handleSubscriptionUpdate` (`workers/api/src/stripe/stripe.ts:249`), the add-on
branch writes `premium_connection_addons` and `return`s early (line 279) *before*
reaching `notifySubscriptionChange` (only the plan path calls it, ~516). The
twist-addon branch (line 282) has the same early return. As a result the client's
usage view goes stale after any add-on change until a manual refresh/resume —
a small latent bug independent of this feature.

**Fix:** call `notifySubscriptionChange` at the end of the add-on and
twist-addon branches, covering both personal and team scope (reuse the existing
`notifySubscriptionChange` + `getOrgMemberUserIds` pattern used by the plan
path). Then the client is pushed the moment provisioning lands.

With that fix, detection is: **push → `SubscriptionService.notifier` updates →
waiting state re-evaluates its completion predicate.** The `resumed` refresh
remains as a belt-and-suspenders backup (covers any missed push, e.g. app was
backgrounded on mobile).

### Architecture

**One shared helper** replaces the duplicated *launch → toast → CommandSkipped*
logic at all three add-on checkout-launch sites. Proposed shape (final name/API
in the implementation plan):

```
Future<CommandReturn> launchCheckoutAndAwait(
  BuildContext context, {
  required String url,               // Stripe Checkout / setup URL
  required String waitingMessage,    // e.g. "Complete checkout in your browser…"
  required bool Function(SubscriptionSnapshot) isComplete, // per-site predicate
  required Future<CommandReturn> Function() onComplete,     // what to do next
});
```

Behaviour:
1. Capture the baseline needed by `isComplete` (each site closes over its own
   baseline, e.g. the scope's current `purchased` count).
2. `launchUrl(url, LaunchMode.externalApplication)`.
3. Show a **waiting Modal** (via the project `Modal` framework, keyboard/back
   navigable, no Cancel button) with `waitingMessage` + spinner.
4. Listen to `SubscriptionService.instance.notifier`. On each update (push- or
   resume-driven), evaluate `isComplete(snapshot)`.
5. On `isComplete` → dismiss the waiting Modal and return `await onComplete()`.
6. On user dismissal (back/Esc/scrim) → return `CommandSkipped`.
7. Safety cap: a generous upper bound (e.g. ~10 min) after which the waiting
   Modal auto-dismisses to `CommandSkipped` so it can't hang forever if the user
   never returns. (Not surfaced as a visible timer.)

**Per-site wiring:**

| Site | File / entry | `isComplete` predicate | `onComplete` |
|------|--------------|------------------------|--------------|
| Connection add-on purchase | `BuyAddonCommand._consent`, `command/upgrade.dart:~236` | scope `premium.purchased > baseline` | `CommandAddonConsented` (caller retries enable → connects) |
| Twist add-on purchase | `BuyTwistAddonCommand`, `command/upgrade.dart:~580` | `personal.twistAddonCount > baseline` | `CommandDone` (caller proceeds to install) |
| Connection add-on needs-card ($0 setup) | `_handleNeedsCard`, `command/twist.dart:~955` | card-on-file becomes true | re-attempt the enable so the connection proceeds |

Scope resolution (personal vs. team) uses the same `teamId`/owner the call site
already has; the connection-add-on predicate reads
`usage.personal.premium` or the matching `usage.teams[…].premium` for the scope.

### Open implementation detail (resolve during planning, not a blocker)

- **Needs-card ($0 setup) completion signal.** Sites #1/#2 key off a
  subscription-count increment that the push already carries. Site #3 only
  captures a card; there may be no client-visible "has payment method" flag in
  `UsageData`/`SubscriptionInfo` today. Options, to decide in the plan:
  (a) expose a `hasPaymentMethod` boolean on the usage/subscription payload and
  key the predicate + push off it; or (b) on return, re-attempt the enable
  (which now finds the card and charges) and treat the resulting count increment
  as completion. Also confirm whether this path is still reachable after #531
  consolidated the no-card connection-add-on path onto coupon-or-card Checkout —
  if it is effectively dead for connection add-ons, site #3 may reduce to the
  twist paths only.

### Edge cases

- **Abandon checkout** (close the Stripe tab without paying): user backs out of
  the waiting Modal → `CommandSkipped`; nothing charged. The server add-on
  provisioning is idempotent, so a later re-attempt reuses any spare credit.
- **Webhook lag** after completion: the push fires when provisioning lands;
  until then the waiting Modal stays up. The `resumed` refresh also re-checks.
- **App backgrounded** during browser checkout (mobile): `resumed` triggers a
  refresh on return, re-evaluating the predicate.
- **Double action / idempotency**: server enable/charge is already idempotent.
- **Card-on-file users**: unchanged — never see the browser or the waiting
  Modal.

## Testing

- **Server:** unit test that `handleSubscriptionUpdate` emits
  `notifySubscriptionChange` for an add-on subscription (personal and team) and
  for a twist-addon subscription; keep the existing plan-path assertions green.
- **Client:** widget/command tests for the shared helper — completion via a
  `SubscriptionService.notifier` update that satisfies the predicate returns
  `onComplete`; modal dismissal returns `CommandSkipped`; the safety cap
  dismisses to `CommandSkipped`. Verify each of the three sites wires its
  predicate/`onComplete` correctly.
- **Manual:** with a no-card scope, confirm the waiting state appears, that
  returning from a completed checkout auto-continues to the connection/twist,
  and that backing out cancels cleanly.

## Out of scope

- Issue #1 beyond documenting the deploy re-run + verification.
- Non-add-on `launchUrl` sites (plan upgrade, manage-billing portal, Terms /
  Privacy links).
- Changing the pre-launch disclosure/confirm copy (the waiting state is the
  fix; the confirm modal is unchanged).
- App Store (StoreKit) purchase flow — it completes in-app already and never
  opens a browser checkout.
