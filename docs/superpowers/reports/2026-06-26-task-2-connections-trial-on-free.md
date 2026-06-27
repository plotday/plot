# Task 2 Report: 30-day connections trial on Free (replaces Core trial)

## Changes (A–D)

### A. `workers/api/src/stripe/utils.ts` — `createInitialTrialSubscription`
- Lookup key: `"core_monthly"` → `"free_monthly"`
- Error message updated to reference `free_monthly`
- Subscription metadata: `plan: "core"` → `plan: "free"`
- `trial_period_days: 30`, `payment_settings`, and `trial_settings.end_behavior.missing_payment_method: "cancel"` unchanged

### B. `workers/api/src/app/account.ts` — activation insert (~L505)
- Comment: `"30-day Core trial (reverse trial)"` → `"30-day connections trial on Free"`
- Inserted `plan: "core"` → `plan: "free"`
- `trial_ends_at = now()+30d`, `status: "active"`, and surrounding logic unchanged

### C. `workers/api/src/utils/trial.ts`
- **`expireTrial` guard**: `if (!sub || sub.plan !== "core" || !sub.trial_ends_at)` → `if (!sub || !sub.trial_ends_at)` — trial is now identified solely by `trial_ends_at`
- **Select**: dropped `"plan"` from `.select(["plan", "trial_ends_at"])` → `.select(["trial_ends_at"])` since plan is no longer used in the guard
- **Removed redundant plan UPDATE**: the `UPDATE user_subscription SET plan='free'` block was removed (user is already on Free during the trial; `enforcePersonalPlanLimits` with `PLAN_LIMITS.free` still runs)
- **Expiry note copy**: `"Your Core trial has ended and you're now on the Free plan."` → `"Your 30-day trial has ended. You're on the Free plan with up to 2 connections — add a $5/mo connection add-on or upgrade to Pro to keep more."`
- **Reminder copy** (`buildReminderContent`): `"Your free Core trial ends in **N days**. Upgrade to keep all your connections and twists."` → `"Your 30-day connections trial ends in **N days**. Upgrade to keep all your connections."`

### D. `workers/api/src/stripe/stripe.ts` — trial detection (~L657)
- `if (subscription.metadata.plan === "core" || subscription.trial_end)` → `if (subscription.trial_end)` — dropped the `plan='core'` check; trial detection is now purely `subscription.trial_end`
- Updated nearby comment: `"expireTrial guards on plan='core' && trial_ends_at"` → `"expireTrial guards on trial_ends_at (plan is always 'free' during trial)"`

## Tests (TDD)

### New files
- `workers/api/src/stripe/utils.test.ts` — 4 tests for `createInitialTrialSubscription`:
  1. Looks up `free_monthly` price (not `core_monthly`) ✓
  2. Sets `metadata.plan = 'free'` (not 'core') ✓
  3. Keeps `trial_period_days: 30` + `missing_payment_method: 'cancel'` ✓
  4. Throws error mentioning `free_monthly` when price not found ✓

- `workers/api/src/utils/trial.test.ts` — 6 tests:
  - `buildReminderContent` copy contains no "Core", includes "trial ends in", includes upgrade link ✓
  - `expireTrial` no-ops when `trial_ends_at` is NULL (regardless of plan) ✓
  - `expireTrial` calls `enforcePersonalPlanLimits` when `trial_ends_at` is set on a Free user ✓
  - Plan column stays `'free'` after expiry (no spurious plan write) ✓

### Updated `stripe/stripe.test.ts`
- 2 new tests in new describe: `handleSubscriptionDeleted — trial detection uses trial_end (not plan='core')`:
  1. Calls `expireTrial` when `subscription.trial_end` is set ✓
  2. Does NOT call `expireTrial` when `subscription.trial_end` is null ✓

### Regression evidence
- All 932 tests pass; tsc exits 0; lint exits 0 (DB: 54333)
- The `plan='core'` seeds remaining in `stripe.test.ts` (app_store guard tests) are unrelated to trial behavior (testing Apple origin detection), left for Task 3 Core removal

## Stripe $0-trial-cancel assumption (FLAG FOR LIVE VERIFICATION)

The `free_monthly` price is a $0/month product. **Assumption**: Stripe fires `customer.subscription.deleted` at end of a `trialing` sub with `trial_settings.end_behavior.missing_payment_method: "cancel"` even when the underlying price is $0, as it does for paid-plan trials.

This is the mechanism the whole trial lifecycle depends on. If Stripe does NOT fire `deleted` for $0 trials with missing payment method (e.g. silently transitions to active at $0 instead), then:
- `expireTrial` is never called → no excess connections are trimmed
- The user retains unlimited connections forever on a $0 Free subscription

**Mitigation**: B5 Task 1's live entitlement check (`trial_ends_at > now()`) already gates the unlimited connection grant — once `trial_ends_at` passes, entitlement reverts to the standard Free pool of 2 via the live check, regardless of whether Stripe fires the deletion. The proactive archival (enforcePersonalPlanLimits) and in-app note are the only things missing if Stripe doesn't cancel the $0 sub. Should be verified against live Stripe test clock before shipping.

## Concerns
- None beyond the Stripe $0-trial-cancel assumption above.

## Report path
`.superpowers/sdd/task-2-report.md`
